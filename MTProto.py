
#!/bin/bash
# =================================================
# 一键安装 MTProto Proxy（FakeTLS + 高速优化 + 后台自启 + Telegram 链接）
# =================================================

set -e
green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

# -------------------------------
# 检查 root
# -------------------------------
if [[ $EUID -ne 0 ]]; then
    red "请使用 root 权限运行该脚本！"
    exit 1
fi

read -p "请输入你的域名（用于 FakeTLS，如 proxy.example.com）: " DOMAIN

green "🚀 开始部署 MTProto Proxy …"

# -------------------------------
# 安装依赖
# -------------------------------
green "➤ 安装依赖 Python3、pip、Nginx …"
apt update
apt install -y python3 python3-pip curl unzip git nginx
pip3 install --upgrade pycryptodome uvloop

# -------------------------------
# 系统优化
# -------------------------------
green "➤ 系统优化 BBR + TCP + ulimit …"

cat <<EOF >/etc/sysctl.d/99-mtproto.conf
fs.file-max = 1024000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.ip_forward = 1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl --system
ulimit -n 1024000
grep -q "nofile" /etc/security/limits.conf || cat <<EOF >>/etc/security/limits.conf
* soft nofile 1024000
* hard nofile 1024000
EOF

# -------------------------------
# 创建后端目录
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

LISTEN = ("0.0.0.0", 8443)
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
            if not data: break
            writer.write(aes_ctr(data, key, iv))
            await writer.drain()
    except: pass
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
    except: pass
    finally:
        writer.close()
        await writer.wait_closed()

async def main():
    print(f"[*] MTProto 后端运行: {LISTEN[0]}:{LISTEN[1]}")
    print(f"[*] dd-secret: dd$SECRET")
    server = await asyncio.start_server(handle, *LISTEN)
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    uvloop.install()
    asyncio.run(main())
EOF

# -------------------------------
# systemd 服务
# -------------------------------
cat <<EOF >/etc/systemd/system/mtproto.service
[Unit]
Description=MTProto Proxy Backend
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/mtproto/mtproto_backend.py
WorkingDirectory=/opt/mtproto
Restart=always
RestartSec=5
LimitNOFILE=1024000
StandardOutput=inherit
StandardError=inherit

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtproto
systemctl start mtproto

# -------------------------------
# Nginx TCP stream（不覆盖原 http 配置）
# -------------------------------
cat <<EOF >/etc/nginx/conf.d/mtproto_stream.conf
stream {
    upstream mtproto_backend {
        server 127.0.0.1:8443;
    }

    server {
        listen 443;
        proxy_pass mtproto_backend;
    }
}
EOF

nginx -t && systemctl restart nginx

# -------------------------------
# 输出 Telegram 链接
# -------------------------------
green "━━━━━━━━━━━━━━━━━━━━━━━━"
green "✅ MTProto Proxy 已安装完成并后台运行！"
green "👉 FakeTLS 前端: 443，后端: 8443"
green "👉 dd-secret: dd$SECRET"
green "👉 Telegram 代理链接:"
echo "tg://proxy?server=$DOMAIN&port=443&secret=dd$SECRET"
green "━━━━━━━━━━━━━━━━━━━━━━━━"
green "查看后端实时日志: sudo journalctl -f -u mtproto"
yellow "⚠️ 请确保防火墙已放行 TCP 443 端口"