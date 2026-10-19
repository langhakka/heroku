#!/usr/bin/env bash
# cf_quick_node.sh —— 无公网 IP 时，用 Cloudflare Quick Tunnel 暴露本机
# sing-box (VLESS + WS)，并自动生成节点链接 / 订阅 / 二维码。
#
# 用法:
#   ./tools/cf_quick_node.sh start  [-p 端口] [-u UUID] [-n 节点名]
#   ./tools/cf_quick_node.sh status
#   ./tools/cf_quick_node.sh link
#   ./tools/cf_quick_node.sh stop
#   ./tools/cf_quick_node.sh restart
#
# 环境变量: UUID / PORT / NAME / OUT_DIR / RUN_DIR
# 说明:
#   - sing-box 只监听 127.0.0.1，公网入口由 cloudflared 隧道提供
#   - 每次 start/restart 都会得到新的 *.trycloudflare.com 域名
#   - 隧道为临时测试用途，进程退出后立即失效
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

RUN_DIR="${RUN_DIR:-$HOME/.cache/cf-quick-node}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/node-out-cf}"
BIN_DIR="$RUN_DIR/bin"
NAME="${NAME:-CF-临时节点}"
PORT="${PORT:-18080}"
UUID="${UUID:-}"

mkdir -p "$RUN_DIR" "$BIN_DIR" "$OUT_DIR"

log()  { printf '\033[1;36m[cf]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的 CPU 架构: $(uname -m)" ;;
esac

ensure_cloudflared() {
  local bin="$BIN_DIR/cloudflared"
  [[ -x "$bin" ]] && return 0
  log "下载 cloudflared ..."
  curl -fL --retry 2 --max-time 180 -o "$bin" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" \
    || die "cloudflared 下载失败"
  chmod +x "$bin"
}

ensure_singbox() {
  local bin="$BIN_DIR/sing-box"
  [[ -x "$bin" ]] && return 0
  log "查询 sing-box 最新版本 ..."
  local url
  url="$(curl -fsSL --max-time 30 \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
    | grep -oE "https://[^\"]*sing-box-[0-9.]+-linux-$ARCH\.tar\.gz" | head -1 || true)"
  if [[ -z "$url" ]]; then
    url="https://github.com/SagerNet/sing-box/releases/download/v1.14.3/sing-box-1.14.3-linux-$ARCH.tar.gz"
    warn "无法查询最新版，回退到 v1.14.3"
  fi
  log "下载 sing-box: ${url##*/}"
  local tmp="$BIN_DIR/sing-box.tar.gz"
  curl -fL --retry 2 --max-time 180 -o "$tmp" "$url" || die "sing-box 下载失败"
  tar -xzf "$tmp" -C "$BIN_DIR"
  local dir
  dir="$(find "$BIN_DIR" -maxdepth 1 -type d -name 'sing-box-*linux*' | head -1)"
  [[ -n "$dir" ]] || die "sing-box 压缩包结构异常"
  cp "$dir/sing-box" "$bin"
  chmod +x "$bin"
  rm -rf "$dir" "$tmp"
}

pid_alive() {
  [[ -f "${1:-}" ]] && kill -0 "$(cat "$1")" 2>/dev/null
}

port_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
    print("yes")
except OSError:
    print("no")
finally:
    s.close()
PY
}

pick_port() {
  local p="${1:-18080}"
  local i
  for i in $(seq 1 100); do
    if [[ "$(port_free "$p")" == "yes" ]]; then
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  die "18080 起连续 100 个端口都被占用"
}

init_uuid() {
  local given="${1:-}"
  [[ -n "$given" ]] && UUID="$given"
  if [[ -z "$UUID" ]]; then
    if [[ -s "$RUN_DIR/uuid.txt" ]]; then
      UUID="$(cat "$RUN_DIR/uuid.txt")"
      log "复用已有 UUID: $UUID"
    else
      UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
      log "生成新 UUID: $UUID"
    fi
  fi
  printf '%s\n' "$UUID" > "$RUN_DIR/uuid.txt"
}

cmd_start() {
  if pid_alive "$RUN_DIR/sing-box.pid" || pid_alive "$RUN_DIR/cloudflared.pid"; then
    warn "已有实例在运行（请先 stop 或 restart）"
    cmd_status
    return 0
  fi

  ensure_cloudflared
  ensure_singbox
  init_uuid "$UUID"
  PORT="$(pick_port "$PORT")"
  log "sing-box 监听端口: 127.0.0.1:$PORT"

  cat > "$RUN_DIR/server.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": $PORT,
      "users": [{ "uuid": "$UUID", "flow": "" }],
      "transport": { "type": "ws", "path": "/ws" }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

  "$BIN_DIR/sing-box" check -c "$RUN_DIR/server.json" >/dev/null \
    || die "sing-box 配置校验失败"

  nohup "$BIN_DIR/sing-box" run -c "$RUN_DIR/server.json" \
      > "$RUN_DIR/sing-box.log" 2>&1 &
  echo $! > "$RUN_DIR/sing-box.pid"

  local i
  for i in $(seq 1 40); do
    [[ "$(port_free "$PORT")" == "no" ]] && break
    sleep 0.25
  done
  if [[ "$(port_free "$PORT")" == "yes" ]]; then
    tail -20 "$RUN_DIR/sing-box.log" || true
    die "sing-box 未能监听 127.0.0.1:$PORT"
  fi
  log "sing-box 已启动 (pid $(cat "$RUN_DIR/sing-box.pid"))"

  : > "$RUN_DIR/cloudflared.log"
  nohup "$BIN_DIR/cloudflared" tunnel --url "http://127.0.0.1:$PORT" \
      --no-autoupdate --protocol http2 --edge-ip-version 4 \
      > "$RUN_DIR/cloudflared.log" 2>&1 &
  echo $! > "$RUN_DIR/cloudflared.pid"

  local url="" host=""
  for i in $(seq 1 60); do
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' \
      "$RUN_DIR/cloudflared.log" 2>/dev/null | head -1 || true)"
    [[ -n "$url" ]] && break
    sleep 1
  done
  if [[ -z "$url" ]]; then
    tail -25 "$RUN_DIR/cloudflared.log" || true
    die "没有拿到 trycloudflare 域名"
  fi
  host="${url#https://}"
  printf '%s\n' "$url"  > "$RUN_DIR/tunnel_url.txt"
  printf '%s\n' "$host" > "$RUN_DIR/tunnel_host.txt"
  log "隧道已建立: $url"

  python3 -c 'import segno' 2>/dev/null \
    || warn "未安装 segno，二维码会被跳过（python3 -m pip install --user segno）"

  python3 "$REPO_ROOT/tools/vless_gen.py" \
    --host "$host" --uuid "$UUID" --name "$NAME" --out "$OUT_DIR" >/dev/null

  # 等 DNS 生效（失败也不影响链接，只是本机暂时解析不到）
  for i in $(seq 1 40); do
    getent hosts "$host" >/dev/null 2>&1 && break
    sleep 1
  done

  local code="" j
  for j in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url/" || true)"
    [[ "$code" == "400" || "$code" == "404" ]] && break
    sleep 1
  done
  log "公网探测: HTTP ${code:-failed}（400/404 表示已到达本地 sing-box）"
  echo
  cmd_summary
}

cmd_summary() {
  local url="" host="" link=""
  [[ -f "$RUN_DIR/tunnel_url.txt" ]] && url="$(cat "$RUN_DIR/tunnel_url.txt")"
  [[ -f "$RUN_DIR/tunnel_host.txt" ]] && host="$(cat "$RUN_DIR/tunnel_host.txt")"
  [[ -f "$OUT_DIR/vless.txt" ]] && link="$(cat "$OUT_DIR/vless.txt")"
  local uuid="$UUID"
  [[ -z "$uuid" && -f "$RUN_DIR/uuid.txt" ]] && uuid="$(cat "$RUN_DIR/uuid.txt")"

  echo "======================================================================"
  echo " 节点已就绪（Cloudflare 临时隧道）"
  echo "   域名   : ${host:-unknown}"
  echo "   端口   : 443 (TLS)"
  echo "   UUID   : ${uuid:-unknown}"
  echo "   路径   : /ws"
  echo "   链接   : ${link:-未生成}"
  echo "   订阅   : ${OUT_DIR}/subscription.txt"
  echo "   二维码 : ${OUT_DIR}/qr.png"
  echo "   客户端 : ${OUT_DIR}/client-config-singbox.json (sing-box)"
  echo "            ${OUT_DIR}/client-config.json (V2Ray/Xray)"
  echo "   日志   : ${RUN_DIR}/cloudflared.log"
  echo "======================================================================"
}

cmd_status() {
  local sb="stopped" cf="stopped" url="" port=""
  pid_alive "$RUN_DIR/sing-box.pid" && sb="running (pid $(cat "$RUN_DIR/sing-box.pid"))"
  pid_alive "$RUN_DIR/cloudflared.pid" && cf="running (pid $(cat "$RUN_DIR/cloudflared.pid"))"
  if [[ -f "$RUN_DIR/server.json" ]]; then
    port="$(grep -oE '"listen_port": *[0-9]+' "$RUN_DIR/server.json" \
      | grep -oE '[0-9]+' | head -1)"
  fi
  [[ -f "$RUN_DIR/tunnel_url.txt" ]] && url="$(cat "$RUN_DIR/tunnel_url.txt")"

  echo "sing-box   : $sb"
  echo "cloudflared: $cf"
  echo "local port : ${port:-unknown}"
  echo "tunnel     : ${url:-none}"
  if [[ -s "$OUT_DIR/vless.txt" ]]; then
    echo "link       : $(cat "$OUT_DIR/vless.txt")"
  fi
}

cmd_link() {
  [[ -s "$OUT_DIR/vless.txt" ]] || die "还没有生成链接，先执行 start"
  cat "$OUT_DIR/vless.txt"
}

cmd_stop() {
  local name pidfile
  for name in cloudflared sing-box; do
    pidfile="$RUN_DIR/$name.pid"
    if pid_alive "$pidfile"; then
      kill "$(cat "$pidfile")" 2>/dev/null || true
      log "已停止 $name (pid $(cat "$pidfile"))"
    fi
    rm -f "$pidfile"
  done
  sleep 1
  # 兜底清理可能残留的进程
  pkill -f "$BIN_DIR/sing-box run -c $RUN_DIR/server.json" 2>/dev/null || true
  pkill -f "$BIN_DIR/cloudflared tunnel --url http://127.0.0.1:" 2>/dev/null || true
  log "已停止"
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

CMD="${1:-start}"
shift || true

while getopts ":p:u:n:o:" opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    u) UUID="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    o) OUT_DIR="$OPTARG"; mkdir -p "$OUT_DIR" ;;
    :) die "参数 -$OPTARG 需要一个值" ;;
    \?) die "未知参数: -$OPTARG" ;;
  esac
done

case "$CMD" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  link)    cmd_link ;;
  *) die "用法: $0 {start|stop|restart|status|link} [-p 端口] [-u UUID] [-n 名称] [-o 输出目录]" ;;
esac


