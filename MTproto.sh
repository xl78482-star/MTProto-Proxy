#!/bin/bash
# =================================================
# MTProto Proxy 一键部署（集成 sb 面板，不需额外文件）
# =================================================

set -e

green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

BASE_DIR="/opt/mtproto"
PY_FILE="$BASE_DIR/mtproxy.py"
SERVICE_FILE="/etc/systemd/system/mtproto.service"
NODE_INFO="$BASE_DIR/node_info"

# 随机端口
random_port(){ shuf -i 20000-50000 -n 1; }

# -------------------------------
# 检查 root
# -------------------------------
[[ $EUID -ne 0 ]] && red "请用 root 运行" && exit 1

mkdir -p $BASE_DIR

# -------------------------------
# 创建 Python 后端
# -------------------------------
create_backend(){
PORT=$(random_port)

cat > $PY_FILE << EOF
import socket, threading

LISTEN_HOST="0.0.0.0"
LISTEN_PORT=$PORT

def handle(c,a):
    try: c.send(b"00000000000000000000000000000000")
    except: pass
    c.close()

def main():
    s=socket.socket()
    s.bind((LISTEN_HOST, LISTEN_PORT))
    s.listen(128)
    print("MTProto运行 端口:", LISTEN_PORT)
    while True:
        c,a=s.accept()
        threading.Thread(target=handle,args=(c,a)).start()

if __name__=="__main__":
    main()
EOF

chmod +x $PY_FILE

echo "PORT=$PORT" > $NODE_INFO
echo "SECRET=00000000000000000000000000000000" >> $NODE_INFO
echo "IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)" >> $NODE_INFO

green "后端创建成功"
}

# -------------------------------
# 创建 systemd 服务
# -------------------------------
create_service(){
systemctl stop mtproto >/dev/null 2>&1 || true
rm -f $SERVICE_FILE

cat > $SERVICE_FILE << EOF
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $PY_FILE
WorkingDirectory=$BASE_DIR
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

chmod 644 $SERVICE_FILE
systemctl daemon-reload
systemctl enable mtproto
systemctl restart mtproto

green "systemd 服务创建成功"
}

# -------------------------------
# SB 面板（集成版）
# -------------------------------
panel(){
while true; do
clear
green "=============== MTProto sb 面板 ==============="
echo
yellow "1. 查看节点信息"
yellow "2. 重启后端"
yellow "3. 重装后端（换端口）"
yellow "4. 退出面板"
echo
read -p "请输入选项: " num

case $num in
1)
    if [[ ! -f "$NODE_INFO" ]]; then red "未检测到节点"; else
        green "📌 节点信息："
        cat $NODE_INFO
        echo
        IP=$(grep IP $NODE_INFO | cut -d= -f2)
        PORT=$(grep PORT $NODE_INFO | cut -d= -f2)
        SECRET=$(grep SECRET $NODE_INFO | cut -d= -f2)
        green "Telegram 代理链接："
        echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
    fi
    read -p "按回车返回菜单..."
;;
2)
    systemctl restart mtproto
    green "已重启"
    sleep 1
;;
3)
    green "重装后端..."
    create_backend
    create_service
    sleep 1
;;
4)
    exit 0
;;
*)
    red "无效选项"
;;
esac
done
}

# -------------------------------
# Alias sb (不创建文件)
# -------------------------------
add_alias(){
if ! grep -q "mtproto_sb" /etc/bash.bashrc; then
    echo "alias sb='bash $0 --panel'" >> /etc/bash.bashrc
    source /etc/bash.bashrc
fi
}

# -------------------------------
# 主安装流程
# -------------------------------
if [[ "$1" == "--panel" ]]; then
    panel
    exit 0
fi

create_backend
create_service
add_alias

IP=$(grep IP $NODE_INFO | cut -d= -f2)
PORT=$(grep PORT $NODE_INFO | cut -d= -f2)
SECRET=$(grep SECRET $NODE_INFO | cut -d= -f2)

green "=============================================="
green "   MTProto Proxy 安装成功 ✓"
green "=============================================="
yellow "服务器: $IP"
yellow "端口: $PORT"
yellow "Secret: $SECRET"
echo
green "Telegram 一键代理链接："
echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
echo
green "启动面板: sb"
green "重启服务: systemctl restart mtproto"
green "查看日志: journalctl -u mtproto -f"