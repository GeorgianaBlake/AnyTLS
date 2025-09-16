#!/usr/bin/env bash
# https://github.com/GeorgianaBlake/AnyTLS
# AnyTLS一键管理脚本：安装/更新/查看/更改端口/更改密码/删除
# 适配 Debian/Ubuntu (apt) 与 CentOS/RHEL/Alma/Rocky
# 兼容 arm64 和 amd64 两种系统架构

set -euo pipefail

CONFIG_DIR="/etc/AnyTLS" # 配置目录
ANYTLS_SNAP_DIR="/tmp/anytls_install_$$" # 临时目录
ANYTLS_SERVER="${CONFIG_DIR}/server" # 服务端文件
ANYTLS_SERVICE_NAME="anytls.service" # 服务
ANYTLS_SERVICE_FILE="/etc/systemd/system/${ANYTLS_SERVICE_NAME}" # 服务目录
ANYTLS_CONFIG_FILE="${CONFIG_DIR}/config.yaml" # 主配置文件
ANYTLS_CLIENT_FILE="${CONFIG_DIR}/anytls.txt" # 主配置文件导出
TZ_DEFAULT="Asia/Shanghai" # 默认时区
SHELL_VERSION="0.1.0" # 版本
ANYTLS_VERSION="0.0.8" # AnyTLS版本
AT_ALIASES="AT_GeorgianaBlake" # AnyTLS别名

# 字体颜色配置
Font="\033[0m"

Black="\033[30m"   # 黑色
Red="\033[31m"     # 红色
Green="\033[32m"   # 绿色
Yellow="\033[33m"  # 黄色
Blue="\033[34m"    # 蓝色
Magenta="\033[35m" # 紫/洋红
Cyan="\033[36m"    # 青
White="\033[37m"   # 白色

BBlack="\033[90m"
BRed="\033[91m"
BGreen="\033[92m"
BYellow="\033[93m"
BBlue="\033[94m"
BMagenta="\033[95m"
BCyan="\033[96m"
BWhite="\033[97m"

BlackBG="\033[40m"
RedBG="\033[41m"
GreenBG="\033[42m"
YellowBG="\033[43m"
BlueBG="\033[44m"
MagentaBG="\033[45m"
CyanBG="\033[46m"
WhiteBG="\033[47m"

Bold="\033[1m"
Dim="\033[2m"
Italic="\033[3m"
Underline="\033[4m"
Blink="\033[5m"
Reverse="\033[7m"
Hidden="\033[8m"
Strike="\033[9m"

OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"
WARN="${Yellow}[WARN]${Font}"
INFO="${Cyan}[INFO]${Font}"

print_ok() {
  echo -e "${OK}${Blue} $1 ${Font}"
}

print_info() {
  echo -e "${INFO}${Cyan} $1 ${Font}"
}

print_error() {
  echo -e "${ERROR} ${RedBG} $1 ${Font}"
}

judge() {
  if [[ 0 -eq $? ]]; then
    print_ok "$1 完成"
    sleep 1
  else
    print_error "$1 失败"
    exit 1
  fi
}

trap 'echo -e "\n${WARN} 已中断"; exit 1' INT

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: 必须使用 root 运行本脚本!" 1>&2
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

get_arch() {
  local arch_raw
  arch_raw=$(uname -m)

  case "$arch_raw" in
    x86_64 | amd64)
      echo "amd64"
      ;;
    # i386 | i686)
    #   echo "386"
    #   ;;
    aarch64 | arm64)
      echo "arm64"
      ;;
    # armv7l | armv7)
    #   echo "armv7"
    #   ;;
    # armv6l | armv6)
    #   echo "armv6"
    #   ;;
    # ppc64le)
    #   echo "ppc64le"
    #   ;;
    # mips64)
    #   echo "mips64"
    #   ;;
    # mips64el)
    #   echo "mips64le"
    #   ;;
    # riscv64)
    #   echo "riscv64"
    #   ;;
    # s390x)
    #   echo "s390x"
    #   ;;
    *)
      print_error "不支持的系统架构 ($arch_raw)" >&2
      return 1
      ;;
  esac
}


os_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y ca-certificates unzip
  elif command -v dnf >/dev/null 2>&1; then
    dnf update -y
    dnf install -y ca-certificates unzip
  elif command -v yum >/dev/null 2>&1; then
    yum update -y
    yum install -y ca-certificates unzip
  else
    echo "未识别的包管理器，请手动安装 ca-certificates、unzip 后重试"
    exit 1
  fi
}

pause() { read -rp "按回车返回菜单..." _; }

quit() { exit 0; }

hr() { printf '%*s\n' 40 '' | tr ' ' '='; }

emxxx() {
  echo ".."
}

# 关闭各类防火墙
close_wall() {
  for svc in firewalld nftables ufw; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
      # 检查状态
      if systemctl is-active --quiet "$svc"; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        print_ok "已关闭并禁用防火墙: $svc"
      else
        print_ok "防火墙 $svc 已存在，但当前处于关闭状态"
        # 如果还在 enabled，就禁用掉
        if systemctl is-enabled --quiet "$svc"; then
          systemctl disable "$svc" 2>/dev/null || true
          print_ok "已禁用开机自启: $svc"
        fi
      fi
    else
      print_error "未找到防火墙: $svc"
    fi
  done
}

urlencode() {
  local s="$1"
  local i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:$i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

random_port() { shuf -i 2000-65000 -n 1; }

gen_password() { cat /proc/sys/kernel/random/uuid; }

# 确保端口是数字并且在合法范围内
valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# 检查端口是否被占用
is_port_used() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln | awk '{print $5}' | grep -Eq "[:.]${port}([[:space:]]|$)"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -i :"$port" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  else
    return 1
  fi
}

read_port_interactive() {
  local input
  while true; do
    read -t 15 -p "回车或等待15秒为随机端口，或者自定义端口请输入(1-65535)：" input || true
    if [[ -z "${input:-}" ]]; then
      input=$(random_port)
    fi

    # 验证端口是否合法
    if ! valid_port "$input"; then
      echo "端口不合法：$input，请输入一个有效的端口（1-65535）。"
      continue
    fi

    # 检查端口是否被占用
    if is_port_used "$input"; then
      echo "端口 $input 已被占用，请选择另一个端口。"
      continue
    fi

    # 如果端口合法且未被占用，退出循环
    echo "$input"
    break
  done
}

get_ip() {
  local ip4 ip6
  ip4=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip4}" ]]; then
    echo "${ip4}"
    return
  fi
  ip6=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip6}" ]]; then
    echo "${ip6}"
    return
  fi
  curl -s https://api.ipify.org || true
}

# 获取版本
get_latest_version() {
  local version
  version=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest \
    | grep '"tag_name":' \
    | sed -E 's/.*"([^"]+)".*/\1/')

  if [[ -z "$version" ]]; then
    print_error "无法获取AnyTLS最新版本号，请检查网络或GitHub API限制" >&2
    return 1
  fi
  echo "$version"
}

# 获取已安装的版本
get_install_version() {
  if [[ -f "$ANYTLS_SERVICE_FILE" ]]; then
    grep '^X-AT-Version=' "$ANYTLS_SERVICE_FILE" | sed -E 's/^X-AT-Version=//'
  else
    echo "unknown"
  fi
}

write_systemd() {
  local version port pass
  port="$2"
  pass="$3"
  if [[ ${1-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    version="$1"
  else
    version="$(get_install_version)"
  fi
  cat > "$ANYTLS_SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS Server Service
Documentation=https://github.com/anytls/anytls-go
After=network.target network-online.target
Wants=network-online.target
X-AT-Version=${version}

[Service]
Type=simple
User=root
Environment=TZ=${TZ_DEFAULT}
ExecStart="${ANYTLS_SERVER}" -l 0.0.0.0:${port} -p "${pass}"
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_config() {
  # 参数：端口 密码
  local port="$1" pass="$2"
  mkdir -p "$(dirname "${ANYTLS_CONFIG_FILE}")"
  cat > "${ANYTLS_CONFIG_FILE}" <<EOF
listen: :${port}
auth:
  type: password
  password: ${pass}
EOF
}

client_export() {
  if [[ ! -f "${ANYTLS_CONFIG_FILE}" ]]; then
    print_error "未找到 ${ANYTLS_CONFIG_FILE}"
    return 1
  fi
  local port pass ip link
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  if [[ -z "${port}" ]]; then
    port=$(awk '/^[[:space:]]*listen:/ { if (match($0, /:([0-9]+)[[:space:]]*$/, a)) print a[1] }' "${ANYTLS_CONFIG_FILE}")
  fi
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  ip=$(get_ip)
  local alias_enc
  alias_enc=$(urlencode "${AT_ALIASES}")
  link="${pass}@${ip}:${port}/?insecure=1#${alias_enc}"

  echo -e "=========== AnyTLS 配置参数 ==========="
  echo -e " 代理模式: AnyTLS"
  echo -e " 地址: ${ip}"
  echo -e " 端口: ${port}"
  echo -e " 密码: ${pass}"
  echo -e " 传输协议: tls"
  echo -e " 跳过证书验证: true"
  echo -e " 备注: AnyTLS 使用自签名证书, 客户端需启用 '允许不安全' 或 '跳过证书验证'"
  echo -e "========================================="
  echo -e " URL链接(可复制导入):"
  echo -e " anytls://${link}"
  echo -e "========================================="
  echo -e " URL二维码(可在浏览器打开):"
  echo -e " https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=anytls://${link}"
  echo -e "========================================="
}

start_service() { print_info "正在启动 AnyTLS 服务..."; systemctl start "${ANYTLS_SERVICE_NAME}"; sleep 1; status_service; }
stop_service() { print_info "正在停止 AnyTLS 服务..."; systemctl stop "${ANYTLS_SERVICE_NAME}"; sleep 1; status_service; }
# restart_service() { print_info "正在重启 AnyTLS 服务..."; systemctl restart "${ANYTLS_SERVICE_NAME}"; sleep 1; status_service; }
status_service() { print_info "AnyTLS 服务状态:"; systemctl status "${ANYTLS_SERVICE_NAME}" --no-pager; }
log_service() { print_info "显示 AnyTLS 服务日志 (按 Ctrl+C 退出):"; journalctl -u "${ANYTLS_SERVICE_NAME}" -f "$@"; }

# 是否存在可执行与服务文件
binary_exists() { [[ -x "${ANYTLS_SERVER}" ]]; }
service_file_exists() { systemctl cat "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1 || [[ -f "${ANYTLS_SERVICE_FILE}" ]]; }

# 是否已安装：二选一即可算“已安装”
is_installed() { binary_exists || service_file_exists; }

# 是否正在运行
is_active() { systemctl is-active "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1; }

install_status_text() {
  if is_installed; then
    if is_active; then
      echo -e "${BGreen}已安装（运行中）${Font}"
    else
      # 进一步分辨 failed / inactive
      if systemctl is-failed "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1; then
        echo -e "${BYellow}已安装（已停止，上次启动失败）${Font}"
      else
        echo -e "${BYellow}已安装（已停止）${Font}"
      fi
    fi
  else
    echo -e "${BRed}未安装${Font}"
  fi
}

restart_service() {
  systemctl daemon-reload || true
  systemctl enable "${ANYTLS_SERVICE_NAME}" || true
  systemctl restart "${ANYTLS_SERVICE_NAME}"
  systemctl status --no-pager "${ANYTLS_SERVICE_NAME}" | sed -n '1,6p' || true
}

install_anytls() {
  mkdir -p "$CONFIG_DIR"

  print_info "正在下载依赖..."
  os_install
  judge "依赖下载"

  print_info "正在关闭防火墙..."
  close_wall
  judge "关闭防火墙"
  
  print_info "正在检测系统架构..."
  ARCH=$(get_arch) || exit 1

  echo -e "${INFO} 检测到系统架构: ${Green}${ARCH}${Font}"

  LATEST=$(get_latest_version) || exit 1

  sleep 1
  print_info "正在下载AnyTLS..."

  AT_URL="https://github.com/anytls/anytls-go/releases/download/${LATEST}/anytls_${LATEST#v}_linux_${ARCH}.zip"

  print_info "AnyTLS最新版本 ${LATEST}"

  if [ ! -d "$ANYTLS_SNAP_DIR" ];then
    mkdir -p "$ANYTLS_SNAP_DIR"
  fi

  FILENAME="anytls_${LATEST#v}_linux_${ARCH}.zip"
  OUTPUT_PATH="${ANYTLS_SNAP_DIR}/${FILENAME}"

  curl -L -o "$OUTPUT_PATH" "$AT_URL"

  if [ $? -ne 0 ]; then
    print_error "下载失败AnyTLS" >&2
    exit 1
  fi

  judge "下载AnyTLS"
  unzip -o "$OUTPUT_PATH" -d "$ANYTLS_SNAP_DIR"

  mv "${ANYTLS_SNAP_DIR}/anytls-server" "$ANYTLS_SERVER"

  rm -rf "${ANYTLS_SNAP_DIR}"

  chmod +x "$ANYTLS_SERVER"

  print_info "正在创建/更新 systemd 服务文件: ${ANYTLS_SERVER} ..."

  local port pass
  port=$(read_port_interactive)
  pass=$(gen_password)

  write_systemd "$LATEST" "$port" "$pass"

  write_config "$port" "$pass"

  systemctl daemon-reload

  if ! systemctl enable "${ANYTLS_SERVICE_NAME}"; then
    print_info "设置开机自启失败"
    exit 1
  fi
  if ! systemctl restart "${ANYTLS_SERVICE_NAME}"; then
    print_error "启动/重启 AnyTLS 服务失败。请检查日志"
    exit 1
  fi
  
  sleep 2
  if systemctl is-active --quiet "${ANYTLS_SERVICE_NAME}"; then
    print_ok "AnyTLS 服务已成功启动"
    echo -e "${OK} 安装完成，以下为客户端导入参数："
    client_export
    echo
    exit 0
  else
    echo "错误: AnyTLS 服务未能成功启动。"; status_service; log_service -n 20;
  fi
}

update_anytls() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法更新"
    exit 1
  fi
  print_info "正在检测系统架构..."
  ARCH=$(get_arch) || exit 1

  echo -e "${INFO} 检测到系统架构: ${Green}${ARCH}${Font}"

  LATEST=$(get_latest_version) || exit 1

  sleep 1
  print_info "正在下载AnyTLS..."

  AT_URL="https://github.com/anytls/anytls-go/releases/download/${LATEST}/anytls_${LATEST#v}_linux_${ARCH}.zip"

  print_info "AnyTLS最新版本 ${LATEST}"

  if [ ! -d "$ANYTLS_SNAP_DIR" ];then
    mkdir -p "$ANYTLS_SNAP_DIR"
  fi

  FILENAME="anytls_${LATEST}_darwin_${ARCH}.zip"
  OUTPUT_PATH="${ANYTLS_SNAP_DIR}/${FILENAME}"

  curl -L -o "$OUTPUT_PATH" "$AT_URL"

  if [ $? -ne 0 ]; then
    print_error "下载失败AnyTLS" >&2
    exit 1
  fi

  judge "下载AnyTLS"
  unzip -o "$OUTPUT_PATH" -d "$ANYTLS_SNAP_DIR"

  mv "${ANYTLS_SNAP_DIR}/anytls-server" "$ANYTLS_SERVER"

  rm -rf "${ANYTLS_SNAP_DIR}"

  chmod +x "$ANYTLS_SERVER"

  print_info "正在创建/更新 systemd 服务文件: ${ANYTLS_SERVER} ..."

  local port pass
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")

  [[ -z "$port" ]] && port=$(random_port)
  [[ -z "$pass" ]] && pass=$(gen_password)

  write_systemd "$LATEST" "$port" "$pass"

  write_config "$port" "$pass"

  systemctl daemon-reload

  if ! systemctl enable "${ANYTLS_SERVICE_NAME}"; then
    print_info "设置开机自启失败"
    exit 1
  fi
  if ! systemctl restart "${ANYTLS_SERVICE_NAME}"; then
    print_error "启动/重启 AnyTLS 服务失败。请检查日志"
    exit 1
  fi
  
  sleep 2
  if systemctl is-active --quiet "${ANYTLS_SERVICE_NAME}"; then
    print_ok "AnyTLS 服务已成功启动"
    echo -e "${OK} 更新完成，以下为客户端导入参数："
    client_export
    echo
    exit 0
  else
    echo "错误: AnyTLS 服务未能成功启动。"; status_service; log_service -n 20;
  fi
}

uninstall_anytls() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法卸载"
    exit 1
  fi
  read -p "确认卸载并删除配置？(y/N): " ans
  if [[ "${ans:-N}" != [yY] ]]; then
    echo "已取消"
    return
  fi
  systemctl stop "${ANYTLS_SERVICE_NAME}" || true
  systemctl disable "${ANYTLS_SERVICE_NAME}" || true
  rm -f /etc/systemd/system/${ANYTLS_SERVICE_NAME} || true
  systemctl daemon-reload || true
  rm -rf "${CONFIG_DIR}" || true
  echo -e "${OK} 卸载完成。"
}

view_config() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法查看配置"
    exit 1
  fi
  echo
  echo -e "以下为客户端导入参数："
  client_export
  echo
  exit 0
}

set_port() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法设置端口"
    exit 1
  fi
  local new_port
  new_port=$(read_port_interactive)
  local pass
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  write_systemd "" "$new_port" "$pass"
  write_config "$new_port" "$pass"
  restart_service
  clear
  echo -e "${OK} 端口已更新为：${new_port}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  client_export
  echo
  exit 0
}

set_password() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法设置端口"
    exit 1
  fi
  local new_pass
  new_pass=$(gen_password)
  local port
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  write_systemd "" "$port" "$new_pass"
  write_config "$port" "$new_pass"
  restart_service
  clear
  echo -e "${OK} 密码已更新为：${new_pass}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  client_export
  echo
  exit 0
}

echo_version() {
  if ! is_installed; then
    return 0
  fi
  echo -e " 当前AnyTLS版本: $(get_install_version)"
}

main() {
  while true; do
    clear
    hr
    echo -e " AnyTLS 一键脚本"
    echo -e " https://github.com/GeorgianaBlake/AnyTLS"
    echo -e " 当前脚本版本: ${Magenta}${SHELL_VERSION}${Font}"
    echo -e " 安装状态：$(install_status_text)"
    echo_version
    hr
    echo -e "${Cyan}1. 安装/重装 AnyTLS${Font}"
    echo -e "${Cyan}2. 更新 AnyTLS${Font}"
    echo -e "${Cyan}3. 查看配置${Font}"
    echo -e "${Cyan}4. 卸载 AnyTLS${Font}"
    echo -e "${Cyan}5. 更改端口${Font}"
    echo -e "${Cyan}6. 更改密码${Font}"
    echo -e "${Cyan}0. 退出${Font}"
    hr
      read -p "请输入数字 [0-6]: " choice
    case "${choice}" in
      1) install_anytls; quit ;;
      2) update_anytls; quit ;;
      3) view_config; quit ;;
      4) uninstall_anytls; quit ;;
      5) set_port; quit ;;
      6) set_password; quit ;;
      0) exit 0 ;;
      *) echo "无效选项"; pause ;;
    esac
  done
}

ensure_root
main
