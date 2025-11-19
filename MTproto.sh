#!/bin/bash
# ===============================================================
# MTProto Proxy sb 管理面板（智能升级版 v7.1）
# 功能：
# - 自动环境检测并安装依赖
# - 多端口多用户
# - FakeTLS 支持
# - 智能环境检测
# - 节点状态检测
# - 自动健康检测与修复（开机自启）
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
HEALTH_SERVICE="/etc/systemd/system/mtproto-health.service"
CONFIG_FILE="$MT_DIR/nodes.conf"
LOG_FILE="$MT_DIR/mtproto.log"
HEALTH_LOG="$MT_DIR/health.log"

mkdir -p $MT_DIR

# ===============================================================
# 0️⃣ 如果以 --health 参数启动，直接运行健康检查
# ===============================================================
if [[ "$1" == "--health" ]]; then
    source $MT_DIR/mtproto.sh
    detect_env
    health_check
    exit 0
fi

# ===============================================================
# 1️⃣ 环境检测与依赖安装
# ===============================================================
detect_and_install_env(){
    green "🔍 检测 VPS 系统环境..."
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
        PKG_UPDATE="apt update -y"
        PKG_INSTALL="apt install -y"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
        PKG_UPDATE="yum update -y"
        PKG_INSTALL="yum install -y"
    else
        red "❌ 不支持的系统，请使用 Debian/Ubuntu 或 CentOS"
        exit 1
    fi
    green "✔ 检测到系统: $OS"
    $PKG_UPDATE

    DEPENDENCIES=("python3" "python3-pip" "openssl" "lsof" "nc" "curl" "wget" "shuf")
    for pkg in "${DEPENDENCIES[@]}"; do
        if ! command -v $pkg >/dev/null 2>&1; then
            yellow "⚠ 缺失依赖: $pkg，正在安装..."
            $PKG_INSTALL $pkg
        else
            green "✔ 已安装依赖: $pkg"
        fi
    done

    if ! python3 -c "import mtproto_proxy" >/dev/null 2>&1; then
        yellow "⚠ mtproto_proxy 模块未安装，正在安装..."
        pip3 install mtproto_proxy
        green "✔ 安装完成 mtproto_proxy 模块"
    fi
    green "✔ 系统环境检测与依赖安装完成"
}

# ===============================================================
# 2️⃣ 日志函数
# ===============================================================
log(){
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] $1" >> $LOG_FILE
}

# ===============================================================
# 3️⃣ 公网 IP 检测
# ===============================================================
detect_ip(){
    IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me || curl -s ip.sb)
    if [[ -z "$IP" ]]; then
        red "❌ 自动检测失败，请手动输入 IP："
        read -p "输入 IP: " IP
    fi
}

# ===============================================================
# 4️⃣ 生成 Secret
# ===============================================================
gen_secret(){ openssl rand -hex 16; }

# ===============================================================
# 5️⃣ 环境检测
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
# 6️⃣ 选择端口和 FakeTLS
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
# 7️⃣ 写 systemd 服务
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
# 8️⃣ 保存节点信息
# ===============================================================
save_node(){
    echo "$PORT $SECRET $FAKE_HOST" >> $CONFIG_FILE
    log "创建新节点: 端口 $PORT | Secret $SECRET | FakeTLS $FAKE_HOST"
}

# ===============================================================
# 9️⃣ 显示节点信息
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
# 10️⃣ 节点状态检测
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

        if systemctl is-active --quiet mtproto; then status_service="✔ 后端运行中"; fi
        if lsof -i:$port >/dev/null 2>&1; then status_port="✔ 端口已监听"; fi
        if command -v nc >/dev/null 2>&1; then
            if nc -z -w3 $IP $port >/dev/null 2>&1; then status_tcp="✔ 可连通"; fi
        fi

        echo "端口: $port | Secret: $secret | FakeTLS域名: $host"
        echo "状态: $status_service | $status_port | $status_tcp"
        echo "-------------------------------------------"
    done < $CONFIG_FILE
}

# ===============================================================
# 11️⃣ 自动创建节点
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
# 12️⃣ 手动添加节点
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
# 13️⃣ 健康检测与自动修复
# ===============================================================
health_check(){
    while true; do
        sleep 15
        if [[ ! -f $CONFIG_FILE ]]; then continue; fi
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
                    if ! lsof -i:$p >/dev/null 2>&1; then echo $p; break; fi
                done)
                restart_needed=1
            else
                PORT=$port
            fi
            if command -v nc >/dev/null 2>&1; then
                if ! nc -z -w3 $IP $PORT >/dev/null 2>&1; then
                    red "❌ TCP 不可连通，重启节点..."
                    log "端口 $PORT TCP 不可连通，重启节点"
                    restart_needed=1
                fi
            fi
            if [[ $restart_needed -eq 1 ]]; then
                systemctl restart mtproto
                green "✔ 节点端口 $PORT 修复完成"
                log "节点端口 $PORT 修复完成"
                sed -i "/$port $secret $host/c\\$PORT $secret $host" $CONFIG_FILE
            fi
        done < $CONFIG_FILE
    done
}

start_health_check(){
    if pgrep -f "health_check" >/dev/null 2>&1; then
        yellow "⚠ 健康检测已在运行"
    else
        nohup bash -c "source $MT_DIR/mtproto.sh; detect_env; health_check" >> $HEALTH_LOG 2>&1 &
        green "✔ 健康检测后台任务已启动，每15秒自动修复节点"
    fi
}

# ===============================================================
# 14️⃣ 设置健康检查开机自启
# ===============================================================
setup_health_service(){
    cat > $HEALTH_SERVICE <<EOF
[Unit]
Description=MTProto Health Check Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $MT_DIR/mtproto.sh --health
WorkingDirectory=$MT_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtproto-health
    systemctl start mtproto-health
    green "✔ 健康检测服务 mtproto-health 已设置开机自启"
}

# ===============================================================
# 15️⃣ Telegram 代理链接
# ===============================================================
generate_telegram_links(){
    detect_ip
    if [[ ! -f $CONFIG_FILE ]]; then
        red "❌ 没有节点，请先创建"
        return
    fi
    LINKS_FILE="$MT_DIR/links.txt"
    > $LINKS_FILE
    echo "================ Telegram 代理链接 =================" >> $LINKS_FILE
    while read port secret host; do
        LINK="tg://proxy?server=$IP&port=$port&secret=$secret"
        echo "$LINK"
        echo "$LINK" >> $LINKS_FILE
    done < $CONFIG_FILE
    green "✔ Telegram 代理链接已生成，保存在 $LINKS_FILE"
    yellow "可直接复制链接到客户端使用"
}

# ===============================================================
# 16️⃣ 多节点快速切换
# ===============================================================
switch_node(){
    detect_ip
    if [[ ! -f $CONFIG_FILE ]]; then
        red "❌ 没有节点，请先创建"
        return
    fi
    echo "================= 可用节点列表 ================="
    i=1
    NODE_LIST=()
    while read port secret host; do
        echo "$i) 端口: $port | Secret: $secret | FakeTLS域名: $host"
        NODE_LIST+=("$port $secret $host")
        ((i++))
    done < $CONFIG_FILE

    read -p "请选择要切换的节点编号: " choice
    if [[ $choice -lt 1 || $choice -gt ${#NODE_LIST[@]} ]]; then
        red "❌ 无效选择"
        return
    fi

    SELECTED_NODE=${NODE_LIST[$choice-1]}
    PORT=$(echo $SELECTED_NODE | awk '{print $1}')
    SECRET=$(echo $SELECTED_NODE | awk '{print $2}')
    FAKE_HOST=$(echo $SELECTED_NODE | awk '{print $3}')

    write_service
    systemctl restart mtproto
    green "✔ 已切换到节点端口 $PORT | Secret $SECRET | FakeTLS $FAKE_HOST"
    log "切换节点: 端口 $PORT | Secret $SECRET | FakeTLS $FAKE_HOST"
}

# ===============================================================
# 17️⃣ sb 面板菜单
# ===============================================================
panel(){
while true; do
clear
echo "========================================"
echo "       MTProto sb 管理面板（智能升级版 v7.1）"
echo "========================================"
echo "1. 自动创建节点"
echo "2. 手动添加节点"
echo "3. 查看节点信息"
echo "4. 节点状态检测"
echo "5. 重启后端"
echo "6. 停止后端"
echo "7. 卸载服务"
echo "8. 退出"
echo "9. 启动健康检测后台任务"
echo "10. 生成 Telegram 客户端代理链接"
echo "11. 查看健康检测与节点日志"
echo "12. 多节点快速切换"
echo "========================================"
read -p "请选择: " num

case $num in
    1) auto_create ;;
    2) manual_add ;;
    3) show_nodes ;;
    4) check_status ;;
    5) systemctl restart mtproto; green '✔ 已重启' ;;
    6) systemctl stop mtproto; green '✔ 已停止' ;;
    7)
        systemctl stop mtproto
        systemctl stop mtproto-health
        systemctl disable mtproto
        systemctl disable mtproto-health
        rm -f $MT_SERVICE $HEALTH_SERVICE
        rm -rf $MT_DIR
        rm -f $MT_BIN
        systemctl daemon-reload
        green "✔ 服务已卸载，sb 命令已移除"
        exit 0
    ;;
    8) exit 0 ;;
    9) start_health_check ;;
    10) generate_telegram_links ;;
    11)
        if [[ -f $LOG_FILE ]]; then
            less $LOG_FILE
        else
            red "❌ 日志文件不存在"
        fi
    ;;
    12) switch_node ;;
    *) red "❌ 无效选择" ;;
esac
read -p "按回车返回菜单..." tmp
done
}

# ===============================================================
# 18️⃣ 安装 sb 命令
# ===============================================================
install_sb(){
cat > $MT_BIN <<EOF
#!/bin/bash
bash $MT_DIR/mtproto.sh
EOF
chmod +x $MT_BIN
cp "$0" $MT_DIR/mtproto.sh

green "✔ sb 面板已安装"
yellow "现在可用命令： sb"
}

# ===============================================================
# 主程序
# ===============================================================
detect_and_install_env
install_sb
setup_health_service
panel
