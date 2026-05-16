# scripts

这里存放一些 VPS 初始化和日常运维脚本。

## setup.sh

`setup.sh` 是一个交互式 VPS 初始化脚本，主要适配 Debian/Ubuntu 和 Fedora。

建议在全新的 VPS 上以 `root` 权限运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Sora3QwQ/useless/main/scripts/setup.sh -o setup.sh && chmod +x setup.sh && sudo ./setup.sh
```

也可以手动指定 xTom 镜像节点：

```bash
XTOM_MIRROR_BASE=https://mirrors.xtom.jp sudo ./setup.sh
```

如果没有手动指定 `XTOM_MIRROR_BASE`，脚本会自动测试多个 xTom 节点，并选择响应最快的源。

### 支持系统

- Debian
- Ubuntu
- Fedora，支持 `dnf5` 或 `dnf`

其他发行版会被脚本主动拒绝，避免误操作。

### 主要功能

- 自动检测 Debian/Ubuntu 或 Fedora。
- 自动选择最快的 xTom 镜像源。
- 配置 xTom 软件源。
- 为 Debian/Ubuntu 添加 backports 源。
- 更新并升级系统软件包。
- 安装常用基础工具、监控工具和网络诊断工具。
- 安装并启用 Chrony，同时设置时区为 `Asia/Shanghai`。
- 自动检测 SSH 端口并配置 `fail2ban`。
- 通过 `/etc/gai.conf` 设置 IPv4 优先，但不禁用 IPv6。
- 在支持的 Debian/Ubuntu amd64 系统上安装 XanMod 内核。
- 安装 `uv` 到 `/usr/local/bin`，并通过 uv 安装 Python 3.13 作为默认版本。
- 安装 Docker 并启用 Docker 服务。
- 将本仓库 `/opt` 目录同步到 VPS 本地 `/opt`。
- 使用 `/opt/smartdns/docker-compose.yml` 通过 Docker Compose 部署 SmartDNS。
- 可选安装 Caddy。
- 可选安装 FFmpeg。
- 可选安装 Realm 转发管理脚本。
- 安装 Ookla Speedtest CLI。
- 执行 Nxtrace 安装脚本。
- 安装 `tcping` 静态二进制。
- 执行结束后询问是否重启系统。

### 交互选项

脚本执行过程中会询问是否安装以下组件：

- Caddy
- FFmpeg
- Realm 转发管理脚本

直接按 Enter 会使用默认选项 `No`。

### 注意事项

- 脚本会修改系统软件源，并在修改前备份现有 APT/YUM 源配置。
- SmartDNS 部署成功后会把 `/etc/resolv.conf` 指向 `127.0.0.1`，并使用 `chattr +i` 锁定。
- 如果后续需要手动修改 `/etc/resolv.conf`，需要先解锁：

```bash
sudo chattr -i /etc/resolv.conf
```

- 普通用户默认不能直接使用 Docker。如需允许某个用户使用 Docker，可以执行：

```bash
sudo usermod -aG docker 用户名
```

修改用户组后，需要退出并重新登录才会生效。

### 适合场景

这个脚本更适合用于个人 VPS、测试机或新机器初始化。  
如果机器已经承载重要业务，建议先阅读脚本内容，确认软件源、DNS、Docker 和重启行为符合预期后再执行。
