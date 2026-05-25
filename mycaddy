#!/usr/bin/env bash

set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
PLAIN="\033[0m"

CADDY_DIR="/etc/caddy"
CONF_DIR="/etc/caddy/conf.d"
MAIN_CONF="/etc/caddy/Caddyfile"

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 用户运行此脚本${PLAIN}"
        exit 1
    fi
}

check_debian() {
    if ! command -v apt >/dev/null 2>&1; then
        echo -e "${RED}当前脚本仅支持 Debian / Ubuntu 系统${PLAIN}"
        exit 1
    fi
}

pause() {
    echo
    read -rp "按 Enter 返回菜单..."
}

install_or_update_caddy() {
    echo -e "${YELLOW}开始安装 / 更新 Caddy...${PLAIN}"

    apt update
    apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg lsb-release

    mkdir -p /usr/share/keyrings

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null

    apt update
    apt install -y caddy

    mkdir -p "$CONF_DIR"

    if [ ! -f "$MAIN_CONF" ]; then
        cat > "$MAIN_CONF" <<EOF
{
    # 全局配置
    # 如需指定邮箱，可取消下面一行注释
    # email your@email.com
}

import $CONF_DIR/*.caddy
EOF
    else
        if ! grep -q "import $CONF_DIR/\*.caddy" "$MAIN_CONF"; then
            cp "$MAIN_CONF" "$MAIN_CONF.bak.$(date +%Y%m%d%H%M%S)"
            cat > "$MAIN_CONF" <<EOF
{
    # 全局配置
    # 如需指定邮箱，可取消下面一行注释
    # email your@email.com
}

import $CONF_DIR/*.caddy
EOF
        fi
    fi

    caddy fmt --overwrite "$MAIN_CONF" >/dev/null 2>&1 || true

    systemctl enable caddy
    systemctl restart caddy

    echo -e "${GREEN}Caddy 安装 / 更新完成${PLAIN}"
    echo
    caddy version || true
}

normalize_domains() {
    echo "$1" | sed 's/,/ /g' | xargs
}

safe_filename() {
    echo "$1" | awk '{print $1}' | sed 's/[^a-zA-Z0-9.-]/_/g'
}

create_proxy_config() {
    local domains="$1"
    local upstream="$2"
    local file="$3"

    cat > "$file" <<EOF
$domains {
    encode zstd gzip

    reverse_proxy $upstream

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        Referrer-Policy no-referrer-when-downgrade
    }
}
EOF
}

reload_caddy() {
    echo -e "${YELLOW}正在检查 Caddy 配置...${PLAIN}"

    caddy fmt --overwrite "$MAIN_CONF" >/dev/null 2>&1 || true

    for f in "$CONF_DIR"/*.caddy; do
        [ -f "$f" ] && caddy fmt --overwrite "$f" >/dev/null 2>&1 || true
    done

    if caddy validate --config "$MAIN_CONF"; then
        systemctl reload caddy || systemctl restart caddy
        echo -e "${GREEN}Caddy 配置已生效${PLAIN}"
    else
        echo -e "${RED}Caddy 配置检测失败，请检查配置${PLAIN}"
        return 1
    fi
}

add_proxy_config() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先安装 / 更新 Caddy${PLAIN}"
        return
    fi

    mkdir -p "$CONF_DIR"

    echo
    echo -e "${GREEN}添加反向代理配置${PLAIN}"
    echo
    echo "域名可以填写一个或多个，例如："
    echo "example.com"
    echo "example.com www.example.com"
    echo "a.com,b.com"
    echo
    read -rp "请输入域名: " raw_domains

    domains=$(normalize_domains "$raw_domains")

    if [ -z "$domains" ]; then
        echo -e "${RED}域名不能为空${PLAIN}"
        return
    fi

    echo
    echo "请输入后端地址，例如："
    echo "127.0.0.1:3000"
    echo "http://127.0.0.1:3000"
    echo "http://localhost:8080"
    echo
    read -rp "请输入反代目标地址: " upstream

    if [ -z "$upstream" ]; then
        echo -e "${RED}反代目标地址不能为空${PLAIN}"
        return
    fi

    filename=$(safe_filename "$domains")
    conf_file="$CONF_DIR/$filename.caddy"

    if [ -f "$conf_file" ]; then
        echo -e "${YELLOW}配置文件已存在：$conf_file${PLAIN}"
        read -rp "是否覆盖？[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "已取消"
            return
        fi
        cp "$conf_file" "$conf_file.bak.$(date +%Y%m%d%H%M%S)"
    fi

    create_proxy_config "$domains" "$upstream" "$conf_file"

    echo
    echo -e "${GREEN}已生成配置文件：$conf_file${PLAIN}"
    echo
    cat "$conf_file"
    echo

    reload_caddy
}

list_proxy_configs() {
    mkdir -p "$CONF_DIR"

    mapfile -t files < <(find "$CONF_DIR" -maxdepth 1 -type f -name "*.caddy" | sort)

    if [ "${#files[@]}" -eq 0 ]; then
        echo -e "${YELLOW}当前没有反代配置${PLAIN}"
        return 1
    fi

    echo
    echo -e "${GREEN}当前反代配置列表：${PLAIN}"
    echo

    local i=1
    for f in "${files[@]}"; do
        echo "$i) $(basename "$f")"
        i=$((i + 1))
    done

    echo
    read -rp "请选择配置编号: " num

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}请输入正确的数字${PLAIN}"
        return 1
    fi

    if [ "$num" -lt 1 ] || [ "$num" -gt "${#files[@]}" ]; then
        echo -e "${RED}编号无效${PLAIN}"
        return 1
    fi

    SELECTED_CONF="${files[$((num - 1))]}"
    return 0
}

modify_proxy_config() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先安装 / 更新 Caddy${PLAIN}"
        return
    fi

    if ! list_proxy_configs; then
        return
    fi

    echo
    echo -e "${YELLOW}当前配置内容：${PLAIN}"
    echo
    cat "$SELECTED_CONF"
    echo

    echo -e "${GREEN}请输入新的配置内容${PLAIN}"
    echo
    echo "域名可以填写一个或多个，例如："
    echo "example.com www.example.com"
    echo
    read -rp "请输入新的域名: " raw_domains

    domains=$(normalize_domains "$raw_domains")

    if [ -z "$domains" ]; then
        echo -e "${RED}域名不能为空${PLAIN}"
        return
    fi

    echo
    echo "请输入新的后端地址，例如："
    echo "127.0.0.1:3000"
    echo "http://127.0.0.1:3000"
    echo
    read -rp "请输入新的反代目标地址: " upstream

    if [ -z "$upstream" ]; then
        echo -e "${RED}反代目标地址不能为空${PLAIN}"
        return
    fi

    cp "$SELECTED_CONF" "$SELECTED_CONF.bak.$(date +%Y%m%d%H%M%S)"

    create_proxy_config "$domains" "$upstream" "$SELECTED_CONF"

    echo
    echo -e "${GREEN}配置已修改：$SELECTED_CONF${PLAIN}"
    echo
    cat "$SELECTED_CONF"
    echo

    reload_caddy
}

view_caddy_config() {
    echo
    echo -e "${GREEN}主配置文件：$MAIN_CONF${PLAIN}"
    echo

    if [ -f "$MAIN_CONF" ]; then
        cat "$MAIN_CONF"
    else
        echo -e "${YELLOW}主配置文件不存在${PLAIN}"
    fi

    echo
    echo -e "${GREEN}站点配置目录：$CONF_DIR${PLAIN}"
    echo

    if [ -d "$CONF_DIR" ]; then
        files=$(find "$CONF_DIR" -maxdepth 1 -type f -name "*.caddy" | sort)

        if [ -z "$files" ]; then
            echo -e "${YELLOW}暂无站点配置${PLAIN}"
        else
            for f in $files; do
                echo
                echo "=================================================="
                echo "配置文件：$f"
                echo "=================================================="
                cat "$f"
                echo
            done
        fi
    else
        echo -e "${YELLOW}站点配置目录不存在${PLAIN}"
    fi
}

stop_caddy() {
    if systemctl is-active --quiet caddy; then
        systemctl stop caddy
        echo -e "${GREEN}Caddy 已停止${PLAIN}"
    else
        echo -e "${YELLOW}Caddy 当前未运行${PLAIN}"
    fi
}

restart_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Caddy，请先安装 / 更新 Caddy${PLAIN}"
        return
    fi

    if caddy validate --config "$MAIN_CONF"; then
        systemctl restart caddy
        echo -e "${GREEN}Caddy 已重启${PLAIN}"
    else
        echo -e "${RED}Caddy 配置检测失败，未重启${PLAIN}"
    fi
}

show_status() {
    echo
    echo -e "${GREEN}Caddy 状态：${PLAIN}"
    systemctl status caddy --no-pager || true
}

show_menu() {
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}        Caddy 反代管理脚本${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo
    echo "1) 安装 / 更新 Caddy"
    echo "2) 添加反代配置"
    echo "3) 修改反代配置"
    echo "4) 查看 Caddy 配置文件"
    echo "5) 停止 Caddy"
    echo "6) 重启 Caddy"
    echo "7) 查看 Caddy 状态"
    echo "0) 退出"
    echo
}

main() {
    check_root
    check_debian

    while true; do
        show_menu
        read -rp "请输入选项: " choice

        case "$choice" in
            1)
                install_or_update_caddy
                pause
                ;;
            2)
                add_proxy_config
                pause
                ;;
            3)
                modify_proxy_config
                pause
                ;;
            4)
                view_caddy_config
                pause
                ;;
            5)
                stop_caddy
                pause
                ;;
            6)
                restart_caddy
                pause
                ;;
            7)
                show_status
                pause
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

main
