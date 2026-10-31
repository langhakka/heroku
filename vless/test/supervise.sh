#!/usr/bin/env bash
# =============================================================================
# supervise.sh - 最外层保活：watchdog 挂了就拉起来（三级链 supervisor → watchdog → 节点）
#
#   bash test/supervise.sh start     # 后台启动（幂等，已在跑就不重复启动）
#   bash test/supervise.sh status    # 三级状态一览
#   bash test/supervise.sh stop      # 只停 supervisor（--all 连节点一起停）
#   bash test/supervise.sh once      # 前台检查一次（排查用）
#
# 为什么需要它：watchdog 自己也可能被杀/OOM/抛错退出，而容器的 PID 1 是平台进程，
# 没有任何东西会把它拉起来。这一层就是补这个洞（再往上一级只能靠容器外触发，
# 见 vless/README.md 的"让它真正无人值守"）。
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR="${VLESS_DEMO_DIR:-$HERE/../.cache/vless-demo}"
SP_PID="$STATE_DIR/supervisor.pid"
WD_PID="$STATE_DIR/watchdog.pid"
LOG="$STATE_DIR/supervisor.log"
INTERVAL="${SUPERVISE_INTERVAL:-30}"

mkdir -p "$STATE_DIR"
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }
pid_of() { [[ -f "$1" ]] && cat "$1" 2>/dev/null || true; }
alive() {
    local p st
    p=$(pid_of "$1"); [[ -n "$p" ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
    [[ "$st" == "Z" ]] && return 1
    return 0
}

rotate_self() {   # supervisor.log 自己别无限长
    local sz
    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    (( sz > 524288 )) && : > "$LOG"
}

ensure_watchdog() {
    if alive "$WD_PID"; then return 0; fi
    log "[restart] watchdog 不在（pid 文件缺失或进程已死），正在拉起"
    if bash "$HERE/test/watchdog.sh" start >>"$LOG" 2>&1; then
        sleep 1
        if alive "$WD_PID"; then log "[ok] watchdog 已恢复 pid=$(pid_of "$WD_PID")"; else log "[fail] watchdog 拉起失败"; fi
    else
        log "[fail] watchdog start 返回非 0（是否缺少二进制？先跑 bootstrap.sh）"
    fi
}

loop() {
    log "[start] supervisor 启动 pid=$$ interval=${INTERVAL}s"
    local n=0
    while true; do
        ensure_watchdog
        n=$((n + 1))
        (( n % 20 == 0 )) && rotate_self
        sleep "$INTERVAL"
    done
}

case "${1:-start}" in
    start)
        if alive "$SP_PID"; then echo "supervisor 已在运行 pid=$(pid_of "$SP_PID")"; exit 0; fi
        [[ -x "$STATE_DIR/watchdog.sh" || -f "$HERE/test/watchdog.sh" ]] || true
        setsid nohup bash "$0" _loop >>"$STATE_DIR/supervisor.stderr" 2>&1 < /dev/null &
        echo $! > "$SP_PID"
        sleep 1
        ensure_watchdog
        echo "supervisor 已启动 pid=$(pid_of "$SP_PID")（watchdog: $(alive "$WD_PID" && echo "运行中 pid=$(pid_of "$WD_PID")" || echo 未运行)）"
        ;;
    _loop) loop ;;
    once)
        ensure_watchdog
        echo "supervisor: $(alive "$SP_PID" && echo "运行中 pid=$(pid_of "$SP_PID")" || echo 未运行)"
        bash "$HERE/test/watchdog.sh" status | head -6
        ;;
    status)
        echo "supervisor: $(alive "$SP_PID" && echo "运行中 pid=$(pid_of "$SP_PID")" || echo 未运行)"
        bash "$HERE/test/watchdog.sh" status | head -6
        echo "最近事件:"
        tail -3 "$LOG" 2>/dev/null
        ;;
    stop)
        if alive "$SP_PID"; then kill "$(pid_of "$SP_PID")" 2>/dev/null && echo "supervisor 已停止"; rm -f "$SP_PID"; else echo "supervisor 未在运行"; fi
        if [[ "${2:-}" == "--all" ]]; then bash "$HERE/test/watchdog.sh" stop --all; fi
        ;;
    *) echo "用法: bash test/supervise.sh {start|status|stop|once}" >&2; exit 1 ;;
esac
