#!/usr/bin/env bash
set -e

# ============================================================
# Hysteria2 一键安装脚本 (基于 sing-box)
# 支持 Ubuntu / Debian / CentOS / Fedora 等主流 Linux 系统
# 功能: 安装 sing-box, 配置 Hysteria2 + Salamander 混淆,
#       优化游戏加速, 生成客户端 URI 和二维码
# ============================================================

# ---- 颜色定义 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---- 全局变量 ----
SING_BOX_VERSION="${SING_BOX_VERSION:-v1.13.0}"  # 可通过环境变量覆盖
HY2_PORT=""
HY2_PASSWORD=""
HY2_OBFS_PASSWORD=""
HY2_SNI=""
SERVER_IP=""
INSTALL_DIR="/etc/sing-box"
CONFIG_FILE="${INSTALL_DIR}/config.json"
CERT_FILE="${INSTALL_DIR}/cert.pem"
KEY_FILE="${INSTALL_DIR}/key.pem"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BINARY="/usr/local/bin/sing-box"
DOMAIN=""
USE_LE_CERT=false
INSECURE_FLAG=1

# ---- 打印函数 ----
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header(){ echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# 安全的 read 封装 (防止 Ctrl+D 导致静默退出)
safe_read() {
    if ! read -p "$1" "$2"; then
        echo ""
        error "用户中断输入"
    fi
}

# ---- 检查 root ----
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 用户运行此脚本"
    fi
}

# ---- 获取公网 IP ----
get_server_ip() {
    # 尝试多个来源获取 IP
    SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s4 --max-time 5 https://icanhazip.com 2>/dev/null || \
                curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -s4 --max-time 5 https://checkip.amazonaws.com 2>/dev/null || \
                hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(ip route get 1 | awk '{print $NF;exit}' 2>/dev/null)
    fi
    if [[ -z "$SERVER_IP" ]]; then
        error "无法获取服务器 IP 地址，请手动设置"
    fi
}

# ---- 检测系统 ----
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        OS=$(uname -s)
    fi
    info "检测到系统: ${OS} ${OS_VERSION}"
}

# ---- 安装依赖 ----
install_deps() {
    info "安装系统依赖..."
    case "$OS" in
        ubuntu|debian|kali)
            apt-get update -qq
            apt-get install -y -qq curl wget openssl qrencode tar gzip systemd iproute2
            ;;
        centos|rhel|fedora|almalinux|rocky)
            if command -v dnf &>/dev/null; then
                dnf install -y curl wget openssl qrencode tar gzip systemd iproute
            else
                yum install -y curl wget openssl qrencode tar gzip systemd net-tools
            fi
            ;;
        arch|manjaro)
            pacman -Syu --noconfirm curl wget openssl qrencode tar gzip systemd iproute2
            ;;
        alpine)
            apk add curl wget openssl qrencode tar gzip iproute2
            ;;
        *)
            warn "未知系统: $OS，尝试使用 apt-get 安装依赖..."
            apt-get update -qq && apt-get install -y -qq curl wget openssl qrencode tar gzip systemd || true
            ;;
    esac
    info "依赖安装完成"
}

# ---- 确保 python3 可用 (用于 URL 编码) ----
ensure_python3() {
    if ! command -v python3 &>/dev/null; then
        info "安装 python3..."
        case "$OS" in
            ubuntu|debian|kali)
                apt-get install -y -qq python3
                ;;
            centos|rhel|fedora|almalinux|rocky)
                if command -v dnf &>/dev/null; then
                    dnf install -y python3
                else
                    yum install -y python3
                fi
                ;;
            arch|manjaro)
                pacman -Syu --noconfirm python3
                ;;
            alpine)
                apk add python3
                ;;
            *)
                apt-get install -y -qq python3 || true
                ;;
        esac
    fi
}

# ---- 开启 BBR ----
enable_bbr() {
    info "优化网络参数 (开启 BBR + 游戏加速配置)..."

    # 清理旧条目避免重复 (标记行 + 8行配置 = 共9行)
    sed -i '/# Hysteria2 网络优化/,+8d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/# Hysteria2 QUIC 优化/,+4d' /etc/sysctl.conf 2>/dev/null || true

    # 检查是否已开启 BBR
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        info "BBR 已开启，跳过"
    else
        # 写入 sysctl 配置
        cat >> /etc/sysctl.conf <<-EOF
# Hysteria2 网络优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
        sysctl -p 2>/dev/null || true
        info "BBR 及其他网络优化参数已启用"
    fi

    # 额外 UDP/QUIC 优化
    cat >> /etc/sysctl.conf <<-EOF
# Hysteria2 QUIC 优化
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
EOF
    sysctl -p 2>/dev/null || true
}

# ---- 安装 sing-box ----
install_sing_box() {
    # 检测是否已安装
    if [[ -x "$BINARY" ]]; then
        local current_ver
        current_ver=$("${BINARY}" version 2>&1 | head -n1)
        info "sing-box 已安装: ${current_ver}"
        safe_read "$(echo -e "${YELLOW}是否重新安装? [y/N]: ${NC}")" reinstall
        if [[ ! "$reinstall" =~ ^[yY]$ ]]; then
            info "跳过安装，使用现有版本"
            return
        fi
        info "正在重新安装..."
    fi

    # 使用全局设定的版本号 (默认 v1.13.0, 可通过 SING_BOX_VERSION 环境变量覆盖)
    local VER="${SING_BOX_VERSION}"
    info "使用 sing-box 版本: ${VER}"

    local ARCH
    case $(uname -m) in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv8l) ARCH="armv7" ;;
        i386|i686)     ARCH="386" ;;
        *) error "不支持的架构: $(uname -m)" ;;
    esac

    local VER_NO_V="${VER#v}"
    local TAR_FILE="sing-box-${VER_NO_V}-linux-${ARCH}.tar.gz"
    local DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VER}/${TAR_FILE}"

    # 下载 (带多个备用源)
    local orig_dir
    orig_dir=$(pwd)
    cd /tmp
    if wget -q --timeout=30 --tries=3 -O "${TAR_FILE}" "${DOWNLOAD_URL}"; then
        info "GitHub 直连下载成功"
    elif wget -q --timeout=30 --tries=3 -O "${TAR_FILE}" "https://ghproxy.net/${DOWNLOAD_URL}"; then
        info "通过 ghproxy.net 代理下载成功"
    elif wget -q --timeout=30 --tries=3 -O "${TAR_FILE}" "https://mirror.ghproxy.com/${DOWNLOAD_URL}"; then
        info "通过 mirror.ghproxy.com 代理下载成功"
    elif wget -q --timeout=30 --tries=3 -O "${TAR_FILE}" "https://gh-proxy.com/${DOWNLOAD_URL}"; then
        info "通过 gh-proxy.com 代理下载成功"
    else
        error "sing-box 下载失败，请检查网络或手动安装"
    fi

    # 从 tar 包中提取 sing-box 二进制 (使用 tar tzf 避免查找目录 Bug)
    local EXTRACTED_DIR
    EXTRACTED_DIR=$(tar tzf "${TAR_FILE}" | head -1 | cut -d/ -f1)
    tar xzf "${TAR_FILE}"
    if [[ ! -d "$EXTRACTED_DIR" ]]; then
        error "解压 sing-box 失败，找不到解压目录"
    fi
    cp "${EXTRACTED_DIR}/sing-box" "${BINARY}"
    chmod +x "${BINARY}"
    rm -rf "${EXTRACTED_DIR}" "${TAR_FILE}"
    cd "$orig_dir"

    info "sing-box 安装完成: $(${BINARY} version 2>&1 | head -n1)"
}

# ---- 生成自签名证书 ----
generate_cert() {
    mkdir -p "$INSTALL_DIR"

    if [[ "$USE_LE_CERT" == "true" && -n "$DOMAIN" ]]; then
        request_le_cert
        return
    fi

    info "生成自签名 TLS 证书..."
    # 如果用户提供了域名则使用域名, 否则使用 IP
    local CERT_CN="${DOMAIN:-$SERVER_IP}"

    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -subj "/CN=${CERT_CN}/O=Hysteria2" \
        -days 825 || error "自签名证书生成失败，请检查 openssl"

    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_FILE}"
    info "自签名证书已生成 (CN=${CERT_CN}, 有效期约 2 年)"
}

# ---- 一键申请 Let's Encrypt 证书 (acme.sh) ----
request_le_cert() {
    info "开始申请 Let's Encrypt 证书 (域名: ${DOMAIN})..."

    # 检查 80/443 端口是否被占用
    local port80_in_use=false
    local stopped_services=""
    if ss -tlnp 2>/dev/null | grep -qE ':80\s'; then
        port80_in_use=true
    fi
    if ss -tlnp 2>/dev/null | grep -qE ':443\s'; then
        warn "端口 443 被占用，HTTPS 证书验证可能受影响"
    fi

    if [[ "$port80_in_use" == "true" ]]; then
        warn "端口 80 被占用 (证书验证需要 80 端口)"
        safe_read "$(echo -e "${YELLOW}是否自动停止占用 80 端口的服务? (nginx/apache/httpd/caddy) [y/N]: ${NC}")" stop_services
        if [[ "$stop_services" =~ ^[yY]$ ]]; then
            # 只停止实际正在运行的服务并记录
            local svc
            for svc in nginx apache2 httpd caddy; do
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    systemctl stop "$svc" 2>/dev/null || true
                    stopped_services="${stopped_services} ${svc}"
                fi
            done
            sleep 1
            if ss -tlnp 2>/dev/null | grep -qE ':80\s'; then
                warn "端口 80 仍被占用，acme.sh 可能无法验证域名"
                warn "请手动停止占用 80 端口的服务后重新运行脚本"
            fi
        else
            warn "跳过停止服务，证书申请可能失败"
        fi
    fi

    # 安装 acme.sh
    if ! command -v acme.sh &>/dev/null; then
        info "安装 acme.sh..."
        curl -sSL https://get.acme.sh | sh -s email=acme@${DOMAIN} 2>/dev/null || \
            error "acme.sh 安装失败，请检查网络"
        # 添加到 PATH
        export PATH="$HOME/.acme.sh:$PATH"
    fi

    # 申请证书 (standalone 模式)
    info "正在申请证书，请稍候..."
    local acme_bin="$HOME/.acme.sh/acme.sh"
    if [[ ! -x "$acme_bin" ]]; then acme_bin="/root/.acme.sh/acme.sh"; fi
    if [[ ! -x "$acme_bin" ]]; then acme_bin="$(which acme.sh 2>/dev/null)"; fi
    if [[ ! -x "$acme_bin" ]]; then
        error "找不到 acme.sh 可执行文件，请手动安装后重试"
    fi

    if "$acme_bin" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force 2>/dev/null; then
        info "Let's Encrypt 证书申请成功!"

        # 安装证书到指定路径
        "$acme_bin" --install-cert -d "$DOMAIN" \
            --cert-file "${CERT_FILE}" \
            --key-file "${KEY_FILE}" \
            --fullchain-file "${CERT_FILE}" \
            --reloadcmd "systemctl restart sing-box" 2>/dev/null || true

        chmod 600 "${KEY_FILE}"
        chmod 644 "${CERT_FILE}"
        info "证书已安装到: ${CERT_FILE}"
        info "证书将自动续期 (有效期 90 天，acme.sh 自动续期)"
    else
        warn "Let's Encrypt 证书申请失败，回退到自签名证书..."
        USE_LE_CERT=false
        INSECURE_FLAG=1

        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "${KEY_FILE}" \
            -out "${CERT_FILE}" \
            -subj "/CN=${DOMAIN}/O=Hysteria2" \
            -days 825 || error "回退自签名证书生成失败，请检查 openssl"

        chmod 600 "${KEY_FILE}"
        chmod 644 "${CERT_FILE}"
        info "自签名证书已生成 (CN=${DOMAIN}, 有效期约 2 年)"
    fi

    # 恢复被停止的服务
    local svc
    for svc in $stopped_services; do
        systemctl start "$svc" 2>/dev/null || true
    done
}

# ---- 生成随机密码 ----
gen_password() {
    # 生成恰好 32 字符的随机密码 (仅字母数字)
    while true; do
        local pwd
        pwd=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)
        if [[ ${#pwd} -eq 32 ]]; then
            echo "$pwd"
            return
        fi
    done
}

# ---- JSON 转义 (处理用户输入中的特殊字符) ----
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"  # 反斜杠
    s="${s//\"/\\\"}"  # 双引号
    s="${s//$'\n'/\\n}"  # 换行
    s="${s//$'\t'/\\t}"  # 制表符
    echo "$s"
}

# ---- 交互式配置 ----
interactive_config() {
    header
    echo -e "${BLUE}  Hysteria2 一键安装脚本${NC}"
    echo -e "${BLUE}  基于 sing-box | 支持游戏加速${NC}"
    header
    echo ""

    # 端口
    safe_read "$(echo -e "${YELLOW}请输入 Hysteria2 监听端口 [默认: 8443]: ${NC}")" input_port
    HY2_PORT="${input_port:-8443}"
    if [[ ! "$HY2_PORT" =~ ^[0-9]+$ || "$HY2_PORT" -lt 1 || "$HY2_PORT" -gt 65535 ]]; then
        error "端口无效"
    fi

    # 检测端口是否已被占用
    if ss -ulnp 2>/dev/null | grep -qE ":${HY2_PORT}\s"; then
        warn "端口 ${HY2_PORT} 已被其他服务占用!"
        safe_read "$(echo -e "${YELLOW}是否继续? (可能导致冲突) [y/N]: ${NC}")" port_continue
        if [[ ! "$port_continue" =~ ^[yY]$ ]]; then
            error "安装已取消"
        fi
    fi

    # 密码
    local default_pwd
    default_pwd=$(gen_password)
    safe_read "$(echo -e "${YELLOW}请输入认证密码 [默认随机: ${default_pwd}]: ${NC}")" input_pwd
    HY2_PASSWORD="${input_pwd:-$default_pwd}"

    # 混淆密码
    local default_obfs
    default_obfs=$(gen_password)
    safe_read "$(echo -e "${YELLOW}请输入 Salamander 混淆密码 [默认随机: ${default_obfs}]: ${NC}")" input_obfs
    HY2_OBFS_PASSWORD="${input_obfs:-$default_obfs}"

    # 伪装域名 (SNI)
    safe_read "$(echo -e "${YELLOW}请输入伪装域名/SNI [默认: www.apple.com]: ${NC}")" input_sni
    HY2_SNI="${input_sni:-www.apple.com}"

    # 域名 (用于证书, 可选)
    safe_read "$(echo -e "${YELLOW}是否拥有域名并已解析到本机? [y/N]: ${NC}")" use_domain
    if [[ "$use_domain" =~ ^[yY] ]]; then
        safe_read "$(echo -e "${YELLOW}请输入您的域名: ${NC}")" DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$ ]]; then
                error "域名格式无效 (仅支持字母、数字、连字符和点)"
            fi
            safe_read "$(echo -e "${YELLOW}是否一键申请 Let's Encrypt 免费证书? (需 80/443 端口空闲) [Y/n]: ${NC}")" use_le
            if [[ "$use_le" =~ ^[nN]$ ]]; then
                USE_LE_CERT=false
                INSECURE_FLAG=1
            else
                USE_LE_CERT=true
                INSECURE_FLAG=0
            fi
            if [[ "$HY2_SNI" == "www.apple.com" ]]; then
                HY2_SNI="$DOMAIN"
            fi
        else
            DOMAIN=""
        fi
    fi

    header
    echo -e "${GREEN}配置摘要:${NC}"
    echo -e "  端口:        ${HY2_PORT}"
    echo -e "  密码:        ${HY2_PASSWORD}"
    echo -e "  混淆密码:    ${HY2_OBFS_PASSWORD}"
    echo -e "  SNI:         ${HY2_SNI}"
    echo -e "  证书域名:    ${DOMAIN:-自签名 (IP: ${SERVER_IP})}"
    local cert_type="自签名"
    if [[ "$USE_LE_CERT" == "true" ]]; then cert_type="Let's Encrypt"; fi
    echo -e "  证书类型:    ${cert_type}"
    header
    echo ""
}

# ---- 生成 sing-box 配置文件 ----
generate_config() {
    info "生成 sing-box 配置文件..."

    mkdir -p "$INSTALL_DIR"

    # JSON 转义密码 (防止特殊字符破坏 JSON)
    local json_pwd
    local json_obfs_pwd
    json_pwd=$(json_escape "${HY2_PASSWORD}")
    json_obfs_pwd=$(json_escape "${HY2_OBFS_PASSWORD}")

    cat > "$CONFIG_FILE" <<-CONFEOF
{
  "log": {
    "level": "warn",
    "output": "${INSTALL_DIR}/sing-box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "name": "game",
          "password": "${json_pwd}"
        }
      ],
      "ignore_client_bandwidth": true,
      "obfs": {
        "type": "salamander",
        "password": "${json_obfs_pwd}"
      },
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
CONFEOF

    info "配置文件生成完毕: ${CONFIG_FILE}"
}

# ---- 创建 systemd 服务 ----
create_service() {
    # Alpine 使用 OpenRC, 不支持 systemd
    if [[ "$OS" == "alpine" ]]; then
        warn "Alpine 使用 OpenRC, 跳过 systemd 服务创建"
        warn "请手动启动: ${BINARY} run -c ${CONFIG_FILE}"
        return
    fi

    info "创建 systemd 服务..."

    cat > "$SERVICE_FILE" <<-EOF
[Unit]
Description=sing-box (Hysteria2) - Universal Proxy Platform
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BINARY} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=65536
LimitAS=infinity
LimitMEMLOCK=infinity
TasksMax=infinity
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sing-box

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    info "systemd 服务创建完毕"
}

# ---- 配置防火墙 ----
config_firewall() {
    info "配置防火墙规则..."

    # ufw
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${HY2_PORT}/udp"
        info "ufw: 已开放端口 ${HY2_PORT}/udp"
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall-cmd --zone=public --add-port="${HY2_PORT}/udp" --permanent
        firewall-cmd --reload
        info "firewalld: 已开放端口 ${HY2_PORT}/udp"
    fi

    # iptables (作为兜底)
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p udp --dport "$HY2_PORT" -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p udp --dport "$HY2_PORT" -j ACCEPT
        # 持久化 (如果存在)
        if command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables/
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            # 检查是否有 iptables-persistent 自动加载
            if ! command -v iptables-persistent &>/dev/null && [[ ! -f /etc/init.d/iptables-persistent ]]; then
                warn "未检测到 iptables-persistent，重启后防火墙规则可能丢失"
                warn "建议手动执行: sudo apt install iptables-persistent 或 sudo dnf install iptables-services"
            fi
        fi
        info "iptables: 已添加规则"
    fi
}

# ---- 生成客户端 URI ----
generate_uri() {
    local domain_part="${DOMAIN:-$SERVER_IP}"
    # URL 编码密码和混淆密码中的特殊字符 (使用环境变量避免单引号注入)
    local encoded_pwd
    local encoded_obfs_pwd
    encoded_pwd=$(HY2_PWD="${HY2_PASSWORD}" python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_PWD'], safe=''))" 2>/dev/null || \
                  HY2_PWD="${HY2_PASSWORD}" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_PWD'], safe=''))" 2>/dev/null || \
                  echo "${HY2_PASSWORD}")
    encoded_obfs_pwd=$(HY2_PWD="${HY2_OBFS_PASSWORD}" python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_PWD'], safe=''))" 2>/dev/null || \
                       HY2_PWD="${HY2_OBFS_PASSWORD}" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_PWD'], safe=''))" 2>/dev/null || \
                       echo "${HY2_OBFS_PASSWORD}")
    # 对 SNI 也进行 URL 编码
    local encoded_sni
    encoded_sni=$(HY2_SNI="${HY2_SNI}" python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_SNI'], safe=''))" 2>/dev/null || \
                  echo "${HY2_SNI}")
    CLIENT_URI="hysteria2://${encoded_pwd}@${domain_part}:${HY2_PORT}?obfs=salamander&obfs-password=${encoded_obfs_pwd}&sni=${encoded_sni}&insecure=${INSECURE_FLAG}#Hy2-Game-${SERVER_IP}"

    echo "$CLIENT_URI" > "${INSTALL_DIR}/client_uri.txt"
    info "客户端 URI 已保存: ${INSTALL_DIR}/client_uri.txt"
}

# ---- 生成二维码 ----
generate_qrcode() {
    info "生成客户端二维码..."

    echo ""
    header
    echo -e "${GREEN}  客户端连接 URI:${NC}"
    echo -e "${CYAN}  ${CLIENT_URI}${NC}"
    header
    echo ""

    # 使用 qrencode 生成二维码 (终端显示)
    if command -v qrencode &>/dev/null; then
        echo -e "${GREEN}  扫描以下二维码导入客户端:${NC}"
        echo ""
        qrencode -t ANSIUTF8 "${CLIENT_URI}"
        echo ""

        # 保存 PNG 图片到安装目录
        qrencode -o "${INSTALL_DIR}/hy2_qrcode.png" "${CLIENT_URI}" 2>/dev/null || true
        info "二维码图片已保存: ${INSTALL_DIR}/hy2_qrcode.png"
    else
        warn "未安装 qrencode，无法显示二维码"
        info "请手动复制上面的 URI 到客户端中使用"
    fi
}

# ---- 启动服务 ----
start_service() {
    info "启动 sing-box 服务..."

    # 先测试配置
    ${BINARY} check -c "$CONFIG_FILE" || error "配置文件检查失败!"

    if [[ "$OS" == "alpine" ]]; then
        nohup ${BINARY} run -c "$CONFIG_FILE" > "${INSTALL_DIR}/sing-box.log" 2>&1 &
        info "sing-box 已在后台启动 (Alpine/OpenRC)"
        return
    fi

    systemctl enable sing-box
    systemctl restart sing-box

    sleep 2
    if systemctl is-active --quiet sing-box; then
        info "sing-box 服务运行正常"
    else
        warn "服务状态异常，检查日志: journalctl -u sing-box -n 50 --no-pager"
    fi
}

# ---- 配置客户端 sing-box ----
generate_client_config() {
    local client_dir="${INSTALL_DIR}/client"
    mkdir -p "$client_dir"

    local domain_part="${DOMAIN:-$SERVER_IP}"

    # JSON 转义密码
    local json_pwd
    local json_obfs_pwd
    json_pwd=$(json_escape "${HY2_PASSWORD}")
    json_obfs_pwd=$(json_escape "${HY2_OBFS_PASSWORD}")

    cat > "${client_dir}/client-config.json" <<-CONFEOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sing-tun",
      "inet4_address": "172.19.0.1/30",
      "mtu": 1420,
      "auto_route": true,
      "strict_route": false
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 1080
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-out",
      "server": "${domain_part}",
      "server_port": ${HY2_PORT},
      "password": "${json_pwd}",
      "obfs": {
        "type": "salamander",
        "password": "${json_obfs_pwd}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${HY2_SNI}",
        "insecure": ${INSECURE_FLAG},
        "alpn": ["h3"]
      }
    }
  ],
  "route": {
    "final": "hy2-out",
    "auto_detect_interface": true
  }
}
CONFEOF

    info "客户端配置已生成: ${client_dir}/client-config.json"
    info "可用于 sing-box 客户端 (PC/路由器等)"
}

# ---- 安装 hy2 管理命令 ----
install_management_tool() {
    info "安装 hy2 管理命令..."

    cat > /usr/local/bin/hy2 << 'MGMT'
#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/etc/sing-box"
CONFIG_FILE="${INSTALL_DIR}/config.json"
CERT_FILE="${INSTALL_DIR}/cert.pem"
KEY_FILE="${INSTALL_DIR}/key.pem"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BINARY="/usr/local/bin/sing-box"

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header(){ echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

show_menu() {
    clear 2>/dev/null || true
    header
    echo -e "${CYAN}  Hysteria2 管理工具${NC}"
    header
    echo ""
    echo -e "  ${BLUE}1)${NC} 启动服务"
    echo -e "  ${BLUE}2)${NC} 停止服务"
    echo -e "  ${BLUE}3)${NC} 重启服务"
    echo -e "  ${BLUE}4)${NC} 查看状态"
    echo -e "  ${BLUE}5)${NC} 查看日志"
    echo -e "  ${BLUE}6)${NC} 查看配置"
    echo -e "  ${BLUE}7)${NC} 查看客户端 URI"
    echo -e "  ${BLUE}8)${NC} 显示二维码"
    echo -e "  ${BLUE}9)${NC} 显示帮助"
    echo -e "  ${BLUE}0)${NC} 卸载 Hysteria2"
    echo -e "  ${RED}q)${NC} 退出"
    echo ""
}

do_start() {
    if ! [[ -f "$BINARY" ]]; then
        error "sing-box 未安装"
    fi
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        warn "服务已在运行中"
        return
    fi
    systemctl start sing-box 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet sing-box; then
        info "服务启动成功"
    else
        error "服务启动失败，检查日志: journalctl -u sing-box -n 20 --no-pager"
    fi
}

do_stop() {
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        warn "服务未运行"
        return
    fi
    systemctl stop sing-box 2>/dev/null || true
    sleep 1
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        info "服务已停止"
    else
        error "停止服务失败"
    fi
}

do_restart() {
    if ! [[ -f "$BINARY" ]]; then
        error "sing-box 未安装"
    fi
    info "重启 sing-box 服务..."
    systemctl restart sing-box 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet sing-box; then
        info "服务重启成功"
    else
        error "服务重启失败，检查日志: journalctl -u sing-box -n 20 --no-pager"
    fi
}

do_status() {
    echo ""
    echo -e "${BLUE}  sing-box 服务状态:${NC}"
    systemctl status sing-box 2>/dev/null || echo "  服务未安装"
    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        local port
        port=$(grep -o '"listen_port": [0-9]*' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "未知")
        echo -e "${BLUE}  配置信息:${NC}"
        echo -e "    端口:   ${port}/UDP"
        echo -e "    配置:   ${CONFIG_FILE}"
        echo -e "    证书:   ${CERT_FILE}"
    fi
    echo ""
}

do_log() {
    echo ""
    echo -e "${BLUE}  最近 30 条日志:${NC}"
    echo ""
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || \
        tail -30 "${INSTALL_DIR}/sing-box.log" 2>/dev/null || \
        warn "无法读取日志"
    echo ""
}

do_show_config() {
    if ! [[ -f "$CONFIG_FILE" ]]; then
        error "配置文件不存在"
    fi
    echo ""
    echo -e "${BLUE}  当前配置:${NC}"
    echo ""
    cat "$CONFIG_FILE"
    echo ""
}

do_show_uri() {
    local uri_file="${INSTALL_DIR}/client_uri.txt"
    if ! [[ -f "$uri_file" ]]; then
        error "客户端 URI 不存在"
    fi
    echo ""
    echo -e "${BLUE}  客户端连接 URI:${NC}"
    echo ""
    echo -e "  ${CYAN}$(cat "$uri_file")${NC}"
    echo ""
}

do_show_qrcode() {
    local uri_file="${INSTALL_DIR}/client_uri.txt"
    if ! [[ -f "$uri_file" ]]; then
        error "客户端 URI 不存在"
    fi
    if ! command -v qrencode &>/dev/null; then
        warn "qrencode 未安装，显示 URI:"
        echo -e "  ${CYAN}$(cat "$uri_file")${NC}"
        return
    fi
    echo ""
    echo -e "${BLUE}  客户端二维码:${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$(cat "$uri_file")"
    echo ""
}

do_show_help() {
    echo ""
    echo -e "${BLUE}  hy2 命令用法:${NC}"
    echo ""
    echo -e "  ${GREEN}hy2${NC}              显示管理菜单 (交互模式)"
    echo -e "  ${GREEN}hy2 start${NC}        启动服务"
    echo -e "  ${GREEN}hy2 stop${NC}         停止服务"
    echo -e "  ${GREEN}hy2 restart${NC}      重启服务"
    echo -e "  ${GREEN}hy2 status${NC}       查看服务状态"
    echo -e "  ${GREEN}hy2 log${NC}          查看最近日志"
    echo -e "  ${GREEN}hy2 config${NC}       查看配置文件"
    echo -e "  ${GREEN}hy2 uri${NC}          查看客户端连接 URI"
    echo -e "  ${GREEN}hy2 qr${NC}           显示客户端二维码"
    echo -e "  ${GREEN}hy2 uninstall${NC}    卸载 Hysteria2"
    echo -e "  ${GREEN}hy2 help${NC}         显示此帮助"
    echo ""
}

do_uninstall() {
    echo ""
    echo -e "${RED}  即将卸载 Hysteria2 / sing-box${NC}"
    echo ""
    echo -e "  ${YELLOW}此操作将删除:${NC}"
    echo -e "    - sing-box 二进制文件"
    echo -e "    - /etc/sing-box/ 目录"
    echo -e "    - systemd 服务文件"
    echo -e "    - 网络优化参数"
    echo -e "    - 防火墙规则"
    echo -e "    - hy2 管理命令"
    echo ""
    read -p "确认卸载? 输入 YES: " confirm
    if [[ "$confirm" != "YES" ]]; then
        info "已取消卸载"
        return
    fi

    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    killall sing-box 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$BINARY"
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/hy2

    sed -i '/# Hysteria2 网络优化/,+8d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/# Hysteria2 QUIC 优化/,+4d' /etc/sysctl.conf 2>/dev/null || true
    sysctl -p 2>/dev/null || true

    for p in 8443 443 8080; do
        ufw delete allow "${p}/udp" 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done

    echo ""
    header
    echo -e "${GREEN}  Hysteria2 已彻底移除!${NC}"
    header
    echo ""
}

# 交互菜单模式
interactive_menu() {
    while true; do
        show_menu
        read -p "  请选择 [0-9/q]: " choice
        case "$choice" in
            1) do_start ;;
            2) do_stop ;;
            3) do_restart ;;
            4) do_status ;;
            5) do_log ;;
            6) do_show_config ;;
            7) do_show_uri ;;
            8) do_show_qrcode ;;
            9) do_show_help ;;
            0) do_uninstall; return ;;
            q|Q) echo -e "${GREEN}  再见!${NC}"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
        echo ""
        read -p "  按 Enter 返回菜单..." _
    done
}

# 命令行直接模式
case "${1:-}" in
    start)    do_start ;;
    stop)     do_stop ;;
    restart)  do_restart ;;
    status)   do_status ;;
    log)      do_log ;;
    config)   do_show_config ;;
    uri)      do_show_uri ;;
    qr)       do_show_qrcode ;;
    uninstall) do_uninstall ;;
    help|-h|--help) do_show_help ;;
    *)        interactive_menu ;;
esac
MGMT

    chmod +x /usr/local/bin/hy2
    info "hy2 管理命令已安装: /usr/local/bin/hy2"
    info "输入 hy2 即可打开管理菜单"
}

# ---- 显示完成信息 ----
show_summary() {
    echo ""
    header
    echo -e "${GREEN}  Hysteria2 安装完成!${NC}"
    header
    echo ""
    echo -e "  ${BLUE}服务端信息:${NC}"
    echo -e "    协议:     Hysteria2"
    echo -e "    地址:     ${DOMAIN:-$SERVER_IP}"
    echo -e "    端口:     ${HY2_PORT}/UDP"
    echo -e "    密码:     ${HY2_PASSWORD}"
    echo -e "    混淆:     Salamander"
    echo -e "    混淆密钥: ${HY2_OBFS_PASSWORD}"
    echo -e "    SNI:      ${HY2_SNI}"
    echo ""
    echo -e "  ${BLUE}管理命令:${NC}"
    if [[ "$OS" == "alpine" ]]; then
        echo -e "    启动:   ${BINARY} run -c ${CONFIG_FILE} &"
        echo -e "    停止:   killall sing-box"
        echo -e "    日志:   tail -f ${INSTALL_DIR}/sing-box.log"
    else
        echo -e "    启动:   systemctl start sing-box"
        echo -e "    停止:   systemctl stop sing-box"
        echo -e "    重启:   systemctl restart sing-box"
        echo -e "    状态:   systemctl status sing-box"
        echo -e "    日志:   journalctl -u sing-box -n 50 -f"
    fi
    echo ""
    echo -e "  ${BLUE}文件路径:${NC}"
    echo -e "    配置:       ${CONFIG_FILE}"
    echo -e "    证书:       ${CERT_FILE}"
    echo -e "    客户端 URI: ${INSTALL_DIR}/client_uri.txt"
    echo -e "    客户端配置: ${INSTALL_DIR}/client/"
    echo ""
    echo -e "  ${YELLOW}推荐客户端:${NC}"
    echo -e "    Windows:  v2rayN / Sing-box / Clash.Meta"
    echo -e "    Android:  NekoBox / Hiddify / Sing-box"
    echo -e "    iOS:      Shadowrocket / Stash / Sing-box"
    echo -e "    macOS:    Clash.Meta / Sing-box"
    echo ""
    echo -e "  ${RED}注意:${NC}"
    if [[ "$USE_LE_CERT" == "true" ]]; then
        echo -e "    使用 Let's Encrypt 证书，客户端无需开启不安全证书"
        echo -e "    证书自动续期，有效期 90 天"
    else
        echo -e "    使用自签名证书，客户端需开启 ${YELLOW}允许不安全证书${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}游戏加速提示:${NC}"
    echo -e "    Hysteria2 基于 QUIC + Brutal 拥塞控制"
    echo -e "    已优化网络参数 (BBR + 大缓冲区)"
    echo -e "    忽略客户端带宽限制，服务器自适应"
    echo ""
}

# ============================================================
# 主流程
# ============================================================

# ---- 彻底移除 Hysteria2 ----
uninstall() {
    header
    echo -e "${RED}  彻底移除 Hysteria2 / sing-box${NC}"
    header
    echo ""
    echo -e "  ${YELLOW}此操作将删除:${NC}"
    echo -e "    - sing-box 二进制文件"
    echo -e "    - /etc/sing-box/ 目录 (配置、证书、日志)"
    echo -e "    - systemd 服务文件"
    echo -e "    - 网络优化参数 (sysctl)"
    echo -e "    - 防火墙规则"
    echo -e "    - Let's Encrypt 证书 (acme.sh)"
    echo -e "    - hy2 管理命令"
    echo ""

    safe_read "$(echo -e "${RED}确认彻底移除? 输入 YES 确认: ${NC}")" confirm
    if [[ "$confirm" != "YES" ]]; then
        info "已取消移除"
        return
    fi

    echo ""

    # 1. 停止并禁用服务
    info "停止 sing-box 服务..."
    if command -v systemctl &>/dev/null; then
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
    fi
    killall sing-box 2>/dev/null || true

    # 2. 检测操作系统
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        OS=$(uname -s)
    fi

    # 3. 移除 systemd 服务文件
    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload 2>/dev/null || true
        info "已移除 systemd 服务文件"
    fi

    # 4. 移除 sing-box 二进制
    if [[ -f "$BINARY" ]]; then
        rm -f "$BINARY"
        info "已移除 sing-box: ${BINARY}"
    fi

    # 4b. 移除 hy2 管理命令
    if [[ -f /usr/local/bin/hy2 ]]; then
        rm -f /usr/local/bin/hy2
        info "已移除 hy2 管理命令"
    fi

    # 5. 移除安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        info "已移除安装目录: ${INSTALL_DIR}"
    fi

    # 6. 清理 sysctl 优化参数
    info "清理 sysctl 网络优化参数..."
    sed -i '/# Hysteria2 网络优化/,+8d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/# Hysteria2 QUIC 优化/,+4d' /etc/sysctl.conf 2>/dev/null || true
    sysctl -p 2>/dev/null || true
    info "已清理 sysctl 配置"

    # 7. 移除防火墙规则
    info "清理防火墙规则..."

    # ufw
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        # 读取配置中的端口
        local fw_port=""
        if [[ -f /etc/sing-box/config.json ]]; then
            fw_port=$(grep -o '"listen_port": [0-9]*' /etc/sing-box/config.json 2>/dev/null | grep -o '[0-9]*' || true)
        fi
        # 尝试用常见端口移除规则
        for p in 8443 443 8080; do
            ufw delete allow "${p}/udp" 2>/dev/null || true
        done
        if [[ -n "$fw_port" ]]; then
            ufw delete allow "${fw_port}/udp" 2>/dev/null || true
        fi
        info "ufw: 已清理相关规则"
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        for p in 8443 443 8080; do
            firewall-cmd --zone=public --remove-port="${p}/udp" --permanent 2>/dev/null || true
        done
        firewall-cmd --reload 2>/dev/null || true
        info "firewalld: 已清理相关规则"
    fi

    # iptables
    if command -v iptables &>/dev/null; then
        for p in 8443 443 8080; do
            iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
        done
        if command -v iptables-save &>/dev/null && [[ -f /etc/iptables/rules.v4 ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        info "iptables: 已清理相关规则"
    fi

    # 8. 移除 Let's Encrypt 证书 (acme.sh)
    local acme_bin="$HOME/.acme.sh/acme.sh"
    if [[ ! -x "$acme_bin" ]]; then acme_bin="/root/.acme.sh/acme.sh"; fi
    if [[ ! -x "$acme_bin" ]]; then acme_bin="$(which acme.sh 2>/dev/null)"; fi

    if [[ -x "$acme_bin" ]]; then
        # 查找所有可能的域名证书
        local acme_domains
        acme_domains=$("$acme_bin" --list 2>/dev/null | grep -oP 'Le_Domain=\K\S+' || true)
        if [[ -n "$acme_domains" ]]; then
            echo ""
            echo -e "${YELLOW}  检测到 acme.sh 管理的域名:${NC}"
            echo "$acme_domains" | while read -r d; do
                echo -e "    - $d"
            done
            echo ""
            safe_read "$(echo -e "${YELLOW}是否移除所有 acme.sh 证书? [y/N]: ${NC}")" remove_certs
            if [[ "$remove_certs" =~ ^[yY]$ ]]; then
                echo "$acme_domains" | while read -r d; do
                    "$acme_bin" --remove -d "$d" --force 2>/dev/null || true
                    info "已移除证书: $d"
                done
                # 移除 acme.sh 本身
                safe_read "$(echo -e "${YELLOW}是否同时卸载 acme.sh? [y/N]: ${NC}")" remove_acme
                if [[ "$remove_acme" =~ ^[yY]$ ]]; then
                    rm -rf "$HOME/.acme.sh"
                    info "已卸载 acme.sh"
                fi
            fi
        fi
    fi

    # 9. 清理残留进程
    pkill -f "sing-box" 2>/dev/null || true

    echo ""
    header
    echo -e "${GREEN}  Hysteria2 已彻底移除!${NC}"
    header
    echo ""
}

main() {
    # 处理命令行参数
    case "${1:-}" in
        --uninstall|-u)
            check_root
            uninstall
            return
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  (无参数)    交互式安装 Hysteria2"
            echo "  -u, --uninstall  彻底移除 Hysteria2"
            echo "  -h, --help       显示此帮助信息"
            return
            ;;
    esac

    clear 2>/dev/null || true
    check_root
    detect_os
    get_server_ip
    install_deps
    ensure_python3
    enable_bbr
    interactive_config
    install_sing_box
    generate_cert
    generate_config
    create_service
    config_firewall
    generate_uri
    generate_qrcode
    generate_client_config
    install_management_tool
    start_service
    show_summary
}

main "$@"
