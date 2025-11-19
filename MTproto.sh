#!/bin/bash
# =================================================
# 一键部署 MTProto Proxy + 智能后台检测自愈 + 最优 DC
# 带节点创建选择 + 自动读取已有节点
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
# 检查 Python3 和依赖
# -------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    red "Python3 未安装，请先安装 Python3"
    exit 1
fi

if ! command -v pip3 >/dev/null 2>&1; then
    yellow "pip3 未安装，尝试自动安装..."
    apt-get update && apt-get install -y python3-pip || yum install -y python3-pip
fi

pip3 install --no-cache-dir uvloop pycryptodome >/dev/null 2>&1 || true

# -------------------------------
# 创建目录
# -------------------------------
mkdir -p /opt/mtproto
NODE_INFO_FILE="/opt/mtproto/node_info"

# -------------------------------
# 选择操作
# -------------------------------
echo "请选择操作："
echo "1) 创建新的 MTProto 节点"
echo "2) 跳过节点创建（使用已有节点）"
read -p "输入 1 或 2: " choice

if [[ "$choice" == "1" ]]; then
    # -------------------------------
    # 用户输入
    # -------------------------------
    read -p "请输入你的域名或 VPS IP（用于 Telegram 代理）: " DOMAIN
    read -p "请输入 MTProto 端口（留空随机中高端端口）: " PORT

    # -------------------------------
    # 生成随机端口
    # -------------------------------
    if [[ -z "$PORT" ]]; then
        while true; do
            PORT=$((RANDOM % 20001 + 20000))
            if ! lsof -i:$PORT >/dev/null 2>&1; then
                break
            fi
        done
        yellow "⚡ 使用随机中高端端口: $PORT"
    fi

    green "🚀 开始部署 MTProto Proxy …"

    # -------------------------------
    # 生成 dd-secret
    # -------------------------------
    SECRET=$(openssl rand -hex 16)
    green "🔑 生成 dd-secret: dd$SECRET"

    # -------------------------------
    # 写入后端 Python 程序
    # -------------------------------
    cat <<EOF > /opt/mtproto/mtproto_backend.py
import os, uvloop, asyncio, hashlib
from Crypto.Cipher import AES
from Crypto.Util import Counter

LISTEN = ("0.0.0.0", $PORT)
SECRET = bytes.fromhex("$SECRET")
TELEGRAM_DCS = [
    ("149.154.167.50", 443),
    ("149.154.167.91", 443),
    ("149.154.167.92", 443),
    ("173.240.5.253", 443),
]

def aes_key(iv, secret):
    return hashlib.sha256(iv + secret).digest()

def aes_ctr(data, key, iv):
    ctr = Counter.new(128, initial_value=int.from_bytes(iv, 'big'))
    cipher = AES.new(key, AES.MODE_CTR, counter=ctr)
    return cipher.encrypt(data)

async def pump(reader, writer, key, iv):
    try:
        while True:
            data = await reader.read(4096)
            if not data:
                break
            writer.write(aes_ctr(data, key, iv))
            await writer.drain()
    except:
        pass
    finally:
        writer.close()
        await writer.wait_closed()

async def handle(reader, writer):
    try:
        iv = os.urandom(16)
        key = aes_key(iv, SECRET)
        import random
        dc_ip, dc_port = TELEGRAM_DCS[random.randint(0,len(TELEGRAM_DCS)-1)]
        tg_reader, tg_writer = await asyncio.open_connection(dc_ip, dc_port)
        await asyncio.gather(
            pump(reader, tg_writer, key, iv),
            pump(tg_reader, writer, key, iv),
        )
    except:
        pass
    finally:
        writer.close()
        await writer.wait_closed()

async def main():
    print(f"[] MTProto 后端运行: {LISTEN[0]}:{LISTEN[1]}")
    print(f"[] dd-secret: dd$SECRET")
    server = await asyncio.start_server(handle, *LISTEN)
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    uvloop.install()
    asyncio.run(main())
EOF

    # -------------------------------
    # 创建 systemd 服务 - MTProto 后端
    # -------------------------------
    cat <<EOF >/etc/systemd/system/mtproto.service
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/mtproto/mtproto_backend.py
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

    # -------------------------------
    # 防火墙开放端口
    # -------------------------------
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $PORT/tcp >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
    fi

    # -------------------------------
    # 保存节点信息到文件
    # -------------------------------
    echo "PORT=$PORT" > $NODE_INFO_FILE
    echo "SECRET=dd$SECRET" >> $NODE_INFO_FILE
    echo "DOMAIN=$DOMAIN" >> $NODE_INFO_FILE

    green "━━━━━━━━━━━━━━━━━━━━━━━━"
    green "✅ MTProto Proxy 已安装完成并后台运行（systemd 自启）！"
    green "👉 MTProto 监听端口: $PORT"
    green "👉 dd-secret: dd$SECRET"
    green "━━━━━━━━━━━━━━━━━━━━━━━━"

elif [[ "$choice" == "2" ]]; then
    # -------------------------------
    # 读取已有节点信息
    # -------------------------------
    if [[ ! -f "$NODE_INFO_FILE" ]]; then
        red "❌ 没有找到已有节点信息文件 $NODE_INFO_FILE，请先创建节点"
        exit 1
    fi
    source $NODE_INFO_FILE
    green "⚡ 已读取已有节点信息: PORT=$PORT, SECRET=$SECRET, DOMAIN=$DOMAIN"
else
    red "输入错误，请输入 1 或 2"
    exit 1
fi

# -------------------------------
# 写入后台检测与自愈脚本
# -------------------------------
cat <<EOF >/opt/mtproto/mtproto_monitor.sh
#!/bin/bash
NODE_INFO_FILE="$NODE_INFO_FILE"
DETECT_INTERVAL=15
TELEGRAM_DCS=("149.154.167.50" "149.154.167.91" "149.154.167.92" "173.240.5.253")

green() { echo -e "\033[32m\$1\033[0m"; }
yellow() { echo -e "\033[33m\$1\033[0m"; }
red() { echo -e "\033[31m\$1\033[0m"; }

# 读取节点信息
if [[ ! -f "\$NODE_INFO_FILE" ]]; then
    red "❌ 节点信息文件未找到，无法启动检测"
    exit 1
fi
source \$NODE_INFO_FILE

while true; do
    echo
    green "🔍 后端状态检测（每 \$DETECT_INTERVAL 秒刷新）…"

    if systemctl is-active --quiet mtproto.service; then
        green "✅ 后端服务正在运行"
    else
        red "❌ 后端服务未运行，尝试启动..."
        systemctl start mtproto.service
        sleep 2
        if systemctl is-active --quiet mtproto.service; then
            green "✅ 后端服务已启动成功"
        else
            red "❌ 后端服务启动失败，请检查日志"
        fi
    fi

    if lsof -i:\$PORT >/dev/null 2>&1; then
        green "✅ 端口 \$PORT 正常监听"
    else
        red "❌ 端口 \$PORT 未监听，尝试重启后端服务..."
        systemctl restart mtproto.service
        sleep 2
        if lsof -i:\$PORT >/dev/null 2>&1; then
            green "✅ 端口 \$PORT 已正常监听"
        else
            red "❌ 端口 \$PORT 仍未监听，请检查防火墙或日志"
        fi
    fi

    BEST_DC=""
    LOWEST_MS=999
    for dc in "\${TELEGRAM_DCS[@]}"; do
        PING_MS=\$(ping -c 1 -W 1 \$dc 2>/dev/null | grep 'time=' | awk -F'time=' '{print \$2}' | awk '{print \$1}')
        if [[ -n "\$PING_MS" ]]; then
     