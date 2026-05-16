#!/usr/bin/env bash

set -uo pipefail

STEP_TOTAL=15
STEP_CURRENT=0

OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
PKG_MGR=""
ARCH_RAW="$(uname -m)"
ARCH_DEB=""
ARCH_GENERIC=""
DNF_CMD=""
XTOM_MIRROR_BASE_USER_SET="${XTOM_MIRROR_BASE:-}"
XTOM_MIRROR_BASE="${XTOM_MIRROR_BASE:-https://mirrors.xtom.hk}"
XTOM_MIRROR_CANDIDATES=(
  "https://mirrors.xtom.hk"
  "https://mirrors.xtom.sg"
  "https://mirrors.xtom.jp"
  "https://mirrors.xtom.us"
  "https://mirrors.xtom.nl"
  "https://mirrors.xtom.de"
  "https://mirrors.xtom.ee"
  "https://mirrors.xtom.au"
)

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

fatal() {
  echo "[ERROR] $*" >&2
  exit 1
}

next_step() {
  STEP_CURRENT=$((STEP_CURRENT + 1))
  echo
  echo "### ${STEP_CURRENT}/${STEP_TOTAL}: $* ###"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_warn() {
  local description="$1"
  shift
  if ! "$@"; then
    warn "${description}失败。"
    return 1
  fi
}

run_fatal() {
  local description="$1"
  shift
  if ! "$@"; then
    fatal "${description}失败。"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default_answer="${2:-N}"
  local answer=""

  if [[ "$default_answer" =~ ^[Yy]$ ]]; then
    read -r -p "${prompt} (Y/n): " answer
    [[ -z "$answer" ]] && answer="Y"
  else
    read -r -p "${prompt} (y/N): " answer
    [[ -z "$answer" ]] && answer="N"
  fi

  [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fatal "请以 root 用户或使用 sudo 运行此脚本。"
  fi
}

detect_system() {
  [[ -r /etc/os-release ]] || fatal "无法读取 /etc/os-release，无法识别系统。"
  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"

  case "$ARCH_RAW" in
    x86_64|amd64)
      ARCH_DEB="amd64"
      ARCH_GENERIC="amd64"
      ;;
    aarch64|arm64)
      ARCH_DEB="arm64"
      ARCH_GENERIC="arm64"
      ;;
    *)
      ARCH_DEB="$ARCH_RAW"
      ARCH_GENERIC="$ARCH_RAW"
      ;;
  esac

  if command_exists dnf5; then
    DNF_CMD="dnf5"
  elif command_exists dnf; then
    DNF_CMD="dnf"
  fi

  case "$OS_ID" in
    debian|ubuntu)
      PKG_MGR="apt"
      if [[ -z "$OS_CODENAME" ]] && command_exists lsb_release; then
        OS_CODENAME="$(lsb_release -sc)"
      fi
      ;;
    fedora)
      [[ -n "$DNF_CMD" ]] || fatal "检测到 Fedora，但未找到 dnf/dnf5。"
      PKG_MGR="dnf"
      ;;
    *)
      fatal "暂不支持的系统: ${OS_ID:-unknown}。当前仅适配 Debian/Ubuntu 和 Fedora。"
      ;;
  esac
}

get_xtom_probe_path() {
  case "$OS_ID" in
    debian)
      echo "/debian/dists/${OS_CODENAME}/InRelease"
      ;;
    ubuntu)
      echo "/ubuntu/dists/${OS_CODENAME}/InRelease"
      ;;
    fedora)
      echo "/fedora/releases/${OS_VERSION_ID}/Everything/${ARCH_RAW}/os/repodata/repomd.xml"
      ;;
    *)
      echo "/"
      ;;
  esac
}

select_nearest_xtom_mirror() {
  local probe_path
  local mirror
  local result
  local fastest
  local temp_file

  if [[ -n "$XTOM_MIRROR_BASE_USER_SET" ]]; then
    info "使用用户指定的 xTom 源: ${XTOM_MIRROR_BASE}"
    return 0
  fi

  if ! command_exists curl; then
    warn "未找到 curl，无法自动测速选择 xTom 源，使用默认源: ${XTOM_MIRROR_BASE}"
    return 0
  fi

  probe_path="$(get_xtom_probe_path)"
  temp_file="$(mktemp)"

  for mirror in "${XTOM_MIRROR_CANDIDATES[@]}"; do
    result="$(
      curl -o /dev/null -sS -L \
        --connect-timeout 3 \
        --max-time 8 \
        -w "%{http_code} %{time_total}" \
        "${mirror}${probe_path}" 2>/dev/null || true
    )"

    if [[ "$result" =~ ^(200|302)[[:space:]]+([0-9.]+)$ ]]; then
      printf '%s %s\n' "${BASH_REMATCH[2]}" "$mirror" >> "$temp_file"
    fi
  done

  fastest="$(sort -n "$temp_file" 2>/dev/null | awk 'NR==1 {print $2}')"
  rm -f "$temp_file"

  if [[ -n "$fastest" ]]; then
    XTOM_MIRROR_BASE="$fastest"
    info "已自动选择最快的 xTom 源: ${XTOM_MIRROR_BASE}"
  else
    warn "xTom 源测速失败，使用默认源: ${XTOM_MIRROR_BASE}"
  fi
}

host_from_url() {
  local url="$1"
  url="${url#*://}"
  echo "${url%%/*}"
}

can_resolve_host() {
  local host="$1"

  if command_exists getent && getent hosts "$host" >/dev/null 2>&1; then
    return 0
  fi

  if command_exists curl && curl -sS --connect-timeout 3 --max-time 6 -o /dev/null "https://${host}/" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

configure_temporary_resolver() {
  local backup_file="/etc/resolv.conf.backup-before-vps-setup"

  if command_exists chattr; then
    chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
  fi

  if [[ -e /etc/resolv.conf && ! -e "$backup_file" ]]; then
    cp -a /etc/resolv.conf "$backup_file" 2>/dev/null || true
  fi

  cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 223.5.5.5
options timeout:2 attempts:3
EOF

  info "已写入临时公共 DNS，用于完成软件源更新；此阶段不会锁定 /etc/resolv.conf。"
}

ensure_dns_for_package_sources() {
  local mirror_host

  mirror_host="$(host_from_url "$XTOM_MIRROR_BASE")"

  if can_resolve_host "$mirror_host"; then
    info "DNS 解析正常: ${mirror_host}"
    return 0
  fi

  warn "当前 DNS 无法解析 ${mirror_host}，尝试写入临时公共 DNS。"
  configure_temporary_resolver

  if can_resolve_host "$mirror_host"; then
    info "临时 DNS 已恢复 ${mirror_host} 解析。"
    return 0
  fi

  warn "写入临时 DNS 后仍无法解析 ${mirror_host}，后续软件源更新可能失败。"
  return 1
}

backup_apt_sources() {
  local backup_dir="/etc/apt/sources.list.d/backup-before-xtom"

  mkdir -p "$backup_dir"

  if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "${backup_dir}/sources.list.bak"
    : > /etc/apt/sources.list
  fi

  find /etc/apt/sources.list.d -maxdepth 1 -type f \
    \( -name "*.list" -o -name "*.sources" \) \
    -exec mv -f {} "$backup_dir"/ \;
}

configure_xtom_apt_sources() {
  local components="main contrib non-free"

  if [[ "$OS_ID" == "debian" ]]; then
    if [[ "$OS_VERSION_ID" =~ ^[0-9]+$ && "$OS_VERSION_ID" -ge 12 ]]; then
      components="main contrib non-free non-free-firmware"
    fi

    if [[ -z "$OS_CODENAME" ]]; then
      warn "未能识别 Debian 代号，跳过 xTom APT 源配置。"
      return 1
    fi

    backup_apt_sources
    cat > /etc/apt/sources.list.d/xtom.sources.list <<EOF
deb ${XTOM_MIRROR_BASE}/debian/ ${OS_CODENAME} ${components}
deb ${XTOM_MIRROR_BASE}/debian/ ${OS_CODENAME}-updates ${components}
deb ${XTOM_MIRROR_BASE}/debian/ ${OS_CODENAME}-backports ${components}
deb ${XTOM_MIRROR_BASE}/debian-security/ ${OS_CODENAME}-security ${components}
EOF
    info "已配置 Debian xTom 源，并添加 ${OS_CODENAME}-backports。"
    return 0
  fi

  if [[ "$OS_ID" == "ubuntu" ]]; then
    if [[ -z "$OS_CODENAME" ]]; then
      warn "未能识别 Ubuntu 代号，跳过 xTom APT 源配置。"
      return 1
    fi

    backup_apt_sources
    cat > /etc/apt/sources.list.d/xtom.sources.list <<EOF
deb ${XTOM_MIRROR_BASE}/ubuntu/ ${OS_CODENAME} main restricted universe multiverse
deb ${XTOM_MIRROR_BASE}/ubuntu/ ${OS_CODENAME}-updates main restricted universe multiverse
deb ${XTOM_MIRROR_BASE}/ubuntu/ ${OS_CODENAME}-backports main restricted universe multiverse
deb ${XTOM_MIRROR_BASE}/ubuntu/ ${OS_CODENAME}-security main restricted universe multiverse
EOF
    info "已配置 Ubuntu xTom 源，并添加 ${OS_CODENAME}-backports。"
    return 0
  fi
}

configure_xtom_fedora_sources() {
  local backup_dir="/etc/yum.repos.d/backup-before-xtom"

  mkdir -p "$backup_dir"
  find /etc/yum.repos.d -maxdepth 1 -type f -name "*.repo" -exec cp -a {} "$backup_dir"/ \;

  cat > /etc/yum.repos.d/fedora.repo <<EOF
[fedora]
name=Fedora \$releasever - \$basearch
baseurl=${XTOM_MIRROR_BASE}/fedora/releases/\$releasever/Everything/\$basearch/os/
enabled=1
countme=0
metadata_expire=7d
repo_gpgcheck=0
type=rpm
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
skip_if_unavailable=False
EOF

  cat > /etc/yum.repos.d/fedora-updates.repo <<EOF
[updates]
name=Fedora \$releasever - \$basearch - Updates
baseurl=${XTOM_MIRROR_BASE}/fedora/updates/\$releasever/Everything/\$basearch/
enabled=1
countme=0
repo_gpgcheck=0
type=rpm
gpgcheck=1
metadata_expire=6h
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
skip_if_unavailable=False
EOF

  info "已配置 Fedora xTom fedora/updates 源。Fedora 没有 Debian backports 等价仓库，已跳过 backports。"
}

configure_xtom_sources() {
  select_nearest_xtom_mirror

  case "$PKG_MGR" in
    apt)
      configure_xtom_apt_sources
      ;;
    dnf)
      configure_xtom_fedora_sources
      ;;
    *)
      fatal "未知包管理器: $PKG_MGR"
      ;;
  esac
}

pkg_update() {
  case "$PKG_MGR" in
    apt) apt update ;;
    dnf) "$DNF_CMD" makecache ;;
    *) fatal "未知包管理器: $PKG_MGR" ;;
  esac
}

pkg_upgrade() {
  case "$PKG_MGR" in
    apt) apt upgrade -y ;;
    dnf) "$DNF_CMD" upgrade --refresh -y ;;
    *) fatal "未知包管理器: $PKG_MGR" ;;
  esac
}

pkg_install() {
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi
  case "$PKG_MGR" in
    apt) apt install -y "$@" ;;
    dnf) "$DNF_CMD" install -y "$@" ;;
    *) fatal "未知包管理器: $PKG_MGR" ;;
  esac
}

enable_service_if_exists() {
  local service="$1"
  if systemctl list-unit-files "$service" >/dev/null 2>&1; then
    run_warn "启用服务 ${service}" systemctl enable --now "$service"
  else
    warn "系统中未找到服务 ${service}，跳过启用。"
  fi
}

disable_service_if_exists() {
  local service="$1"
  if systemctl list-unit-files "$service" >/dev/null 2>&1; then
    run_warn "停用服务 ${service}" systemctl disable --now "$service"
  fi
}

install_base_packages() {
  local packages=()

  if [[ "$PKG_MGR" == "apt" ]]; then
    packages=(
      ca-certificates curl wget sudo nano gpg unzip tar git chrony
      debian-keyring debian-archive-keyring apt-transport-https dnsutils
      lsb-release htop btop iftop nethogs vnstat mtr iperf3 tmux ncdu jq
      fail2ban iproute2 e2fsprogs
    )
  else
    packages=(
      ca-certificates curl wget sudo nano gnupg2 systemd unzip tar git chrony bind-utils
      htop btop iftop nethogs vnstat mtr iperf3 tmux ncdu jq fail2ban
      iproute e2fsprogs
    )
  fi

  run_fatal "更新软件源" pkg_update
  run_fatal "升级系统软件包" pkg_upgrade
  run_fatal "安装基础工具" pkg_install "${packages[@]}"

  if [[ "$PKG_MGR" == "apt" ]]; then
    disable_service_if_exists systemd-timesyncd.service
    enable_service_if_exists chrony.service
  else
    enable_service_if_exists chronyd.service
  fi
}

configure_timezone_and_ntp() {
  run_warn "设置系统时区为 Asia/Shanghai" timedatectl set-timezone Asia/Shanghai

  if [[ "$PKG_MGR" == "apt" ]]; then
    run_warn "设置 chrony 为 NTP 提供者" timedatectl set-ntp true
  else
    run_warn "设置 chronyd 为 NTP 提供者" timedatectl set-ntp true
  fi
}

configure_ipv4_preference() {
  local gai_conf="/etc/gai.conf"
  local preference_line="precedence ::ffff:0:0/96  100"

  touch "$gai_conf"

  if grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' "$gai_conf"; then
    info "系统已配置 IPv4 优先。"
    return 0
  fi

  if grep -Eq '^[[:space:]]*#?[[:space:]]*precedence[[:space:]]+::ffff:0:0/96' "$gai_conf"; then
    sed -i 's|^[[:space:]]*#\?[[:space:]]*precedence[[:space:]]\+::ffff:0:0/96.*$|precedence ::ffff:0:0/96  100|' "$gai_conf"
  else
    printf '\n# Prefer IPv4 over IPv6\n%s\n' "$preference_line" >> "$gai_conf"
  fi

  info "已设置系统 IPv4 优先。"
}

detect_ssh_port() {
  local port
  port="$(ss -tlnp 2>/dev/null | awk '/sshd/ {split($4, a, ":"); print a[length(a)]; exit}')"
  echo "${port:-22}"
}

configure_fail2ban() {
  local ssh_port
  ssh_port="$(detect_ssh_port)"
  info "检测到 SSH 端口: ${ssh_port}"

  mkdir -p /etc/fail2ban
  cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${ssh_port}
maxretry = 3
bantime = -1
findtime = 600
EOF

  enable_service_if_exists fail2ban.service
  enable_service_if_exists vnstat.service
  info "fail2ban 与 vnstat 已处理完成。"
}

install_xanmod() {
  local xanmod_package=""
  local package
  local candidates=(
    linux-xanmod-x64v3
    linux-xanmod-lts-x64v3
  )

  if [[ "$PKG_MGR" != "apt" ]]; then
    info "Fedora 不适用 XanMod APT 仓库，跳过。"
    return 0
  fi

  if [[ "$ARCH_DEB" != "amd64" ]]; then
    warn "XanMod 官方 APT 仓库主要面向 amd64 Debian 系，当前架构 ${ARCH_DEB}，跳过。"
    return 0
  fi

  if [[ -z "$OS_CODENAME" ]]; then
    warn "未能识别 Debian/Ubuntu 代号，跳过 XanMod 安装。"
    return 0
  fi

  mkdir -p /etc/apt/keyrings
  chmod 755 /etc/apt/keyrings

  if ! wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg; then
    warn "XanMod 密钥导入失败，跳过内核安装。"
    return 1
  fi

  cat > /etc/apt/sources.list.d/xanmod-release.list <<EOF
deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${OS_CODENAME} main
EOF

  if ! pkg_update; then
    warn "XanMod 源更新失败。"
    return 1
  fi

  for package in "${candidates[@]}"; do
    if apt-cache policy "$package" | awk '/Candidate:/ && $2 != "(none)" {found=1} END {exit !found}'; then
      xanmod_package="$package"
      break
    fi
  done

  if [[ -z "$xanmod_package" ]]; then
    warn "XanMod 仓库中未找到 linux-xanmod-x64v3 或 linux-xanmod-lts-x64v3，跳过内核安装。"
    return 1
  fi

  info "选择安装 XanMod 内核包: ${xanmod_package}"

  if ! pkg_install "$xanmod_package"; then
    warn "XanMod 内核安装失败。"
    return 1
  fi

  info "XanMod 内核安装成功: ${xanmod_package}"
}

install_uv_python() {
  local uv_bin="/usr/local/bin/uv"
  local python_install_dir="/opt/uv/python"
  local python_path=""
  local profile_file="/etc/profile.d/uv.sh"

  if curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL=/usr/local/bin sh; then
    info "uv 安装完成。"
  else
    warn "uv 安装失败。"
    return 1
  fi

  if [[ ! -x "$uv_bin" ]]; then
    warn "未找到 ${uv_bin}，无法继续安装 Python 3.13。"
    return 1
  fi

  cat > "$profile_file" <<EOF
export PATH="/usr/local/bin:\$PATH"
EOF
  chmod +x "$profile_file"
  export PATH="/usr/local/bin:${PATH}"

  mkdir -p "$python_install_dir"
  chmod 755 /opt/uv "$python_install_dir"

  if UV_PYTHON_INSTALL_DIR="$python_install_dir" "$uv_bin" python install 3.13; then
    info "Python 3.13 已通过 uv 安装到 ${python_install_dir}。"
  else
    warn "Python 3.13 安装失败。"
    return 1
  fi

  python_path="$(UV_PYTHON_INSTALL_DIR="$python_install_dir" "$uv_bin" python find 3.13 2>/dev/null || true)"
  if [[ -z "$python_path" || ! -x "$python_path" ]]; then
    warn "无法定位 uv 安装的 Python 3.13。"
    return 1
  fi

  ln -sfn "$python_path" /usr/local/bin/python3.13
  ln -sfn "$python_path" /usr/local/bin/python3
  ln -sfn "$python_path" /usr/local/bin/python
  info "已将 Python 3.13 设置为 /usr/local/bin 下的默认 python/python3。"

  if command_exists python3; then
    info "当前 python3: $(python3 --version 2>&1)"
  fi

  if command_exists python; then
    info "当前 python: $(python --version 2>&1)"
  fi
}

install_docker() {
  if curl -fsSL https://get.docker.com | bash -s docker; then
    enable_service_if_exists docker.service
    info "Docker 安装完成。"
  else
    warn "Docker 安装失败。"
  fi
}

sync_opt_assets() {
  local repo_url="https://github.com/Sora3QwQ/useless.git"
  local temp_dir="/tmp/useless-opt-sync"

  rm -rf "$temp_dir"

  if ! git clone --depth 1 "$repo_url" "$temp_dir"; then
    warn "克隆 ${repo_url} 失败。"
    return 1
  fi

  if [[ ! -d "${temp_dir}/opt" ]]; then
    warn "仓库中未找到 opt 目录。"
    rm -rf "$temp_dir"
    return 1
  fi

  mkdir -p /opt
  if ! cp -a "${temp_dir}/opt/." /opt/; then
    warn "同步仓库中的 /opt 内容到本地 /opt 失败。"
    rm -rf "$temp_dir"
    return 1
  fi

  rm -rf "$temp_dir"
  info "已同步仓库中的 /opt 内容到本地 /opt。"
}

ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi

  warn "当前 Docker 环境缺少 docker compose 插件，SmartDNS 容器无法启动。"
  return 1
}

configure_resolv_conf_for_smartdns() {
  if command_exists chattr; then
    chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
  fi

  cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
options timeout:2 attempts:3
EOF
  info "已将 /etc/resolv.conf 指向本机 SmartDNS。"
}

deploy_smartdns() {
  local compose_dir="/opt/smartdns"

  if [[ ! -f "${compose_dir}/docker-compose.yml" ]]; then
    warn "未找到 ${compose_dir}/docker-compose.yml，无法部署 SmartDNS。"
    return 1
  fi

  ensure_docker_compose || return 1

  mkdir -p \
    "${compose_dir}/data/var/lib/smartdns" \
    "${compose_dir}/data/var/log/smartdns"

  if (cd "$compose_dir" && docker compose up -d); then
    configure_resolv_conf_for_smartdns
    lock_resolv_conf
    info "SmartDNS 已通过 Docker Compose 部署完成。"
  else
    warn "SmartDNS Docker Compose 启动失败。"
    return 1
  fi
}

lock_resolv_conf() {
  if [[ ! -e /etc/resolv.conf ]]; then
    warn "/etc/resolv.conf 不存在，跳过锁定。"
    return 0
  fi

  if ! command_exists chattr; then
    warn "未找到 chattr，跳过锁定 /etc/resolv.conf。"
    return 0
  fi

  if chattr +i /etc/resolv.conf; then
    info "/etc/resolv.conf 已锁定。"
  else
    warn "锁定 /etc/resolv.conf 失败。"
  fi
}

install_caddy_debian() {
  mkdir -p /usr/share/keyrings

  run_warn "导入 Caddy GPG 密钥" bash -c \
    "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg" || return 1

  run_warn "写入 Caddy APT 源" bash -c \
    "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list" || return 1

  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod o+r /etc/apt/sources.list.d/caddy-stable.list

  if pkg_update && pkg_install caddy; then
    enable_service_if_exists caddy.service
    info "Caddy 安装成功。"
  else
    warn "Caddy 安装失败。"
    return 1
  fi
}

install_caddy_fedora() {
  local plugin_pkg="dnf5-plugins"

  if [[ "$DNF_CMD" == "dnf" ]]; then
    plugin_pkg="dnf-plugins-core"
  fi

  if ! pkg_install "$plugin_pkg"; then
    warn "安装 ${plugin_pkg} 失败，无法启用 Caddy COPR。"
    return 1
  fi

  if ! "$DNF_CMD" -y copr enable @caddy/caddy; then
    warn "启用 Caddy COPR 仓库失败。"
    return 1
  fi

  if pkg_install caddy; then
    enable_service_if_exists caddy.service
    info "Caddy 安装成功。"
  else
    warn "Caddy 安装失败。"
    return 1
  fi
}

install_caddy() {
  if [[ "$PKG_MGR" == "apt" ]]; then
    install_caddy_debian
  else
    install_caddy_fedora
  fi
}

install_ffmpeg() {
  local archive=""
  local extract_dir="/opt"
  local profile_file="/etc/profile.d/ffmpeg.sh"

  case "$ARCH_GENERIC" in
    amd64)
      archive="ffmpeg-master-latest-linux64-gpl.tar.xz"
      ;;
    *)
      warn "当前架构 ${ARCH_GENERIC} 未配置 FFmpeg 二进制安装地址，跳过。"
      return 1
      ;;
  esac

  if ! wget "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/${archive}" -O /tmp/ffmpeg.tar.xz; then
    warn "FFmpeg 下载失败。"
    return 1
  fi

  if ! tar -Jxf /tmp/ffmpeg.tar.xz -C "$extract_dir"; then
    warn "FFmpeg 解压失败。"
    rm -f /tmp/ffmpeg.tar.xz
    return 1
  fi

  local ffmpeg_root
  ffmpeg_root="$(tar -tf /tmp/ffmpeg.tar.xz | head -n1 | cut -d/ -f1)"

  rm -f /tmp/ffmpeg.tar.xz

  if [[ -z "$ffmpeg_root" || ! -d "${extract_dir}/${ffmpeg_root}/bin" ]]; then
    warn "无法定位 FFmpeg 解压目录。"
    return 1
  fi

  cat > "$profile_file" <<EOF
export PATH="${extract_dir}/${ffmpeg_root}/bin:\$PATH"
EOF
  chmod +x "$profile_file"
  export PATH="${extract_dir}/${ffmpeg_root}/bin:${PATH}"

  if command_exists ffmpeg; then
    info "FFmpeg 安装成功: $(ffmpeg -version | head -n1)"
  else
    warn "FFmpeg 安装后验证失败。"
    return 1
  fi
}

install_realm() {
  if wget -qO- https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | bash -s install; then
    info "Realm 转发管理脚本安装成功，可使用 pf 命令管理。"
  else
    warn "Realm 转发脚本安装失败。"
  fi
}

install_speedtest() {
  local script_url=""

  if [[ "$PKG_MGR" == "apt" ]]; then
    script_url="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
  else
    script_url="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
  fi

  if ! curl -fsSL "$script_url" | bash; then
    warn "Speedtest CLI 仓库配置失败。"
    return 1
  fi

  if pkg_install speedtest; then
    info "Speedtest CLI 安装成功。"
  else
    warn "Speedtest CLI 安装失败。"
    return 1
  fi
}

run_nxtrace() {
  if curl -fsSL nxtrace.org/nt | bash; then
    info "Nxtrace 执行完成。"
  else
    warn "Nxtrace 脚本执行失败。"
  fi
}

install_tcping() {
  local tarball=""
  local temp_dir="/tmp/tcping-install"

  case "$ARCH_GENERIC" in
    amd64|arm64)
      tarball="tcping-linux-${ARCH_GENERIC}-static.tar.gz"
      ;;
    *)
      warn "当前架构 ${ARCH_GENERIC} 未配置 tcping 安装包，跳过。"
      return 1
      ;;
  esac

  rm -rf "$temp_dir"
  mkdir -p "$temp_dir"

  if ! wget "https://github.com/pouriyajamshidi/tcping/releases/latest/download/${tarball}" -O "${temp_dir}/tcping.tar.gz"; then
    warn "tcping 下载失败。"
    rm -rf "$temp_dir"
    return 1
  fi

  if ! tar -xzf "${temp_dir}/tcping.tar.gz" -C "$temp_dir"; then
    warn "tcping 解压失败。"
    rm -rf "$temp_dir"
    return 1
  fi

  if [[ ! -f "${temp_dir}/tcping" ]]; then
    warn "未在压缩包中找到 tcping 可执行文件。"
    rm -rf "$temp_dir"
    return 1
  fi

  install -m 0755 "${temp_dir}/tcping" /usr/local/bin/tcping
  rm -rf "$temp_dir"

  if command_exists tcping; then
    info "tcping 安装成功: $(tcping --version 2>/dev/null | head -n1)"
  else
    warn "tcping 安装后验证失败。"
    return 1
  fi
}

final_reboot() {
  if ask_yes_no "是否现在重启系统以应用内核或服务变更？" "N"; then
    info "5 秒后重启系统，请确保当前连接可以中断。"
    sleep 5
    reboot
  else
    info "已跳过自动重启。"
  fi
}

main() {
  require_root
  detect_system

  echo "--- 开始执行 VPS 初始化配置脚本 ---"
  echo "系统: ${OS_ID} ${OS_VERSION_ID:-unknown} | 架构: ${ARCH_RAW} | 包管理器: ${PKG_MGR}"
  echo "本脚本共 ${STEP_TOTAL} 个步骤，其中 Caddy、FFmpeg 和 Realm 为可选安装。"

  next_step "配置 xTom 软件源并添加 backports"
  configure_xtom_sources
  ensure_dns_for_package_sources

  next_step "更新系统并安装基础工具"
  install_base_packages
  configure_timezone_and_ntp
  configure_fail2ban

  next_step "设置系统 IPv4 优先"
  configure_ipv4_preference

  next_step "安装 XanMod 内核"
  install_xanmod

  next_step "安装 uv 并设置 Python 3.13 为默认版本"
  install_uv_python

  next_step "安装 Docker"
  install_docker

  next_step "同步远程仓库中的 /opt 内容"
  sync_opt_assets

  next_step "部署 SmartDNS（Docker Compose）"
  deploy_smartdns

  next_step "安装 Caddy Web 服务器（可选）"
  if ask_yes_no "是否安装 Caddy Web 服务器？" "N"; then
    install_caddy
  else
    info "已跳过 Caddy 安装。"
  fi

  next_step "安装 FFmpeg（可选）"
  if ask_yes_no "是否安装 FFmpeg？" "N"; then
    install_ffmpeg
  else
    info "已跳过 FFmpeg 安装。"
  fi

  next_step "安装 Realm 转发管理脚本（可选）"
  if ask_yes_no "是否安装 Realm 网络转发管理脚本？" "N"; then
    install_realm
  else
    info "已跳过 Realm 安装。"
  fi

  next_step "安装 Speedtest CLI"
  install_speedtest

  next_step "执行 Nxtrace 脚本"
  run_nxtrace

  next_step "安装 tcping"
  install_tcping

  next_step "执行完成后的重启处理"
  echo "--- 配置完成 ---"
  final_reboot
}

main "$@"
