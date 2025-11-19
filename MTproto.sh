#!/bin/bash
# =================================================
# MTProto 一键部署（完整修复版 + 面板 + systemd 无错误）
# =================================================

set -e

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

MT_DIR="/opt/mtproto"
NODE_INFO="$MT_DIR/node_info"
CONFIG_FILE="$MT_DIR/config.py"
MONITOR_SH="$MT_DIR/monitor.sh"

mkdir -p $MT_DIR

# -------------------------------
# 安装依赖
# -------------------------------
install_dependencies() {
    green "⚡ 安装依赖中..."
    apt-get update >/dev/null 2>&1 || yum update -y >/dev/null 2>&1
    apt-get install -y python3 python3-pip curl git >/dev/null 2>&1 || \
    yum install -y python3 python3-pip curl git >/dev/null 2>&1
    pip3 install mtprotoproxy >/dev/null 2>&1 || true
    green "✅ 依赖安装完成"
}

# -------------------------------
# 生成可用端口
# -------------------------------
random_port() {
    while :; do
        PORT=$((RANDOM % 30000 + 20000))
        if ! lsof -i:$PORT >/dev/null 2>&1; then
            echo $PORT
            return
        fi
    done
}

# -------------------------------
# 创建节点
# -------------------------------
create_node() {
    green "⚡ 创建节点..."
    DOMAIN=$(curl -s https://api.ipify.org)
    PORT=$(random_port)
    SECRET="dd$(openssl rand -hex 16)"

    cat > $NODE_INFO <<EOF
DOMAIN=$DOMAIN
PORT=$PORT
SECRET=$SECRET
EOF

    write_config
    green "🌐 IP: $DOMAIN"
    green "⚡ 端口: $PORT"
    green "🔑 SECRET: $SECRET"
}

# -------------------------------
# 写入 config.py
# -------------------------------
write_config() {
    source $NODE_INFO
    cat > $CONFIG_FILE <<EOF
PORT = $PORT
USERS = {"$SECRET": 100}
DEBUG = False
TG_DOMAIN = "$DOMAIN"
EOF
}

# -------------------------------
# systemd 后端服务（无错误）
# -------------------------------
create_mtproto_service() {
    PY=$(which python3)

sudo bash -c "cat > /etc/systemd/system/mtproto.service <<EOF
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=$PY -m mtprotoproxy $CONFIG_FILE
Restart=always
RestartSec=5
WorkingDirectory=$MT_DIR
StandardOutput=append:$MT_DIR/mtproto.log
StandardError=append:$MT_DIR/mtproto.log

[Install]
WantedBy=multi-user.target
EOF"
}

# -------------------------------
# 监控脚本
# -------------------------------
create_monitor_sh() {
cat > $MONITOR_SH <<'EOF'
#!/bin/bash
while true; do
    if ! systemctl is-active --quiet mtproto.service; then
        systemctl restart mtproto.service
    fi
    sleep 15
done
EOF

chmod +x $MONITOR_SH
}

# -------------------------------
# systemd 监控服务（无错误）
# -------------------------------
create_monitor_service() {

sudo bash -c "cat > /etc/systemd/system/mtproto-monitor.service <<EOF
[Unit]
Description=MTProto Proxy Monitor
After=network.target mtproto.service

[Service]
Type=simple
ExecStart=$MONITOR_SH
Restart=always
RestartSec=10
WorkingDirectory=$MT_DIR
StandardOutput=append:$MT_DIR/monitor.log
StandardError=append:$MT_DIR/monitor.log

[Install]
WantedBy=multi-user.target
EOF"
}

# -------------------------------
# 启动所有服务
# -------------------------------
start_services() {
    systemctl daemon-reload
    systemctl enable mtproto.service mtproto-monitor.service
    systemctl restart mtproto.service mtproto-monitor.service
    green "✅ 后端、监控服务已启动且开机自启"
}

# -------------------------------
# 面板
# -------------------------------
panel() {
    source $NODE_INFO
    while true; do
        green "=========== MTProto 面板 =========="
        echo "1) 查看节点信息"
        echo "2) 重启后端"
        echo "3) 查看日志"
        echo "4) 修改端口"
        echo "5) 修改 SECRET"
        echo "0) 退出"
        echo "==================================="
        read -p "选择功能: " c

        case $c in
            1)
                green "🌐 IP: $DOMAIN"
                green "⚡ 端口: $PORT"
                green "🔑 SECRET: $SECRET"
                ;;
            2)
                systemctl restart mtproto.service
                green "✅ 已重启"
                ;;
            3)
                tail -n 50 $MT_DIR/mtproto.log
                ;;
            4)
                read -p "输入新端口: " new_port
                sed -i "s/PORT=.*/PORT=$new_port/" $NODE_INFO
                write_config
                systemctl restart mtproto.service
                green "✅ 端口修改成功：$new_port"
                ;;
            5)
                new_secret="dd$(openssl rand -hex 16)"
                sed -i "s/SECRET=.*/SECRET=$new_secret/" $NODE_INFO
                SECRET=$new_secret
                write_config
                systemctl restart mtproto.service
                green "✅ SECRET 已更新"
                ;;
            0)
                break ;;
        esac
    done
}

# -------------------------------
# alias sb
# -------------------------------
setup_alias() {
    if ! grep -q "alias sb=" ~/.bashrc; then
        echo "alias sb='bash $0 panel'" >> ~/.bashrc
        source ~/.bashrc
        green "✅ 已添加 sb 命令，输入 sb 打开面板"
    fi
}

# -------------------------------
# 主程序
# -------------------------------
main() {
    install_dependencies
    create_node
    create_mtproto_service
    create_monitor_sh
    create_monitor_service
    start_services
    setup_alias

    green "🎉 部署完成！直接输入 sb 打开面板"
}

# -------------------------------
# 面板模式
# -------------------------------
if [[ "$1" == "panel" ]]; then
    panel
    exit 0
fi

main