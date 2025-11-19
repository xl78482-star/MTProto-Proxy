#!/bin/bash
# =================================================
# 一键部署 MTProto (守护进程版 + 全功能面板 sb)
# 集成依赖安装、节点创建、后端、后台守护、面板管理、在线修改端口/SECRET，端口自动检测
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
# 检测端口是否可用
# -------------------------------
check_port_available() {
    local port=$1
    if lsof -i:$port >/dev/null 2>&1; then
        return 1
    else
        return 0
    fi
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
        if check_port_available $PORT && [[ ! " ${used_ports[@]} " =~ " $PORT " ]]; then
            break
        fi
    done

    SECRET=$(openssl rand -hex 16)
    echo "PORT=$PORT" > $NODE_INFO_FILE
    echo "SECRET=dd$SECRET" >> $NODE_INFO_FILE
    echo "DOMAIN=$DOMAIN" >> $NODE_INFO_FILE

    write_config
    green "✅ 节点创建完成：端口 $PORT, SECRET dd$SECRET"
}

# -------------------------------
# 写入 config.py
# -------------------------------
write_config() {
    source $NODE_INFO_FILE
    cat <<CONFIG >$CONFIG_FILE
PORT = $PORT
USERS = {"$SECRET": 100}
DEBUG = False
TG_DOMAIN = "$DOMAIN"
CONFIG
}

# -------------------------------
# 创建 systemd 服务
# -------------------------------
create_services() {
    PYTHON_PATH=$(which python3)
    sudo touch /opt/mtproto/mtproto.log /opt/mtproto/mtproto-monitor.log
    sudo chmod 666 /opt/mtproto/mtproto.log /opt/mtproto/mtproto-monitor.log

    green "⚡ 创建 MTProto systemd 服务..."

    # 后端服务
    sudo bash -c "cat > $SERVICE_FILE <<EOF
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=$PYTHON_PATH -m mtprotoproxy $CONFIG_FILE
Restart=always
RestartSec=5s
WorkingDirectory=/opt/mtproto
StandardOutput=file:/opt/mtproto/mtproto.log
StandardError=file:/opt/mtproto/mtproto.log

[Install]
WantedBy=multi-user.target
EOF"

    # 监控服务
    sudo bash -c "cat > $MONITOR_FILE <<EOF
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
EOF"

    sudo systemctl daemon-reload
    sudo systemctl enable mtproto.service mtproto-monitor.service
    sudo systemctl restart mtproto.service mtproto-monitor.service
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
        echo "7) 修改端口 (自动检测可用性)"
        echo "8) 修改 SECRET"
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
                sudo systemctl start mtproto.service && green "✅ 后端已启动"
                ;;
            4)
                sudo systemctl stop mtproto.service && green "✅ 后端已停止"
                ;;
            5)
                sudo systemctl restart mtproto.service && green "✅ 后端已重启"
                ;;
            6)
                tail -n 100 /opt/mtproto/mtproto.log
                ;;
            7)
                read -p "请输入新端口: " new_port
                if [[ $new_port =~ ^[0-9]+$ ]] && [ $new_port -ge 1024 ] && [ $new_port -le 65535 ]; then
                    if check_port_available $new_port; then
                        sed -i "s/^PORT=.*/PORT=$new_port/" $NODE_INFO_FILE
                        write_config
                        sudo systemctl restart mtproto.service
                        PORT=$new_port
                        green "✅ 端口已修改为 $new_port 并重启后端"
                    else
                        red "❌ 端口 $new_port 已被占用，请选择其他端口"
                    fi
                else
                    red "❌ 无效端口"
                fi
                ;;
            8)
                new_secret="dd$(openssl rand -hex 16)"
                sed -i "s/^SECRET=.*/SECRET=$new_secret/" $NODE_INFO_FILE
                write_config
                SECRET=$new_secret
                sudo systemctl restart mtproto.service
                green "✅ SECRET 已修改为 $new_secret 并重启后端"
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