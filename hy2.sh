#!/usr/bin/env bash
set -e
# ============================================================
# Hysteria2 一键安装脚本 (基于 sing-box) - UDP/QUIC 优化版 v3
#
# 相比 v2 的改动:
#   1. sysctl 参数改为独立文件 /etc/sysctl.d/99-hysteria2.conf,
#      重复运行不再产生重复配置 (修复 v2 的追加写入 bug)
#   2. UDP/QUIC 专项调优: 64MB 收发缓冲上限、UDP GRO、分片重组
#      队列加大、软中断预算加大、IPv6 分片同步优化
#   3. 新增网卡优化 (ethtool): 自动拉满 Ring Buffer + 开启
#      GRO/GSO 卸载, 并通过 systemd 开机自动应用
#   4. 客户端 TUN MTU 1420 -> 1400, 降低跨国链路分片丢包
#   5. 卸载逻辑同步清理 sysctl.d 文件与网卡优化服务
#   6. 新增端口跳跃 (Port Hopping): iptables DNAT 将 UDP 端口段重定向到
#      主监听端口, systemd 开机自动应用, 客户端 URI 自动附带 mport 参数
#   7. 修复 jq 双重转义 bug (含特殊字符的密码/混淆密码此前会写入错误值)
#   8. 新增 SWAP 管理: 内存 <= 1G 自动创建物理内存 2 倍的 SWAP;
#      大于 1G 时询问用户自选大小 (可跳过); fstab 持久化, 幂等可重跑
#   9. sysctl 补充 vm.swappiness/vfs_cache_pressure 调优;
#      内核不支持 BBR 时给出明确告警
# ============================================================
# ---- 颜色定义 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
# ---- 全局变量 ----
SING_BOX_VERSION="${SING_BOX_VERSION:-v1.13.0}"
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
SYSCTL_FILE="/etc/sysctl.d/99-hysteria2.conf"
NIC_OPT_SCRIPT="/usr/local/bin/hy2-nic-opt"
NIC_SERVICE="/etc/systemd/system/hy2-nic-opt.service"
# ---- 端口跳跃 ----
HY2_HOP_ENABLE=false
HY2_HOP_START=20000
HY2_HOP_END=50000
PORT_HOP_SCRIPT="/usr/local/bin/hy2-port-hop"
PORT_HOP_SERVICE="/etc/systemd/system/hy2-port-hop.service"
# ---- 打印函数 ----
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header(){ echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
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
        OS_VERSION="${VERSION_ID:-}"
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
            apt-get install -y -qq curl wget openssl qrencode tar gzip systemd iproute2 jq nginx ethtool
            ;;
        centos|rhel|fedora|almalinux|rocky)
            if command -v dnf &>/dev/null; then
                dnf install -y curl wget openssl qrencode tar gzip systemd iproute jq nginx ethtool
            else
                yum install -y curl wget openssl qrencode tar gzip systemd net-tools jq nginx ethtool
            fi
            ;;
        arch|manjaro)
            pacman -Syu --noconfirm curl wget openssl qrencode tar gzip systemd iproute2 jq nginx ethtool
            ;;
        alpine)
            apk add curl wget openssl qrencode tar gzip iproute2 jq nginx ethtool
            ;;
        *)
            warn "未知系统: $OS，尝试使用 apt-get 安装依赖..."
            apt-get update -qq && apt-get install -y -qq curl wget openssl qrencode tar gzip systemd jq nginx ethtool || true
            ;;
    esac
    info "依赖安装完成"
}
# ---- 确保 nginx 目录存在 ----
ensure_nginx_dirs() {
    info "检查并创建 nginx 目录..."
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled

    # 检查主配置文件是否包含 sites-enabled
    if ! grep -q "include /etc/nginx/sites-enabled/\*" /etc/nginx/nginx.conf 2>/dev/null; then
        info "添加 sites-enabled 包含到 nginx 主配置..."
        sed -i '/http {/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
    info "nginx 目录检查完成"
}
# ---- 确保 python3 可用 ----
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
    if ! command -v python3 &>/dev/null; then
        error "python3 安装失败，无法继续"
    fi
}
# ---- SWAP 管理 (内存 <= 1G 自动创建 2 倍内存 SWAP; 否则询问用户) ----
SWAP_FILE="/swapfile"
get_total_ram_mb() {
    awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}
get_current_swap_mb() {
    awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}
create_swap_file() {
    # $1 = swap 大小 (MB), 假设调用方已确认需要创建
    local swap_mb="$1"
    info "创建 ${swap_mb}MB SWAP 文件 (${SWAP_FILE})..."
    # fallocate 秒级完成, 部分文件系统不支持时回退 dd
    if ! fallocate -l "${swap_mb}M" "$SWAP_FILE" 2>/dev/null; then
        warn "fallocate 不可用, 改用 dd (较慢, 取决于大小)..."
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_mb" status=none || error "SWAP 文件创建失败 (磁盘空间不足?)"
    fi
    chmod 600 "$SWAP_FILE" || error "SWAP 文件权限设置失败"
    mkswap -f "$SWAP_FILE" >/dev/null 2>&1 || error "mkswap 失败"
    swapon "$SWAP_FILE" 2>/dev/null || error "启用 SWAP 失败"
    # fstab 持久化 (幂等)
    if ! grep -q "^${SWAP_FILE} " /etc/fstab 2>/dev/null; then
        echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
    fi
    info "SWAP 已启用并写入 /etc/fstab (重启后依然生效)"
}
setup_swap() {
    local ram_mb cur_swap swap_mb swap_input
    ram_mb=$(get_total_ram_mb)
    cur_swap=$(get_current_swap_mb)
    if [[ -z "$ram_mb" || "$ram_mb" -eq 0 ]]; then
        warn "无法读取内存大小 (/proc/meminfo), 跳过 SWAP 配置"
        return
    fi
    info "检测内存: ${ram_mb}MB, 现有 SWAP: ${cur_swap}MB"
    if [[ "$ram_mb" -le 1024 ]]; then
        swap_mb=$(( ram_mb * 2 ))
        info "内存 <= 1G, 自动创建 ${swap_mb}MB SWAP (物理内存 2 倍, 防止编译/高峰期 OOM)"
    else
        safe_read "$(echo -e "${YELLOW}内存 > 1G, 是否创建 SWAP? 输入大小 (MB, 如 2048), 直接回车跳过: ${NC}")" swap_input
        if [[ -z "$swap_input" ]]; then
            info "跳过 SWAP 配置"
            return
        fi
        if [[ ! "$swap_input" =~ ^[0-9]+$ || "$swap_input" -lt 128 ]]; then
            warn "SWAP 大小无效 (需 >= 128 的整数 MB), 跳过"
            return
        fi
        swap_mb="$swap_input"
    fi
    if [[ "$cur_swap" -ge "$swap_mb" ]]; then
        info "现有 SWAP (${cur_swap}MB) 已满足需求, 无需创建"
        return
    fi
    if [[ -f "$SWAP_FILE" ]]; then
        warn "${SWAP_FILE} 已存在 (当前可能未挂载), 为避免覆盖数据跳过创建; 如需重建请手动执行: swapoff ${SWAP_FILE} && rm -f ${SWAP_FILE}"
        return
    fi
    create_swap_file "$swap_mb"
}
# ---- 清理旧版脚本写入 sysctl.conf 的参数块 ----
cleanup_legacy_sysctl() {
    sed -i '/# Hysteria2 网络优化/,+14d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/# Hysteria2 QUIC 优化/,+10d' /etc/sysctl.conf 2>/dev/null || true
}
# ---- 网络优化 (BBR + UDP/QUIC 专项) ----
optimize_network() {
    info "优化网络参数 (BBR + UDP/QUIC 专项调优)..."
    cleanup_legacy_sysctl
    mkdir -p /etc/sysctl.d

    # 独立配置文件, 重复运行直接覆盖, 不会产生重复项
    cat > "$SYSCTL_FILE" <<-'EOF'
# ============ Hysteria2 网络优化 (v3) ============
# --- TCP 基础 (BBR) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# --- UDP/QUIC 专项 ---
# 收发缓冲区上限 64MB (按需分配, 不预占内存)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
# UDP socket 默认缓冲 25MB
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
# 控制消息缓冲上限 (UDP GRO 聚合所需)
net.core.optmem_max = 25165824

# --- 网络栈吞吐 ---
# 收包队列深度, 减少突发流量丢包
net.core.netdev_max_backlog = 250000
# 单轮软中断处理预算 (包数/微秒)
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 5000

# --- IP 分片重组 (QUIC 大包 / 转发流量防丢片) ---
net.ipv4.ipfrag_high_thresh = 8388608
net.ipv4.ipfrag_low_thresh = 6291456
net.ipv4.ipfrag_time = 15
net.ipv6.ip6frag_high_thresh = 8388608
net.ipv6.ip6frag_low_thresh = 6291456
net.ipv6.ip6frag_time = 15

# --- SWAP/内存调优 (低内存 VPS 稳定性; 避免内存充足时滥用 SWAP) ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# --- 系统限制 ---
fs.file-max = 1048576
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

    local cc qdisc rmax
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    rmax=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    rmax=$(( ${rmax:-0} / 1024 / 1024 ))
    info "当前生效: 拥塞控制=${cc} 队列=${qdisc} UDP缓冲上限=${rmax}MB"
    info "网络参数已写入 ${SYSCTL_FILE}"
    if [[ "$cc" != "bbr" ]]; then
        warn "内核未启用 BBR (当前: ${cc}), 跨境加速效果受限, 建议升级内核后重跑本脚本"
    fi
}
# ---- 网卡优化 (Ring Buffer / GRO/GSO, 开机自动应用) ----
install_nic_opt() {
    info "配置网卡优化..."

    if ! command -v ethtool &>/dev/null; then
        warn "ethtool 不可用, 跳过网卡优化"
        return
    fi

    cat > "$NIC_OPT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Hysteria2 网卡优化: 拉满收发环形缓冲 + 开启聚合卸载
IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
[ -z "$IFACE" ] && exit 0
command -v ethtool &>/dev/null || exit 0
MAXRX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^RX:/{print $2; exit}')
MAXTX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^TX:/{print $2; exit}')
if [ -n "$MAXRX" ] && [ "$MAXRX" -gt 0 ] 2>/dev/null; then
    ethtool -G "$IFACE" rx "$MAXRX" 2>/dev/null || true
fi
if [ -n "$MAXTX" ] && [ "$MAXTX" -gt 0 ] 2>/dev/null; then
    ethtool -G "$IFACE" tx "$MAXTX" 2>/dev/null || true
fi
ethtool -K "$IFACE" gro on gso on 2>/dev/null || true
exit 0
EOF
    chmod +x "$NIC_OPT_SCRIPT"

    if [[ "$OS" == "alpine" ]]; then
        warn "Alpine 跳过 systemd 服务, 仅执行一次网卡优化"
        bash "$NIC_OPT_SCRIPT"
        return
    fi

    cat > "$NIC_SERVICE" <<EOF
[Unit]
Description=Hysteria2 NIC optimization (ring buffer / offload)
After=network.target
[Service]
Type=oneshot
ExecStart=${NIC_OPT_SCRIPT}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hy2-nic-opt >/dev/null 2>&1
    systemctl restart hy2-nic-opt 2>/dev/null || bash "$NIC_OPT_SCRIPT"

    local IFACE
    IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "$IFACE" ]]; then
        info "网卡 ${IFACE}: Ring Buffer 已拉满, GRO/GSO 已开启 (开机自动应用)"
    fi
}
# ---- 安装 sing-box ----
install_sing_box() {
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

    local orig_dir
    orig_dir=$(pwd)

    (
        cd /tmp || error "无法进入 /tmp 目录"
        if wget -q --timeout=30 --tries=3 -O "${TAR_FILE}" "${DOWNLOAD_URL}"; then
            info "GitHub 直连下载成功"
        elif wget -q --timeout=30 --tries=3 -O "${TAR_FILE}" "https://ghproxy.net/${DOWNLOAD_URL}"; then
            info "通过 ghproxy.net 代理下载成功"
        else
            error "sing-box 下载失败"
        fi

        local EXTRACTED_DIR
        EXTRACTED_DIR=$(tar tzf "${TAR_FILE}" 2>/dev/null | head -1 | cut -d/ -f1)
        if [[ -z "$EXTRACTED_DIR" ]]; then
            error "无法从 tar 文件中提取目录信息"
        fi

        tar xzf "${TAR_FILE}" || error "解压 tar 文件失败"
        cp "${EXTRACTED_DIR}/sing-box" "${BINARY}" || error "复制二进制文件失败"
        chmod +x "${BINARY}"
        rm -rf "${EXTRACTED_DIR}" "${TAR_FILE}"
    )

    if [[ ! -x "${BINARY}" ]]; then
        error "sing-box 安装失败，二进制文件不存在"
    fi

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
    local CERT_CN="${DOMAIN:-$SERVER_IP}"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -subj "/CN=${CERT_CN}/O=Hysteria2" \
        -days 825 || error "自签名证书生成失败"
    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_FILE}"
    info "自签名证书已生成 (CN=${CERT_CN})"
}
# ---- 申请 Let's Encrypt 证书 ----
request_le_cert() {
    info "开始申请 Let's Encrypt 证书 (域名: ${DOMAIN})..."

    # DNS 解析预检：很多 VPS 失败是因为域名没有解析到本机
    local resolved_ip
    resolved_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z "$resolved_ip" ]]; then
        resolved_ip=$(dig +short A "$DOMAIN" 2>/dev/null | head -n1)
    fi
    if [[ -z "$resolved_ip" ]]; then
        resolved_ip=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: /{print $2; exit}')
    fi
    if [[ -z "$resolved_ip" ]]; then
        warn "无法解析域名 ${DOMAIN} 的 A 记录，请检查 DNS 配置"
        warn "Let's Encrypt 必须能通过 80 端口访问到本机才能签发证书"
    elif [[ "$resolved_ip" != "$SERVER_IP" ]]; then
        warn "域名 ${DOMAIN} 当前解析到 ${resolved_ip}，本机 IP 为 ${SERVER_IP}"
        warn "Let's Encrypt 签发要求域名解析到本机，否则会失败"
        safe_read "$(echo -e "${YELLOW}是否仍要继续申请证书? [y/N]: ${NC}")" dns_continue
        if [[ ! "$dns_continue" =~ ^[yY]$ ]]; then
            error "已取消证书申请"
        fi
    else
        info "DNS 校验通过: ${DOMAIN} -> ${resolved_ip}"
    fi

    # 开放 80 端口（acme.sh standalone 需要）
    config_firewall

    # 检查端口占用
    local port80_in_use=false
    local stopped_services=""
    if ss -tlnp 2>/dev/null | grep -qE ':80\b'; then
        port80_in_use=true
    fi
    if [[ "$port80_in_use" == "true" ]]; then
        warn "端口 80 被占用"
        # 显示占用 80 端口的具体进程
        ss -tlnp 2>/dev/null | grep ':80\b' | sed 's/^/  /'
        safe_read "$(echo -e "${YELLOW}是否自动停止占用 80 端口的服务? [y/N]: ${NC}")" stop_services
        if [[ "$stop_services" =~ ^[yY]$ ]]; then
            # 先尝试停止常见服务
            for svc in nginx apache2 httpd caddy; do
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    info "正在停止 ${svc}..."
                    systemctl stop "$svc" 2>/dev/null || true
                    stopped_services="${stopped_services} ${svc}"
                fi
            done
            sleep 1
            # 如果还占用，直接 kill 占用进程
            if ss -tlnp 2>/dev/null | grep -qE ':80\b'; then
                warn "常见服务已停止，但端口 80 仍被占用"
                local port80_pid
                port80_pid=$(ss -tlnp 2>/dev/null | grep ':80\b' | grep -oP 'pid=\K[0-9]+' | head -n1)
                if [[ -n "$port80_pid" ]]; then
                    local port80_name
                    port80_name=$(ps -p "$port80_pid" -o comm= 2>/dev/null || echo "未知")
                    warn "占用端口 80 的进程: ${port80_name} (PID: ${port80_pid})"
                    safe_read "$(echo -e "${YELLOW}是否强制终止该进程? [y/N]: ${NC}")" kill_confirm
                    if [[ "$kill_confirm" =~ ^[yY]$ ]]; then
                        kill -9 "$port80_pid" 2>/dev/null || true
                        sleep 1
                    fi
                fi
            fi
            # 最终确认
            if ss -tlnp 2>/dev/null | grep -qE ':80\b'; then
                warn "端口 80 仍被占用，acme.sh 可能无法申请证书"
            else
                info "端口 80 已释放"
            fi
        else
            warn "未停止占用 80 的服务，acme.sh 申请可能失败"
        fi
    fi

    # 安装 acme.sh
    local acme_installed=false
    # 先检查是否已安装
    for p in "$HOME/.acme.sh/acme.sh" "/root/.acme.sh/acme.sh" "/usr/local/bin/acme.sh"; do
        if [[ -x "$p" ]]; then
            acme_installed=true
            break
        fi
    done
    if [[ "$acme_installed" == "false" ]] && ! command -v acme.sh &>/dev/null; then
        info "安装 acme.sh..."
        if ! curl -fsSL https://get.acme.sh | sh; then
            error "acme.sh 安装失败 (无法从 get.acme.sh 下载)"
        fi
        sleep 2
        # 安装后设置 CA 并注册邮箱
        export PATH="$HOME/.acme.sh:$PATH"
        local _acme="$HOME/.acme.sh/acme.sh"
        [[ -x "$_acme" ]] && "$_acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
        [[ -x "$_acme" ]] && "$_acme" --register-account -m "admin@${DOMAIN}" >/dev/null 2>&1 || true
    fi

    # PATH 设置
    export PATH="$HOME/.acme.sh:$PATH"

    # 查找 acme.sh 可执行文件
    info "正在申请证书..."
    local acme_bin=""
    for p in "$HOME/.acme.sh/acme.sh" "/root/.acme.sh/acme.sh" "/usr/local/bin/acme.sh"; do
        if [[ -x "$p" ]]; then
            acme_bin="$p"
            break
        fi
    done
    # 最后用 command -v 兜底
    if [[ -z "$acme_bin" ]] && command -v acme.sh &>/dev/null; then
        acme_bin="$(command -v acme.sh)"
    fi

    if [[ -z "$acme_bin" ]] || [[ ! -x "$acme_bin" ]]; then
        warn "找不到 acme.sh 可执行文件，尝试手动定位..."
        # 尝试 find 查找
        acme_bin=$(find /root/.acme.sh /home -name "acme.sh" -type f -executable 2>/dev/null | head -n1)
        if [[ -z "$acme_bin" ]] || [[ ! -x "$acme_bin" ]]; then
            error "acme.sh 安装失败或不可用，请检查网络后重试"
        fi
        info "找到 acme.sh: ${acme_bin}"
    fi
    info "使用 acme.sh: ${acme_bin}"

    # 申请证书，保留 stderr 到日志便于诊断；增加 120s 超时防止挂死
    local acme_log="/tmp/acme_issue.log"
    info "日志位置: ${acme_log}"
    local acme_exit=0
    timeout 120 "$acme_bin" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force >"$acme_log" 2>&1 || acme_exit=$?

    if [[ "$acme_exit" -eq 0 ]]; then
        info "Let's Encrypt 证书申请成功!"
        "$acme_bin" --install-cert -d "$DOMAIN" \
            --cert-file "${CERT_FILE}" \
            --key-file "${KEY_FILE}" \
            --fullchain-file "${CERT_FILE}" \
            --reloadcmd "systemctl reload sing-box 2>/dev/null || true" >>"$acme_log" 2>&1 || \
            warn "证书安装到 ${CERT_FILE} 失败，详情见 ${acme_log}"
        chmod 600 "${KEY_FILE}"
        chmod 644 "${CERT_FILE}"
        info "证书已安装到: ${CERT_FILE}"
    elif [[ "$acme_exit" -eq 124 ]]; then
        warn "Let's Encrypt 证书申请超时 (120秒)！"
        warn "可能原因: 80 端口无法访问、网络不通、或 DNS 未指向本机"
        warn "详细日志: ${acme_log}"
        echo ""
        tail -n 20 "$acme_log" 2>/dev/null | sed 's/^/  /'
        echo ""
        warn "回退到自签名证书 (客户端需要开启「允许不安全证书」)..."
        USE_LE_CERT=false
        INSECURE_FLAG=1
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "${KEY_FILE}" \
            -out "${CERT_FILE}" \
            -subj "/CN=${DOMAIN}/O=Hysteria2" \
            -days 825 || error "回退自签名证书生成失败"
        chmod 600 "${KEY_FILE}"
        chmod 644 "${CERT_FILE}"
        info "自签名证书已生成"
    else
        warn "Let's Encrypt 证书申请失败 (退出码: ${acme_exit})，日志如下:"
        echo ""
        tail -n 40 "$acme_log" 2>/dev/null | sed 's/^/  /'
        echo ""
        warn "常见原因:"
        warn "  1) 域名未解析到本机 IP (${SERVER_IP})"
        warn "  2) ISP/云服务商屏蔽了 80/443 端口的入站"
        warn "  3) Let's Encrypt 限速 (同一域名 7 天内最多 5 张重复证书)"
        warn "  4) 系统时间不正确"
        warn "回退到自签名证书 (客户端需要开启「允许不安全证书」)..."
        USE_LE_CERT=false
        INSECURE_FLAG=1
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "${KEY_FILE}" \
            -out "${CERT_FILE}" \
            -subj "/CN=${DOMAIN}/O=Hysteria2" \
            -days 825 || error "回退自签名证书生成失败"
        chmod 600 "${KEY_FILE}"
        chmod 644 "${CERT_FILE}"
        info "自签名证书已生成"
    fi

    # 恢复服务
    for svc in $stopped_services; do
        systemctl start "$svc" 2>/dev/null || true
    done
}
# ---- 生成随机密码 ----
gen_password() {
    while true; do
        local pwd
        pwd=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)
        if [[ ${#pwd} -eq 32 ]]; then
            echo "$pwd"
            return
        fi
    done
}
# ---- 交互式配置 ----
interactive_config() {
    header
    echo -e "${BLUE}  Hysteria2 一键安装脚本 (UDP/QUIC 优化版 v3)${NC}"
    echo -e "${BLUE}  基于 sing-box | 支持游戏加速${NC}"
    header
    echo ""
    safe_read "$(echo -e "${YELLOW}请输入 Hysteria2 监听端口 [默认: 443]: ${NC}")" input_port
    HY2_PORT="${input_port:-443}"
    if [[ ! "$HY2_PORT" =~ ^[0-9]+$ || "$HY2_PORT" -lt 1 || "$HY2_PORT" -gt 65535 ]]; then
        error "端口无效"
    fi
    if ss -ulnp 2>/dev/null | grep -qE ":${HY2_PORT}\b"; then
        warn "UDP 端口 ${HY2_PORT} 已被其他服务占用!"
        safe_read "$(echo -e "${YELLOW}是否继续? (可能导致冲突) [y/N]: ${NC}")" port_continue
        if [[ ! "$port_continue" =~ ^[yY]$ ]]; then
            error "安装已取消"
        fi
    fi
    if ss -tlnp 2>/dev/null | grep -qE ":${HY2_PORT}\b"; then
        warn "TCP 端口 ${HY2_PORT} 也被占用 (伪装网站 80/443 与之可能冲突)"
    fi

    # ---- 端口跳跃配置 ----
    safe_read "$(echo -e "${YELLOW}是否开启端口跳跃 Port Hopping (抗 UDP 限速/封锁)? [Y/n]: ${NC}")" use_hop
    if [[ "$use_hop" =~ ^[nN]$ ]]; then
        HY2_HOP_ENABLE=false
    else
        HY2_HOP_ENABLE=true
        safe_read "$(echo -e "${YELLOW}请输入跳跃端口范围 [默认: 20000-50000]: ${NC}")" input_hop
        if [[ -n "$input_hop" ]]; then
            if [[ ! "$input_hop" =~ ^[0-9]+-[0-9]+$ ]]; then
                error "端口范围格式无效 (应为 起始-结束, 如 20000-50000)"
            fi
            HY2_HOP_START="${input_hop%-*}"
            HY2_HOP_END="${input_hop#*-}"
        fi
        if [[ "$HY2_HOP_START" -lt 1 || "$HY2_HOP_END" -gt 65535 || "$HY2_HOP_START" -gt "$HY2_HOP_END" ]]; then
            error "端口范围无效 (需 1-65535 且起始 <= 结束)"
        fi
        if [[ "$HY2_PORT" -ge "$HY2_HOP_START" && "$HY2_PORT" -le "$HY2_HOP_END" ]]; then
            info "主端口 ${HY2_PORT} 在跳跃范围内, DNAT 到自身无影响, 可正常使用"
        fi
        if command -v iptables &>/dev/null; then
            if ! iptables -t nat -L PREROUTING -n >/dev/null 2>&1; then
                warn "iptables nat 表不可用 (部分内核模块缺失), 端口跳跃可能无法生效"
            fi
        else
            warn "系统缺少 iptables, 端口跳跃将无法生效"
        fi
    fi

    local default_pwd
    default_pwd=$(gen_password)
    safe_read "$(echo -e "${YELLOW}请输入认证密码 [默认随机: ${default_pwd}]: ${NC}")" input_pwd
    HY2_PASSWORD="${input_pwd:-$default_pwd}"

    local default_obfs
    default_obfs=$(gen_password)
    safe_read "$(echo -e "${YELLOW}请输入 Salamander 混淆密码 [默认随机: ${default_obfs}]: ${NC}")" input_obfs
    HY2_OBFS_PASSWORD="${input_obfs:-$default_obfs}"

    safe_read "$(echo -e "${YELLOW}请输入伪装域名/SNI [默认: www.cloudflare.com]: ${NC}")" input_sni
    HY2_SNI="${input_sni:-www.cloudflare.com}"

    safe_read "$(echo -e "${YELLOW}是否拥有域名并已解析到本机? [y/N]: ${NC}")" use_domain
    if [[ "$use_domain" =~ ^[yY]$ ]]; then
        safe_read "$(echo -e "${YELLOW}请输入您的域名: ${NC}")" DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$ ]]; then
                error "域名格式无效"
            fi
            safe_read "$(echo -e "${YELLOW}是否一键申请 Let's Encrypt 免费证书? [Y/n]: ${NC}")" use_le
            if [[ "$use_le" =~ ^[nN]$ ]]; then
                USE_LE_CERT=false
                INSECURE_FLAG=1
            else
                USE_LE_CERT=true
                INSECURE_FLAG=0
            fi
            if [[ "$HY2_SNI" == "www.cloudflare.com" ]]; then
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
    if [[ "$HY2_HOP_ENABLE" == "true" ]]; then
        echo -e "  端口跳跃:    ${HY2_HOP_START}-${HY2_HOP_END}/UDP -> ${HY2_PORT}"
    else
        echo -e "  端口跳跃:    未开启"
    fi
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
    # 注意: jq --arg 会正确处理 JSON 转义, 不能手动预转义 (否则特殊字符密码会被双重转义)
    jq -n \
        --arg pwd "${HY2_PASSWORD}" \
        --arg obfs "${HY2_OBFS_PASSWORD}" \
        --arg cert "$CERT_FILE" \
        --arg key "$KEY_FILE" \
        --argjson port "$HY2_PORT" \
        --arg sni "${HY2_SNI}" \
        '{
            log: { level: "warn", output: "/etc/sing-box/sing-box.log", timestamp: true },
            inbounds: [{
                type: "hysteria2",
                tag: "hy2-in",
                listen: "::",
                listen_port: $port,
                users: [{ name: "game", password: $pwd }],
                ignore_client_bandwidth: true,
                obfs: { type: "salamander", password: $obfs },
                tls: { enabled: true, alpn: ["h3"], certificate_path: $cert, key_path: $key }
            }],
            outbounds: [{ type: "direct", tag: "direct" }]
        }' > "$CONFIG_FILE" || error "生成配置文件失败"

    info "配置文件生成完毕: ${CONFIG_FILE}"
}
# ---- 创建 systemd 服务 ----
create_service() {
    if [[ "$OS" == "alpine" ]]; then
        warn "Alpine 使用 OpenRC, 跳过 systemd 服务创建"
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
LimitNOFILE=1048576
LimitNPROC=65536
LimitAS=infinity
LimitMEMLOCK=infinity
TasksMax=infinity
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sing-box
Nice=-10
CPUSchedulingPolicy=rr
CPUSchedulingPriority=50
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    info "systemd 服务创建完毕"
}
# ---- 配置防火墙 ----
config_firewall() {
    info "配置防火墙规则..."
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${HY2_PORT}/udp"
        info "ufw: 已开放端口 ${HY2_PORT}/udp"
        if [[ -n "$DOMAIN" ]]; then
            ufw allow 80/tcp 2>/dev/null || true
            ufw allow 443/tcp 2>/dev/null || true
        fi
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall-cmd --zone=public --add-port="${HY2_PORT}/udp" --permanent
        if [[ -n "$DOMAIN" ]]; then
            firewall-cmd --zone=public --add-port="80/tcp" --permanent 2>/dev/null || true
            firewall-cmd --zone=public --add-port="443/tcp" --permanent 2>/dev/null || true
        fi
        firewall-cmd --reload
    fi
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p udp --dport "$HY2_PORT" -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p udp --dport "$HY2_PORT" -j ACCEPT
        if [[ -n "$DOMAIN" ]]; then
            iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
                iptables -A INPUT -p tcp --dport 80 -j ACCEPT
            iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
                iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        fi
    fi
}
# ---- 配置端口跳跃 (iptables DNAT + 开机自动应用) ----
# 原理: 服务器仍只监听 HY2_PORT 单端口, 用 nat PREROUTING 把整个 UDP 端口段
#       DNAT 到主端口, 客户端通过 mport 参数在端口段内定期换端口, 抗 QoS/封锁
setup_port_hopping() {
    if [[ "$HY2_HOP_ENABLE" != "true" ]]; then
        info "未开启端口跳跃, 跳过"
        return
    fi
    info "配置端口跳跃: UDP ${HY2_HOP_START}-${HY2_HOP_END} -> ${HY2_PORT}..."

    if ! command -v iptables &>/dev/null; then
        warn "iptables 不可用, 端口跳跃无法配置, 已跳过"
        HY2_HOP_ENABLE=false
        return
    fi

    mkdir -p "$INSTALL_DIR"
    cat > "$PORT_HOP_SCRIPT" <<EOF
#!/usr/bin/env bash
# Hysteria2 端口跳跃: 将 UDP ${HY2_HOP_START}-${HY2_HOP_END} DNAT 到 ${HY2_PORT}
# 用法: hy2-port-hop [clean]  (clean 移除规则)
HOP_START="${HY2_HOP_START}"
HOP_END="${HY2_HOP_END}"
TARGET_PORT="${HY2_PORT}"
apply_rules() {
    local bin="\$1"
    # 先删旧规则再添加, 保证幂等
    "\$bin" -t nat -D PREROUTING -p udp --dport "\${HOP_START}:\${HOP_END}" -j DNAT --to-destination ":\${TARGET_PORT}" 2>/dev/null || true
    "\$bin" -t nat -A PREROUTING -p udp --dport "\${HOP_START}:\${HOP_END}" -j DNAT --to-destination ":\${TARGET_PORT}" 2>/dev/null || true
    "\$bin" -C INPUT -p udp --dport "\${HOP_START}:\${HOP_END}" -j ACCEPT 2>/dev/null || \\
        "\$bin" -A INPUT -p udp --dport "\${HOP_START}:\${HOP_END}" -j ACCEPT 2>/dev/null || true
}
clean_rules() {
    local bin="\$1"
    "\$bin" -t nat -D PREROUTING -p udp --dport "\${HOP_START}:\${HOP_END}" -j DNAT --to-destination ":\${TARGET_PORT}" 2>/dev/null || true
    "\$bin" -D INPUT -p udp --dport "\${HOP_START}:\${HOP_END}" -j ACCEPT 2>/dev/null || true
}
case "\$1" in
    clean)
        clean_rules iptables
        command -v ip6tables >/dev/null 2>&1 && clean_rules ip6tables
        ;;
    *)
        apply_rules iptables
        command -v ip6tables >/dev/null 2>&1 && apply_rules ip6tables
        ;;
esac
exit 0
EOF
    chmod +x "$PORT_HOP_SCRIPT"

    # 立即应用规则
    "$PORT_HOP_SCRIPT"
    info "iptables DNAT 规则已应用"

    # ufw / firewalld 放行端口段
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${HY2_HOP_START}:${HY2_HOP_END}/udp" >/dev/null 2>&1 || true
        info "ufw: 已放行 ${HY2_HOP_START}:${HY2_HOP_END}/udp"
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall-cmd --zone=public --add-port="${HY2_HOP_START}-${HY2_HOP_END}/udp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld: 已放行 ${HY2_HOP_START}-${HY2_HOP_END}/udp"
    fi

    # Alpine 无 systemd, 规则仅本次生效
    if [[ "$OS" == "alpine" ]]; then
        warn "Alpine 无 systemd, 端口跳跃规则仅在本次开机周期内生效"
        return
    fi

    cat > "$PORT_HOP_SERVICE" <<EOF
[Unit]
Description=Hysteria2 port hopping (UDP DNAT ${HY2_HOP_START}-${HY2_HOP_END} -> ${HY2_PORT})
After=network.target
[Service]
Type=oneshot
ExecStart=${PORT_HOP_SCRIPT}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hy2-port-hop >/dev/null 2>&1
    systemctl restart hy2-port-hop 2>/dev/null || true
    info "端口跳跃已设为开机自动应用 (hy2-port-hop.service)"
}
# ---- 生成客户端 URI ----
generate_uri() {
    local domain_part="${DOMAIN:-$SERVER_IP}"
    local encoded_pwd
    local encoded_obfs_pwd
    encoded_pwd=$(HY2_PWD="${HY2_PASSWORD}" python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_PWD'], safe=''))" 2>/dev/null || echo "${HY2_PASSWORD}")
    encoded_obfs_pwd=$(HY2_PWD="${HY2_OBFS_PASSWORD}" python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_PWD'], safe=''))" 2>/dev/null || echo "${HY2_OBFS_PASSWORD}")
    local encoded_sni
    encoded_sni=$(HY2_SNI="${HY2_SNI}" python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_SNI'], safe=''))" 2>/dev/null || echo "${HY2_SNI}")
    CLIENT_URI="hysteria2://${encoded_pwd}@${domain_part}:${HY2_PORT}?obfs=salamander&obfs-password=${encoded_obfs_pwd}&sni=${encoded_sni}&insecure=${INSECURE_FLAG}"
    if [[ "$HY2_HOP_ENABLE" == "true" ]]; then
        CLIENT_URI="${CLIENT_URI}&mport=${HY2_HOP_START}-${HY2_HOP_END}"
    fi
    CLIENT_URI="${CLIENT_URI}#Hy2-Game-${SERVER_IP}"
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
    if command -v qrencode &>/dev/null; then
        echo -e "${GREEN}  扫描以下二维码导入客户端:${NC}"
        echo ""
        qrencode -t ANSIUTF8 "${CLIENT_URI}"
        echo ""
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
    # 注意: jq --arg 会正确处理 JSON 转义, 不能手动预转义
    jq -n \
        --arg pwd "${HY2_PASSWORD}" \
        --arg obfs "${HY2_OBFS_PASSWORD}" \
        --arg server "$domain_part" \
        --argjson port "$HY2_PORT" \
        --arg sni "${HY2_SNI}" \
        --argjson insecure "$INSECURE_FLAG" \
        '{
            log: { level: "info" },
            inbounds: [
                { type: "tun", tag: "tun-in", interface_name: "sing-tun", inet4_address: "172.19.0.1/30", mtu: 1400, auto_route: true, strict_route: false },
                { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 1080 }
            ],
            outbounds: [
                {
                    type: "hysteria2",
                    tag: "hy2-out",
                    server: $server,
                    server_port: $port,
                    password: $pwd,
                    obfs: { type: "salamander", password: $obfs },
                    tls: { enabled: true, server_name: $sni, insecure: $insecure, alpn: ["h3"] }
                }
            ],
            route: { final: "hy2-out", auto_detect_interface: true }
        }' > "${client_dir}/client-config.json" || error "生成客户端配置失败"

    info "客户端配置已生成: ${client_dir}/client-config.json (TUN MTU: 1400)"
}
# ---- 搭建伪装网站 ----
setup_camouflage_site() {
    if [[ -z "$DOMAIN" ]]; then
        info "未使用域名，跳过伪装网站搭建"
        return
    fi
    info "搭建伪装网站 (域名: ${DOMAIN})..."
    local WEB_DIR="/var/www/camouflage"
    local NGINX_CONF="/etc/nginx/sites-available/camouflage"

    # 确保 nginx 目录存在
    ensure_nginx_dirs

    # 创建网站目录
    mkdir -p "$WEB_DIR"

    # 创建默认页面 - CDN/视频流媒体风格伪装网站
    cat > "${WEB_DIR}/index.html" <<-'DEFAULTHTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Global CDN Network - High Performance Content Delivery</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif; background: #0a0e27; color: #e0e0e0; overflow-x: hidden; }
        .nav { display: flex; justify-content: space-between; align-items: center; padding: 20px 60px; background: rgba(10,14,39,0.95); position: fixed; width: 100%; top: 0; z-index: 100; border-bottom: 1px solid rgba(255,255,255,0.05); }
        .nav-logo { font-size: 1.5em; font-weight: 700; color: #00d4ff; letter-spacing: 2px; }
        .nav-logo span { color: #fff; }
        .nav-links a { color: #8892b0; text-decoration: none; margin-left: 30px; font-size: 0.95em; transition: color 0.3s; }
        .nav-links a:hover { color: #00d4ff; }
        .hero { padding: 160px 60px 100px; text-align: center; position: relative; }
        .hero::before { content: ''; position: absolute; top: 0; left: 0; right: 0; bottom: 0; background: radial-gradient(ellipse at 50% 0%, rgba(0,212,255,0.15) 0%, transparent 60%); pointer-events: none; }
        .hero h1 { font-size: 3.2em; font-weight: 800; margin-bottom: 20px; background: linear-gradient(135deg, #00d4ff, #7b2ff7, #ff0080); -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; line-height: 1.2; }
        .hero p { font-size: 1.25em; color: #8892b0; max-width: 700px; margin: 0 auto 40px; line-height: 1.8; }
        .hero-stats { display: flex; justify-content: center; gap: 60px; margin-top: 50px; }
        .stat { text-align: center; }
        .stat-num { font-size: 2.8em; font-weight: 800; color: #00d4ff; }
        .stat-label { font-size: 0.85em; color: #8892b0; margin-top: 5px; text-transform: uppercase; letter-spacing: 1px; }
        .bandwidth-bar { max-width: 800px; margin: 50px auto 0; background: rgba(255,255,255,0.05); border-radius: 12px; padding: 25px 30px; border: 1px solid rgba(0,212,255,0.2); }
        .bandwidth-bar h3 { font-size: 0.85em; color: #8892b0; text-transform: uppercase; letter-spacing: 2px; margin-bottom: 15px; }
        .bw-meter { height: 8px; background: rgba(255,255,255,0.1); border-radius: 4px; overflow: hidden; margin-bottom: 10px; }
        .bw-fill { height: 100%; width: 73%; background: linear-gradient(90deg, #00d4ff, #7b2ff7); border-radius: 4px; animation: pulse 2s ease-in-out infinite; }
        @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.7; } }
        .bw-info { display: flex; justify-content: space-between; font-size: 0.85em; color: #8892b0; }
        .bw-info .current { color: #00d4ff; font-weight: 600; }
        .section { padding: 100px 60px; }
        .section-title { text-align: center; margin-bottom: 60px; }
        .section-title h2 { font-size: 2.2em; font-weight: 700; color: #fff; margin-bottom: 15px; }
        .section-title p { color: #8892b0; font-size: 1.1em; }
        .features-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 30px; max-width: 1200px; margin: 0 auto; }
        .feature-card { background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.08); border-radius: 16px; padding: 40px 30px; transition: all 0.3s; position: relative; overflow: hidden; }
        .feature-card:hover { border-color: rgba(0,212,255,0.3); transform: translateY(-5px); box-shadow: 0 20px 40px rgba(0,0,0,0.3); }
        .feature-card::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 3px; background: linear-gradient(90deg, #00d4ff, #7b2ff7); opacity: 0; transition: opacity 0.3s; }
        .feature-card:hover::before { opacity: 1; }
        .feature-icon { width: 50px; height: 50px; border-radius: 12px; display: flex; align-items: center; justify-content: center; font-size: 1.5em; margin-bottom: 20px; }
        .icon-blue { background: rgba(0,212,255,0.1); color: #00d4ff; }
        .icon-purple { background: rgba(123,47,247,0.1); color: #7b2ff7; }
        .icon-pink { background: rgba(255,0,128,0.1); color: #ff0080; }
        .feature-card h3 { font-size: 1.2em; color: #fff; margin-bottom: 12px; }
        .feature-card p { color: #8892b0; line-height: 1.7; font-size: 0.95em; }
        .edge-nodes { max-width: 1200px; margin: 0 auto; }
        .node-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 20px; margin-top: 40px; }
        .node-card { background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.06); border-radius: 12px; padding: 20px; text-align: center; }
        .node-flag { font-size: 2em; margin-bottom: 8px; }
        .node-name { font-size: 0.9em; color: #fff; font-weight: 600; }
        .node-latency { font-size: 0.8em; color: #00d4ff; margin-top: 5px; }
        .node-status { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #00ff88; margin-right: 5px; animation: blink 1.5s infinite; }
        @keyframes blink { 0%,100% { opacity: 1; } 50% { opacity: 0.4; } }
        .pricing { max-width: 1000px; margin: 0 auto; }
        .pricing-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 30px; }
        .price-card { background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.08); border-radius: 16px; padding: 40px 30px; text-align: center; position: relative; }
        .price-card.popular { border-color: #00d4ff; background: rgba(0,212,255,0.05); }
        .price-badge { position: absolute; top: -12px; left: 50%; transform: translateX(-50%); background: linear-gradient(135deg, #00d4ff, #7b2ff7); color: #fff; padding: 4px 16px; border-radius: 20px; font-size: 0.75em; font-weight: 600; }
        .price-name { font-size: 1.1em; color: #8892b0; margin-bottom: 10px; }
        .price-amount { font-size: 3em; font-weight: 800; color: #fff; }
        .price-amount span { font-size: 0.4em; color: #8892b0; }
        .price-desc { color: #8892b0; margin: 15px 0 25px; font-size: 0.9em; }
        .price-features { list-style: none; text-align: left; margin-bottom: 30px; }
        .price-features li { padding: 8px 0; color: #8892b0; font-size: 0.9em; border-bottom: 1px solid rgba(255,255,255,0.05); }
        .price-features li::before { content: '✓'; color: #00d4ff; margin-right: 10px; font-weight: 700; }
        .btn-primary { display: inline-block; padding: 12px 30px; background: linear-gradient(135deg, #00d4ff, #7b2ff7); color: #fff; border: none; border-radius: 8px; font-size: 0.95em; font-weight: 600; cursor: pointer; text-decoration: none; transition: all 0.3s; }
        .btn-primary:hover { transform: translateY(-2px); box-shadow: 0 10px 30px rgba(0,0,212,255,0.3); }
        .btn-outline { display: inline-block; padding: 12px 30px; background: transparent; color: #00d4ff; border: 1px solid rgba(0,212,255,0.3); border-radius: 8px; font-size: 0.95em; font-weight: 600; cursor: pointer; text-decoration: none; transition: all 0.3s; }
        .btn-outline:hover { background: rgba(0,212,255,0.1); }
        .log-section { max-width: 900px; margin: 0 auto; background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; padding: 30px; font-family: 'Courier New', monospace; }
        .log-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; padding-bottom: 15px; border-bottom: 1px solid rgba(255,255,255,0.1); }
        .log-header h3 { color: #00d4ff; font-size: 0.9em; }
        .log-live { display: flex; align-items: center; gap: 8px; font-size: 0.8em; color: #00ff88; }
        .log-live::before { content: ''; width: 8px; height: 8px; border-radius: 50%; background: #00ff88; animation: blink 1s infinite; }
        .log-entry { font-size: 0.8em; line-height: 1.8; color: #8892b0; }
        .log-entry .time { color: #555; }
        .log-entry .method { color: #00d4ff; }
        .log-entry .path { color: #7b2ff7; }
        .log-entry .status { color: #00ff88; }
        .log-entry .size { color: #ff0080; }
        .footer { padding: 60px; text-align: center; border-top: 1px solid rgba(255,255,255,0.05); }
        .footer-links { display: flex; justify-content: center; gap: 40px; margin-bottom: 20px; }
        .footer-links a { color: #8892b0; text-decoration: none; font-size: 0.9em; }
        .footer-links a:hover { color: #00d4ff; }
        .footer p { color: #555; font-size: 0.85em; }
        @media (max-width: 768px) {
            .nav { padding: 15px 20px; }
            .nav-links { display: none; }
            .hero { padding: 120px 20px 60px; }
            .hero h1 { font-size: 2em; }
            .hero-stats { flex-direction: column; gap: 30px; }
            .features-grid, .pricing-grid, .node-grid { grid-template-columns: 1fr; }
            .section { padding: 60px 20px; }
        }
    </style>
</head>
<body>
    <nav class="nav">
        <div class="nav-logo"><span>CDN</span>GLOBAL</div>
        <div class="nav-links">
            <a href="#features">Features</a>
            <a href="#network">Network</a>
            <a href="#pricing">Pricing</a>
            <a href="#docs">Documentation</a>
        </div>
    </nav>

    <section class="hero">
        <h1>Enterprise-Grade CDN<br>Content Delivery Network</h1>
        <p>Lightning-fast content delivery across 200+ edge locations worldwide. Stream, cache, and distribute your content with 99.99% uptime guarantee.</p>
        <div class="hero-stats">
            <div class="stat">
                <div class="stat-num">2.4PB</div>
                <div class="stat-label">Daily Traffic</div>
            </div>
            <div class="stat">
                <div class="stat-num">200+</div>
                <div class="stat-label">Edge Nodes</div>
            </div>
            <div class="stat">
                <div class="stat-num">12ms</div>
                <div class="stat-label">Avg Latency</div>
            </div>
            <div class="stat">
                <div class="stat-num">99.99%</div>
                <div class="stat-label">Uptime SLA</div>
            </div>
        </div>
        <div class="bandwidth-bar">
            <h3>Real-Time Bandwidth Usage</h3>
            <div class="bw-meter"><div class="bw-fill"></div></div>
            <div class="bw-info">
                <span>Current: <span class="current">847.3 Gbps</span></span>
                <span>Capacity: 1.2 Tbps</span>
            </div>
        </div>
    </section>

    <section class="section" id="features">
        <div class="section-title">
            <h2>Why Choose CDN Global</h2>
            <p>Enterprise performance meets developer experience</p>
        </div>
        <div class="features-grid">
            <div class="feature-card">
                <div class="feature-icon icon-blue">⚡</div>
                <h3>Ultra-Low Latency</h3>
                <p>Intelligent edge routing ensures your content is served from the nearest node. Average TTFB under 15ms globally.</p>
            </div>
            <div class="feature-card">
                <div class="feature-icon icon-purple">🔒</div>
                <h3>DDoS Protection</h3>
                <p>Enterprise-grade DDoS mitigation with automatic traffic scrubbing. Protect up to 3 Tbps of volumetric attacks.</p>
            </div>
            <div class="feature-card">
                <div class="feature-icon icon-pink">📊</div>
                <h3>Real-Time Analytics</h3>
                <p>Monitor bandwidth, cache hit ratios, and error rates in real-time with our comprehensive dashboard.</p>
            </div>
            <div class="feature-card">
                <div class="feature-icon icon-blue">🎬</div>
                <h3>Video Streaming</h3>
                <p>Adaptive bitrate streaming with HLS/DASH support. Deliver 4K content to millions of concurrent viewers.</p>
            </div>
            <div class="feature-card">
                <div class="feature-icon icon-purple">🌐</div>
                <h3>Global Network</h3>
                <p>200+ PoPs across 6 continents. Automatic failover ensures zero-downtime content delivery.</p>
            </div>
            <div class="feature-card">
                <div class="feature-icon icon-pink">🚀</div>
                <h3>Instant Purge</h3>
                <p>Purge cached content across all edge nodes in under 150ms. Full API access for automation.</p>
            </div>
        </div>
    </section>

    <section class="section" id="network" style="background: rgba(0,0,0,0.2);">
        <div class="section-title">
            <h2>Global Edge Network</h2>
            <p>Live status of our edge nodes worldwide</p>
        </div>
        <div class="node-grid">
            <div class="node-card"><div class="node-flag">🇺🇸</div><div class="node-name">New York</div><div class="node-latency"><span class="node-status"></span>8ms</div></div>
            <div class="node-card"><div class="node-flag">🇺🇸</div><div class="node-name">Los Angeles</div><div class="node-latency"><span class="node-status"></span>12ms</div></div>
            <div class="node-card"><div class="node-flag">🇬🇧</div><div class="node-name">London</div><div class="node-latency"><span class="node-status"></span>15ms</div></div>
            <div class="node-card"><div class="node-flag">🇩🇪</div><div class="node-name">Frankfurt</div><div class="node-latency"><span class="node-status"></span>11ms</div></div>
            <div class="node-card"><div class="node-flag">🇯🇵</div><div class="node-name">Tokyo</div><div class="node-latency"><span class="node-status"></span>9ms</div></div>
            <div class="node-card"><div class="node-flag">🇸🇬</div><div class="node-name">Singapore</div><div class="node-latency"><span class="node-status"></span>14ms</div></div>
            <div class="node-card"><div class="node-flag">🇦🇺</div><div class="node-name">Sydney</div><div class="node-latency"><span class="node-status"></span>18ms</div></div>
            <div class="node-card"><div class="node-flag">🇧🇷</div><div class="node-name">São Paulo</div><div class="node-latency"><span class="node-status"></span>22ms</div></div>
        </div>
    </section>

    <section class="section" id="pricing">
        <div class="section-title">
            <h2>Simple Pricing</h2>
            <p>Pay only for what you use. No hidden fees.</p>
        </div>
        <div class="pricing-grid">
            <div class="price-card">
                <div class="price-name">Starter</div>
                <div class="price-amount">$49<span>/mo</span></div>
                <div class="price-desc">Perfect for small projects</div>
                <ul class="price-features">
                    <li>1TB Bandwidth/month</li>
                    <li>50 Edge Locations</li>
                    <li>SSL Certificate</li>
                    <li>Email Support</li>
                </ul>
                <a href="#" class="btn-outline">Get Started</a>
            </div>
            <div class="price-card popular">
                <div class="price-badge">MOST POPULAR</div>
                <div class="price-name">Pro</div>
                <div class="price-amount">$199<span>/mo</span></div>
                <div class="price-desc">For growing businesses</div>
                <ul class="price-features">
                    <li>10TB Bandwidth/month</li>
                    <li>200+ Edge Locations</li>
                    <li>DDoS Protection</li>
                    <li>Priority Support</li>
                    <li>Real-Time Analytics</li>
                </ul>
                <a href="#" class="btn-primary">Get Started</a>
            </div>
            <div class="price-card">
                <div class="price-name">Enterprise</div>
                <div class="price-amount">Custom</div>
                <div class="price-desc">For high-traffic applications</div>
                <ul class="price-features">
                    <li>Unlimited Bandwidth</li>
                    <li>200+ Edge Locations</li>
                    <li>Advanced DDoS</li>
                    <li>24/7 Dedicated Support</li>
                    <li>Custom SLA</li>
                </ul>
                <a href="#" class="btn-outline">Contact Sales</a>
            </div>
        </div>
    </section>

    <section class="section" id="docs" style="background: rgba(0,0,0,0.2);">
        <div class="section-title">
            <h2>Live Request Log</h2>
            <p>Real-time edge server activity</p>
        </div>
        <div class="log-section">
            <div class="log-header">
                <h3>EDGE-SERVER-01.US-EAST</h3>
                <div class="log-live">LIVE</div>
            </div>
            <div class="log-entry">
                <span class="time">[2025-06-26 14:23:01]</span> <span class="method">GET</span> <span class="path">/api/v2/stream/4k-content</span> <span class="status">200</span> <span class="size">184.7MB</span> edge=ny-cdn-03<br>
                <span class="time">[2025-06-26 14:23:01]</span> <span class="method">GET</span> <span class="path">/assets/video/chunk-0042.m4s</span> <span class="status">200</span> <span class="size">4.2MB</span> edge=ny-cdn-01<br>
                <span class="time">[2025-06-26 14:23:02]</span> <span class="method">POST</span> <span class="path">/api/upload/chunk</span> <span class="status">201</span> <span class="size">67.8MB</span> edge=ny-cdn-02<br>
                <span class="time">[2025-06-26 14:23:02]</span> <span class="method">GET</span> <span class="path">/media/stream/manifest.mpd</span> <span class="status">200</span> <span class="size">12.1MB</span> edge=la-cdn-01<br>
                <span class="time">[2025-06-26 14:23:03]</span> <span class="method">GET</span> <span class="path">/download/package-v3.8.2.tar.gz</span> <span class="status">200</span> <span class="size">248.3MB</span> edge=lon-cdn-01<br>
                <span class="time">[2025-06-26 14:23:03]</span> <span class="method">GET</span> <span class="path">/api/v2/stream/live-sports</span> <span class="status">200</span> <span class="size">95.4MB</span> edge=tyo-cdn-01<br>
                <span class="time">[2025-06-26 14:23:04]</span> <span class="method">PURGE</span> <span class="path">/cache/*</span> <span class="status">200</span> <span class="size">-</span> edge=all<br>
                <span class="time">[2025-06-26 14:23:04]</span> <span class="method">GET</span> <span class="path">/media/trailer-4k.mp4</span> <span class="status">200</span> <span class="size">512.6MB</span> edge=sgp-cdn-01<br>
                <span class="time">[2025-06-26 14:23:05]</span> <span class="method">GET</span> <span class="path">/api/cdn/purge/batch</span> <span class="status">200</span> <span class="size">1.2KB</span> edge=fra-cdn-01<br>
                <span class="time">[2025-06-26 14:23:05]</span> <span class="method">GET</span> <span class="path">/stream/playlist.m3u8</span> <span class="status">200</span> <span class="size">8.7MB</span> edge=la-cdn-03<br>
                <span class="time">[2025-06-26 14:23:06]</span> <span class="method">PUT</span> <span class="path">/api/upload/resume?id=xf8k2m</span> <span class="status">200</span> <span class="size">1.4GB</span> edge=ny-cdn-01<br>
                <span class="time">[2025-06-26 14:23:06]</span> <span class="method">GET</span> <span class="path">/cdn/assets/css/main.bundle.css</span> <span class="status">200</span> <span class="size">342KB</span> edge=lon-cdn-02<br>
                <span class="time">[2025-06-26 14:23:07]</span> <span class="method">GET</span> <span class="path">/video/ad-stream?quality=4k</span> <span class="status">200</span> <span class="size">287.9MB</span> edge=tyo-cdn-02
            </div>
        </div>
    </section>

    <footer class="footer">
        <div class="footer-links">
            <a href="#">Documentation</a>
            <a href="#">API Reference</a>
            <a href="#">Status Page</a>
            <a href="#">Blog</a>
            <a href="#">Support</a>
        </div>
        <p>&copy; 2025 CDN Global Network. All rights reserved.</p>
    </footer>

    <script>
        setInterval(function() {
            var entry = document.querySelector('.log-entry');
            var methods = ['GET','GET','GET','POST','PUT','PURGE','GET','GET','GET','GET'];
            var paths = ['/api/v2/stream/4k','/media/chunk-0043.m4s','/download/build-4.1.0.zip','/api/upload/chunk','/stream/manifest.mpd','/cache/purge','/media/live-sports','/api/v2/cdn/stats','/assets/js/app.min.js','/video/trailer-1080p.mp4'];
            var statuses = ['200','200','200','201','200','200','200','200','304','200'];
            var sizes = ['184.7MB','4.2MB','356.1MB','67.8MB','12.1MB','-','95.4MB','2.3KB','89KB','312.4MB'];
            var edges = ['ny-cdn-01','la-cdn-01','lon-cdn-01','sgp-cdn-01','tyo-cdn-01','fra-cdn-01','syd-cdn-01','bom-cdn-01','nyc-cdn-02','lax-cdn-02'];
            var now = new Date();
            var ts = now.getFullYear()+'-'+String(now.getMonth()+1).padStart(2,'0')+'-'+String(now.getDate()).padStart(2,'0')+' '+String(now.getHours()).padStart(2,'0')+':'+String(now.getMinutes()).padStart(2,'0')+':'+String(now.getSeconds()).padStart(2,'0');
            var i = Math.floor(Math.random()*methods.length);
            var line = '<span class="time">['+ts+']</span> <span class="method">'+methods[i]+'</span> <span class="path">'+paths[i]+'</span> <span class="status">'+statuses[i]+'</span> <span class="size">'+sizes[i]+'</span> edge='+edges[Math.floor(Math.random()*edges.length)];
            entry.innerHTML = line + '<br>' + entry.innerHTML;
            var lines = entry.innerHTML.split('<br>');
            if (lines.length > 15) { entry.innerHTML = lines.slice(0,15).join('<br>'); }
        }, 2000);
    </script>
</body>
</html>
DEFAULTHTML

    # 生成 nginx 配置
    cat > "$NGINX_CONF" <<-NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEB_DIR};
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
}
NGINXEOF

    # 如果使用 HTTPS，添加 443 配置
    if [[ "$USE_LE_CERT" == "true" && -f "$CERT_FILE" ]]; then
        cat >> "$NGINX_CONF" <<-NGINXSSL
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    root ${WEB_DIR};
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
}
NGINXSSL
        info "已配置 HTTPS (使用 Let's Encrypt 证书)"
    fi

    # 启用站点
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/camouflage
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    # 测试并启动 nginx
    if nginx -t 2>/dev/null; then
        systemctl enable nginx 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
        info "伪装网站搭建完成: http://${DOMAIN}"
        if [[ "$USE_LE_CERT" == "true" ]]; then
            info "HTTPS: https://${DOMAIN}"
        fi
    else
        warn "nginx 配置测试失败，跳过启动"
    fi
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
BINARY="/usr/local/bin/sing-box"
SYSCTL_FILE="/etc/sysctl.d/99-hysteria2.conf"
NIC_OPT_SCRIPT="/usr/local/bin/hy2-nic-opt"
NIC_SERVICE="/etc/systemd/system/hy2-nic-opt.service"
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
    if ! [[ -f "$BINARY" ]]; then error "sing-box 未安装"; fi
    if systemctl is-active --quiet sing-box 2>/dev/null; then warn "服务已在运行中"; return; fi
    systemctl start sing-box 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet sing-box; then info "服务启动成功"; else error "服务启动失败"; fi
}
do_stop() {
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then warn "服务未运行"; return; fi
    systemctl stop sing-box 2>/dev/null || true
    sleep 1
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then info "服务已停止"; else error "停止服务失败"; fi
}
do_restart() {
    if ! [[ -f "$BINARY" ]]; then error "sing-box 未安装"; fi
    info "重启 sing-box 服务..."
    systemctl restart sing-box 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet sing-box; then info "服务重启成功"; else error "服务重启失败"; fi
}
do_status() {
    echo ""
    echo -e "${BLUE}  sing-box 服务状态:${NC}"
    systemctl status sing-box 2>/dev/null || echo "  服务未安装"
    echo ""
}
do_log() {
    echo ""
    echo -e "${BLUE}  最近 30 条日志:${NC}"
    echo ""
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || tail -30 "${INSTALL_DIR}/sing-box.log" 2>/dev/null || warn "无法读取日志"
    echo ""
}
do_show_config() {
    if ! [[ -f "$CONFIG_FILE" ]]; then error "配置文件不存在"; fi
    echo ""
    echo -e "${BLUE}  当前配置:${NC}"
    echo ""
    cat "$CONFIG_FILE"
    echo ""
}
do_show_uri() {
    local uri_file="${INSTALL_DIR}/client_uri.txt"
    if ! [[ -f "$uri_file" ]]; then error "客户端 URI 不存在"; fi
    echo ""
    echo -e "${BLUE}  客户端连接 URI:${NC}"
    echo ""
    echo -e "  ${CYAN}$(cat "$uri_file")${NC}"
    echo ""
}
do_show_qrcode() {
    local uri_file="${INSTALL_DIR}/client_uri.txt"
    if ! [[ -f "$uri_file" ]]; then error "客户端 URI 不存在"; fi
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
    echo -e "  ${GREEN}hy2${NC}              显示管理菜单"
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
    read -p "确认卸载? 输入 YES: " confirm
    if [[ "$confirm" != "YES" ]]; then info "已取消卸载"; return; fi
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    killall sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl stop hy2-nic-opt 2>/dev/null || true
    systemctl disable hy2-nic-opt 2>/dev/null || true
    rm -f /etc/systemd/system/hy2-nic-opt.service
    rm -f /usr/local/bin/hy2-nic-opt
    if [[ -x /usr/local/bin/hy2-port-hop ]]; then /usr/local/bin/hy2-port-hop clean 2>/dev/null || true; fi
    systemctl stop hy2-port-hop 2>/dev/null || true
    systemctl disable hy2-port-hop 2>/dev/null || true
    rm -f /etc/systemd/system/hy2-port-hop.service
    rm -f /usr/local/bin/hy2-port-hop
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$BINARY"
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/hy2
    rm -f /etc/sysctl.d/99-hysteria2.conf
    sed -i '/# Hysteria2 网络优化/,+14d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/# Hysteria2 QUIC 优化/,+10d' /etc/sysctl.conf 2>/dev/null || true
    sysctl --system 2>/dev/null || true
    echo ""
    header
    echo -e "${GREEN}  Hysteria2 已彻底移除!${NC}"
    header
    echo ""
}
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
    echo -e "${GREEN}  Hysteria2 安装完成! (UDP/QUIC 优化版 v3)${NC}"
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
    if [[ "$HY2_HOP_ENABLE" == "true" ]]; then
        echo ""
        echo -e "  ${BLUE}端口跳跃 Port Hopping:${NC}"
        echo -e "    范围:     ${HY2_HOP_START}-${HY2_HOP_END}/UDP (DNAT -> ${HY2_PORT})"
        echo -e "    持久化:   hy2-port-hop.service (开机自动应用)"
        echo -e "    客户端:   URI 已含 mport 参数, 支持的客户端自动换端口"
        echo -e "    注意:     云厂商防火墙也需放行 ${HY2_HOP_START}-${HY2_HOP_END}/UDP"
    fi
    echo ""
    echo -e "  ${BLUE}UDP/QUIC 优化:${NC}"
    echo -e "    sysctl:   ${SYSCTL_FILE} (64MB UDP 缓冲/分片重组/软中断预算)"
    echo -e "    网卡:     Ring Buffer 拉满 + GRO/GSO, 开机自动应用"
    echo -e "    客户端:   TUN MTU 1400 (减少跨境分片丢包)"
    local swap_now
    swap_now=$(awk '/^SwapTotal:/{printf "%dMB", $2/1024}' /proc/meminfo 2>/dev/null)
    if [[ -n "$swap_now" && "$swap_now" != "0MB" ]]; then
        echo -e "    SWAP:     ${swap_now} (低内存 VPS 稳定性保障)"
    else
        echo -e "    SWAP:     未配置"
    fi
    echo ""
    echo -e "  ${BLUE}管理命令:${NC}"
    echo -e "    启动:   systemctl start sing-box"
    echo -e "    停止:   systemctl stop sing-box"
    echo -e "    重启:   systemctl restart sing-box"
    echo -e "    状态:   systemctl status sing-box"
    echo -e "    日志:   journalctl -u sing-box -n 50 -f"
    echo -e "    菜单:   hy2"
    echo ""
    echo -e "  ${BLUE}文件路径:${NC}"
    echo -e "    配置:       ${CONFIG_FILE}"
    echo -e "    证书:       ${CERT_FILE}"
    echo -e "    客户端 URI: ${INSTALL_DIR}/client_uri.txt"
    echo -e "    客户端配置: ${INSTALL_DIR}/client/"
    if [[ -n "$DOMAIN" ]]; then
        echo -e "    伪装网站:   /var/www/camouflage/"
    fi
    echo ""
    if [[ -n "$DOMAIN" ]]; then
        echo -e "  ${BLUE}伪装网站:${NC}"
        echo -e "    访问:   http://${DOMAIN}"
        if [[ "$USE_LE_CERT" == "true" ]]; then
            echo -e "    HTTPS:  https://${DOMAIN}"
        fi
        echo -e "    目录:   /var/www/camouflage/"
        echo ""
    fi
    echo -e "  ${YELLOW}推荐客户端:${NC}"
    echo -e "    Windows:  v2rayN / Sing-box / Clash.Meta"
    echo -e "    Android:  NekoBox / Hiddify / Sing-box"
    echo -e "    iOS:      Shadowrocket / Stash / Sing-box"
    echo -e "    macOS:    Clash.Meta / Sing-box"
    echo ""
    echo -e "  ${RED}注意:${NC}"
    if [[ "$USE_LE_CERT" == "true" ]]; then
        echo -e "    使用 Let's Encrypt 证书，客户端无需开启不安全证书"
    else
        echo -e "    使用自签名证书，客户端需开启 ${YELLOW}允许不安全证书${NC}"
    fi
    echo -e "    云厂商控制台防火墙需放行 ${HY2_PORT}/UDP"
    echo ""
}
# ---- 彻底移除 Hysteria2 ----
uninstall() {
    header
    echo -e "${RED}  彻底移除 Hysteria2 / sing-box${NC}"
    header
    echo ""
    safe_read "$(echo -e "${RED}确认彻底移除? 输入 YES 确认: ${NC}")" confirm
    if [[ "$confirm" != "YES" ]]; then info "已取消移除"; return; fi
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    killall sing-box 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl stop hy2-nic-opt 2>/dev/null || true
    systemctl disable hy2-nic-opt 2>/dev/null || true
    rm -f "$NIC_SERVICE" "$NIC_OPT_SCRIPT"
    if [[ -x "$PORT_HOP_SCRIPT" ]]; then "$PORT_HOP_SCRIPT" clean 2>/dev/null || true; fi
    systemctl stop hy2-port-hop 2>/dev/null || true
    systemctl disable hy2-port-hop 2>/dev/null || true
    rm -f "$PORT_HOP_SERVICE" "$PORT_HOP_SCRIPT"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$BINARY"
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/hy2
    rm -f "$SYSCTL_FILE"
    cleanup_legacy_sysctl
    sysctl --system 2>/dev/null || true
    echo ""
    header
    echo -e "${GREEN}  Hysteria2 已彻底移除!${NC}"
    header
    echo ""
}
main() {
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
    setup_swap
    install_deps
    ensure_nginx_dirs
    ensure_python3
    optimize_network
    install_nic_opt
    interactive_config
    install_sing_box
    generate_cert
    generate_config
    setup_camouflage_site
    create_service
    config_firewall
    setup_port_hopping
    generate_uri
    generate_qrcode
    generate_client_config
    install_management_tool
    start_service
    show_summary
}
main "$@"
