#!/bin/bash
# =================================================
# MTProto Proxy 检测脚本（自动推荐最佳 DC + 生成链接）
# =================================================

set -e

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# -------------------------------
# 用户输入
# -------------------------------
read -p "请输入你的域名或 VPS IP: " DOMAIN

# -------------------------------
# 检查 Python 后端进程
# -------------------------------
PID=$(pgrep -f mtproto_backend.py || true)
if [[ -z "$PID" ]]; then
    red "❌ MTProto 后端未运行！"
else
    green "✅ MTProto 后端正在运行，PID: $PID"
fi

# -------------------------------
# 获取监听端口
# -------------------------------
if [[ -f /opt/mtproto/mtproto_backend.py ]]; then
    PORT=$(grep "LISTEN = " /opt/mtproto/mtproto_backend.py | grep -oP '\d+')
    green "⚡ 监听端口: $PORT"
else
    yellow "⚠️ 后端脚本不存在，无法获取端口"
fi

# -------------------------------
# 获取 dd-secret
# -------------------------------
if [[ -f /opt/mtproto/mtproto_backend.py ]]; then
    SECRET=$(grep "SECRET = bytes.fromhex" /opt/mtproto/mtproto_backend.py | grep -oP '[0-9a-f]{32}')
    green "🔑 dd-secret: dd$SECRET"
fi

# -------------------------------
# 本地端口连通性
# -------------------------------
if [[ ! -z "$PORT" ]]; then
    if command -v nc >/dev/null 2>&1; then
        nc -zvw3 127.0.0.1 $PORT
        if [[ $? -eq 0 ]]; then
            green "✅ 本地端口 $PORT 可连接"
        else
            red "❌ 本地端口 $PORT 无法连接"
        fi
    else
        yellow "⚠️ nc 命令不可用，无法检测本地端口"
    fi
fi

# -------------------------------
# 远程端口连通性
# -------------------------------
if [[ ! -z "$PORT" ]]; then
    green "🌐 测试远程端口连通性（模拟客户端）:"
    if command -v nc >/dev/null 2>&1; then
        nc -zvw5 $DOMAIN $PORT
        if [[ $? -eq 0 ]]; then
            green "✅ $DOMAIN:$PORT 可从远程访问"
        else
            red "❌ $DOMAIN:$PORT 无法从远程访问，请检查防火墙或安全组"
        fi
    else
        yellow "⚠️ nc 命令不可用，无法检测远程端口"
    fi
fi

# -------------------------------
# Telegram DC 平均延迟测试
# -------------------------------
TELEGRAM_DCS=("149.154.167.50" "149.154.167.91" "149.154.167.92" "173.240.5.253")
green "🌐 Telegram DC 平均延迟测试 (ping 5 次):"

BEST_DC=""
MIN_AVG=9999

for ip in "${TELEGRAM_DCS[@]}"; do
    if command -v ping >/dev/null 2>&1; then
        PING_TOTAL=0
        COUNT=0
        for i in {1..5}; do
            TIME_MS=$(ping -c 1 -W 1 $ip | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}')
            if [[ ! -z "$TIME_MS" ]]; then
                PING_TOTAL=$(echo "$PING_TOTAL + $TIME_MS" | bc)
                COUNT=$((COUNT + 1))
            fi
        done
        if [[ $COUNT -gt 0 ]]; then
            AVG=$(echo "scale=2; $PING_TOTAL / $COUNT" | bc)
            green "DC $ip 平均延迟: ${AVG} ms"
            if (( $(echo "$AVG < $MIN_AVG" | bc -l) )); then
                MIN_AVG=$AVG
                BEST_DC=$ip
            fi
        else
            yellow "DC $ip 无法 ping 通"
        fi
    fi
done

if [[ ! -z "$BEST_DC" ]]; then
    green "⚡ 推荐最佳 DC: $BEST_DC（平均延迟 ${MIN_AVG} ms）"
fi

# -------------------------------
# Telegram 客户端链接（使用最佳 DC）
# -------------------------------
if [[ ! -z "$PORT" && ! -z "$SECRET" && ! -z "$DOMAIN" ]]; then
    PROXY_LINK="tg://proxy?server=$DOMAIN&port=$PORT&secret=dd$SECRET"
    green "Telegram 代理链接 (可直接导入客户端):"
    echo "$PROXY_LINK"
    if [[ ! -z "$BEST_DC" ]]; then
        green "⚡ 注意: 推荐优先连接 DC $BEST_DC"
    fi
else
    yellow "⚠️ 无法生成 Telegram 链接，请手动检查 DOMAIN/端口/SECRET"
fi

# -------------------------------
# 后端日志提示
# -------------------------------
green "查看后端日志: tail -f /opt/mtproto/logs/mtproto.log"