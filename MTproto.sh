#!/bin/bash
# =================================================
# 一键部署 MTProto Proxy（Python 后端直连 + 中高端随机端口 + systemd 自启）
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
# 用户输入
# -------------------------------
read -p "请输入你的域名或 VPS IP（用于 Telegram 代理）: " DOMAIN
read -p "请输入 MTProto 端口（留空随机中高端端口）: " PORT

# -------------------------------
# 生成随机端口（并检查是否占用）
# -------------------------------
if [[ -z "$PORT" ]]; then
    while true; do
        PORT=$((RANDOM % 20001 + 20000))  # 20000-40000
        if ! lsof -i:$PORT >/dev/null 2>&1; then
            break
        fi
    done
    yellow "⚡ 使用随机中高端端口: $PORT"
fi

green "🚀 开始部署 MTProto Proxy …"

# -------------------------------
# 创建目录
# -------------------------------
mkdir -p /opt/mtproto
cd /opt/mtproto

# -------------------------------
# 生成 dd-secret
# -------------------------------
SECRET=$(openssl rand -hex 16)
green "🔑 生成 dd-secret: dd$SECRET"

# -------------------------------
# 写入后端 Python 程序
# -------------------------------
cat <<EOF > mtproto_backend.py
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
        dc_ip, dc_port = TELEGRAM_DCS[os.urandom(1)[0] % len(TELEGRAM_DCS)]
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
# 创建 systemd 服务
# -------------------------------
cat <<EOF >/etc/systemd/system/mtproto.service
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/mtproto/mtproto_backend.py
Restart=always
WorkingDirectory=/opt/mtproto
StandardOutput=append:/opt/mtproto/mtproto.log
StandardError=append:/opt/mtproto/mtproto.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtproto.service
systemctl start mtproto.service

# -------------------------------
# 输出 Telegram 链接
# -------------------------------
green "━━━━━━━━━━━━━━━━━━━━━━━━"
green "✅ MTProto Proxy 已安装完成并后台运行（systemd 自启）！"
green "👉 MTProto 监听端口: $PORT"
green "👉 dd-secret: dd$SECRET"
green "👉 Telegram 代理链接:"
echo "tg://proxy?server=$DOMAIN&port=$PORT&secret=dd$SECRET"
green "━━━━━━━━━━━━━━━━━━━━━━━━"
green "查看后端日志: tail -f /opt/mtproto/mtproto.log"
yellow "⚠️ 确保 VPS 防火墙允许 $PORT 入站"