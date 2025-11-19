#!/bin/bash
# ===============================================================
# MTProto Proxy sb 管理面板（智能升级版 v7.2 完整版）
# ===============================================================

green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

# ===============================================================
# 0️⃣ 自动检测依赖并安装（已安装跳过）
# ===============================================================
DEPENDENCIES=("git" "curl" "wget" "python3" "python3-pip" "openssl" "lsof" "nc" "shuf")

echo "🔍 检查依赖..."
MISSING_DEPS=()
for pkg in "${DEPENDENCIES[@]}"; do
    if ! command -v $pkg >/dev/null 2>&1; then
        MISSING_DEPS+=("$pkg")
    else
        green "✔ 已安装: $pkg"
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    yellow "⚠ 缺失依赖，将自动安装: ${MISSING_DEPS[*]}"
    if [[ -f /etc/debian_version ]]; then
        apt update -y
        apt install -y "${MISSING_DEPS[@]}" || { red "❌ 安装失败"; exit 1; }
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y "${MISSING_DEPS[@]}" || { red "❌ 安装失败"; exit 1; }
    else
        red "❌ 不支持的系统，请手动安装: ${MISSING_DEPS[*]}"
        exit 1
    fi
fi

# 再次确认所有依赖
FAILED_DEPS=()
for pkg in "${DEPENDENCIES[@]}"; do
    if ! command -v $pkg >/dev/null 2>&1; then
        FAILED_DEPS+=("$pkg")
    fi
done

if [ ${#FAILED_DEPS[@]} -gt 0 ]; then
    red "❌ 以下依赖安装失败: ${FAILED_DEPS[*]}"
    exit 1
else
    green "✔ 所有依赖已安装或已存在，继续执行脚本"
fi

# 安装 Python mtproto_proxy 模块
if ! python3 -c "import mtproto_proxy" >/dev/null 2>&1; then
    yellow "⚠ mtproto_proxy 模块未安装，正在安装..."
    pip3 install mtproto_proxy || { red "❌ mtproto_proxy 安装失败"; exit 1; }
    green "✔ mtproto_proxy 模块安装成功"
else
    green "✔ mtproto_proxy 模块已安装"
fi

# ===============================================================
# 1️⃣ 基础路径和日志
# ===============================================================
MT_DIR="/usr/local/mtproto"
MT_BIN="/usr/local/bin/sb"
MT_SERVICE="/etc/systemd/system/mtproto.service"
CONFIG_FILE="$MT_DIR/nodes.conf"
LOG_FILE="$MT_DIR/mtproto.log"

mkdir -p $MT_DIR

log(){ TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S"); echo "[$TIMESTAMP] $1" >> $LOG_FILE; }

# ===============================================================
# 2️⃣ 公网 IP 检测
# ===============================================================
detect_ip(){
    IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me || curl -s ip.sb)
    if [[ -z "$IP" ]]; then
        red "❌ 自动检测失败，请手动输入 IP："
        read -p "输入 IP: " IP
    fi
}

# ===============================================================
# 3️⃣ 生成 Secret
# ===============================================================
gen_secret(){ openssl rand -hex 16; }

# ===============================================================
# 4️⃣ 环境检测
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
# 5️⃣ 选择端口和 FakeTLS
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
# 6️⃣ 写 systemd 服务
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
# 7️⃣ 节点操作函数（完整展开）
# ===============================================================
save_node(){ echo "$PORT $SECRET $FAKE_HOST" >> $CONFIG_FILE; log "创建节点: $PORT $SECRET $FAKE_HOST"; }

show_nodes(){
    detect_ip
    [[ ! -f $CONFIG_FILE ]] && { red "❌ 没有节点"; return; }
    echo "================ 节点列表 ================="
    while read port secret host; do
        LINK="tg://proxy?server=$IP&port=$port&secret=$secret"
        echo "端口: $port | Secret: $secret | FakeTLS: $host"
        echo "链接: $LINK"
        echo "-------------------------------------------"
    done < $CONFIG_FILE
}

check_status(){
    detect_ip
    [[ ! -f $CONFIG_FILE ]] && { red "❌ 没有节点"; return; }
    echo "================ 节点状态检测 ================"
    while read port secret host; do
        status_service="❌ 后端未运行"; status_port="❌ 端口未监听"; status_tcp="❌ 不可连通"
        systemctl is-active --quiet mtproto && status_service="✔ 后端运行中"
        lsof -i:$port >/dev/null 2>&1 && status_port="✔ 端口已监听"
        command -v nc >/dev/null 2>&1 && nc -z -w3 $IP $port >/dev/null 2>&1 && status_tcp="✔ 可连通"
        echo "端口: $port | Secret: $secret | FakeTLS: $host"
        echo "状态: $status_service | $status_port | $status_tcp"
        echo "-------------------------------------------"
    done < $CONFIG_FILE
}

auto_create(){
    detect_env; select_best_params; SECRET=$(gen_secret)
    save_node; write_service; show_nodes
}

manual_add(){
    detect_env; select_best_params; SECRET=$(gen_secret)
    read -p "使用自动端口和FakeTLS? (y/n) 默认y: " use_auto; use_auto=${use_auto:-y}
    if [[ $use_auto == "n" ]]; then
        read -p "输入端口: " PORT
        read -p "输入 Secret: " SECRET
        read -p "输入 FakeTLS 域名 (默认 www.gstatic.com): " FAKE_HOST; FAKE_HOST=${FAKE_HOST:-www.gstatic.com}
    fi
    save_node; write_service; show_nodes
}

health_check(){
    while true; do
        sleep 15
        [[ ! -f $CONFIG_FILE ]] && continue
        detect_ip
        while read port secret host; do
            restart_needed=0
            ! systemctl is-active --quiet mtproto && { log "后端未运行，重启"; restart_needed=1; }
            ! lsof -i:$port >/dev/null 2>&1 && { PORT=$(for p in $(shuf -i 20000-39999 -n $SCAN_PORT_COUNT); do lsof -i:$p >/dev/null 2>&1 || echo $p; done); restart_needed=1; }
            command -v nc >/dev/null 2>&1 && ! nc -z -w3 $IP $PORT >/dev/null 2>&1 && restart_needed=1
            [[ $restart_needed -eq 1 ]] && systemctl restart mtproto && log "节点 $PORT 修复完成"
        done < $CONFIG_FILE
    done
}

start_health_check(){
    pgrep -f "health_check" >/dev/null 2>&1 && { yellow "⚠ 健康检测已在运行"; return; }
    nohup bash -c 'source /usr/local/mtproto/MTProto_sb_v7.2_full.sh; detect_env; health_check' >/dev/null 2>&1 &
    green "✔ 健康检测后台任务已启动，每15秒自动修复节点"
}

generate_telegram_links(){
    detect_ip
    [[ ! -f $CONFIG_FILE ]] && { red "❌ 没有节点"; return; }
    LINKS_FILE="$MT_DIR/links.txt"; >$LINKS_FILE
    while read port secret host; do
        LINK="tg://proxy?server=$IP&port=$port&secret=$secret"
        echo "$LINK" >> $LINKS_FILE
        echo "$LINK"
    done < $CONFIG_FILE
    green "✔ Telegram 代理链接已生成: $LINKS_FILE"
}

switch_node(){
    detect_ip
    [[ ! -f $CONFIG_FILE ]] && { red "❌ 没有节点"; return; }
    echo "================= 可用节点列表 ================="
    i=1; NODE_LIST=()
    while read port secret host; do
        echo "$i) 端口: $port | Secret: $secret | FakeTLS: $host"
        NODE_LIST+=("$port $secret $host"); ((i++))
    done < $CONFIG_FILE
    read -p "选择节点编号: " choice
    [[ $choice -lt 1 || $choice -gt ${#NODE_LIST[@]} ]] && { red "❌ 无效选择"; return; }
    SELECTED_NODE=${NODE_LIST[$choice-1]}
    PORT=$(echo $SELECTED_NODE | awk '{print $1}'); SECRET=$(echo $SELECTED_NODE | awk '{print $2}'); FAKE_HOST=$(echo $SELECTED_NODE | awk '{print $3}')
    write_service; systemctl restart mtproto; green "✔ 已切换到节点 $PORT"
}

# ===============================================================
# 8️⃣ 面板菜单
# ===============================================================
panel(){
while true; do
clear
echo "========================================"
echo "       MTProto sb 管理面板 v7.2 完整版"
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
echo "11. 查看日志"
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
        systemctl disable mtproto
        rm -f $MT_SERVICE
        rm -rf $MT_DIR
        rm -f $MT_BIN
        systemctl daemon-reload
        green "✔ 服务已卸载"
        exit 0
    ;;
    8) exit 0 ;;
    9) start_health_check ;;
    10) generate_telegram_links ;;
    11) [[ -f $LOG_FILE ]] && less $LOG_FILE || red "❌ 日志不存在" ;;
    12) switch_node ;;
    *) red "❌ 无效选择" ;;
esac
read -p "按回车返回菜单..." tmp
done
}

# ===============================================================
# 9️⃣ 安装 sb 命令
# ===============================================================
install_sb(){
cat > $MT_BIN <<EOF
#!/bin/bash
bash /usr/local/mtproto/MTProto_sb_v7.2_full.sh
EOF
chmod +x $MT_BIN
cp "$0" /usr/local/mtproto/MTProto_sb_v7.2_full.sh
green "✔ sb 面板已安装"
yellow "现在可用命令： sb"
}

install_sb
panel
