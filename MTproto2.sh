#!/bin/bash
# =================================================
# MTProto 代理一键检测脚本
# =================================================

set -e

VPS_IP="103.193.172.97"   # 你的 VPS IP
PORT=443                  # Nginx 前端监听端口
BACKEND_PORT=8443         # Python 后端端口

green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red()    { echo -e "\033[31m$1\033[0m"; }

green "🚀 开始检测 MTProto 代理可用性 …"

# -------------------------------
# 检查 Nginx stream 模块
# -------------------------------
if nginx -V 2>&1 | grep -- '--with-stream' >/dev/null; then
    green "✔ Nginx 支持 stream 模块"
else
    red "✖ Nginx 未启用 stream 模块"
fi

# -------------------------------
# 检查 Nginx 配置和端口
# -------------------------------
if nginx -t >/dev/null 2>&1; then
    green "✔ Nginx 配置语法正确"
else
    red "✖ Nginx 配置有错误"
fi

if ss -tlnp | grep ":$PORT" >/dev/null; then
    green "✔ Nginx 前端端口 $PORT 已监听"
else
    red "✖ Nginx 前端端口 $PORT 未监听"
fi

# -------------------------------
# 检查 Python 后端
# -------------------------------
if ps aux | grep mtproto_backend.py | grep -v grep >/dev/null; then
    green "✔ Python 后端正在运行"
else
    red "✖ Python 后端未运行"
fi

if ss -tlnp | grep ":$BACKEND_PORT" >/dev/null; then
    green "✔ Python 后端端口 $BACKEND_PORT 已监听"
else
    red "✖ Python 后端端口 $BACKEND_PORT 未监听"
fi

# -------------------------------
# 测试 VPS 到 Telegram DC 的连通性
# -------------------------------
TELEGRAM_DCS=("149.154.167.50" "149.154.167.91" "149.154.167.92" "173.240.5.253")

for DC in "${TELEGRAM_DCS[@]}"; do
    echo -n "测试到 Telegram DC $DC:443 … "
    if timeout 3 bash -c "echo > /dev/tcp/$DC/443" >/dev/null 2>&1; then
        green "✔ 连通"
    else
        red "✖ 不通"
    fi
done

# -------------------------------
# 测试 VPS 前端端口可达性
# -------------------------------
echo -n "测试 VPS 公网 IP $VPS_IP:$PORT 可达性 … "
if timeout 3 bash -c "echo > /dev/tcp/$VPS_IP/$PORT" >/dev/null 2>&1; then
    green "✔ 可达"
else
    red "✖ 不可达（检查防火墙或安全组）"
fi

green "✅ 检测完成"