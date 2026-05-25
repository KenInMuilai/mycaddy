#!/bin/bash

# ============================================
# Caddy 一键管理脚本
# 支持反代多域名、自动申请SSL证书
# ============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 配置路径
CADDY_BIN="/usr/local/bin/caddy"
CADDY_CONFIG="/etc/caddy/Caddyfile"
CADDY_SERVICE="/etc/systemd/system/caddy.service"
CADDY_DATA_DIR="/var/lib/caddy"
CADDY_LOG_DIR="/var/log/caddy"
SCRIPT_PATH="/usr/local/bin/ca"

# ============================================
# 工具函数
# ============================================

print_line() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_title() {
    clear
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║         Caddy 反向代理管理脚本             ║"
    echo "  ║              Author: VPS Tool              ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行"
        error "请使用: sudo $0"
        exit 1
    fi
}

# 检查Caddy是否已安装
check_caddy_installed() {
    if [[ ! -f "$CADDY_BIN" ]]; then
        return 1
    fi
    return 0
}

# 检查Caddy服务状态
check_caddy_status() {
    if systemctl is-active --quiet caddy 2>/dev/null; then
        echo -e "${GREEN}● 运行中${NC}"
    else
        echo -e "${RED}● 已停止${NC}"
    fi
}

# 按任意键继续
press_any_key() {
    echo ""
    echo -e "${YELLOW}按任意键返回主菜单...${NC}"
    read -n 1 -s
}

# ============================================
# 1. 安装/更新 Caddy
# ============================================

install_caddy() {
    print_title
    print_line
    echo -e "${WHITE}  [1] 安装 / 更新 Caddy${NC}"
    print_line
    echo ""

    # 检测系统类型
    if [[ -f /etc/debian_version ]]; then
        OS_TYPE="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS_TYPE="redhat"
    else
        OS_TYPE="other"
    fi

    # 检查是否已安装
    if check_caddy_installed; then
        CURRENT_VER=$($CADDY_BIN version 2>/dev/null | head -n1)
        warn "Caddy 已安装，当前版本: ${CURRENT_VER}"
        echo ""
        echo -e "  ${WHITE}选择操作:${NC}"
        echo -e "  ${GREEN}[1]${NC} 更新到最新版本"
        echo -e "  ${RED}[0]${NC} 返回主菜单"
        echo ""
        read -rp "  请输入选项: " choice
        case $choice in
            1) info "开始更新 Caddy..." ;;
            0) return ;;
            *) warn "无效选项"; press_any_key; return ;;
        esac
    else
        info "开始安装 Caddy..."
    fi

    echo ""

    # 停止已有服务
    if systemctl is-active --quiet caddy 2>/dev/null; then
        info "停止 Caddy 服务..."
        systemctl stop caddy
    fi

    # 安装依赖
    info "安装依赖..."
    if [[ "$OS_TYPE" == "debian" ]]; then
        apt-get update -qq
        apt-get install -y -qq curl wget debian-keyring debian-archive-keyring apt-transport-https 2>/dev/null
    elif [[ "$OS_TYPE" == "redhat" ]]; then
        yum install -y -q curl wget 2>/dev/null || dnf install -y -q curl wget 2>/dev/null
    fi

    # 使用官方安装方式
    info "下载并安装 Caddy..."
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Debian/Ubuntu 官方包安装
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
        apt-get update -qq
        apt-get install -y caddy 2>/dev/null
        
        # 检查是否安装成功
        if [[ ! -f "$CADDY_BIN" ]]; then
            warn "官方源安装失败，尝试直接下载二进制..."
            install_caddy_binary
        fi
    else
        install_caddy_binary
    fi

    # 验证安装
    if check_caddy_installed; then
        NEW_VER=$($CADDY_BIN version 2>/dev/null | head -n1)
        success "Caddy 安装成功！版本: ${NEW_VER}"
        echo ""

        # 初始化配置
        setup_caddy_environment
    else
        error "Caddy 安装失败，请检查网络或手动安装"
    fi

    press_any_key
}

# 二进制方式安装
install_caddy_binary() {
    info "通过二进制方式安装..."
    
    # 获取系统架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  CADDY_ARCH="amd64" ;;
        aarch64) CADDY_ARCH="arm64" ;;
        armv7l)  CADDY_ARCH="armv7" ;;
        *)       CADDY_ARCH="amd64" ;;
    esac

    # 获取最新版本号
    info "获取最新版本信息..."
    LATEST_VER=$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest \
        | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null)
    
    if [[ -z "$LATEST_VER" ]]; then
        LATEST_VER="v2.7.6"
        warn "无法获取最新版本，使用默认版本: $LATEST_VER"
    fi

    DOWNLOAD_URL="https://github.com/caddyserver/caddy/releases/download/${LATEST_VER}/caddy_${LATEST_VER#v}_linux_${CADDY_ARCH}.tar.gz"
    
    info "下载 Caddy ${LATEST_VER} (${CADDY_ARCH})..."
    
    TMP_DIR=$(mktemp -d)
    if curl -L --progress-bar "$DOWNLOAD_URL" -o "${TMP_DIR}/caddy.tar.gz"; then
        tar -xzf "${TMP_DIR}/caddy.tar.gz" -C "$TMP_DIR"
        mv "${TMP_DIR}/caddy" "$CADDY_BIN"
        chmod +x "$CADDY_BIN"
        success "二进制文件安装成功"
    else
        error "下载失败，请检查网络连接"
    fi
    rm -rf "$TMP_DIR"
}

# 初始化 Caddy 运行环境
setup_caddy_environment() {
    info "配置 Caddy 运行环境..."

    # 创建必要目录
    mkdir -p /etc/caddy
    mkdir -p "$CADDY_DATA_DIR"
    mkdir -p "$CADDY_LOG_DIR"

    # 创建 caddy 用户（如果不存在）
    if ! id -u caddy &>/dev/null; then
        useradd --system --home "$CADDY_DATA_DIR" \
            --shell /bin/false --comment "Caddy web server" caddy 2>/dev/null
        success "创建 caddy 用户"
    fi

    # 设置目录权限
    chown -R caddy:caddy "$CADDY_DATA_DIR" 2>/dev/null
    chown -R caddy:caddy "$CADDY_LOG_DIR" 2>/dev/null

    # 创建默认 Caddyfile（如果不存在）
    if [[ ! -f "$CADDY_CONFIG" ]]; then
        cat > "$CADDY_CONFIG" << 'EOF'
# Caddy 配置文件
# 由 Caddy 管理脚本生成
# ================================

# 全局选项
{
    # email 用于 Let's Encrypt 证书通知（请修改为你的邮箱）
    # email your@email.com
    
    # 如需测试，可启用 staging 避免频率限制
    # acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}

# 示例配置（已注释）
# example.com {
#     reverse_proxy localhost:8080
#     tls your@email.com
# }

EOF
        success "创建默认 Caddyfile"
    fi

    # 创建/更新 systemd 服务文件
    create_systemd_service

    # 设置配置文件权限
    chown root:caddy "$CADDY_CONFIG"
    chmod 640 "$CADDY_CONFIG"

    # 启用并启动服务
    systemctl daemon-reload
    systemctl enable caddy --now 2>/dev/null

    if systemctl is-active --quiet caddy; then
        success "Caddy 服务已启动并设置为开机自启"
    else
        warn "Caddy 服务启动失败，请检查配置文件"
        journalctl -u caddy -n 10 --no-pager 2>/dev/null
    fi
}

# 创建 systemd 服务文件
create_systemd_service() {
    cat > "$CADDY_SERVICE" << EOF
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=$CADDY_BIN run --environ --config $CADDY_CONFIG
ExecReload=$CADDY_BIN reload --config $CADDY_CONFIG --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    success "创建 systemd 服务文件"
}

# ============================================
# 2. 添加反代配置
# ============================================

add_proxy() {
    print_title
    print_line
    echo -e "${WHITE}  [2] 添加反向代理配置${NC}"
    print_line
    echo ""

    if ! check_caddy_installed; then
        error "Caddy 未安装，请先安装 Caddy"
        press_any_key
        return
    fi

    echo -e "  ${CYAN}提示: 证书将由 Caddy 自动申请 (Let's Encrypt)${NC}"
    echo -e "  ${CYAN}请确保域名已正确解析到本服务器IP${NC}"
    echo ""
    print_line

    # 输入域名
    while true; do
        read -rp "  请输入域名 (如: example.com): " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's|https\?://||g' | sed 's|/||g')
        if [[ -z "$DOMAIN" ]]; then
            warn "域名不能为空，请重新输入"
        elif [[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
            break
        else
            warn "域名格式不正确，请重新输入"
        fi
    done

    # 检查域名是否已存在
    if grep -q "^${DOMAIN}" "$CADDY_CONFIG" 2>/dev/null; then
        warn "域名 ${DOMAIN} 已存在于配置文件中"
        echo ""
        echo -e "  ${WHITE}选择操作:${NC}"
        echo -e "  ${GREEN}[1]${NC} 覆盖该域名配置"
        echo -e "  ${RED}[0]${NC} 返回主菜单"
        read -rp "  请输入选项: " choice
        case $choice in
            1)
                # 删除已有配置
                delete_domain_config "$DOMAIN"
                ;;
            0) return ;;
            *) warn "无效选项"; press_any_key; return ;;
        esac
    fi

    # 输入后端地址
    echo ""
    echo -e "  ${WHITE}后端代理地址配置:${NC}"
    echo -e "  ${CYAN}格式示例: localhost:8080 | 127.0.0.1:3000 | 192.168.1.100:80${NC}"
    echo ""
    
    while true; do
        read -rp "  请输入后端地址和端口: " BACKEND
        if [[ -z "$BACKEND" ]]; then
            warn "后端地址不能为空"
        else
            # 补全协议前缀检查
            if [[ ! "$BACKEND" =~ ^https?:// ]]; then
                BACKEND_DISPLAY="http://$BACKEND"
            else
                BACKEND_DISPLAY="$BACKEND"
            fi
            break
        fi
    done

    # 配置选项
    echo ""
    print_line
    echo -e "  ${WHITE}高级选项 (直接回车使用默认值):${NC}"
    echo ""

    # HTTPS 强制跳转
    read -rp "  是否强制 HTTP 跳转 HTTPS? [Y/n]: " FORCE_HTTPS
    FORCE_HTTPS=${FORCE_HTTPS:-Y}

    # 证书邮箱
    read -rp "  SSL证书通知邮箱 (留空则跳过): " SSL_EMAIL

    # 是否配置 WebSocket
    read -rp "  是否支持 WebSocket? [y/N]: " ENABLE_WS
    ENABLE_WS=${ENABLE_WS:-N}

    # 是否配置压缩
    read -rp "  是否启用 Gzip/Zstd 压缩? [Y/n]: " ENABLE_ENCODE
    ENABLE_ENCODE=${ENABLE_ENCODE:-Y}

    echo ""
    print_line
    echo -e "  ${WHITE}配置预览:${NC}"
    echo -e "  域名     : ${GREEN}$DOMAIN${NC}"
    echo -e "  后端地址 : ${GREEN}$BACKEND${NC}"
    echo -e "  强制HTTPS: ${GREEN}$([ "${FORCE_HTTPS,,}" = "y" ] && echo "是" || echo "否")${NC}"
    echo -e "  WebSocket: ${GREEN}$([ "${ENABLE_WS,,}" = "y" ] && echo "是" || echo "否")${NC}"
    echo -e "  压缩     : ${GREEN}$([ "${ENABLE_ENCODE,,}" = "y" ] && echo "是" || echo "否")${NC}"
    print_line
    echo ""
    read -rp "  确认添加? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}

    if [[ "${CONFIRM,,}" != "y" ]]; then
        info "已取消操作"
        press_any_key
        return
    fi

    # 生成配置内容
    CONFIG_BLOCK=""
    
    # 更新全局邮箱配置（如果提供）
    if [[ -n "$SSL_EMAIL" ]]; then
        if grep -q "^{" "$CADDY_CONFIG"; then
            # 已有全局块，检查是否有email
            if grep -q "email" "$CADDY_CONFIG"; then
                sed -i "s/.*email .*/    email $SSL_EMAIL/" "$CADDY_CONFIG"
            else
                sed -i "/^{/a\\    email $SSL_EMAIL" "$CADDY_CONFIG"
            fi
        fi
    fi

    # 构建域名配置块
    CONFIG_BLOCK="\n# 反代配置 - ${DOMAIN} - $(date '+%Y-%m-%d %H:%M:%S')\n"
    CONFIG_BLOCK+="${DOMAIN} {\n"

    # WebSocket 头部
    if [[ "${ENABLE_WS,,}" == "y" ]]; then
        CONFIG_BLOCK+="    # 反向代理（支持 WebSocket）\n"
        CONFIG_BLOCK+="    reverse_proxy $BACKEND {\n"
        CONFIG_BLOCK+="        header_up Host {host}\n"
        CONFIG_BLOCK+="        header_up X-Real-IP {remote_host}\n"
        CONFIG_BLOCK+="        header_up X-Forwarded-For {remote_host}\n"
        CONFIG_BLOCK+="        header_up X-Forwarded-Proto {scheme}\n"
        CONFIG_BLOCK+="    }\n"
    else
        CONFIG_BLOCK+="    # 反向代理\n"
        CONFIG_BLOCK+="    reverse_proxy $BACKEND {\n"
        CONFIG_BLOCK+="        header_up Host {host}\n"
        CONFIG_BLOCK+="        header_up X-Real-IP {remote_host}\n"
        CONFIG_BLOCK+="        header_up X-Forwarded-For {remote_host}\n"
        CONFIG_BLOCK+="        header_up X-Forwarded-Proto {scheme}\n"
        CONFIG_BLOCK+="    }\n"
    fi

    # 压缩
    if [[ "${ENABLE_ENCODE,,}" == "y" ]]; then
        CONFIG_BLOCK+="    \n"
        CONFIG_BLOCK+="    # 启用压缩\n"
        CONFIG_BLOCK+="    encode zstd gzip\n"
    fi

    # 日志
    CONFIG_BLOCK+="    \n"
    CONFIG_BLOCK+="    # 访问日志\n"
    CONFIG_BLOCK+="    log {\n"
    CONFIG_BLOCK+="        output file ${CADDY_LOG_DIR}/${DOMAIN}.log {\n"
    CONFIG_BLOCK+="            roll_size 10mb\n"
    CONFIG_BLOCK+="            roll_keep 5\n"
    CONFIG_BLOCK+="        }\n"
    CONFIG_BLOCK+="    }\n"
    CONFIG_BLOCK+="}\n"

    # 如果需要强制HTTPS，添加HTTP重定向
    if [[ "${FORCE_HTTPS,,}" == "y" ]]; then
        CONFIG_BLOCK+="\n# HTTP 重定向到 HTTPS - ${DOMAIN}\n"
        CONFIG_BLOCK+="http://${DOMAIN} {\n"
        CONFIG_BLOCK+="    redir https://{host}{uri} permanent\n"
        CONFIG_BLOCK+="}\n"
    fi

    # 追加到配置文件
    echo -e "$CONFIG_BLOCK" >> "$CADDY_CONFIG"

    success "配置已添加到 $CADDY_CONFIG"
    echo ""

    # 验证配置
    info "验证配置文件语法..."
    if $CADDY_BIN validate --config "$CADDY_CONFIG" 2>/dev/null; then
        success "配置文件语法正确"
        echo ""
        # 重载配置
        info "重载 Caddy 配置..."
        if systemctl is-active --quiet caddy; then
            if $CADDY_BIN reload --config "$CADDY_CONFIG" 2>/dev/null; then
                success "配置已热重载，无需重启"
            else
                warn "热重载失败，尝试重启服务..."
                systemctl restart caddy
            fi
        else
            systemctl start caddy
        fi

        if systemctl is-active --quiet caddy; then
            success "Caddy 服务运行正常"
            echo ""
            echo -e "  ${CYAN}✓ 域名 ${WHITE}${DOMAIN}${CYAN} 反代配置已生效${NC}"
            echo -e "  ${CYAN}✓ SSL 证书将在首次访问时自动申请${NC}"
        else
            error "Caddy 启动失败"
            journalctl -u caddy -n 20 --no-pager
        fi
    else
        error "配置文件语法错误，请检查配置"
        warn "回滚本次修改..."
        # 删除刚添加的配置
        delete_domain_config "$DOMAIN"
        error "已回滚，请重新配置"
    fi

    press_any_key
}

# ============================================
# 3. 修改反代配置
# ============================================

edit_proxy() {
    print_title
    print_line
    echo -e "${WHITE}  [3] 修改反向代理配置${NC}"
    print_line
    echo ""

    if ! check_caddy_installed; then
        error "Caddy 未安装"
        press_any_key
        return
    fi

    # 列出当前配置的域名
    echo -e "  ${WHITE}当前配置的域名列表:${NC}"
    echo ""
    
    # 提取所有域名（排除注释和http://域名、全局块）
    DOMAINS=$(grep -E '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}[[:space:]]*\{' "$CADDY_CONFIG" 2>/dev/null \
        | sed 's/[[:space:]]*{//' | sed 's/^[[:space:]]*//')

    if [[ -z "$DOMAINS" ]]; then
        warn "暂无配置的域名"
        echo ""
        echo -e "  ${CYAN}提示: 您可以选择:${NC}"
        echo -e "  ${GREEN}[1]${NC} 直接编辑 Caddyfile"
        echo -e "  ${RED}[0]${NC} 返回主菜单"
        read -rp "  请输入选项: " choice
        case $choice in
            1) edit_caddyfile_directly ;;
            *) return ;;
        esac
        return
    fi

    # 显示域名列表
    i=1
    declare -a DOMAIN_LIST
    while IFS= read -r domain; do
        echo -e "  ${GREEN}[$i]${NC} $domain"
        DOMAIN_LIST+=("$domain")
        ((i++))
    done <<< "$DOMAINS"
    
    echo ""
    echo -e "  ${GREEN}[e]${NC} 直接编辑整个 Caddyfile"
    echo -e "  ${RED}[0]${NC} 返回主菜单"
    echo ""

    read -rp "  请选择要修改的域名编号: " choice

    case $choice in
        0) return ;;
        e|E) edit_caddyfile_directly; return ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DOMAIN_LIST[@]} )); then
                SELECTED_DOMAIN="${DOMAIN_LIST[$((choice-1))]}"
                edit_domain_config "$SELECTED_DOMAIN"
            else
                warn "无效选项"
            fi
            ;;
    esac

    press_any_key
}

# 编辑指定域名配置
edit_domain_config() {
    local DOMAIN="$1"
    echo ""
    info "编辑域名: $DOMAIN"
    echo ""
    echo -e "  ${WHITE}修改方式:${NC}"
    echo -e "  ${GREEN}[1]${NC} 修改后端代理地址"
    echo -e "  ${GREEN}[2]${NC} 使用编辑器直接编辑"
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -rp "  请选择: " sub_choice

    case $sub_choice in
        1)
            echo ""
            # 显示当前后端地址
            CURRENT_BACKEND=$(awk "/^${DOMAIN}[[:space:]]*\{/,/^\}/" "$CADDY_CONFIG" \
                | grep "reverse_proxy" | awk '{print $2}' | head -n1)
            echo -e "  当前后端地址: ${CYAN}$CURRENT_BACKEND${NC}"
            echo ""
            read -rp "  请输入新的后端地址和端口: " NEW_BACKEND
            
            if [[ -z "$NEW_BACKEND" ]]; then
                warn "地址不能为空"
                return
            fi

            # 备份配置
            cp "$CADDY_CONFIG" "${CADDY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
            
            # 替换后端地址（在该域名块内）
            python3 - <<PYEOF 2>/dev/null || \
            sed -i "s|reverse_proxy ${CURRENT_BACKEND}|reverse_proxy ${NEW_BACKEND}|g" "$CADDY_CONFIG"
import re

with open('$CADDY_CONFIG', 'r') as f:
    content = f.read()

# 在指定域名块内替换
domain_pattern = r'(${DOMAIN}\s*\{.*?reverse_proxy\s+)${CURRENT_BACKEND}(\b)'
content = re.sub(
    r'(reverse_proxy\s+)${CURRENT_BACKEND}',
    r'\g<1>${NEW_BACKEND}',
    content
)

with open('$CADDY_CONFIG', 'w') as f:
    f.write(content)
PYEOF

            success "后端地址已更新: $NEW_BACKEND"
            reload_caddy
            ;;
        2)
            edit_caddyfile_directly
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

# 直接编辑 Caddyfile
edit_caddyfile_directly() {
    echo ""
    # 备份
    cp "$CADDY_CONFIG" "${CADDY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份配置文件"
    
    # 选择编辑器
    if command -v nano &>/dev/null; then
        EDITOR="nano"
    elif command -v vim &>/dev/null; then
        EDITOR="vim"
    elif command -v vi &>/dev/null; then
        EDITOR="vi"
    else
        error "未找到可用的文本编辑器"
        return
    fi

    info "使用 $EDITOR 编辑配置文件..."
    sleep 1
    $EDITOR "$CADDY_CONFIG"
    
    echo ""
    # 验证配置
    info "验证配置文件..."
    if $CADDY_BIN validate --config "$CADDY_CONFIG" 2>/dev/null; then
        success "配置文件验证通过"
        reload_caddy
    else
        error "配置文件有误！"
        echo ""
        echo -e "  ${WHITE}选择操作:${NC}"
        echo -e "  ${GREEN}[1]${NC} 恢复备份"
        echo -e "  ${YELLOW}[2]${NC} 继续保存（谨慎）"
        read -rp "  请选择: " restore_choice
        case $restore_choice in
            1)
                LATEST_BAK=$(ls -t ${CADDY_CONFIG}.bak.* 2>/dev/null | head -n1)
                if [[ -f "$LATEST_BAK" ]]; then
                    cp "$LATEST_BAK" "$CADDY_CONFIG"
                    success "已恢复备份: $LATEST_BAK"
                fi
                ;;
            2) warn "保留当前配置，请注意服务可能无法启动" ;;
        esac
    fi
}

# ============================================
# 4. 删除反代配置
# ============================================

delete_proxy() {
    print_title
    print_line
    echo -e "${WHITE}  [4] 删除反向代理配置${NC}"
    print_line
    echo ""

    if ! check_caddy_installed; then
        error "Caddy 未安装"
        press_any_key
        return
    fi

    # 列出当前域名
    echo -e "  ${WHITE}当前配置的域名:${NC}"
    echo ""
    
    DOMAINS=$(grep -E '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}[[:space:]]*\{'
