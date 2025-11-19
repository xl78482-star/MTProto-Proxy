#!/bin/bash
# =================================================
# 一键部署 MTProto + 功能面板 (sb)
# 自动检测可用端口
# =================================================

set -e

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

NODE_INFO_FILE="/opt/mtproto/node_info"

# -------------------------------
# 安装 sb 面板脚本
# -------------------------------
install_sb() {
sudo bash -c 'cat > /usr/local/bin/sb <<'"'"'EOF'"'"'
#!/bin/bash
# =================================================
# MTProto 功能面板 (sb)
# =================================================

set -e

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

NODE_INFO_FILE="/opt/mtproto/node_info"

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
# 创建节点（自动检测可用端口）
# -------------------------------
create_node() {
    green "⚡ 创建新节点..."
    mkdir -p /opt/mtproto
    DOMAIN=$(curl -s https://api.ipify.org)
    green "🌐 检测到 VPS 公网 IP: $DOMAIN"

    # 已用端口
    used_ports=()
    [[ -f "$NODE_INFO_FILE" ]] && used_ports=($(awk -F= '/PORT/ {print $2}' $NODE_INFO_FILE))

    # 自动检测可用端口
    for ((p=1;p<=65535;p++)); do
        if ! lsof -i:$p >/dev/null 2>&1 && [[ ! " ${used_ports[@]} " =~ " $p " ]]; then
            PORT=$p
            break
        fi
    done

    if [[ -z "$PORT" ]]; then
        red "❌ 没有找到可用端口"
        exit 1
    fi

    green "⚡ 使用可用端口: $PORT"
    SECRET=$(openssl rand -hex 16)
    green "🔑 dd-secret: dd$SECRET"

    # 保存节点信息
    echo "PORT=$PORT" > $NODE_INFO_FILE
    echo "SECRET=dd$SECRET" >> $NODE_INFO_FILE
    echo "DOMAIN=$DOMAIN" >> $NODE_INFO_FILE

    # 生成配置文件
    cat <<CONFIG >/opt/mtproto/config.py
PORT = $PORT
USERS = {"dd$SECRET": 100}
DEBUG = False
TG_DOMAIN = "$DOMAIN"
CONFIG

    green "✅ 节点创建完成"
}

# -------------------------------
# 启动 MTProto 后端
# -------------------------------
start_backend() {
    green "⚡ 启动 MTProto 后端..."
    mkdir -p /opt/mtproto
    cat <<SERVICE >/etc/systemd/system/mtproto.service
[Unit]
Description=MTProto Proxy
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
SERVICE

    systemctl daemon-reload
    systemctl enable mtproto.service
    systemctl restart mtproto.service
    green "✅ 后端服务已启动并保持运行"
}

# -------------------------------
# 后台监控与自愈
# -------------------------------
start_monitor() {
    green "⚡ 启动后台监控与自愈..."
    cat <<'MONITOR' >/opt/mtproto/mtproto_monitor.sh
#!/bin/bash
NODE_INFO_FILE="/opt/mtproto/node_info"
DETECT_INTERVAL=15
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
    systemctl is-active --quiet mtproto.service || systemctl restart mtproto.service
    for p in "${PORTS_TO_TRY[@]}"; do
        if check_port $DOMAIN $p; then
            [[ "$p" != "$PORT" ]] && sed -i "s/^PORT = .*/PORT = $p/" /opt/mtproto/config.py && systemctl restart mtproto.service && PORT=$p
            break
        fi
    done
    sleep $DETECT_INTERVAL
done
MONITOR

    chmod +x /opt/mtproto/mtproto_monitor.sh
    cat <<SERVICE >/etc/systemd/system/mtproto-monitor.service
[Unit]
Description=MTProto 后端监控与自愈
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
SERVICE

    systemctl daemon-reload
    systemctl enable mtproto-monitor.service
    systemctl restart mtproto-monitor.service
    green "✅ 后台监控已启动并保持运行"
}

# -------------------------------
# 查看节点状态
# -------------------------------
show_info() {
    if [[ ! -f "$NODE_INFO_FILE" ]]; then
        red "❌ 节点信息未找到"
        return
    fi
    source $NODE_INFO_FILE
    green "⚡ 当前节点信息:"
    echo "🌐 域名/IP: $DOMAIN"
    echo "⚡ 端口: $PORT"
    if systemctl is-active --quiet mtproto.service; then
        green "✅ 后端服务运行中"
    else
        red "❌ 后端服务未运行"
    fi
    timeout 2 bash -c "</dev/tcp/$DOMAIN/$PORT" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        green "✅ 端口可达，节点可用"
    else
        red "❌ 端口不可达，节点可能不可用"
    fi
}

# -------------------------------
# 功能面板主循环
# -------------------------------
while true; do
    echo
    green "================ MTProto 功能面板 (sb) ================"
    echo "1) 安装依赖"
    echo "2) 创建新节点"
    echo "3) 启动 MTProto 后端"
    echo "4) 启动后台监控与自愈"
    echo "5) 查看节点状态"
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
EOF'

# 设置可执行权限
sudo chmod +x /usr/local/bin/sb

# 添加 alias
if ! grep -q "alias sb=" ~/.bashrc; then
    echo "alias sb='/usr/local/bin/sb'" >> ~/.bashrc
fi
source ~/.bashrc

green "✅ 安装完成！登录 VPS 后直接输入 sb 调出 MTProto 面板"
}

# -------------------------------
# 执行安装
# -------------------------------
install_sb