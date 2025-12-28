import socket
import ssl
import ipaddress
import concurrent.futures
import sys
import os # 新增：用于检查文件存在

# --- 全局文件名定义 ---
CIDR_FILE = "全部ip段.txt "
VALID_IPS_FILE = "初筛ip.txt"
LOG_FILE = "response_log.txt"
# --------------------

def check_https_ip(ip, port=443, timeout=3):
    """
    检测 IP 是否为有效 HTTPS 节点。
    """
    # -------------------------------------------------
    # 配置区域 - 请根据你的实际需求修改这里
    # -------------------------------------------------
    target_host = "workers.uowo.de"  # 目标域名 (SNI)
    target_path = "/"                 # 访问路径
    expected_keyword = "workercheck"  # 必须包含的关键词
    # -------------------------------------------------

    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    
    try:
        sock = socket.create_connection((ip, port), timeout=timeout)
        with context.wrap_socket(sock, server_hostname=target_host) as ssock:
            request = (
                f"GET {target_path} HTTP/1.1\r\n"
                f"Host: {target_host}\r\n"
                f"User-Agent: Mozilla/5.0\r\n"
                f"Connection: close\r\n\r\n"
            )
            ssock.sendall(request.encode())
            
            # 使用更安全的循环接收数据，但为了快速检测，此处简化为一次接收
            data = ssock.recv(4096).decode('utf-8', errors='ignore')
            
            if "HTTP/1.1 200" in data and expected_keyword in data:
                return True, ip, data
            else:
                return False, ip, None
                
    except Exception:
        return False, ip, None

def read_cidr_list(filename):
    """
    从文件中读取 IP 段列表。
    """
    if not os.path.exists(filename):
        print(f"❌ 错误: 文件 '{filename}' 不存在。请创建该文件并每行输入一个 CIDR IP 段。")
        return []
    
    with open(filename, 'r') as f:
        # 去除空白行和行首行尾空格
        cidrs = [line.strip() for line in f if line.strip()]
    return cidrs

def scan_network(cidr_network, max_threads=300):
    print(f"\n--- 🚀 开始扫描网段: \033[94m{cidr_network}\033[0m ---")

    found_ips = []

    try:
        # 生成 IP 对象列表
        network = ipaddress.ip_network(cidr_network, strict=False)
        # 排除网络地址和广播地址，只扫描可用的主机地址
        ips_to_scan = list(network.hosts())
        total_ips = len(ips_to_scan)
        
        if total_ips == 0:
            print("警告: 网段中没有可扫描的 IP 地址。")
            return []

        if total_ips > 65536:
            print(f"⚠️ 警告: IP 数量庞大 ({total_ips})，初始化可能需要时间...")

        processed_count = 0 
        
        with concurrent.futures.ThreadPoolExecutor(max_workers=max_threads) as executor:
            # 提交所有任务
            future_to_ip = {executor.submit(check_https_ip, str(ip)): ip for ip in ips_to_scan}
            
            for future in concurrent.futures.as_completed(future_to_ip):
                processed_count += 1
                is_valid, ip, response_data = future.result()
                
                # --- 进度条逻辑 ---
                percentage = (processed_count / total_ips) * 100
                status_bar = f"\r[进度: {processed_count}/{total_ips} | {percentage:.1f}%] 当前网段发现: {len(found_ips)}"
                sys.stdout.write(status_bar)
                sys.stdout.flush()
                # -----------------
                
                if is_valid:
                    # 发现 IP 时，打印一个换行，避免和进度条冲突
                    sys.stdout.write('\n')
                    print(f"[+] 发现可用 IP: \033[92m{ip}\033[0m")
                    
                    found_ips.append(ip)
                    
                    # 写入优选IP文件
                    with open(VALID_IPS_FILE, "a") as f:
                        f.write(f"{ip}\n")
                        
                    # 写入响应日志文件
                    with open(LOG_FILE, "a", encoding='utf-8') as log_f:
                        log_f.write(f"={'='*20}\nIP: {ip}\nResponse:\n{response_data}\n{'='*20}\n\n")

            # 确保进度条完成后的最终换行
            sys.stdout.write('\n')
            
    except ValueError:
        print(f"\n❌ 错误: 无效的 IP 段格式: {cidr_network}")
    except KeyboardInterrupt:
        print("\n\n👋 扫描停止。")
    except Exception as e:
        print(f"\n\n🚨 发生未知错误: {e}")
        
    print(f"--- ✅ 网段 {cidr_network} 扫描完成。共发现 {len(found_ips)} 个有效 IP。---")
    return found_ips

if __name__ == "__main__":
    print(f"💡 脚本启动。将从 \033[93m{CIDR_FILE}\033[0m 读取 IP 段，结果将写入 \033[92m{VALID_IPS_FILE}\033[0m。")
    
    # 1. 读取所有 IP 段
    cidr_list = read_cidr_list(CIDR_FILE)
    
    if not cidr_list:
        sys.exit(1)

    print(f"🔍 成功读取 {len(cidr_list)} 个 IP 段进行扫描。")
    print("=" * 60)
    
    all_found_ips = []
    
    # 2. 循环扫描每个 IP 段
    for cidr in cidr_list:
        found = scan_network(cidr, max_threads=500)
        all_found_ips.extend(found)
    
    # 3. 最终总结
    print("\n" + "#" * 60)
    print(f"🎉 所有任务完成！")
    print(f"总共扫描了 {len(cidr_list)} 个网段。")
    print(f"最终在 \033[92m{VALID_IPS_FILE}\033[0m 中记录了 \033[92m{len(all_found_ips)}\033[0m 个优选 IP。")
    print("#" * 60)
