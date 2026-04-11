#!/usr/bin/env bash
set -euo pipefail

# ========= 参数 =========
XRAY_DIR="/etc/xray"
WORK_DIR="/etc/proxy-scripts"
INFO_FILE="${WORK_DIR}/info.conf"
CONFIG_FILE="${XRAY_DIR}/config.json"
URLS_FILE="${XRAY_DIR}/urls.txt"

SNI="${SNI:-www.nvidia.com}"
VLESS_PORT="${PORT:-$(shuf -i 10000-50000 -n 1)}"

# ========= 输出 =========
red(){ echo -e "\033[1;91m$*\033[0m"; }
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
die(){ red "错误: $*"; exit 1; }

# ========= 校验 =========
check_env() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
  [ -f /etc/debian_version ] || die "仅支持 Debian/Ubuntu"
}

# ========= 工具 =========
get_arch() {
  case "$(uname -m)" in
    x86_64) echo "64" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    armv7l) echo "arm32-v7a" ;;
    i386|i686) echo "32" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

install_deps() {
  yellow "安装依赖..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y >/dev/null
  apt install -y curl jq unzip openssl iptables >/dev/null
}

get_real_ip() {
  local ip4 ip6
  ip4="$(curl -4fsS --max-time 4 https://api.ipify.org || true)"
  ip6="$(curl -6fsS --max-time 4 https://api64.ipify.org || true)"
  if [ -n "$ip4" ]; then
    echo "$ip4"
  elif [ -n "$ip6" ]; then
    echo "[$ip6]"
  else
    echo "127.0.0.1"
  fi
}

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen; else cat /proc/sys/kernel/random/uuid; fi
}

extract_keys() {
  local out="$1" pri pub
  pri="$(printf '%s\n' "$out" | awk -F': ' '/^PrivateKey:/ {print $2}' | head -n1)"
  pub="$(printf '%s\n' "$out" | awk -F': ' '/^PublicKey:/ {print $2}' | head -n1)"
  [ -z "$pub" ] && pub="$(printf '%s\n' "$out" | awk -F': ' '/^Password \(PublicKey\):/ {print $2}' | head -n1)"
  [ -z "$pri" ] && pri="$(printf '%s\n' "$out" | awk '/^Private key:/ {print $3}' | head -n1)"
  [ -z "$pub" ] && pub="$(printf '%s\n' "$out" | awk '/^Public key:/ {print $3}' | head -n1)"

  [[ "$pri" =~ ^[A-Za-z0-9_-]{43,44}$ ]] || return 1
  [[ "$pub" =~ ^[A-Za-z0-9_-]{43,44}$ ]] || return 1
  echo "${pri}|${pub}"
}

# ========= 安装 Xray =========
install_xray() {
  yellow "安装 Xray..."
  mkdir -p "$XRAY_DIR" "$WORK_DIR"

  local ver arch url
  ver="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name|sub("^v";"")')"
  [ -n "$ver" ] || die "获取 Xray 版本失败"

  arch="$(get_arch)"
  if [ "$arch" = "64" ]; then
    url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-64.zip"
  elif [ "$arch" = "32" ]; then
    url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-32.zip"
  else
    url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-${arch}.zip"
  fi

  cd /tmp
  curl -fL --retry 3 -o xray.zip "$url"
  unzip -o xray.zip -d "$XRAY_DIR" xray geosite.dat geoip.dat >/dev/null
  chmod +x "${XRAY_DIR}/xray"
  rm -f xray.zip
}

# ========= 配置 =========
gen_config() {
  yellow "生成配置..."
  local uuid out pair pri pub
  uuid="$(gen_uuid)"

  out="$("${XRAY_DIR}/xray" x25519 2>/dev/null || true)"
  pair="$(extract_keys "$out" || true)"
  [ -n "$pair" ] || die "x25519 密钥解析失败: $out"
  pri="${pair%%|*}"
  pub="${pair##*|}"

  cat > "$CONFIG_FILE" <<EOF
{
  "log": { "disabled": false, "level": "warning" },
  "inbounds": [
    {
      "listen": "::",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${uuid}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${SNI}:443",
          "serverNames": ["${SNI}"],
          "privateKey": "${pri}",
          "shortIds": [""]
        }
      },
      "tag": "vless-reality"
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

  "${XRAY_DIR}/xray" run -test -config "$CONFIG_FILE" >/dev/null || die "Xray 配置校验失败"

  cat > "$INFO_FILE" <<EOF
UUID=${uuid}
PRIVATE_KEY=${pri}
PUBLIC_KEY=${pub}
VLESS_PORT=${VLESS_PORT}
SNI=${SNI}
EOF
  chmod 600 "$INFO_FILE"
}

# ========= 服务 =========
create_service() {
  yellow "创建 systemd 服务..."
  cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/etc/xray/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable xray >/dev/null
}

open_port() {
  yellow "放行端口 ${VLESS_PORT}/tcp ..."
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${VLESS_PORT}/tcp" >/dev/null 2>&1 || true
  fi
  iptables -C INPUT -p tcp --dport "${VLESS_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "${VLESS_PORT}" -j ACCEPT
}

start_service() {
  yellow "启动服务..."
  systemctl restart xray
  systemctl is-active xray >/dev/null || die "Xray 启动失败"
}

# ========= 输出节点 =========
gen_url() {
  # shellcheck disable=SC1090
  source "$INFO_FILE"

  local ip tag vless
  ip="$(get_real_ip)"
  tag="$(curl -fsS --max-time 3 https://ipapi.co/json 2>/dev/null | jq -r '.country_code + "-" + (.org // "VPS")' 2>/dev/null || echo VPS)"
  tag="${tag// /_}"

  vless="vless://${UUID}@${ip}:${VLESS_PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp&headerType=none#${tag}"

  cat > "$URLS_FILE" <<EOF
[VLESS-Reality]
${vless}

UUID: ${UUID}
Port: ${VLESS_PORT}
SNI: ${SNI}
PublicKey: ${PUBLIC_KEY}
EOF

  green "安装完成！"
  echo
  cat "$URLS_FILE"
  echo
  green "配置文件: ${CONFIG_FILE}"
  green "节点文件: ${URLS_FILE}"
  green "服务状态: systemctl status xray --no-pager"
}

main() {
  check_env
  install_deps
  install_xray
  gen_config
  create_service
  open_port
  start_service
  gen_url
}

main "$@"
