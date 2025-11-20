#!/bin/bash

clear
echo "============================================="
echo " Telegram 动态北京时间昵称 更新器 一键部署脚本"
echo "============================================="

# ==== 获取 API 信息 ====
echo
read -p "请输入 Telegram API_ID: " TG_API_ID
read -p "请输入 Telegram API_HASH: " TG_API_HASH

# ==== 创建运行目录 ====
INSTALL_DIR="$HOME/tg_name_clock"
mkdir -p $INSTALL_DIR

echo
echo "📁 创建目录: $INSTALL_DIR"

# ==== 写入 Python 主程序 ====
cat > $INSTALL_DIR/tg_name_clock.py << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import re
import asyncio
import logging
from datetime import datetime

try:
    from zoneinfo import ZoneInfo  # Python 3.9+
except ImportError:
    from backports.zoneinfo import ZoneInfo

from telethon import TelegramClient, errors
from telethon.tl.functions.account import UpdateProfileRequest

# ========= 配置 =========
CHECK_INTERVAL = 5
TIMEZONE = "Asia/Shanghai"

api_id = int(os.getenv("TG_API_ID", "0"))
api_hash = os.getenv("TG_API_HASH", "")
session_name = "tg_time_session"

if not api_id or not api_hash:
    raise SystemExit("环境变量 TG_API_ID 或 TG_API_HASH 未设置！")

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("tg-clock")

TIME_TAIL_RE = re.compile(r"\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?: [\u2600-\U0001FAFF])?$")

CLOCKS = [
    "🕛", "🕧", "🕐", "🕜", "🕑", "🕝", "🕒", "🕞",
    "🕓", "🕟", "🕔", "🕠", "🕕", "🕡", "🕖", "🕢",
    "🕗", "🕣", "🕘", "🕤", "🕙", "🕥", "🕚", "🕦"
]

def clock_for(hour: int, minute: int) -> str:
    idx = (hour % 12) * 2 + (1 if minute >= 30 else 0)
    return CLOCKS[idx]

client = TelegramClient(session_name, api_id, api_hash)

async def change_name_loop():
    me = await client.get_me()
    original_first = me.first_name or ""
    original_last = me.last_name or ""

    tz = ZoneInfo(TIMEZONE)
    last_time_str = ""

    try:
        while True:
            now = datetime.now(tz)
            time_str = now.strftime("%Y-%m-%d %H:%M")

            if time_str != last_time_str:
                emoji = clock_for(now.hour, now.minute)
                me = await client.get_me()

                base = re.sub(TIME_TAIL_RE, "", me.first_name or "").strip()
                new_name = f"{base} {time_str} {emoji}"

                try:
                    await client(UpdateProfileRequest(first_name=new_name, last_name=""))
                    logger.info(f"Updated: {new_name}")
                    last_time_str = time_str
                except errors.FloodWaitError as e:
                    logger.warning(f"FloodWait: 等待 {e.seconds}s")
                    await asyncio.sleep(e.seconds)
                    continue

            await asyncio.sleep(CHECK_INTERVAL)

    except asyncio.CancelledError:
        logger.info("恢复原昵称…")
        await client(UpdateProfileRequest(
            first_name=original_first, last_name=original_last
        ))
        raise

async def main():
    await client.start()
    task = asyncio.create_task(change_name_loop())
    try:
        await task
    except Exception as e:
        logger.error(f"Error: {e}")
        task.cancel()

if __name__ == "__main__":
    asyncio.run(main())
EOF

echo "✅ Python 主程序已生成"

# ==== 写入环境变量 ====
echo
echo "🔧 写入环境变量…"

cat > $INSTALL_DIR/env.sh << EOF
export TG_API_ID=$TG_API_ID
export TG_API_HASH=$TG_API_HASH
EOF

echo "source \$HOME/tg_name_clock/env.sh" >> $HOME/.bashrc

# ==== 安装依赖 ====
echo
echo "📦 安装 Python 依赖…"
sudo apt update -y >/dev/null 2>&1
sudo apt install -y python3 python3-pip python3-venv >/dev/null 2>&1

python3 -m pip install --upgrade pip >/dev/null 2>&1
python3 -m pip install telethon backports.zoneinfo >/dev/null 2>&1

echo "✅ 依赖安装完成"

# ==== 启动脚本 ====
echo
echo "🚀 启动 Telegram 昵称自动更新时间脚本…"

source $INSTALL_DIR/env.sh

nohup python3 $INSTALL_DIR/tg_name_clock.py > $INSTALL_DIR/run.log 2>&1 &

echo
echo "============================================="
echo " 部署完成！你的昵称会自动显示北京时间和动态时钟表情"
echo "============================================="
echo "后台运行日志: $INSTALL_DIR/run.log"
echo "停止脚本命令: pkill -f tg_name_clock.py"
echo "重启脚本命令: nohup python3 $INSTALL_DIR/tg_name_clock.py > $INSTALL_DIR/run.log 2>&1 &"
echo "============================================="