cat > /usr/local/bin/ca <<'EOF'
#!/usr/bin/env bash

CADDYFILE="/etc/caddy/Caddyfile"
BACKUP_DIR="/etc/caddy/backup"
SCRIPT_PATH="/usr/local/bin/ca"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 用户运行本脚本${PLAIN}"
        exit 1
    fi
}

pause() {
    echo
    read -rp "按回车键继续..."
}

ensure_dirs() {
    mkdir -p /etc/caddy
    mkdir -p "$BACKUP_DIR"

    if [ ! -f "$CADDYFILE" ]; then
        cat > "$CADDYFILE" <<'EOC'
{
    # Caddy 会自动申请和续签 HTTPS 证书
    # 请确保域名已经解析到本 VPS，并且 80/443 端口已放行
}
EOC
    fi
}

backup_caddyfile() {
    ensure_dirs
    local ts
    ts=$(date +"%Y%m%d_%H%M%S")
    cp "$CADDYFILE" "$BACKUP_DIR/Caddyfile_$ts.bak"
    echo "$BACKUP_DIR/Caddyfile_$ts.bak"
}

install_update_caddy() {
    echo -e "${BLUE}正在安装 / 更新 Caddy...${PLAIN}"

    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg

        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list

        chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        chmod o+r /etc/apt/sources.list.d/caddy-stable.list

        apt update
        apt install -y caddy

    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y 'dnf-command(copr)' curl
        dnf copr enable -y @caddy/caddy
        dnf install -y caddy

    elif command -v yum >/dev/null 2>&1; then
        yum install -y yum-plugin-copr curl
        yum copr enable -y @caddy/caddy
        yum install -y caddy

    else
        echo -e "${RED}不支持的系统包管理器，请使用 Debian/Ubuntu/CentOS/RHEL 系统${PLAIN}"
        pause
        return
    fi

    ensure_dirs

    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy

    echo -e "${GREEN}Caddy 安装 / 更新完成${PLAIN}"
    echo -e "${YELLOW}提示：请确保 VPS 的 80 和 443 端口已放行。${PLAIN}"
    pause
}

caddy_validate() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先安装 Caddy${PLAIN}"
        return 1
    fi

    caddy fmt --overwrite "$CADDYFILE" >/dev/null 2>&1

    if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

reload_caddy() {
    if caddy_validate; then
        systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy
        echo -e "${GREEN}Caddy 配置已生效${PLAIN}"
        return 0
    else
        echo -e "${RED}Caddy 配置检测失败，请检查 Caddyfile${PLAIN}"
        caddy validate --config "$CADDYFILE"
        return 1
    fi
}

normalize_domains() {
    echo "$1" | tr ',' ' ' | xargs | sed 's/ /, /g'
}

add_proxy() {
    ensure_dirs

    echo -e "${BLUE}添加反代配置${PLAIN}"
    echo
    echo "说明："
    echo "1. 域名需要提前解析到本 VPS"
    echo "2. Caddy 会自动申请 HTTPS 证书"
    echo "3. 请确保 80/443 端口已放行"
    echo

    read -rp "请输入域名，多个域名用空格或英文逗号分隔: " domains_raw
    if [ -z "$domains_raw" ]; then
        echo -e "${RED}域名不能为空${PLAIN}"
        pause
        return
    fi

    domains=$(normalize_domains "$domains_raw")

    read -rp "请输入后端地址，默认 127.0.0.1: " backend_host
    backend_host=${backend_host:-127.0.0.1}

    read -rp "请输入后端端口，例如 3000/8080: " backend_port
    if [ -z "$backend_port" ]; then
        echo -e "${RED}端口不能为空${PLAIN}"
        pause
        return
    fi

    read -rp "请输入反代路径，默认 / ，例如 /api/* : " proxy_path
    proxy_path=${proxy_path:-/}

    upstream="${backend_host}:${backend_port}"

    echo
    echo -e "${YELLOW}即将添加以下配置：${PLAIN}"
    echo "域名：$domains"
    echo "后端：$upstream"
    echo "路径：$proxy_path"
    echo

    read -rp "确认添加？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        pause
        return
    fi

    backup_file=$(backup_caddyfile)

    id=$(echo "$domains_raw" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_//;s/_$//')
    id="${id}_$(date +%s)"

    {
        echo
        echo "# >>> ca-proxy: $id | domains: $domains | upstream: $upstream | path: $proxy_path"
        echo "$domains {"
        echo "    encode zstd gzip"

        if [ "$proxy_path" = "/" ]; then
            echo "    reverse_proxy $upstream"
        else
            echo "    handle $proxy_path {"
            echo "        reverse_proxy $upstream"
            echo "    }"
        fi

        echo "}"
        echo "# <<< ca-proxy: $id"
    } >> "$CADDYFILE"

    if reload_caddy; then
        echo -e "${GREEN}反代配置添加成功${PLAIN}"
        echo -e "${GREEN}证书会由 Caddy 自动申请和续签${PLAIN}"
    else
        echo -e "${RED}配置有误，正在恢复备份${PLAIN}"
        cp "$backup_file" "$CADDYFILE"
        systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy
    fi

    pause
}

edit_caddyfile() {
    ensure_dirs

    echo -e "${BLUE}即将直接编辑 Caddyfile${PLAIN}"
    echo "配置文件路径：$CADDYFILE"
    echo

    backup_file=$(backup_caddyfile)

    if command -v nano >/dev/null 2>&1; then
        editor="nano"
    elif command -v vim >/dev/null 2>&1; then
        editor="vim"
    elif command -v vi >/dev/null 2>&1; then
        editor="vi"
    else
        echo -e "${RED}未找到 nano/vim/vi 编辑器${PLAIN}"
        pause
        return
    fi

    $editor "$CADDYFILE"

    echo
    echo -e "${BLUE}正在检测配置...${PLAIN}"

    if reload_caddy; then
        echo -e "${GREEN}修改完成，配置已生效${PLAIN}"
    else
        echo
        read -rp "配置检测失败，是否恢复修改前备份？[Y/n]: " restore
        if [[ ! "$restore" =~ ^[Nn]$ ]]; then
            cp "$backup_file" "$CADDYFILE"
            systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy
            echo -e "${GREEN}已恢复备份配置${PLAIN}"
        else
            echo -e "${YELLOW}未恢复，请手动修复 Caddyfile${PLAIN}"
        fi
    fi

    pause
}

list_proxy_blocks() {
    ensure_dirs

    echo -e "${BLUE}当前由 ca 脚本添加的反代配置：${PLAIN}"
    echo

    if ! grep -q "# >>> ca-proxy:" "$CADDYFILE"; then
        echo "暂无通过脚本添加的反代配置"
        return
    fi

    grep "# >>> ca-proxy:" "$CADDYFILE" | nl -w2 -s'. '
}

delete_proxy() {
    ensure_dirs

    echo -e "${BLUE}删除反代配置${PLAIN}"
    echo

    list_proxy_blocks
    echo

    if ! grep -q "# >>> ca-proxy:" "$CADDYFILE"; then
        pause
        return
    fi

    echo "请输入要删除的关键词："
    echo "可以输入域名、端口、upstream、或 ca-proxy 后面的 ID"
    echo

    read -rp "关键词: " keyword
    if [ -z "$keyword" ]; then
        echo -e "${RED}关键词不能为空${PLAIN}"
        pause
        return
    fi

    if ! grep "# >>> ca-proxy:" "$CADDYFILE" | grep -q "$keyword"; then
        echo -e "${RED}未找到匹配的反代配置${PLAIN}"
        pause
        return
    fi

    echo
    echo -e "${YELLOW}将删除以下配置块：${PLAIN}"
    grep "# >>> ca-proxy:" "$CADDYFILE" | grep "$keyword"
    echo

    read -rp "确认删除？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        pause
        return
    fi

    backup_file=$(backup_caddyfile)
    tmp_file=$(mktemp)

    awk -v key="$keyword" '
        BEGIN {skip=0}
        /^# >>> ca-proxy:/ {
            if (index($0, key) > 0) {
                skip=1
                next
            }
        }
        /^# <<< ca-proxy:/ {
            if (skip==1) {
                skip=0
                next
            }
        }
        skip==0 {print}
    ' "$CADDYFILE" > "$tmp_file"

    cat "$tmp_file" > "$CADDYFILE"
    rm -f "$tmp_file"

    if reload_caddy; then
        echo -e "${GREEN}反代配置删除成功${PLAIN}"
    else
        echo -e "${RED}删除后配置检测失败，正在恢复备份${PLAIN}"
        cp "$backup_file" "$CADDYFILE"
        systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy
    fi

    pause
}

view_caddyfile() {
    ensure_dirs

    echo -e "${BLUE}查看 Caddy 配置文件：$CADDYFILE${PLAIN}"
    echo

    if command -v less >/dev/null 2>&1; then
        less "$CADDYFILE"
    else
        cat "$CADDYFILE"
    fi

    pause
}

restart_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先安装${PLAIN}"
        pause
        return
    fi

    echo -e "${BLUE}正在重启 Caddy...${PLAIN}"

    if caddy_validate; then
        systemctl restart caddy
        echo -e "${GREEN}Caddy 已重启${PLAIN}"
    else
        echo -e "${RED}配置检测失败，未执行重启${PLAIN}"
    fi

    pause
}

stop_caddy() {
    echo -e "${BLUE}正在停止 Caddy...${PLAIN}"

    if systemctl stop caddy; then
        echo -e "${GREEN}Caddy 已停止${PLAIN}"
    else
        echo -e "${RED}停止失败，可能 Caddy 未安装或未运行${PLAIN}"
    fi

    pause
}

uninstall_caddy() {
    echo -e "${RED}卸载 Caddy${PLAIN}"
    echo
    read -rp "确认卸载 Caddy？[y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        pause
        return
    fi

    systemctl stop caddy >/dev/null 2>&1
    systemctl disable caddy >/dev/null 2>&1

    if command -v apt >/dev/null 2>&1; then
        apt remove -y caddy
        apt autoremove -y
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y caddy
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y caddy
    else
        echo -e "${YELLOW}未识别包管理器，请手动卸载 Caddy${PLAIN}"
    fi

    echo
    read -rp "是否删除 Caddy 配置文件 /etc/caddy ？[y/N]: " del_conf
    if [[ "$del_conf" =~ ^[Yy]$ ]]; then
        rm -rf /etc/caddy
        echo -e "${GREEN}已删除 /etc/caddy${PLAIN}"
    else
        echo -e "${YELLOW}已保留 /etc/caddy${PLAIN}"
    fi

    echo -e "${GREEN}Caddy 卸载完成${PLAIN}"
    pause
}

show_status() {
    echo -e "${BLUE}Caddy 状态：${PLAIN}"

    if command -v caddy >/dev/null 2>&1; then
        caddy version 2>/dev/null
    else
        echo "未安装"
    fi

    if systemctl list-unit-files | grep -q '^caddy.service'; then
        systemctl is-active caddy >/dev/null 2>&1 && echo "运行状态：运行中" || echo "运行状态：未运行"
    fi
}

menu() {
    clear
    echo "================================================="
    echo "             Caddy 一键管理脚本"
    echo "================================================="
    show_status
    echo "-------------------------------------------------"
    echo "1. 安装 / 更新 Caddy"
    echo "2. 添加反代配置"
    echo "3. 修改反代配置，直接编辑 Caddyfile"
    echo "4. 删除反代配置"
    echo "5. 查看 Caddy 配置文件"
    echo "6. 重启 Caddy"
    echo "7. 停止 Caddy"
    echo "8. 卸载 Caddy"
    echo "0. 退出脚本"
    echo "-------------------------------------------------"
}

main() {
    check_root

    while true; do
        menu
        read -rp "请输入选项: " choice

        case "$choice" in
            1)
                install_update_caddy
                ;;
            2)
                add_proxy
                ;;
            3)
                edit_caddyfile
                ;;
            4)
                delete_proxy
                ;;
            5)
                view_caddyfile
                ;;
            6)
                restart_caddy
                ;;
            7)
                stop_caddy
                ;;
            8)
                uninstall_caddy
                ;;
            0)
                echo "已退出"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项${PLAIN}"
                pause
                ;;
        esac
    done
}

main
EOF

chmod +x /usr/local/bin/ca

echo "安装完成，现在可以输入 ca 打开 Caddy 管理脚本"
