#!/bin/bash
# 部署到自己的服务器（服务器上已有 Caddy：~/www 是网站文件，/api/* 转发到 127.0.0.1:9100）
#   ./deploy.sh                       默认 mogu@139.180.145.132
#   ./deploy.sh 用户名@服务器地址
# 只会询问一次 SSH 密码。不需要 sudo。
set -euo pipefail
cd "$(dirname "$0")"

HOST="${1:-mogu@139.180.145.132}"
PORT=9100
SOCK="$(mktemp -u /tmp/wbj-ssh.XXXXXX)"
SSH=(ssh -o ControlPath="$SOCK")

echo "→ 连接 $HOST（请输入服务器密码）"
ssh -o ControlMaster=yes -o ControlPath="$SOCK" -o ControlPersist=300 -o StrictHostKeyChecking=accept-new -fN "$HOST"
trap '"${SSH[@]}" -O exit "$HOST" 2>/dev/null || true' EXIT

echo "→ 上传文件"
"${SSH[@]}" "$HOST" 'mkdir -p ~/wubianji ~/www'
scp -q -o ControlPath="$SOCK" server.py "$HOST":wubianji/server.py
scp -q -o ControlPath="$SOCK" index.html "$HOST":wubianji/index.html

echo "→ 安装并启动协作服务器"
"${SSH[@]}" "$HOST" "PORT=$PORT bash -s" <<'REMOTE'
set -e
command -v python3 >/dev/null || { echo "服务器上没有 python3，请先安装"; exit 1; }

# 网站首页（原来的占位页备份为 index.html.bak）
if [ -f ~/www/index.html ] && ! grep -q '无边记' ~/www/index.html; then cp ~/www/index.html ~/www/index.html.bak; fi
cp ~/wubianji/index.html ~/www/index.html

CMD="$(command -v python3) -u $HOME/wubianji/server.py --host 127.0.0.1 --port $PORT --data $HOME/wubianji/collab-data"

# 优先用 systemd 用户服务（需要已开启 linger，退出登录后才会继续运行），否则用 nohup + 开机自启的 crontab
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] && systemctl --user status >/dev/null 2>&1; then
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/wubianji.service <<EOF
[Unit]
Description=无边记协作服务器
After=network.target

[Service]
ExecStart=$CMD
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable wubianji >/dev/null 2>&1
  systemctl --user restart wubianji
  echo "  已用 systemd 用户服务运行（systemctl --user status wubianji）"
else
  pkill -f "wubianji/server.py" 2>/dev/null || true
  sleep 0.5
  nohup $CMD >> ~/wubianji/server.log 2>&1 < /dev/null &
  ( crontab -l 2>/dev/null | grep -v 'wubianji/server.py' ; echo "@reboot $CMD >> $HOME/wubianji/server.log 2>&1" ) | crontab - 2>/dev/null \
    || echo "  （没能设置开机自启，服务器重启后需要重新运行 deploy.sh）"
  echo "  已在后台运行，日志：~/wubianji/server.log"
fi

for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://127.0.0.1:$PORT/api/info" >/dev/null 2>&1; then echo "  服务器已就绪"; exit 0; fi
  sleep 0.5
done
echo "  服务器没有启动成功，最近的日志："; tail -20 ~/wubianji/server.log 2>/dev/null || journalctl --user -u wubianji -n 20 --no-pager
exit 1
REMOTE

echo "→ 检查网站"
sleep 1
if curl -fsS -m 10 "https://mogu.oiii.fun/api/info" >/dev/null 2>&1; then
  echo "✓ 部署完成：https://mogu.oiii.fun/"
else
  echo "! 服务器已启动，但 https://mogu.oiii.fun/api/info 无法访问，请检查 Caddy 的 /api 转发配置"
fi
