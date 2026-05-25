cat > /usr/local/bin/ca <<'EOF'
#!/usr/bin/env bash

# =========================================================
# Caddy 一键管理脚本
# 命令：ca
# =========================================================

CADDYFILE="/etc/caddy/Caddyfile"
BACKUP_DIR="/etc/caddy/backup"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
PLAIN="\033[0m"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 用户运行本脚本。${PLAIN}"
        exit 1
    fi
}

pause() {
    echo
    read -rp "按回车键继续..."
}

ensure_dirs() {
    mkdir -p /etc/caddy "$BACKUP_DIR"

    if [ ! -f "$CADDYFILE" ]; then
        cat > "$CADDYFILE" <<'EOC'
{
    # Caddy 会自动申请和续签 HTTPS 证书
    # 请确保域名已解析到本 VPS，并放行 80/443 端口
}
EOC
    fi
}

backup_caddyfile() {
    ensure_dirs
    local backup_file
    backup_file="$BACKUP_DIR/Caddyfile_$(date '+%Y%m%d_%H%M%S').bak"
    cp -a "$CADDYFILE" "$backup_file"
    echo "$backup_file"
}

install_vim() {
    if command -v vim >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}未检测到 vim，正在自动安装 vim...${PLAIN}"

    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y vim
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y vim
    elif command -v yum >/dev/null 2>&1; then
        yum install -y vim
    else
        echo -e "${RED}无法识别系统包管理器，请手动安装 vim。${PLAIN}"
        return 1
    fi
}

install_update_caddy() {
    echo -e "${BLUE}正在安装 / 更新 Caddy...${PLAIN}"
    echo

    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg vim

        mkdir -p /usr/share/keyrings
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list

        chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        chmod o+r /etc/apt/sources.list.d/caddy-stable.list

        apt update
        apt install -y caddy

    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y dnf-plugins-core curl vim
        dnf copr enable -y @caddy/caddy
        dnf install -y caddy

    elif command -v yum >/dev/null 2>&1; then
        yum install -y yum-plugin-copr curl vim
        yum copr enable -y @caddy/caddy
        yum install -y caddy

    else
        echo -e "${RED}不支持当前系统，请使用 Debian / Ubuntu / CentOS / Rocky / AlmaLinux。${PLAIN}"
        pause
        return
    fi

    ensure_dirs

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy

    echo
    echo -e "${GREEN}Caddy 安装 / 更新完成。${PLAIN}"
    echo -e "${YELLOW}请确保域名已解析到本机，并放行 80 和 443 端口。${PLAIN}"
    pause
}

caddy_validate() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先安装 Caddy。${PLAIN}"
        return 1
    fi

    if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${RED}Caddy 配置检测失败，详细信息如下：${PLAIN}"
    caddy validate --config "$CADDYFILE"
    return 1
}

reload_caddy() {
    if ! caddy_validate; then
        return 1
    fi

    caddy fmt --overwrite "$CADDYFILE" >/dev/null 2>&1 || true

    if systemctl reload caddy >/dev/null 2>&1; then
        echo -e "${GREEN}Caddy 配置已加载生效。${PLAIN}"
        return 0
    fi

    if systemctl restart caddy >/dev/null 2>&1; then
        echo -e "${GREEN}Caddy 已重启，配置已生效。${PLAIN}"
        return 0
    fi

    echo -e "${RED}Caddy 配置正确，但服务加载失败，请执行 systemctl status caddy 查看原因。${PLAIN}"
    return 1
}

normalize_domain_list() {
    echo "$1" | tr ',' ' ' | xargs
}

format_domains_for_caddy() {
    echo "$1" | tr ',' ' ' | xargs | sed 's/ /, /g'
}

domain_exists() {
    local target="$1"

    awk -v target="$target" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*[^#].*\{[[:space:]]*$/ {
            line=$0
            sub(/[[:space:]]*\{[[:space:]]*$/, "", line)
            gsub(/,/, " ", line)
            n=split(line, items, /[[:space:]]+/)
            for (i=1; i<=n; i++) {
                if (items[i] == target) {
                    found=1
                }
            }
        }
        END {
            if (found == 1) exit 0
            exit 1
        }
    ' "$CADDYFILE"
}

add_proxy() {
    ensure_dirs

    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先选择 1 安装 Caddy。${PLAIN}"
        pause
        return
    fi

    echo -e "${BLUE}添加反代配置${PLAIN}"
    echo "-------------------------------------------------"
    echo "说明："
    echo "1. 域名需要提前解析到当前 VPS。"
    echo "2. Caddy 会自动申请和续签 HTTPS 证书。"
    echo "3. 请确保服务器及安全组已放行 80/443 端口。"
    echo "4. 多个域名可使用空格或英文逗号分隔。"
    echo
    echo "示例一："
    echo "  域名：example.com"
    echo "  后端地址：127.0.0.1"
    echo "  后端端口：8052"
    echo
    echo "示例二："
    echo "  域名：example.com"
    echo "  后端地址：http://127.0.0.1:8052"
    echo "  后端端口：无需输入"
    echo "-------------------------------------------------"
    echo

    local domains_raw domains_space domains upstream
    local backend_host backend_port proxy_path id backup_file
    local d

    read -rp "请输入域名，多个域名用空格或英文逗号分隔: " domains_raw
    domains_space=$(normalize_domain_list "$domains_raw")

    if [ -z "$domains_space" ]; then
        echo -e "${RED}域名不能为空。${PLAIN}"
        pause
        return
    fi

    for d in $domains_space; do
        if domain_exists "$d"; then
            echo -e "${RED}域名已经存在于 Caddyfile 中：$d${PLAIN}"
            echo -e "${YELLOW}如需修改该站点，请选择菜单 3 直接编辑 Caddyfile。${PLAIN}"
            pause
            return
        fi
    done

    domains=$(format_domains_for_caddy "$domains_raw")

    read -rp "请输入后端地址，默认 127.0.0.1，也可直接填写 127.0.0.1:8052: " backend_host
    backend_host=${backend_host:-127.0.0.1}

    if echo "$backend_host" | grep -Eq ':[0-9]+/?$'; then
        upstream="$backend_host"
        echo -e "${YELLOW}已检测到后端地址包含端口：$upstream${PLAIN}"
    else
        read -rp "请输入后端端口，例如 3000 或 8052: " backend_port

        if ! [[ "$backend_port" =~ ^[0-9]+$ ]] || [ "$backend_port" -lt 1 ] || [ "$backend_port" -gt 65535 ]; then
            echo -e "${RED}端口格式错误，请输入 1 - 65535 之间的数字。${PLAIN}"
            pause
            return
        fi

        upstream="${backend_host}:${backend_port}"
    fi

    read -rp "请输入反代路径，直接回车默认为 /，例如 /api/* : " proxy_path
    proxy_path=${proxy_path:-/}

    backup_file=$(backup_caddyfile)
    id=$(echo "$domains_space" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_//;s/_$//')
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

    echo
    echo -e "${CYAN}正在生成以下反代配置：${PLAIN}"
    echo "域名：$domains"
    echo "后端：$upstream"
    echo "路径：$proxy_path"
    echo

    if reload_caddy; then
        echo -e "${GREEN}反代配置添加成功。${PLAIN}"
        echo -e "${GREEN}如域名解析正确，HTTPS 证书将由 Caddy 自动申请。${PLAIN}"
    else
        echo -e "${RED}新配置无法生效，正在恢复添加前的配置。${PLAIN}"
        cp -a "$backup_file" "$CADDYFILE"
        systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1
        echo -e "${YELLOW}已恢复备份：$backup_file${PLAIN}"
    fi

    pause
}

edit_caddyfile() {
    ensure_dirs

    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先选择 1 安装 Caddy。${PLAIN}"
        pause
        return
    fi

    if ! install_vim; then
        pause
        return
    fi

    local backup_file restore
    backup_file=$(backup_caddyfile)

    echo -e "${BLUE}使用 vim 修改 Caddy 配置文件${PLAIN}"
    echo "-------------------------------------------------"
    echo "配置文件：$CADDYFILE"
    echo
    echo "vim 常用操作："
    echo "  开始编辑：按 i"
    echo "  保存退出：按 Esc，然后输入 :wq 并回车"
    echo "  不保存退出：按 Esc，然后输入 :q! 并回车"
    echo "-------------------------------------------------"
    echo
    read -rp "按回车键进入 vim 编辑器..."

    vim "$CADDYFILE"

    echo
    echo -e "${BLUE}正在检测修改后的 Caddy 配置...${PLAIN}"

    if reload_caddy; then
        echo -e "${GREEN}配置修改成功，并已生效。${PLAIN}"
    else
        echo
        read -rp "配置检测失败，是否恢复修改前的配置？[Y/n]: " restore
        if [[ ! "$restore" =~ ^[Nn]$ ]]; then
            cp -a "$backup_file" "$CADDYFILE"
            systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1
            echo -e "${GREEN}已恢复修改前的配置。${PLAIN}"
        else
            echo -e "${YELLOW}当前错误配置已保留，请尽快重新修改修复。${PLAIN}"
        fi
    fi

    pause
}

list_proxy_blocks() {
    ensure_dirs

    if ! grep -q '^# >>> ca-proxy:' "$CADDYFILE" 2>/dev/null; then
        echo "暂无通过 ca 脚本添加的反代配置。"
        return 1
    fi

    grep '^# >>> ca-proxy:' "$CADDYFILE" | nl -w2 -s'. '
    return 0
}

delete_proxy() {
    ensure_dirs

    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先安装 Caddy。${PLAIN}"
        pause
        return
    fi

    echo -e "${BLUE}删除反代配置${PLAIN}"
    echo "-------------------------------------------------"
    echo "当前由 ca 脚本添加的配置："
    echo

    if ! list_proxy_blocks; then
        pause
        return
    fi

    echo
    echo "可输入域名、后端端口或配置 ID 进行删除。"
    echo "例如：example.com 或 8052"
    echo

    local keyword backup_file tmp_file confirm
    read -rp "请输入需要删除的配置关键词: " keyword

    if [ -z "$keyword" ]; then
        echo -e "${RED}关键词不能为空。${PLAIN}"
        pause
        return
    fi

    if ! grep '^# >>> ca-proxy:' "$CADDYFILE" | grep -Fq "$keyword"; then
        echo -e "${RED}未找到匹配的脚本反代配置。${PLAIN}"
        pause
        return
    fi

    echo
    echo -e "${YELLOW}匹配到以下配置：${PLAIN}"
    grep '^# >>> ca-proxy:' "$CADDYFILE" | grep -F "$keyword"
    echo

    read -rp "确认删除以上匹配的配置？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消删除。"
        pause
        return
    fi

    backup_file=$(backup_caddyfile)
    tmp_file=$(mktemp)

    awk -v key="$keyword" '
        BEGIN { skip=0 }
        /^# >>> ca-proxy:/ {
            if (index($0, key) > 0) {
                skip=1
                next
            }
        }
        /^# <<< ca-proxy:/ {
            if (skip == 1) {
                skip=0
                next
            }
        }
        skip == 0 { print }
    ' "$CADDYFILE" > "$tmp_file"

    cat "$tmp_file" > "$CADDYFILE"
    rm -f "$tmp_file"

    if reload_caddy; then
        echo -e "${GREEN}反代配置删除成功。${PLAIN}"
    else
        echo -e "${RED}删除后的配置无法生效，正在恢复备份。${PLAIN}"
        cp -a "$backup_file" "$CADDYFILE"
        systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1
        echo -e "${YELLOW}已恢复备份：$backup_file${PLAIN}"
    fi

    pause
}

view_caddyfile() {
    ensure_dirs

    echo -e "${BLUE}查看 Caddy 配置文件${PLAIN}"
    echo "配置文件：$CADDYFILE"
    echo
    echo -e "${YELLOW}提示：进入查看界面后，按 q 即可退出查看。${PLAIN}"
    echo
    read -rp "按回车键开始查看..."

    if command -v less >/dev/null 2>&1; then
        less "$CADDYFILE"
    else
        cat "$CADDYFILE"
    fi

    pause
}

restart_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先安装 Caddy。${PLAIN}"
        pause
        return
    fi

    echo -e "${BLUE}正在重启 Caddy...${PLAIN}"

    if caddy_validate; then
        caddy fmt --overwrite "$CADDYFILE" >/dev/null 2>&1 || true

        if systemctl restart caddy; then
            echo -e "${GREEN}Caddy 已重启。${PLAIN}"
        else
            echo -e "${RED}Caddy 重启失败，请执行 systemctl status caddy 查看原因。${PLAIN}"
        fi
    else
        echo -e "${RED}配置存在错误，已取消重启。${PLAIN}"
    fi

    pause
}

stop_caddy() {
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^caddy.service'; then
        echo -e "${RED}未检测到 Caddy 服务。${PLAIN}"
        pause
        return
    fi

    echo -e "${BLUE}正在停止 Caddy...${PLAIN}"

    if systemctl stop caddy; then
        echo -e "${GREEN}Caddy 已停止。${PLAIN}"
    else
        echo -e "${RED}Caddy 停止失败。${PLAIN}"
    fi

    pause
}

uninstall_caddy() {
    local confirm del_conf

    echo -e "${RED}卸载 Caddy${PLAIN}"
    echo "-------------------------------------------------"
    echo "卸载 Caddy 后，ca 管理脚本仍会保留，后续可以重新安装。"
    echo

    read -rp "确认卸载 Caddy？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消卸载。"
        pause
        return
    fi

    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true

    if command -v apt >/dev/null 2>&1; then
        apt remove -y caddy
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y caddy
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y caddy
    else
        echo -e "${YELLOW}未识别包管理器，请手动卸载 Caddy。${PLAIN}"
    fi

    echo
    read -rp "是否同时删除配置文件和备份目录 /etc/caddy？[y/N]: " del_conf
    if [[ "$del_conf" =~ ^[Yy]$ ]]; then
        rm -rf /etc/caddy
        echo -e "${GREEN}已删除 /etc/caddy。${PLAIN}"
    else
        echo -e "${YELLOW}已保留 /etc/caddy 配置文件和备份。${PLAIN}"
    fi

    echo -e "${GREEN}Caddy 卸载完成。${PLAIN}"
    pause
}

show_status() {
    echo -e "${BLUE}Caddy 状态：${PLAIN}"

    if command -v caddy >/dev/null 2>&1; then
        echo -n "版本："
        caddy version 2>/dev/null | awk '{print $1}'

        if systemctl is-active caddy >/dev/null 2>&1; then
            echo -e "运行状态：${GREEN}运行中${PLAIN}"
        else
            echo -e "运行状态：${YELLOW}未运行${PLAIN}"
        fi
    else
        echo -e "安装状态：${YELLOW}未安装${PLAIN}"
    fi
}

menu() {
    clear
    echo "================================================="
    echo "              Caddy 一键管理脚本"
    echo "================================================="
    show_status
    echo "-------------------------------------------------"
    echo "1. 安装 / 更新 Caddy"
    echo "2. 添加反代配置"
    echo "3. 修改反代配置（vim 编辑 Caddyfile）"
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
            1) install_update_caddy ;;
            2) add_proxy ;;
            3) edit_caddyfile ;;
            4) delete_proxy ;;
            5) view_caddyfile ;;
            6) restart_caddy ;;
            7) stop_caddy ;;
            8) uninstall_caddy ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入。${PLAIN}"
                pause
                ;;
        esac
    done
}

main
EOF

chmod +x /usr/local/bin/ca

echo "================================================="
echo "ca 管理脚本安装 / 更新完成"
echo "现在直接输入 ca 即可打开 Caddy 管理菜单"
echo "================================================="
