#!/bin/bash

echo "=== MTProxy + FakeTLS + 优化 一键安装脚本 | Debian 12 ==="

# 更新系统
apt update -y
apt install git curl build-essential openssl -y

cd /root

# 下载 MTProxy
if [ ! -d "/root/MTProxy" ]; then
    git clone https://github.com/TelegramMessenger/MTProxy
fi

cd MTProxy || exit

# 编译
make

# 生成 Secret
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
FAKETLS_SECRET=$(head -c 16 /dev/urandom | xxd -ps)

# FakeTLS 伪装域名（可换 apple.com / cloudflare.com）
FAKETLS_DOMAIN="www.microsoft.com"

# 获取公网IP
SERVER_IP=$(curl -s ipv4.icanhazip.com)

echo "生成的普通 Secret: $SECRET"
echo "生成的 FakeTLS Secret: $FAKETLS_SECRET"
echo "使用伪装域名: $FAKETLS_DOMAIN"

# 创建 systemd 服务（优化版）
cat >/etc/systemd/system/mtproxy.service <<EOF
[Unit]
Description=MTProxy with FakeTLS (Optimized)
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/MTProxy
ExecStart=/root/MTProxy/objs/bin/mtproto-proxy \\
  -u nobody \\
  -p 8888 \\
  -H 443 \\
  --aes-pwd proxy-secret proxy-multi.conf \\
  -S ${SECRET} \\
  --fake-tls ${FAKETLS_DOMAIN} \\
  -P ${FAKETLS_SECRET} \\
  -M 4 \\
  --log-file /var/log/mtproxy.log \\
  --max-special-connections 2048
Restart=always
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# 系统参数优化 sysctl
cat >>/etc/sysctl.conf <<EOF
fs.file-max = 2000000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 1024
EOF

sysctl -p

# 文件句柄数优化
cat >>/etc/security/limits.conf <<EOF
* soft nofile 1000000
* hard nofile 1000000
EOF

# 启动 MTProxy
systemctl daemon-reload
systemctl enable mtproxy
systemctl restart mtproxy

echo
echo "=== MTProxy + FakeTLS 已成功安装并优化完成 ==="
echo "服务器 IP: $SERVER_IP"
echo "端口: 443"
echo
echo "🔹 普通代理链接："
echo "tg://proxy?server=${SERVER_IP}&port=443&secret=${SECRET}"
echo
echo "🔹 FakeTLS 高级代理链接（推荐）："
echo "tg://proxy?server=${SERVER_IP}&port=443&secret=dd${FAKETLS_SECRET}${SECRET}"
echo
echo "MTProxy 已自动开机启动。"
echo "日志位置：/var/log/mtproxy.log"
echo