#!/bin/bash

# =========================
# Xray + Hysteria2 双协议安装脚本
# VLESS-Reality | Hysteria2
# 最后更新时间: 2025.01.10
# =========================

export LANG=en_US.UTF-8

# 定义颜色
red="\033[1;91m"
green="\033[1;32m"
yellow="\033[1;33m"
purple="\033[1;35m"
skyblue="\033[1;36m"
re="\033[0m"

# 颜色输出函数
red() { echo -e "${red}$1${re}"; }
green() { echo -e "${green}$1${re}"; }
yellow() { echo -e "${yellow}$1${re}"; }
purple() { echo -e "${purple}$1${re}"; }
skyblue() { echo -e "${skyblue}$1${re}"; }
reading() {
    local prompt="$1"
    local varname="$2"
    read -p "$(red "$prompt")" "$varname"
}

# 定义常量
XRAY_DIR="/etc/xray"
HYSTERIA_DIR="/etc/hysteria2"
CONFIG_DIR="${XRAY_DIR}/config.json"
CLIENT_DIR="${XRAY_DIR}/urls.txt"
WORK_DIR="/etc/proxy-scripts"

# 默认配置
DEFAULT_REALITY_SNI="www.nvidia.com"
VLESS_PORT=${PORT:-$(shuf -i 10000-50000 -n 1)}
HY2_PORT=$((VLESS_PORT + 2))

# =========================
# 工具函数
# =========================

# 检查是否为root
check_root() {
    [[ $EUID -ne 0 ]] && red "请在root用户下运行脚本" && exit 1
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检测系统类型
detect_system() {
    if [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "redhat"
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

# 检测系统架构
detect_arch() {
    local ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') echo 'amd64' ;;
        'x86' | 'i686' | 'i386') echo '386' ;;
        'aarch64' | 'arm64') echo 'arm64' ;;
        'armv7l') echo 'armv7' ;;
        's390x') echo 's390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac
}

# 获取最新版本
get_latest_version() {
    local repo=$1
    curl -s "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name | sub("^v"; "")'
}

# 包管理函数
manage_packages() {
    local action=$1
    shift

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} 已安装"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt install -y "$package" >/dev/null 2>&1
            elif command_exists apk; then
                apk update >/dev/null 2>&1
                apk add "$package" >/dev/null 2>&1
            elif command_exists yum; then
                yum install -y "$package" >/dev/null 2>&1
            elif command_exists dnf; then
                dnf install -y "$package" >/dev/null 2>&1
            else
                red "无法安装 ${package}，未知的包管理器"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} 未安装"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" >/dev/null 2>&1
            elif command_exists apk; then
                apk del "$package" >/dev/null 2>&1
            elif command_exists yum; then
                yum remove -y "$package" >/dev/null 2>&1
            elif command_exists dnf; then
                dnf remove -y "$package" >/dev/null 2>&1
            fi
        fi
    done
}

# 防火墙端口放行
allow_port() {
    for rule in "$@"; do
        local port=${rule%/*}
        local proto=${rule#*/}

        # ufw
        if command_exists ufw; then
            ufw allow ${port}/${proto} >/dev/null 2>&1
        fi

        # firewalld
        if command_exists firewall-cmd; then
            systemctl is-active firewalld >/dev/null 2>&1 && \
                firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1 && \
                firewall-cmd --reload >/dev/null 2>&1
        fi

        # iptables
        if command_exists iptables; then
            iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1 || \
                iptables -I INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1
        fi

        # ip6tables
        if command_exists ip6tables; then
            ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1 || \
                ip6tables -I INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1
        fi
    done

    # 保存规则
    if command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1
    elif [ -f /etc/init.d/iptables ]; then
        /etc/init.d/iptables save >/dev/null 2>&1
    fi
}

# 获取真实IP
get_realip() {
    local ip=$(curl -4 -sm 2 ip.sb 2>/dev/null)
    local get_ipv6=$(curl -6 -sm 2 ip.sb 2>/dev/null)

    if [ -z "$ip" ]; then
        echo "[${get_ipv6}]"
    elif curl -4 -sm 2 http://ipinfo.io/org 2>/dev/null | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        echo "[${get_ipv6}]"
    else
        echo "$ip"
    fi
}

# 生成随机UUID
generate_uuid() {
    if command_exists uuidgen; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || \
        cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 8 | head -n 1 | \
        xargs -I {} echo "{}$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 12 | head -n 1)"
    fi
}

# 生成随机密码
generate_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# =========================
# Xray 安装
# =========================

install_xray() {
    clear
    purple "正在安装 Xray..."

    local ARCH=$(detect_arch)
    local SYSTEM=$(detect_system)
    local XRAY_VERSION=$(get_latest_version "XTLS/Xray-core")

    # 创建目录
    mkdir -p "${XRAY_DIR}"
    mkdir -p "${WORK_DIR}"

    # 下载 Xray
    yellow "下载 Xray-core v${XRAY_VERSION} (${ARCH})..."
    local XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"

    if [ "$ARCH" == "arm64" ]; then
        XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-arm64-v8a.zip"
    elif [ "$ARCH" == "armv7" ]; then
        XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-arm32-v7a.zip"
    elif [ "$ARCH" == "386" ]; then
        XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-32.zip"
    fi

    cd /tmp
    rm -f Xray-*.zip
    curl -L -o Xray.zip "${XRAY_URL}"
    unzip -o Xray.zip -d "${XRAY_DIR}" xray geosite.dat geoip.dat
    chmod +x ${XRAY_DIR}/xray
    rm -f Xray.zip

    green "Xray 安装完成"
}

# =========================
# Hysteria2 安装
# =========================

install_hysteria2() {
    clear
    purple "正在安装 Hysteria2..."

    local ARCH=$(detect_arch)
    # Hysteria 仓库地址和文件名
    local HY2_VERSION=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r '.tag_name')

    # 创建目录
    mkdir -p "${HYSTERIA_DIR}"

    # 下载 Hysteria2
    yellow "下载 Hysteria2 ${HY2_VERSION} (${ARCH})..."

    # 根据架构选择正确的文件名
    local arch_file="linux-amd64"
    if [ "$ARCH" == "arm64" ]; then
        arch_file="linux-arm64"
    elif [ "$ARCH" == "armv7" ]; then
        arch_file="linux-arm"
    elif [ "$ARCH" == "386" ]; then
        arch_file="linux-386"
    fi

    # Hysteria 使用 hysteria-xxx 文件名
    local HY2_URL="https://github.com/apernet/hysteria/releases/download/${HY2_VERSION}/hysteria-${arch_file}"

    curl -L -o "${HYSTERIA_DIR}/hysteria2" "${HY2_URL}"
    chmod +x ${HYSTERIA_DIR}/hysteria2

    green "Hysteria2 安装完成"
}

# =========================
# 配置生成
# =========================

generate_config() {
    purple "正在生成配置..."

    # 生成认证信息
    local UUID=$(generate_uuid)
    local PASSWORD=$(generate_password)

    # 生成 Reality 密钥对
    # 注意：Xray x25519 输出中 Password 字段就是客户端需要的 PublicKey
    local output=$(${XRAY_DIR}/xray x25519)
    local PRIVATE_KEY=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
    local PUBLIC_KEY=$(echo "${output}" | awk '/Password:/ {print $2}')

    # 生成自签名证书（用于 Hysteria2）
    openssl ecparam -genkey -name prime256v1 -out "${HYSTERIA_DIR}/private.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${HYSTERIA_DIR}/private.key" \
        -out "${HYSTERIA_DIR}/cert.pem" -subj "/CN=www.nvidia.com" 2>/dev/null

    # 检测网络类型
    local dns_strategy="prefer_ipv4"
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        dns_strategy="prefer_ipv4"
    elif ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1; then
        dns_strategy="prefer_ipv6"
    fi

    # 保存配置信息
    cat > "${WORK_DIR}/info.conf" << EOF
UUID=${UUID}
PASSWORD=${PASSWORD}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
VLESS_PORT=${VLESS_PORT}
HY2_PORT=${HY2_PORT}
REALITY_SNI=${DEFAULT_REALITY_SNI}
EOF

    chmod 600 "${WORK_DIR}/info.conf"

    # 生成 Xray 配置
    generate_xray_config "$UUID" "$PRIVATE_KEY" "$dns_strategy"

    # 生成 Hysteria2 配置
    generate_hysteria2_config "$PASSWORD"

    green "配置生成完成"
}

# 生成 Xray 配置文件
generate_xray_config() {
    local uuid=$1
    local private_key=$2
    local dns_strategy=$3

    cat > "${CONFIG_DIR}" << EOF
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
          "dest": "${DEFAULT_REALITY_SNI}:443",
          "serverNames": [
            "${DEFAULT_REALITY_SNI}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [""]
        }
      },
      "tag": "vless-reality"
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "route": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["vless-reality"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "port": "0-65535",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
}

# 生成 Hysteria2 配置文件
generate_hysteria2_config() {
    local password=$1

    cat > "${HYSTERIA_DIR}/config.yaml" << EOF
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
    url: https://www.nvidia.com
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps

socks5:
  enabled: false
EOF
}

# =========================
# 服务管理
# =========================

create_xray_service() {
    local SYSTEM=$(detect_system)

    if [ "$SYSTEM" == "alpine" ]; then
        # OpenRC 服务
        cat > /etc/init.d/xray << EOF
#!/sbin/openrc-run

description="Xray Service"
command="${XRAY_DIR}/xray"
command_args="run -config ${CONFIG_DIR}"
command_background=true
pidfile="/run/xray.pid"
depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default >/dev/null 2>&1
    else
        # systemd 服务
        cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_DIR}/xray run -config ${CONFIG_DIR}
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
    fi
}

create_hysteria2_service() {
    local SYSTEM=$(detect_system)

    if [ "$SYSTEM" == "alpine" ]; then
        # OpenRC 服务
        cat > /etc/init.d/hysteria2 << EOF
#!/sbin/openrc-run

description="Hysteria2 Service"
command="${HYSTERIA_DIR}/hysteria2"
command_args="server -c ${HYSTERIA_DIR}/config.yaml"
command_background=true
pidfile="/run/hysteria2.pid"
depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/hysteria2
        rc-update add hysteria2 default >/dev/null 2>&1
    else
        # systemd 服务
        cat > /etc/systemd/system/hysteria2.service << EOF
[Unit]
Description=Hysteria2 Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${HYSTERIA_DIR}/hysteria2 server -c ${HYSTERIA_DIR}/config.yaml
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria2 >/dev/null 2>&1
    fi
}

# 通用服务管理
manage_service() {
    local service_name=$1
    local action=$2
    local SYSTEM=$(detect_system)

    case "$action" in
        start)
            if [ "$SYSTEM" == "alpine" ]; then
                rc-service ${service_name} start
            else
                systemctl start ${service_name}
            fi
            ;;
        stop)
            if [ "$SYSTEM" == "alpine" ]; then
                rc-service ${service_name} stop
            else
                systemctl stop ${service_name}
            fi
            ;;
        restart)
            if [ "$SYSTEM" == "alpine" ]; then
                rc-service ${service_name} restart
            else
                systemctl restart ${service_name}
            fi
            ;;
        status)
            if [ "$SYSTEM" == "alpine" ]; then
                rc-service ${service_name} status 2>&1 | grep -q "started" && echo "running" || echo "not running"
            else
                systemctl is-active ${service_name} 2>&1 | grep -q "^active$" && echo "running" || echo "not running"
            fi
            ;;
    esac
}

# =========================
# 时间同步
# =========================

setup_time_sync() {
    purple "配置时间同步..."

    local SYSTEM=$(detect_system)

    if [ "$SYSTEM" == "alpine" ]; then
        apk add chrony >/dev/null 2>&1
        rc-update add chronyd default >/dev/null 2>&1
        rc-service chronyd start >/dev/null 2>&1
    else
        manage_packages install chrony >/dev/null 2>&1
        systemctl enable chronyd >/dev/null 2>&1
        systemctl start chronyd >/dev/null 2>&1
    fi

    green "时间同步配置完成"
}

# =========================
# 节点信息生成
# =========================

generate_urls() {
    purple "正在生成节点链接..."

    # 读取配置
    if [ -f "${WORK_DIR}/info.conf" ]; then
        source "${WORK_DIR}/info.conf"
    else
        red "配置文件不存在"
        return 1
    fi

    # 获取服务器IP
    local SERVER_IP=$(get_realip)
    local ISP=$(curl -s --max-time 2 https://ipapi.co/json 2>/dev/null | \
        tr -d '\n[:space:]' | \
        sed 's/.*"country_code":"\([^"]*\)".*"org":"\([^"]*\)".*/\1-\2/' | \
        sed 's/ /_/g' 2>/dev/null || echo "VPS")

    # VLESS-Reality 链接
    local VLESS_URL="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEFAULT_REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp&headerType=none#${ISP}"

    # Hysteria2 链接
    local HY2_URL="hysteria2://${PASSWORD}@${SERVER_IP}:${HY2_PORT}/?sni=www.nvidia.com&insecure=1&alpn=h3&obfs=none#${ISP}"

    # 保存到文件
    cat > "${CLIENT_DIR}" << EOF
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

Reality 伪装: ${DEFAULT_REALITY_SNI}
===========================================
EOF

    chmod 600 "${CLIENT_DIR}"
    green "节点链接已生成"
}

# 显示节点信息
show_urls() {
    if [ ! -f "${CLIENT_DIR}" ]; then
        red "请先安装 Xray + Hysteria2"
        return 1
    fi

    clear
    cat "${CLIENT_DIR}"
    echo ""
}

# =========================
# 配置修改功能
# =========================

change_port() {
    if [ ! -f "${WORK_DIR}/info.conf" ]; then
        red "请先安装 Xray + Hysteria2"
        return 1
    fi

    source "${WORK_DIR}/info.conf"

    clear
    green "=== 修改端口 ===\n"
    green "1. VLESS-Reality 端口 (当前: ${VLESS_PORT})"
    green "2. Hysteria2 端口 (当前: ${HY2_PORT})"
    purple "0. 返回"

    reading "请选择: " choice

    case $choice in
        1)
            reading "输入新的 VLESS 端口 (10000-50000): " new_port
            if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 10000 ] || [ "$new_port" -gt 50000 ]; then
                red "无效的端口号"
                return 1
            fi

            # 更新配置
            sed -i "s/\"port\": ${VLESS_PORT}/\"port\": ${new_port}/" "${CONFIG_DIR}"

            # 防火墙
            allow_port ${new_port}/tcp

            # 更新配置文件
            sed -i "s/VLESS_PORT=.*/VLESS_PORT=${new_port}/" "${WORK_DIR}/info.conf"

            # 重启服务
            manage_service xray restart
            VLESS_PORT=$new_port
            generate_urls

            green "VLESS 端口已更新为: ${new_port}"
            ;;
        2)
            reading "输入新的 Hysteria2 端口: " new_port
            if [[ ! "$new_port" =~ ^[0-9]+$ ]]; then
                red "无效的端口号"
                return 1
            fi

            # 更新配置
            sed -i "s/listen: :${HY2_PORT}/listen: :${new_port}/" "${HYSTERIA_DIR}/config.yaml"

            # 防火墙
            allow_port ${new_port}/udp

            # 更新配置文件
            sed -i "s/HY2_PORT=.*/HY2_PORT=${new_port}/" "${WORK_DIR}/info.conf"

            # 重启服务
            manage_service hysteria2 restart
            HY2_PORT=$new_port
            generate_urls

            green "Hysteria2 端口已更新为: ${new_port}"
            ;;
        0)
            return
            ;;
        *)
            red "无效的选择"
            ;;
    esac
}

change_uuid() {
    if [ ! -f "${WORK_DIR}/info.conf" ]; then
        red "请先安装 Xray + Hysteria2"
        return 1
    fi

    source "${WORK_DIR}/info.conf"

    clear
    green "=== 修改认证信息 ===\n"

    reading "是否生成新的 UUID? (y/n): " new_uuid_choice
    if [ "$new_uuid_choice" == "y" ]; then
        UUID=$(generate_uuid)
        green "新 UUID: ${UUID}"
    fi

    reading "是否生成新的 Hysteria2 密码? (y/n): " new_pwd_choice
    if [ "$new_pwd_choice" == "y" ]; then
        PASSWORD=$(generate_password)
        green "新密码: ${PASSWORD}"
    fi

    # 更新 Xray 配置
    sed -i "s/\"id\": \"[^\"]*\"/\"id\": \"${UUID}\"/" "${CONFIG_DIR}"

    # 更新 Hysteria2 配置
    sed -i "s/\"${PASSWORD}\": \"admin\"/\"${PASSWORD}\": \"admin\"/" "${HYSTERIA_DIR}/config.yaml"

    # 更新配置文件
    sed -i "s/UUID=.*/UUID=${UUID}/" "${WORK_DIR}/info.conf"
    sed -i "s/PASSWORD=.*/PASSWORD=${PASSWORD}/" "${WORK_DIR}/info.conf"

    # 重启服务
    manage_service xray restart
    manage_service hysteria2 restart

    # 重新生成链接
    generate_urls

    green "\n认证信息已更新"
    green "UUID: ${UUID}"
    green "Hysteria2 密码: ${PASSWORD}"
}

change_sni() {
    if [ ! -f "${WORK_DIR}/info.conf" ]; then
        red "请先安装 Xray + Hysteria2"
        return 1
    fi

    source "${WORK_DIR}/info.conf"

    clear
    green "=== 修改 Reality 伪装域名 ===\n"
    green "常用伪装域名:"
    green "1. www.microsoft.com"
    green "2. www.apple.com"
    green "3. www.nvidia.com (当前)"
    green "4. www.intel.com"
    green "5. www.adobe.com"
    green "6. 自定义"
    purple "0. 返回"

    reading "\n请选择: " choice

    case $choice in
        1) new_sni="www.microsoft.com" ;;
        2) new_sni="www.apple.com" ;;
        3) new_sni="www.nvidia.com" ;;
        4) new_sni="www.intel.com" ;;
        5) new_sni="www.adobe.com" ;;
        6)
            reading "输入自定义域名: " new_sni
            ;;
        0)
            return
            ;;
        *)
            red "无效的选择"
            return
            ;;
    esac

    # 更新 Xray 配置
    sed -i "s/\"dest\": \"[^\"]*\"/\"dest\": \"${new_sni}:443\"/" "${CONFIG_DIR}"
    sed -i "s/\"serverNames\": \[[^]]*\]/\"serverNames\": [\"${new_sni}\"]/" "${CONFIG_DIR}"

    # 重新生成 Reality 密钥对
    output=$(${XRAY_DIR}/xray x25519)
    new_private_key=$(echo "${output}" | awk '/Private key:/ {print $3}')
    new_public_key=$(echo "${output}" | awk '/Public key:/ {print $3}')

    sed -i "s/\"privateKey\": \"[^\"]*\"/\"privateKey\": \"${new_private_key}\"/" "${CONFIG_DIR}"

    # 更新配置文件
    sed -i "s/REALITY_SNI=.*/REALITY_SNI=${new_sni}/" "${WORK_DIR}/info.conf"
    sed -i "s/PUBLIC_KEY=.*/PUBLIC_KEY=${new_public_key}/" "${WORK_DIR}/info.conf"
    sed -i "s/PRIVATE_KEY=.*/PRIVATE_KEY=${new_private_key}/" "${WORK_DIR}/info.conf"

    # 重启服务
    manage_service xray restart

    # 重新生成链接
    DEFAULT_REALITY_SNI=$new_sni
    generate_urls

    green "Reality 伪装域名已更新为: ${new_sni}"
}

# =========================
# 主安装流程
# =========================

install_all() {
    clear
    purple "开始安装 Xray + Hysteria2..."

    # 检查系统
    local SYSTEM=$(detect_system)
    if [ "$SYSTEM" == "unknown" ]; then
        red "不支持的系统"
        exit 1
    fi

    green "检测到系统: ${SYSTEM}"

    # 安装依赖
    purple "安装依赖包..."
    manage_packages install curl jq unzip openssl

    # 安装 Xray
    install_xray

    # 安装 Hysteria2
    install_hysteria2

    # 生成配置
    generate_config

    # 创建服务
    create_xray_service
    create_hysteria2_service

    # 配置时间同步
    setup_time_sync

    # 放行端口
    purple "配置防火墙..."
    allow_port ${VLESS_PORT}/tcp
    allow_port ${HY2_PORT}/udp

    # 启动服务
    purple "启动服务..."
    manage_service xray start
    manage_service hysteria2 start

    # 等待服务启动
    sleep 3

    # 生成节点链接
    generate_urls

    # 显示信息
    clear
    green "=== 安装完成 ===\n"
    show_urls

    # 创建快捷指令
    create_shortcut
}

# =========================
# 卸载
# =========================

uninstall_all() {
    reading "确定要卸载 Xray + Hysteria2? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        purple "已取消"
        return
    fi

    yellow "正在卸载..."

    # 停止服务
    manage_service xray stop
    manage_service hysteria2 stop

    # 禁用服务
    local SYSTEM=$(detect_system)
    if [ "$SYSTEM" == "alpine" ]; then
        rc-update del xray default
        rc-update del hysteria2 default
    else
        systemctl disable xray
        systemctl disable hysteria2
    fi

    # 删除服务文件
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/hysteria2.service
    rm -f /etc/init.d/xray
    rm -f /etc/init.d/hysteria2

    # 重新加载 systemd
    if [ "$SYSTEM" != "alpine" ]; then
        systemctl daemon-reload
    fi

    # 删除文件
    rm -rf "${XRAY_DIR}"
    rm -rf "${HYSTERIA_DIR}"
    rm -rf "${WORK_DIR}"

    # 删除快捷指令
    rm -f /usr/local/bin/xr

    green "卸载完成"
}

# =========================
# 快捷指令
# =========================

create_shortcut() {
    cat > /usr/local/bin/xr << 'EOF'
#!/bin/bash
bash <(curl -Ls https://raw.githubusercontent.com/your-repo/xray-hysteria2/main/xray-hysteria2.sh) "$1"
EOF

    # 或本地调用
    cat > /usr/local/bin/xr << EOF
#!/bin/bash
bash $(readlink -f "$0") "\$@"
EOF

    chmod +x /usr/local/bin/xr

    if [ -s /usr/local/bin/xr ]; then
        green "\n快捷指令 'xr' 创建成功"
        green "使用方法: xr [选项]"
    fi
}

# =========================
# 服务管理菜单
# =========================

service_menu() {
    while true; do
        clear
        green "=== 服务管理 ===\n"

        local xray_status=$(manage_service xray status)
        local hy2_status=$(manage_service hysteria2 status)

        green "Xray 状态: ${xray_status}"
        green "Hysteria2 状态: ${hy2_status}\n"

        green "1. 启动所有服务"
        green "2. 停止所有服务"
        green "3. 重启所有服务"
        purple "0. 返回主菜单"

        reading "请选择: " choice

        case $choice in
            1)
                manage_service xray start
                manage_service hysteria2 start
                green "服务已启动"
                ;;
            2)
                manage_service xray stop
                manage_service hysteria2 stop
                green "服务已停止"
                ;;
            3)
                manage_service xray restart
                manage_service hysteria2 restart
                green "服务已重启"
                ;;
            0)
                return
                ;;
            *)
                red "无效的选择"
                ;;
        esac

        reading "\n按回车继续..."
    done
}

# =========================
# 配置管理菜单
# =========================

config_menu() {
    while true; do
        clear
        green "=== 配置管理 ===\n"
        green "1. 修改端口"
        green "2. 修改认证信息 (UUID/密码)"
        green "3. 修改 Reality 伪装域名"
        green "4. 查看节点链接"
        purple "0. 返回主菜单"

        reading "请选择: " choice

        case $choice in
            1)
                change_port
                reading "\n按回车继续..."
                ;;
            2)
                change_uuid
                reading "\n按回车继续..."
                ;;
            3)
                change_sni
                reading "\n按回车继续..."
                ;;
            4)
                show_urls
                reading "\n按回车继续..."
                ;;
            0)
                return
                ;;
            *)
                red "无效的选择"
                reading "\n按回车继续..."
                ;;
        esac
    done
}

# =========================
# 主菜单
# =========================

main_menu() {
    while true; do
        clear
        echo ""
        purple "╔═══════════════════════════════════════╗"
        purple "║   Xray + Hysteria2 管理脚本           ║"
        purple "╚═══════════════════════════════════════╝"
        echo ""

        # 检查安装状态
        local xray_installed=false
        local hy2_installed=false

        [ -f "${XRAY_DIR}/xray" ] && xray_installed=true
        [ -f "${HYSTERIA_DIR}/hysteria2" ] && hy2_installed=true

        if [ "$xray_installed" = true ] && [ "$hy2_installed" = true ]; then
            local xray_status=$(manage_service xray status)
            local hy2_status=$(manage_service hysteria2 status)

            purple "--- 服务状态 ---"
            purple "Xray: ${xray_status}"
            purple "Hysteria2: ${hy2_status}"
            echo ""
        fi

        green "1. 安装 Xray + Hysteria2"
        green "2. 卸载 Xray + Hysteria2"
        echo "==================="
        green "3. 服务管理"
        green "4. 配置管理"
        echo "==================="
        green "5. 查看节点链接"
        green "6. 查看 IP 地址"
        echo "==================="
        red "0. 退出"

        reading "请选择 (0-6): " choice

        case $choice in
            1)
                if [ "$xray_installed" = true ] || [ "$hy2_installed" = true ]; then
                    yellow "Xray 或 Hysteria2 已经安装"
                    reading "按回车继续..."
                else
                    install_all
                    reading "\n按回车返回主菜单..."
                fi
                ;;
            2)
                uninstall_all
                reading "\n按回车继续..."
                ;;
            3)
                if [ "$xray_installed" = false ] || [ "$hy2_installed" = false ]; then
                    yellow "请先安装 Xray + Hysteria2"
                    reading "按回车继续..."
                else
                    service_menu
                fi
                ;;
            4)
                if [ "$xray_installed" = false ] || [ "$hy2_installed" = false ]; then
                    yellow "请先安装 Xray + Hysteria2"
                    reading "按回车继续..."
                else
                    config_menu
                fi
                ;;
            5)
                if [ "$xray_installed" = false ] || [ "$hy2_installed" = false ]; then
                    yellow "请先安装 Xray + Hysteria2"
                else
                    show_urls
                fi
                reading "\n按回车继续..."
                ;;
            6)
                purple "服务器 IP: $(get_realip)"
                reading "\n按回车继续..."
                ;;
            0)
                purple "退出脚本"
                exit 0
                ;;
            *)
                red "无效的选择"
                reading "\n按回车继续..."
                ;;
        esac
    done
}

# =========================
# 脚本入口
# =========================

check_root

# 捕获 Ctrl+C
trap 'echo -e "\n${red}已取消操作${re}"; exit' INT

# 启动主菜单
main_menu
