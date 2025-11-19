#!/bin/bash
# =================================================
# 一键部署官方 MTProto Proxy + 多端口自动降级 + 后台检测
# =================================================

set -e

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# -------------------------------
# 检查 root
# -------------------------------
if [[ $EUID -ne 0 ]]; then
    red "请使用 root 权限运行该脚本！"
    exit 1
fi

# -------------------------------
# 安装依赖
# -------------------------------
apt-get update && apt-get install -y python3-pip git >/dev/null 2>&1 || yum install -y python3-pip git
pip3 install --no-cache-dir mtprotoproxy >/dev/null 2>&1 || true

# -------------------------------
# 创建目录
# -------------------------------
mkdir -p /opt/mtproto
NODE_INFO_FILE="/opt/mtproto/node_info"

# -------------------------------
# 检测端口可达性函数
# -------------------------------
check_port() {
    local host=$1
    local port=$2
    timeout 2 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1 && return 0 || return 1
}

# -------------------------------
# 选择操作
# -------------------------------
echo "请选择操作："
echo "1) 创建新的 MTProto 节点"
echo "2) 跳过节点创建（使用已有节点）"
read -p "输入 1 或 2: " choice

if [[ "$choice" == "1" ]]; then
    read -p "请输入你的域名或 VPS IP（用于 Telegram 代理）: " DOMAIN
    read -p "请输入 MTProto 端口（留空随机高端）: " PORT

    [[ -z "$PORT" ]] && PORT=$((RANDOM % 20001 + 20000))

    # 自动端口降级尝试
    PORTS_TO_TRY=($PORT 443 80 25 110)
    PORT_OK=0
    for p in "${PORTS_TO_TRY[@]}"; do
        if check_port $DOMAIN $p; then
            PORT=$p
            PORT_OK=1
            green "✅ 选择端口 $PORT 可用"
            break
        fi
    done
    if [[ $PORT_OK -ne 1 ]]; then
        red "❌ 所有常用端口均不可用，请检查 VPS 防火墙或安全组"
        exit 1
    fi

    # 生成 dd-secret
    SECRET=$(openssl rand -hex 16)
    green "🔑 dd-secret: dd$SECRET"

    # 保存节点信息
    echo "PORT=$PORT" > $NODE_INFO_FILE
    echo "SECRET=dd$SECRET" >> $NODE_INFO_FILE
    echo "DOMAIN=$DOMAIN" >> $NODE_INFO_FILE

    # -------------------------------
    # 写官方 MTProto Proxy 配置文件
    # -------------------------------
    cat <<EOF >/opt/mtproto/config.py
# -*- coding: utf-8 -*-
PORT = $PORT
USERS = {
    "dd$SECRET": 100,
}
DEBUG = False
TG_DOMAIN = "$DOMAIN"
EOF

elif [[ "$choice" == "2" ]]; then
    # 使用已有节点
    if [[ ! -f "$NODE_INFO_FILE" ]]; then
        red "❌ 没有找到已有节点信息，请先创建节点"
        exit 1
    fi
    source $NODE_INFO_FILE
    DOMAIN=${DOMAIN:-$DOMAIN}
    PORT=${PORT:-$PORT}
    SECRET=${SECRET:-$SECRET}
    green "⚡ 已读取已有节点信息: PORT=$PORT, SECRET=$SECRET, DOMAIN=$DOMAIN"
else
    red "输入错误，请输入 1 或 2"
    exit 1
fi

# -------------------------------
# 创建 systemd 服务（MTProto 后端）
# -------------------------------
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
green "✅ MTProto Proxy 后端已启动"

# -------------------------------
# 后台检测与自愈（多端口自动降级）
# -------------------------------
cat <<'EOF' >/opt/mtproto/mtproto_monitor.sh
#!/bin/bash
NODE_INFO_FILE="/opt/mtproto/node_info"
DETECT_INTERVAL=15
TELEGRAM_DCS=("149.154.167.50" "149.154.167.91" "149.154.167.92" "173.240.5.253")
PORTS_TO_TRY=()

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

check_port() {
    local host=$1
    local port=$2
    timeout 2 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1 && return 0 || return 1
}

if [[ ! -f "$NODE_INFO_FILE" ]]; then
    red "❌ 节点信息文件未找到"
    exit 1
fi
source $NODE_INFO_FILE

# 初始化端口尝试顺序
PORTS_TO_TRY=($PORT 443 80 25 110)

while true; do
    echo
    green "🔍 检测 MTProto 后端服务…"

    if systemctl is-active --quiet mtproto.service; then
        green "✅ 后端服务运行中"
    else
        red "❌ 服务未运行，尝试启动"
        systemctl start mtproto.service
    fi

    PORT_OK=0
    for p in "${PORTS_TO_TRY[@]}"; do
        if check_port $DOMAIN $p; then
            if [[ "$p" != "$PORT" ]]; then
                yellow "⚠️ 当前端口 $PORT 不可达，自动切换到 $p"
                PORT=$p
                sed -i "s/^PORT = .*/PORT = $PORT/" /opt/mtproto/config.py
                systemctl restart mtproto.service
            fi
            PORT_OK=1
            green "✅ 端口 $PORT 可用"
            break
        fi
    done

    if [[ $PORT_OK -ne 1 ]]; then
        red "❌ 所有常用端口均不可用，请检查 VPS 防火墙或安全组"
    fi

    BEST_DC=""
    LOWEST_MS=999
    for dc in "${TELEGRAM_DCS[@]}"; do
        PING_MS=$(ping -c 1 -W 1 $dc 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}')
        if [[ -n "$PING_MS" ]]; then
            PING_INT=${PING_MS%.*}
            if [[ $PING_INT -lt $LOWEST_MS ]]; then
                LOWEST_MS=$PING_INT
                BEST_DC=$dc
            fi
        fi
    done

    if [[ -n "$BEST_DC" ]]; then
        green "👉 最优 DC: $BEST_DC (延迟 ${LOWEST_MS}ms)"
        echo "tg://proxy?server=$BEST_DC&port=$PORT&secret=$SECRET"
    else
        yellow "⚠️ 无法检测到 DC 延迟，使用默认域名生成链接"
        echo "tg://proxy?server=$DOMAIN&port=$PORT&secret=$SECRET"
    fi

    sleep $DETECT_INTERVAL
done
EOF

chmod +x /opt/mtproto/mtproto_monitor.sh

# -------------------------------
# systemd 服务（后台检测）
# -------------------------------
cat <<EOF >/etc/systemd/system/mtproto-monitor.service
[Unit]
Description=MTProto 后端检测与最优 DC
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

green "✅ 后台检测与自愈已启动，日志: /opt/mtproto/mtproto_monitor.log"
green "🎉 部署完成，Telegram 代理链接可在日志中查看"