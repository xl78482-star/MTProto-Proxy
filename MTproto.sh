#!/bin/bash
# =================================================
# 一键部署 MTProto (守护进程版 + 全功能面板 sb)
# 集成依赖安装、节点创建、后端、后台监控、自带面板
# =================================================

set -e

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

NODE_INFO_FILE="/opt/mtproto/node_info"
CONFIG_FILE="/opt/mtproto/config.py"
SERVICE_FILE="/etc/systemd/system/mtproto.service"
MONITOR_FILE="/etc/systemd/system/mtproto-monitor.service"
mkdir -p /opt/mtproto

# -------------------------------
# 安装依赖
# -------------------------------
install_dependencies() {
    green "⚡ 安装依赖..."
    apt-get update && apt-get install -y python3-pip git curl >/dev/null 2>&1 || yum install -y python3-pip git curl
    pip3 install --no-cache-dir mtprotoproxy >/dev/null 2>&1 || true
    green "✅ 依赖安装完成"
}

# -------------------------------
# 创建节点
# -------------------------------
create_node() {
    green "⚡ 创建节点..."
    DOMAIN=$(curl -s https://api.ipify.org)
    green "🌐 VPS 公网 IP: $DOMAIN"

    used_ports=()
    [[ -f "$NODE_INFO_FILE" ]] && used_ports=($(awk -F= '/PORT/ {print $2}' $NODE_INFO_FILE))

    while :; do
        PORT=$((RANDOM % 30000 + 30000))
        if ! lsof -i:$PORT >/dev/null 2>&1 && [[ ! " ${used_ports[@]} " =~ " $PORT " ]]; then
            break
        fi
    done

    SECRET=$(openssl rand -hex 16)
    echo "PORT=$PORT" > $NODE_INFO_FILE
    echo "SECRET=dd$SECRET" >> $NODE_INFO_FILE
    echo "DOMAIN=$DOMAIN" >> $NODE_INFO_FILE

    cat <<CONFIG >$CONFIG_FILE
PORT = $PORT
USERS = {"dd$SECRET": 100}
DEBUG = False
TG_DOMAIN = "$DOMAIN"
CONFIG

    green "✅ 节点创建完成：端口 $PORT, SECRET dd$SECRET"
}

# -------------------------------
# 创建 systemd 服务
# -------------------------------
create_services() {
    green "⚡ 创建 MTProto systemd 服务..."

    # 后端服务
    cat <<SERVICE >$SERVICE_FILE
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m mtprotoproxy $CONFIG_FILE
Restart=always
RestartSec=5s
WorkingDirectory=/opt/mtproto
StandardOutput=file:/opt/mtproto/mtproto.log
StandardError=file:/opt/mtproto/mtproto.log

[Install]
WantedBy=multi-user.target
SERVICE

    # 监控服务
    cat <<MONITOR >$MONITOR_FILE
[Unit]
Description=MTProto Proxy Monitor
After=network.target mtproto.service

[Service]
Type=simple
ExecStart=/bin/bash -c '
while true; do
    systemctl is-active --quiet mtproto.service || systemctl restart mtproto.service
    sleep 15
done
'
Restart=always
RestartSec=10s
WorkingDirectory=/opt/mtproto
StandardOutput=file:/opt/mtproto/mtproto-monitor.log
StandardError=file:/opt/mtproto/mtproto-monitor.log

[Install]
WantedBy=multi-user.target
MONITOR

    systemctl daemon-reload
    systemctl enable mtproto.service mtproto-monitor.service
    systemctl restart mtproto.service mtproto-monitor.service
    green "✅ 后端与监控服务已启动并设置开机自启"
}

# -------------------------------
# 面板功能
# -------------------------------
panel() {
    if [[ ! -f "$NODE_INFO_FILE" ]]; then
        red "❌ 节点信息未找到"
        return
    fi
    source $NODE_INFO_FILE
    while true; do
        green "================ MTProto 面板 ================"
        echo "1) 查看节点状态"
        echo "2) 显示面板信息 (端口/SECRET/IP)"
        echo "3) 启动后端服务"
        echo "4) 停止后端服务"
        echo "5) 重启后端服务"
        echo "6) 查看日志 (最近100行)"
        echo "0) 退出"
        echo "============================================"
        read -p "请输入选项: " opt
        case $opt in
            1)
                systemctl is-active --quiet mtproto.service && green "✅ 后端运行中" || red "❌ 后端未运行"
                ;;
            2)
                green "🌐 域名/IP: $DOMAIN"
                green "⚡ 端口: $PORT"
                green "🔑 SECRET: $SECRET"
                ;;
            3)
                systemctl start mtproto.service && green "✅ 后端已启动"
                ;;
            4)
                systemctl stop mtproto.service && green "✅ 后端已停止"
                ;;
            5)
                systemctl restart mtproto.service && green "✅ 后端已重启"
                ;;
            6)
                tail -n 100 /opt/mtproto/mtproto.log
                ;;
            0)
                break
                ;;
            *)
                red "输入错误"
                ;;
        esac
        echo
    done
}

# -------------------------------
# 添加 alias sb
# -------------------------------
setup_alias() {
    if ! grep -q "alias sb=" ~/.bashrc; then
        echo "alias sb='bash $0 panel'" >> ~/.bashrc
        source ~/.bashrc
        green "✅ alias sb 已添加，可直接输入 sb 调出面板"
    fi
}

# -------------------------------
# 执行面板 (如果传参 panel)
# -------------------------------
if [[ "$1" == "panel" ]]; then
    panel
    exit 0
fi

# -------------------------------
# 主流程
# -------------------------------
main() {
    install_dependencies
    create_node
    create_services
    setup_alias
    green "⚡ MTProto 后端和监控已启动为守护进程，关闭终端也能运行"
    green "⚡ 输入 sb 查看面板信息"
}

main