#!/bin/bash
# =================================================
# MTProto 功能面板 (sb 命令调用)
# =================================================

set -e

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

NODE_INFO_FILE="/opt/mtproto/node_info"

# -------------------------------
# 功能函数
# -------------------------------

install_dependencies() {
    green "⚡ 安装依赖..."
    apt-get update && apt-get install -y python3-pip git curl >/dev/null 2>&1 || yum install -y python3-pip git curl
    pip3 install --no-cache-dir mtprotoproxy >/dev/null 2>&1 || true
    green "✅ 依赖安装完成"
}

create_node() {
    green "⚡ 创建新节点..."
    mkdir -p /opt/mtproto
    DOMAIN=$(curl -s https://api.ipify.org)
    green "🌐 检测到 VPS 公网 IP: $DOMAIN"

    used_ports=()
    [[ -f "$NODE_INFO_FILE" ]] && used_ports=($(awk -F= '/PORT/ {print $2}' $NODE_INFO_FILE))
    while true; do
        PORT=$((RANDOM % 65535 + 1))
        if ! lsof -i:$PORT >/dev/null 2>&1 && [[ ! " ${used_ports[@]} " =~ " $PORT " ]]; then
            break
        fi
    done
    green "⚡ 选择可用端口: $PORT"

    SECRET=$(openssl rand -hex 16)
    green "🔑 dd-secret: dd$SECRET"

    echo "PORT=$PORT" > $NODE_INFO_FILE
    echo "SECRET=dd$SECRET" >> $NODE_INFO_FILE
    echo "DOMAIN=$DOMAIN" >> $NODE_INFO_FILE

    cat <<EOF >/opt/mtproto/config.py
PORT = $PORT
USERS = {"dd$SECRET": 100}
DEBUG = False
TG_DOMAIN = "$DOMAIN"
EOF

    green "✅ 节点创建完成"
}

start_backend() {
    green "⚡ 启动 MTProto 后端..."
    cat <<EOF >/etc/systemd/system/mtproto.service
[Unit]
Description=官方 MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m mtprotoproxy /opt/mtproto/config.py
Restart=always
RestartSec=5s
WorkingDirectory=/opt/mtproto
StandardOutput=file:/opt/mtproto/mtproto.log
StandardError=file:/opt/mtproto/mtproto.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtproto.service
    systemctl start mtproto.service
    green "✅ MTProto 后端已启动"
}

start_monitor() {
    green "⚡ 启动后台检测..."
    cat <<'EOF' >/opt/mtproto/mtproto_monitor.sh
#!/bin/bash
NODE_INFO_FILE="/opt/mtproto/node_info"
DETECT_INTERVAL=15
TELEGRAM_DCS=("149.154.167.50" "149.154.167.91" "149.154.167.92" "173.240.5.253")
PORTS_TO_TRY=()

check_port() {
    local host=$1
    local port=$2
    timeout 2 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1 && return 0 || return 1
}

if [[ ! -f "$NODE_INFO_FILE" ]]; then exit 1; fi
source $NODE_INFO_FILE
PORTS_TO_TRY=($PORT 443 80 25 110)

while true; do
    systemctl is-active --quiet mtproto.service || systemctl start mtproto.service
    PORT_OK=0
    for p in "${PORTS_TO_TRY[@]}"; do
        if check_port $DOMAIN $p; then
            [[ "$p" != "$PORT" ]] && sed -i "s/^PORT = .*/PORT = $p/" /opt/mtproto/config.py && systemctl restart mtproto.service && PORT=$p
            PORT_OK=1
            break
        fi
    done
    sleep $DETECT_INTERVAL
done
EOF

    chmod +x /opt/mtproto/mtproto_monitor.sh

    cat <<EOF >/etc/systemd/system/mtproto-monitor.service
[Unit]
Description=MTProto 后端检测与自愈
After=network.target mtproto.service

[Service]
Type=simple
ExecStart=/opt/mtproto/mtproto_monitor.sh
Restart=always
RestartSec=10s
WorkingDirectory=/opt/mtproto
StandardOutput=file:/opt/mtproto/mtproto_monitor.log
StandardError=file:/opt/mtproto/mtproto_monitor.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtproto-monitor.service
    systemctl start mtproto-monitor.service
    green "✅ 后台检测已启动"
}

show_info() {
    if [[ ! -f "$NODE_INFO_FILE" ]]; then
        red "❌ 节点信息未找到"
        return
    fi
    source $NODE_INFO_FILE
    green "⚡ 当前节点信息:"
    echo "🌐 域名/IP: $DOMAIN"
    echo "🔑 dd-secret: $SECRET"
    echo "⚡ 端口: $PORT"
    yellow "Telegram 链接: tg://proxy?server=$DOMAIN&port=$PORT&secret=$SECRET"
}

# -------------------------------
# 功能面板
# -------------------------------
while true; do
    echo
    green "================ MTProto 功能面板 (sb) ================"
    echo "1) 安装依赖"
    echo "2) 创建新节点"
    echo "3) 启动 MTProto 后端"
    echo "4) 启动后台检测与自愈"
    echo "5) 查看节点信息与 Telegram 链接"
    echo "0) 退出"
    echo "======================================================"
    read -p "请输入功能编号: " func

    case $func in
        1) install_dependencies ;;
        2) create_node ;;
        3) start_backend ;;
        4) start_monitor ;;
        5) show_info ;;
        0) exit 0 ;;
        *) red "输入错误，请输入正确编号" ;;
    esac
done