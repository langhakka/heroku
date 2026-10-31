#!/usr/bin/env bash
# =============================================================================
# status-report.sh - 输出一条可直接发到 IM / 邮件的节点状态摘要（纯文本）
#
#   bash test/status-report.sh            # 给人看的一段话
#   bash test/status-report.sh --json     # 给程序用的单行 JSON
#
# 设计：所有判断都复用 bootstrap.sh --check 的结果，避免两套健康检查逻辑打架。
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR="${VLESS_DEMO_DIR:-$HERE/../.cache/vless-demo}"
JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

pid_of() { [[ -f "$1" ]] && cat "$1" 2>/dev/null || true; }
alive() {
    local p st
    p=$(pid_of "$1"); [[ -n "$p" ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
    [[ "$st" == "Z" ]] && return 1
    return 0
}
onoff() { alive "$STATE_DIR/$1.pid" && echo "up:$(pid_of "$STATE_DIR/$1.pid")" || echo "down"; }

NOW=$(date -u '+%Y-%m-%d %H:%M UTC')
HOST=$(cat "$STATE_DIR/host.txt" 2>/dev/null || echo "")
LINK=$(cat "$STATE_DIR/link.txt" 2>/dev/null || echo "")
NAMED="否（临时隧道，域名会变）"
[[ -f "$STATE_DIR/tunnel.env" ]] && NAMED="是（命名隧道，域名固定）"
UP_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)

CHECK="fail"
bash "$HERE/test/bootstrap.sh" --check >/dev/null 2>&1 && CHECK="ok"
[[ "$CHECK" == "ok" ]] && VERDICT="✅ 正常" || VERDICT="⚠️ 异常"

# 重启次数（watchdog 日志里的 [restart] 计数，够用且便宜）
RESTARTS=$(grep -c '\[restart\]' "$STATE_DIR/watchdog.log" 2>/dev/null || echo 0)

if (( JSON == 1 )); then
    printf '{"time":"%s","verdict":"%s","check":"%s","host":"%s","named_tunnel":"%s","node":"%s","tunnel":"%s","watchdog":"%s","supervisor":"%s","restarts":%s,"uptime_s":%s,"link":"%s"}\n' \
        "$NOW" "$VERDICT" "$CHECK" "$HOST" "$NAMED" \
        "$(onoff server)" "$(onoff cloudflared)" "$(onoff watchdog)" "$(onoff supervisor)" \
        "$RESTARTS" "$UP_S" "$LINK"
    exit 0
fi

cat <<EOF
$VERDICT  VLESS 节点状态（$NOW）

域名   : ${HOST:-（无）}
固定域名: $NAMED
节点   : $(onoff server)（127.0.0.1:$(grep -o '"port": [0-9]*' "$STATE_DIR/server.json" 2>/dev/null | head -1 | grep -o '[0-9]*')）
隧道   : $(onoff cloudflared)
链路自检: $CHECK（WebSocket 101）
守护   : watchdog $(onoff watchdog) / supervisor $(onoff supervisor)
累计重启: ${RESTARTS} 次
宿主运行: $((UP_S / 3600))h$(( (UP_S % 3600) / 60 ))m

链接:
${LINK:-（无）}
EOF
