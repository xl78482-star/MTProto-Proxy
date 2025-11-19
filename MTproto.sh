#!/bin/bash
# ===============================================================
# MTProto Proxy sb 管理面板（智能升级版 v6）
# 功能：
# - 多端口多用户
# - FakeTLS 支持
# - 智能环境检测
# - 节点状态检测
# - 自动健康检测与修复
# - 一键生成 Telegram 客户端代理链接
# - 日志记录与查看功能
# - 多节点快速切换功能
# ===============================================================

green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

MT_DIR="/usr/local/mtproto"
MT_BIN="/usr/local/bin/sb"
MT_SERVICE="/etc/systemd/system/mtproto.service"
CONFIG_FILE="$MT_DIR/nodes.conf"
LOG_FILE="$MT_DIR/mtproto.log"

mkdir -p $MT_DIR

# ===============================================================
# 日志记录函数
# ===============================================================
log(){
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] $1" >> $LOG_FILE
}

# ===============================================================
# 公网 IP 检测
# ===============================================================
detect_ip(){
    IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me || curl -s ip.sb)
    if [[ -z "$IP" ]]; then
        red "❌ 自动检测失败，请手动输入 IP："
        read -p "输入 IP: " IP
    fi
}

# ===============================================================
# 生成 Secret
# ===============================================================
gen_secret(){
    openssl rand -hex 16
}

# ===============================================================
# 环境检测
# ===============================================================
detect_env(){
    CPU_CORES=$(nproc)
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    ping_time=$(ping -c 2 8.8.8.8 | tail -1| awk -F '/' '{print $5}')

    green "VPS 环境检测：CPU $CPU_CORES 核, 内存 $MEM_TOTAL MB, 网络延迟 $ping_time ms"

    if [[ $CPU_CORES -ge 4 && $MEM_TOTAL -ge 2048 ]]; then
        SCAN_PORT_COUNT=2000
        MAX_NODES=10
        FAKE_HOSTS=("www.gstatic.com" "www.google.com" "www.youtube.com")
    else
        SCAN_PORT_COUNT=500
        MAX_NODES=3
        FAKE_HOSTS=("www.gstatic.com")
    fi
}

# ===============================================================
# 根据环境选择最佳参数
# ===============================================================
select_best_params(){
    if [[ ${#FAKE_HOSTS[@]} -gt 0 ]]; then
        FAKE_HOST=${FAKE_HOSTS[$RANDOM % ${#FAKE_HOSTS[@]}]}
    else
        FAKE_HOST="www.gstatic.com"
    fi

    PORT=$(for port in $(shuf -i 20000-39999 -n $SCAN_PORT_COUNT); do
        if ! lsof -i:$port >/dev/null 2>&1; then
            echo $port
            break
        fi
    done)

    if [[ -z $PORT ]]; then
        red "❌ 未找到可用端口"
        exit 1
    fi
}

# ===============================================================
# 写入 systemd 服务
# ===============================================================
write_service(){
    cat > $MT_SERVICE <<EOF
[Unit]
Description=MTProto Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m mtproto_proxy --port $PORT --secret $SECRET --tls $FAKE_HOST
WorkingDirectory=$MT_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mtproto
    systemctl restart mtproto
}

# ===============================================================
# 保存节点信息
# ===============================================================
save_node(){
    echo "$PORT $SECRET $FAKE_HOST" >> $CONFIG_FILE
    log "创建新节点: 端口 $PORT | Secret $SECRET | FakeTLS $FAKE_HOST"
}

# ===============================================================
# 显示节点信息
# ===============================================================
show_nodes(){
    detect_ip
    if [[ ! -f $CONFIG_FILE ]]; then
        red "❌ 没有节点，请先创建"
        return
    fi
    echo "================= 节点列表 ================="
    while read port secret host; do
        LINK="tg://proxy?server=$IP&port=$port&secret=$secret"
        echo "端口: $port | Secret: $secret | FakeTLS域名: $host"
        echo "连接链接: $LINK"
        echo "-------------------------------------------"
    done < $CONFIG_FILE
}

# ===============================================================
# 节点状态检测
# ===============================================================
check_status(){
    detect_ip
    if [[ ! -f $CONFIG_FILE ]]; then
        red "❌ 没有节点，请先创建"
        return
    fi
    echo "================ 节点状态检测 ================"
    while read port secret host; do
        status_service="❌ 后端未运行"
        status_port="❌ 端口未监听"
        status_tcp="❌ 不可连通"

        if systemctl is-active --quiet mtproto; then
            status_service="✔ 后端运行中"
        fi

        if lsof -i:$port >/dev/null 2>&1; then
            status_port="✔ 端口已监听"
        fi

        if command -v nc >/dev/null 2>&1; then
            if nc -z -w3 $IP $port >/dev/null 2>&1; then
                status_tcp="✔ 可连通"
            fi
        fi

        echo "端口: $port | Secret: $secret | FakeTLS域名: $host"
        echo "状态: $status_service | $status_port | $status_tcp"
        echo "-------------------------------------------"
    done < $CONFIG_FILE
}

# ===============================================================
# 自动创建节点
# ===============================================================
auto_create(){
    detect_env
    select_best_params
    SECRET=$(gen_secret)
    save_node
    write_service
    show_nodes
}

# ===============================================================
# 手动添加节点
# ===============================================================
manual_add(){
    detect_env
    select_best_params
    SECRET=$(gen_secret)
    read -p "是否使用自动选择的端口和FakeTLS？(y/n) 默认y: " use_auto
    use_auto=${use_auto:-y}
    if [[ $use_auto == "n" ]]; then
        read -p "输入端口: " PORT
        read -p "输入 Secret: " SECRET
        read -p "输入 FakeTLS 域名（默认 www.gstatic.com）: " FAKE_HOST
        FAKE_HOST=${FAKE_HOST:-www.gstatic.com}
    fi
    save_node
    write_service
    show_nodes
}

# ===============================================================
# 健康检测与自动修复
# ===============================================================
health_check(){
    while true; do
        sleep 15
        if [[ ! -f $CONFIG_FILE ]]; then
            continue
        fi
        detect_ip
        while read port secret host; do
            restart_needed=0
            if ! systemctl is-active --quiet mtproto; then
                red "❌ 后端服务未运行，自动重启..."
                log "后端服务未运行，自动重启"
                restart_needed=1
            fi
            if ! lsof -i:$port >/dev/null 2>&1; then
                red "❌ 端口 $port 未监听，分配新端口..."
                log "端口 $port 未监听，分配新端口"
                PORT=$(for p in $(shuf -i 20000-39999 -n $SCAN_PORT_COUNT); do
                    if ! lsof -i:$p >/dev/null 2>&1; then
                        echo $p
                        break
                    fi
                done)
                restart_needed=1
            else
                PORT=$port
            fi
            if command -v nc >/dev/null 2>&1; then
                if ! nc -z -w3 $IP $PORT >/dev/null 2>&1; then
                    red "❌ 