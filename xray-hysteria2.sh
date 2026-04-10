#!/usr/bin/env bash

# =========================
# Xray + Hysteria2 双协议安装脚本（增强完整版）
# VLESS-Reality | Hysteria2
# =========================

export LANG=en_US.UTF-8
set -u
umask 077

# ---------- 颜色 ----------
C_RED="\033[1;91m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_PURPLE="\033[1;35m"
C_SKY="\033[1;36m"
C_RESET="\033[0m"

red()    { echo -e "${C_RED}$*${C_RESET}"; }
green()  { echo -e "${C_GREEN}$*${C_RESET}"; }
yellow() { echo -e "${C_YELLOW}$*${C_RESET}"; }
purple() { echo -e "${C_PURPLE}$*${C_RESET}"; }
sky()    { echo -e "${C_SKY}$*${C_RESET}"; }

reading() {
  local prompt="$1" varname="$2"
  read -r -p "$(red "$prompt")" "$varname"
}

die() {
  red "错误: $*"
  exit 1
}

# ---------- 常量 ----------
XRAY_DIR="/etc/xray"
HYSTERIA_DIR="/etc/hysteria2"
CONFIG_DIR="${XRAY_DIR}/config.json"
CLIENT_DIR="${XRAY_DIR}/urls.txt"
WORK_DIR="/etc/proxy-scripts"
INFO_FILE="${WORK_DIR}/info.conf"

DEFAULT_REALITY_SNI="www.nvidia.com"
VLESS_PORT=${PORT:-$(shuf -i 10000-50000 -n 1)}
HY2_PORT=$((VLESS_PORT + 2))

# 若设置了 SCRIPT_URL，会生成远程更新型 xr 命令；否则生成本地提示型 xr
SCRIPT_URL="${SCRIPT_URL:-}"

# ---------- 基础工具 ----------
check_root() {
  [[ "${EUID}" -ne 0 ]] && die "请在 root 用户下运行"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_system() {
  if [[ -f /etc/alpine-release ]]; then
    echo "alpine"
  elif [[ -f /etc/debian_version ]]; then
    echo "debian"
  elif [[ -f /etc/redhat-release ]]; then
    echo "redhat"
  else
    echo "unknown"
  fi
}

detect_arch() {
  local raw
  raw="$(uname -m)"
  case "$raw" in
    x86_64) echo "amd64" ;;
    i386|i686|x86) echo "386" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    s390x) echo "s390x" ;;
    *) die "不支持的架构: $raw" ;;
  esac
}

manage_packages() {
  local action="$1"; shift
  local pkg
  for pkg in "$@"; do
    if [[ "$action" == "install" ]]; then
      if command_exists "$pkg"; then
        green "$pkg 已安装"
        continue
      fi
      yellow "正在安装: $pkg"
      if command_exists apt; then
        DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt install -y "$pkg" >/dev/null 2>&1 || die "安装 $pkg 失败"
      elif command_exists apk; then
        apk update >/dev/null 2>&1 || true
        apk add "$pkg" >/dev/null 2>&1 || die "安装 $pkg 失败"
      elif command_exists dnf; then
        dnf install -y "$pkg" >/dev/null 2>&1 || die "安装 $pkg 失败"
      elif command_exists yum; then
        yum install -y "$pkg" >/dev/null 2>&1 || die "安装 $pkg 失败"
      else
        die "未知包管理器，无法安装 $pkg"
      fi
    fi
  done
}

ensure_dirs() {
  mkdir -p "$XRAY_DIR" "$HYSTERIA_DIR" "$WORK_DIR"
}

get_latest_version_no_v() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name|sub("^v";"")'
}

get_latest_tag_raw() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name'
}

port_in_use() {
  local p="$1"
  if command_exists ss; then
    ss -lntup 2>/dev/null | grep -qE "[\:\.]${p}\b"
  elif command_exists netstat; then
    netstat -lntup 2>/dev/null | grep -qE "[\:\.]${p}\b"
  else
    return 1
  fi
}

allow_port() {
  local rule port proto
  for rule in "$@"; do
    port="${rule%/*}"
    proto="${rule#*/}"

    command_exists ufw && ufw allow "${port}/${proto}" >/dev/null 2>&1 || true

    if command_exists firewall-cmd && command_exists systemctl; then
      if systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
      fi
    fi

    command_exists iptables  && (iptables  -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || iptables  -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1) || true
    command_exists ip6tables && (ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || ip6tables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1) || true
  done

  command_exists netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
  [[ -f /etc/init.d/iptables ]] && /etc/init.d/iptables save >/dev/null 2>&1 || true
}

get_realip() {
  local ipv4 ipv6
  ipv4="$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ipv4" ]] && ipv4="$(curl -4 -fsS --max-time 4 https://ip.sb 2>/dev/null || true)"
  [[ -z "$ipv4" ]] && ipv4="$(curl -4 -fsS --max-time 4 https://ifconfig.me 2>/dev/null || true)"

  ipv6="$(curl -6 -fsS --max-time 4 https://api64.ipify.org 2>/dev/null || true)"
  [[ -z "$ipv6" ]] && ipv6="$(curl -6 -fsS --max-time 4 https://ip.sb 2>/dev/null || true)"

  if [[ -n "$ipv4" ]]; then
    echo "$ipv4"
  elif [[ -n "$ipv6" ]]; then
    echo "[$ipv6]"
  else
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

generate_uuid() {
  if command_exists uuidgen; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
  fi
}

generate_password() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24; }

extract_x25519_keys() {
  local out="$1" pri pub

  # PrivateKey: xxxx
  pri="$(echo "$out" | sed -nE 's/.*PrivateKey:[[:space:]]*([A-Za-z0-9+\/=_-]+).*/\1/p' | head -n1)"
  # PublicKey: xxxx
  pub="$(echo "$out" | sed -nE 's/.*PublicKey:[[:space:]]*([A-Za-z0-9+\/=_-]+).*/\1/p' | head -n1)"

  # 兼容：Password (PublicKey): xxxx
  [[ -z "$pub" ]] && pub="$(echo "$out" | sed -nE 's/.*Password[[:space:]]*\(PublicKey\):[[:space:]]*([A-Za-z0-9+\/=_-]+).*/\1/p' | head -n1)"

  # 兼容旧格式：Private key / Public key
  [[ -z "$pri" ]] && pri="$(echo "$out" | awk '/Private key:/ {print $3}' | head -n1)"
  [[ -z "$pub" ]] && pub="$(echo "$out" | awk '/Public key:/ {print $3}' | head -n1)"

  # 兜底：只要包含 Password: 也尝试取第二列
  [[ -z "$pub" ]] && pub="$(echo "$out" | awk '/Password/ {print $NF}' | head -n1)"

  [[ -n "$pri" && -n "$pub" ]] || return 1
  echo "${pri}|${pub}"
}


# ---------- 安装 ----------
install_xray() {
  purple "正在安装 Xray..."
  local arch ver url
  arch="$(detect_arch)"
  ver="$(get_latest_version_no_v "XTLS/Xray-core")"
  [[ -n "$ver" && "$ver" != "null" ]] || die "获取 Xray 版本失败"

  ensure_dirs

  case "$arch" in
    amd64) url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-64.zip" ;;
    arm64) url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-arm64-v8a.zip" ;;
    armv7) url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-arm32-v7a.zip" ;;
    386)   url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-32.zip" ;;
    *) die "Xray 暂不支持架构: $arch" ;;
  esac

  cd /tmp || die "无法进入 /tmp"
  rm -f Xray.zip
  curl -fL --retry 3 -o Xray.zip "$url" || die "下载 Xray 失败"
  unzip -o Xray.zip -d "$XRAY_DIR" xray geosite.dat geoip.dat >/dev/null || die "解压 Xray 失败"
  chmod +x "${XRAY_DIR}/xray"
  rm -f Xray.zip

  "${XRAY_DIR}/xray" version >/dev/null 2>&1 || die "Xray 二进制不可执行"
  green "Xray 安装完成"
}

install_hysteria2() {
  purple "正在安装 Hysteria2..."
  local arch ver arch_file url
  arch="$(detect_arch)"
  ver="$(get_latest_tag_raw "apernet/hysteria")"
  [[ -n "$ver" && "$ver" != "null" ]] || die "获取 Hysteria2 版本失败"

  ensure_dirs

  case "$arch" in
    amd64) arch_file="linux-amd64" ;;
    arm64) arch_file="linux-arm64" ;;
    armv7) arch_file="linux-arm" ;;
    386)   arch_file="linux-386" ;;
    *) die "Hysteria2 暂不支持架构: $arch" ;;
  esac

  url="https://github.com/apernet/hysteria/releases/download/${ver}/hysteria-${arch_file}"
  curl -fL --retry 3 -o "${HYSTERIA_DIR}/hysteria2" "$url" || die "下载 Hysteria2 失败"
  chmod +x "${HYSTERIA_DIR}/hysteria2"

  "${HYSTERIA_DIR}/hysteria2" version >/dev/null 2>&1 || die "Hysteria2 二进制不可执行"
  green "Hysteria2 安装完成"
}

# ---------- 配置 ----------
generate_xray_config() {
  local uuid="$1" private_key="$2" dns_strategy="$3" sni="$4"
  cat > "${CONFIG_DIR}" <<EOF
{
  "log": {
    "disabled": false,
    "level": "warning",
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      {
        "tag": "local",
        "address": "local",
        "strategy": "${dns_strategy}"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "::",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${sni}:443",
          "serverNames": ["${sni}"],
          "privateKey": "${private_key}",
          "shortIds": [""]
        }
      },
      "tag": "vless-reality"
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF
}

generate_hysteria2_config() {
  local password="$1" sni="$2"
  cat > "${HYSTERIA_DIR}/config.yaml" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${HYSTERIA_DIR}/cert.pem
  key: ${HYSTERIA_DIR}/private.key

auth:
  type: password
  password: "${password}"

quic:
  initStreamReceiveWindow: 65536
  maxStreamReceiveWindow: 1048576
  initConnReceiveWindow: 15728640
  maxConnReceiveWindow: 62914560
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false

masquerade:
  type: proxy
  proxy:
    url: https://${sni}
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF
}

save_info() {
  cat > "${INFO_FILE}" <<EOF
UUID=$1
PASSWORD=$2
PRIVATE_KEY=$3
PUBLIC_KEY=$4
VLESS_PORT=$5
HY2_PORT=$6
REALITY_SNI=$7
EOF
  chmod 600 "${INFO_FILE}"
}

load_info() {
  [[ -f "${INFO_FILE}" ]] || return 1
  # shellcheck disable=SC1090
  source "${INFO_FILE}"
  return 0
}

generate_config() {
  purple "正在生成配置..."
  ensure_dirs

  local UUID PASSWORD output pair PRIVATE_KEY PUBLIC_KEY dns_strategy sni
  UUID="$(generate_uuid)"
  PASSWORD="$(generate_password)"
  sni="${DEFAULT_REALITY_SNI}"

  output="$("${XRAY_DIR}/xray" x25519 2>/dev/null || true)"
  pair="$(extract_x25519_keys "$output" || true)"
  [[ -n "$pair" ]] || die "Reality 密钥生成失败，x25519 输出异常: ${output}"

  PRIVATE_KEY="${pair%%|*}"
  PUBLIC_KEY="${pair##*|}"

  openssl ecparam -genkey -name prime256v1 -out "${HYSTERIA_DIR}/private.key" >/dev/null 2>&1 || die "生成证书私钥失败"
  openssl req -new -x509 -days 3650 -key "${HYSTERIA_DIR}/private.key" -out "${HYSTERIA_DIR}/cert.pem" -subj "/CN=${sni}" >/dev/null 2>&1 || die "生成证书失败"

  dns_strategy="prefer_ipv4"
  ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && dns_strategy="prefer_ipv4"
  ping -6 -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1 && [[ "$dns_strategy" != "prefer_ipv4" ]] && dns_strategy="prefer_ipv6"

  generate_xray_config "$UUID" "$PRIVATE_KEY" "$dns_strategy" "$sni"
  generate_hysteria2_config "$PASSWORD" "$sni"
  save_info "$UUID" "$PASSWORD" "$PRIVATE_KEY" "$PUBLIC_KEY" "$VLESS_PORT" "$HY2_PORT" "$sni"

  "${XRAY_DIR}/xray" run -test -config "${CONFIG_DIR}" >/dev/null 2>&1 || die "Xray 配置校验失败"
  "${HYSTERIA_DIR}/hysteria2" server -c "${HYSTERIA_DIR}/config.yaml" --check >/dev/null 2>&1 || die "Hysteria2 配置校验失败"

  green "配置生成完成"
}

# ---------- 服务 ----------
create_xray_service() {
  local system
  system="$(detect_system)"
  if [[ "$system" == "alpine" ]]; then
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="${XRAY_DIR}/xray"
command_args="run -config ${CONFIG_DIR}"
command_background=true
pidfile="/run/xray.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
  else
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_DIR}/xray run -config ${CONFIG_DIR}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
  fi
}

create_hysteria2_service() {
  local system
  system="$(detect_system)"
  if [[ "$system" == "alpine" ]]; then
    cat > /etc/init.d/hysteria2 <<EOF
#!/sbin/openrc-run
description="Hysteria2 Service"
command="${HYSTERIA_DIR}/hysteria2"
command_args="server -c ${HYSTERIA_DIR}/config.yaml"
command_background=true
pidfile="/run/hysteria2.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/hysteria2
    rc-update add hysteria2 default >/dev/null 2>&1 || true
  else
    cat > /etc/systemd/system/hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${HYSTERIA_DIR}/hysteria2 server -c ${HYSTERIA_DIR}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria2 >/dev/null 2>&1 || true
  fi
}

manage_service() {
  local name="$1" action="$2" system
  system="$(detect_system)"
  case "$action" in
    start|stop|restart)
      if [[ "$system" == "alpine" ]]; then
        rc-service "$name" "$action"
      else
        systemctl "$action" "$name"
      fi
      ;;
    status)
      if [[ "$system" == "alpine" ]]; then
        rc-service "$name" status 2>&1 | grep -q "started" && echo "running" || echo "not running"
      else
        systemctl is-active "$name" >/dev/null 2>&1 && echo "running" || echo "not running"
      fi
      ;;
  esac
}

setup_time_sync() {
  purple "配置时间同步..."
  local system
  system="$(detect_system)"
  if [[ "$system" == "alpine" ]]; then
    manage_packages install chrony
    rc-update add chronyd default >/dev/null 2>&1 || true
    rc-service chronyd start >/dev/null 2>&1 || true
  else
    manage_packages install chrony
    systemctl enable chronyd >/dev/null 2>&1 || true
    systemctl start chronyd >/dev/null 2>&1 || true
  fi
  green "时间同步配置完成"
}

# ---------- 链接 ----------
generate_urls() {
  purple "正在生成节点链接..."
  load_info || die "配置文件不存在"

  local server_ip isp sni
  server_ip="$(get_realip)"
  [[ -n "$server_ip" ]] || server_ip="0.0.0.0"

  isp="$(curl -fsS --max-time 3 https://ipapi.co/json 2>/dev/null | jq -r '.country_code + "-" + (.org // "VPS")' 2>/dev/null || echo "VPS")"
  isp="${isp// /_}"

  sni="${REALITY_SNI:-$DEFAULT_REALITY_SNI}"

  local VLESS_URL="vless://${UUID}@${server_ip}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp&headerType=none#${isp}"
  local HY2_URL="hysteria2://${PASSWORD}@${server_ip}:${HY2_PORT}/?sni=${sni}&insecure=1&alpn=h3&obfs=none#${isp}"

  cat > "${CLIENT_DIR}" <<EOF
===========================================
        Xray + Hysteria2 节点信息
===========================================

[VLESS-Reality]
${VLESS_URL}

[Hysteria2]
${HY2_URL}

===========================================
端口信息:
  VLESS-Reality: ${VLESS_PORT}
  Hysteria2: ${HY2_PORT}

认证信息:
  UUID: ${UUID}
  Hysteria2 密码: ${PASSWORD}
  PublicKey: ${PUBLIC_KEY}

Reality 伪装: ${sni}
===========================================
EOF

  chmod 600 "${CLIENT_DIR}"
  green "节点链接已生成: ${CLIENT_DIR}"
}

show_urls() {
  [[ -f "${CLIENT_DIR}" ]] || { red "请先安装"; return 1; }
  clear
  cat "${CLIENT_DIR}"
  echo
}

# ---------- 配置修改 ----------
change_port() {
  load_info || { red "请先安装"; return 1; }

  clear
  green "=== 修改端口 ==="
  green "1. VLESS-Reality (当前: ${VLESS_PORT})"
  green "2. Hysteria2 (当前: ${HY2_PORT})"
  purple "0. 返回"
  reading "请选择: " choice

  case "$choice" in
    1)
      reading "输入新的 VLESS 端口 (10000-50000): " new_port
      [[ "$new_port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }
      (( new_port >= 10000 && new_port <= 50000 )) || { red "端口范围错误"; return 1; }
      port_in_use "$new_port" && { red "端口已占用"; return 1; }

      sed -i -E "s/\"port\": [0-9]+/\"port\": ${new_port}/" "${CONFIG_DIR}"
      sed -i -E "s/^VLESS_PORT=.*/VLESS_PORT=${new_port}/" "${INFO_FILE}"
      VLESS_PORT="$new_port"
      allow_port "${VLESS_PORT}/tcp"
      manage_service xray restart
      generate_urls
      green "VLESS 端口已更新: ${VLESS_PORT}"
      ;;
    2)
      reading "输入新的 Hysteria2 端口: " new_port
      [[ "$new_port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }
      (( new_port >= 1 && new_port <= 65535 )) || { red "端口范围错误"; return 1; }
      port_in_use "$new_port" && { red "端口已占用"; return 1; }

      sed -i -E "s/^listen: :.*/listen: :${new_port}/" "${HYSTERIA_DIR}/config.yaml"
      sed -i -E "s/^HY2_PORT=.*/HY2_PORT=${new_port}/" "${INFO_FILE}"
      HY2_PORT="$new_port"
      allow_port "${HY2_PORT}/udp"
      manage_service hysteria2 restart
      generate_urls
      green "Hysteria2 端口已更新: ${HY2_PORT}"
      ;;
    0) return ;;
    *) red "无效选择" ;;
  esac
}

change_uuid() {
  load_info || { red "请先安装"; return 1; }
  clear
  green "=== 修改认证信息 ==="

  local c1 c2
  reading "生成新的 UUID? (y/n): " c1
  reading "生成新的 Hysteria2 密码? (y/n): " c2

  [[ "$c1" == "y" ]] && UUID="$(generate_uuid)"
  [[ "$c2" == "y" ]] && PASSWORD="$(generate_password)"

  sed -i -E "s/\"id\": \"[^\"]+\"/\"id\": \"${UUID}\"/" "${CONFIG_DIR}"
  sed -i -E "s/^  password: \".*\"/  password: \"${PASSWORD}\"/" "${HYSTERIA_DIR}/config.yaml"
  sed -i -E "s/^UUID=.*/UUID=${UUID}/" "${INFO_FILE}"
  sed -i -E "s/^PASSWORD=.*/PASSWORD=${PASSWORD}/" "${INFO_FILE}"

  manage_service xray restart
  manage_service hysteria2 restart
  generate_urls

  green "认证信息已更新"
  green "UUID: ${UUID}"
  green "密码: ${PASSWORD}"
}

change_sni() {
  load_info || { red "请先安装"; return 1; }

  clear
  green "=== 修改 Reality 伪装域名 ==="
  green "1. www.microsoft.com"
  green "2. www.apple.com"
  green "3. www.nvidia.com"
  green "4. www.intel.com"
  green "5. www.adobe.com"
  green "6. 自定义"
  purple "0. 返回"
  reading "请选择: " choice

  local new_sni output pair new_private new_public
  case "$choice" in
    1) new_sni="www.microsoft.com" ;;
    2) new_sni="www.apple.com" ;;
    3) new_sni="www.nvidia.com" ;;
    4) new_sni="www.intel.com" ;;
    5) new_sni="www.adobe.com" ;;
    6) reading "输入自定义域名: " new_sni ;;
    0) return ;;
    *) red "无效选择"; return 1 ;;
  esac

  output="$("${XRAY_DIR}/xray" x25519 2>/dev/null || true)"
  pair="$(extract_x25519_keys "$output" || true)"
  [[ -n "$pair" ]] || { red "重新生成密钥失败"; return 1; }
  new_private="${pair%%|*}"
  new_public="${pair##*|}"

  sed -i -E "s/\"dest\": \"[^\"]+\"/\"dest\": \"${new_sni}:443\"/" "${CONFIG_DIR}"
  sed -i -E "s/\"serverNames\": \[[^]]*\]/\"serverNames\": [\"${new_sni}\"]/" "${CONFIG_DIR}"
  sed -i -E "s/\"privateKey\": \"[^\"]+\"/\"privateKey\": \"${new_private}\"/" "${CONFIG_DIR}"

  sed -i -E "s/^    url: .*/    url: https:\/\/${new_sni}/" "${HYSTERIA_DIR}/config.yaml"

  sed -i -E "s/^REALITY_SNI=.*/REALITY_SNI=${new_sni}/" "${INFO_FILE}"
  sed -i -E "s/^PRIVATE_KEY=.*/PRIVATE_KEY=${new_private}/" "${INFO_FILE}"
  sed -i -E "s/^PUBLIC_KEY=.*/PUBLIC_KEY=${new_public}/" "${INFO_FILE}"

  manage_service xray restart
  manage_service hysteria2 restart
  generate_urls
  green "SNI 已更新: ${new_sni}"
}

# ---------- 快捷指令 ----------
create_shortcut() {
  if [[ -n "$SCRIPT_URL" ]]; then
    cat > /usr/local/bin/xr <<EOF
#!/usr/bin/env bash
bash <(curl -fsSL "${SCRIPT_URL}") "\$@"
EOF
  else
    cat > /usr/local/bin/xr <<'EOF'
#!/usr/bin/env bash
echo "请先设置 SCRIPT_URL 后重新安装，或直接运行原脚本文件。"
exit 1
EOF
  fi
  chmod +x /usr/local/bin/xr
  green "快捷命令 xr 已创建"
}

# ---------- 主流程 ----------
install_all() {
  clear
  purple "开始安装 Xray + Hysteria2..."

  local system
  system="$(detect_system)"
  [[ "$system" != "unknown" ]] || die "不支持的系统"
  green "系统: ${system}"

  manage_packages install curl jq unzip openssl iproute2

  port_in_use "$VLESS_PORT" && die "VLESS 端口已占用: $VLESS_PORT"
  port_in_use "$HY2_PORT" && die "Hysteria2 端口已占用: $HY2_PORT"

  install_xray
  install_hysteria2
  generate_config
  create_xray_service
  create_hysteria2_service
  setup_time_sync

  purple "配置防火墙..."
  allow_port "${VLESS_PORT}/tcp" "${HY2_PORT}/udp"

  purple "启动服务..."
  manage_service xray start || die "xray 启动失败"
  manage_service hysteria2 start || die "hysteria2 启动失败"
  sleep 2

  generate_urls
  create_shortcut

  clear
  green "=== 安装完成 ==="
  show_urls
}

uninstall_all() {
  reading "确定要卸载 Xray + Hysteria2? (y/n): " c
  [[ "$c" == "y" ]] || { yellow "已取消"; return; }

  yellow "正在卸载..."
  manage_service xray stop >/dev/null 2>&1 || true
  manage_service hysteria2 stop >/dev/null 2>&1 || true

  local system
  system="$(detect_system)"
  if [[ "$system" == "alpine" ]]; then
    rc-update del xray default >/dev/null 2>&1 || true
    rc-update del hysteria2 default >/dev/null 2>&1 || true
  else
    systemctl disable xray hysteria2 >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria2.service
  rm -f /etc/init.d/xray /etc/init.d/hysteria2
  rm -rf "$XRAY_DIR" "$HYSTERIA_DIR" "$WORK_DIR"
  rm -f /usr/local/bin/xr
  green "卸载完成"
}

# ---------- 菜单 ----------
service_menu() {
  while true; do
    clear
    green "=== 服务管理 ==="
    green "Xray: $(manage_service xray status)"
    green "Hysteria2: $(manage_service hysteria2 status)"
    echo "1) 启动  2) 停止  3) 重启  0) 返回"
    reading "请选择: " ch
    case "$ch" in
      1) manage_service xray start; manage_service hysteria2 start ;;
      2) manage_service xray stop; manage_service hysteria2 stop ;;
      3) manage_service xray restart; manage_service hysteria2 restart ;;
      0) return ;;
      *) red "无效选择" ;;
    esac
    reading "回车继续..." _
  done
}

config_menu() {
  while true; do
    clear
    green "=== 配置管理 ==="
    echo "1) 修改端口"
    echo "2) 修改认证信息"
    echo "3) 修改 SNI"
    echo "4) 查看节点链接"
    echo "0) 返回"
    reading "请选择: " ch
    case "$ch" in
      1) change_port ;;
      2) change_uuid ;;
      3) change_sni ;;
      4) show_urls ;;
      0) return ;;
      *) red "无效选择" ;;
    esac
    reading "回车继续..." _
  done
}

main_menu() {
  while true; do
    clear
    purple "╔═══════════════════════════════════════╗"
    purple "║    Xray + Hysteria2 管理脚本(增强)    ║"
    purple "╚═══════════════════════════════════════╝"
    echo

    local xray_installed=false hy2_installed=false
    [[ -x "${XRAY_DIR}/xray" ]] && xray_installed=true
    [[ -x "${HYSTERIA_DIR}/hysteria2" ]] && hy2_installed=true

    if [[ "$xray_installed" == true && "$hy2_installed" == true ]]; then
      sky "Xray: $(manage_service xray status)"
      sky "Hysteria2: $(manage_service hysteria2 status)"
      echo
    fi

    echo "1) 安装 Xray + Hysteria2"
    echo "2) 卸载 Xray + Hysteria2"
    echo "3) 服务管理"
    echo "4) 配置管理"
    echo "5) 查看节点链接"
    echo "6) 查看服务器 IP"
    echo "0) 退出"

    reading "请选择 (0-6): " choice
    case "$choice" in
      1)
        if [[ "$xray_installed" == true || "$hy2_installed" == true ]]; then
          yellow "检测到已安装，请先卸载或手动清理"
        else
          install_all
        fi
        reading "回车继续..." _
        ;;
      2) uninstall_all; reading "回车继续..." _ ;;
      3)
        if [[ "$xray_installed" == true && "$hy2_installed" == true ]]; then
          service_menu
        else
          yellow "请先安装"
          reading "回车继续..." _
        fi
        ;;
      4)
        if [[ "$xray_installed" == true && "$hy2_installed" == true ]]; then
          config_menu
        else
          yellow "请先安装"
          reading "回车继续..." _
        fi
        ;;
      5) show_urls; reading "回车继续..." _ ;;
      6) purple "服务器 IP: $(get_realip)"; reading "回车继续..." _ ;;
      0) purple "退出"; exit 0 ;;
      *) red "无效选择"; reading "回车继续..." _ ;;
    esac
  done
}

# ---------- 入口 ----------
check_root
trap 'echo; red "已取消操作"; exit 130' INT
main_menu
