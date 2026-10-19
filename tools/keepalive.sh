#!/usr/bin/env bash
# keepalive.sh —— cf_quick_node.sh 的看门狗
#
# 功能:
#   1. 每 INTERVAL 秒检查 sing-box / cloudflared 进程是否存活
#   2. 定期探测本地端口和公网域名，连续失败自动 restart
#   3. 检测沙箱冻结/恢复到的时间跳变，恢复后立即体检
#   4. 重启冷却 + flock 串行化，避免雪崩式重启
#
# 用法:
#   ./tools/keepalive.sh start     # 后台启动看门狗
#   ./tools/keepalive.sh stop
#   ./tools/keepalive.sh status
#   ./tools/keepalive.sh once      # 只做一次体检，不重启
#
# 可调环境变量:
#   INTERVAL=10          进程检查间隔（秒）
#   HEALTH_EVERY=30      健康检查间隔（秒）
#   FAIL_LIMIT=2         连续失败几次触发重启
#   RESTART_COOLDOWN=45  两次重启的最小间隔（秒）
#   RUN_DIR=~/.cache/cf-quick-node
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
NODE="$REPO_ROOT/tools/cf_quick_node.sh"

RUN_DIR="${RUN_DIR:-$HOME/.cache/cf-quick-node}"
INTERVAL="${INTERVAL:-10}"
HEALTH_EVERY="${HEALTH_EVERY:-30}"
FAIL_LIMIT="${FAIL_LIMIT:-2}"
RESTART_COOLDOWN="${RESTART_COOLDOWN:-45}"

LOG="$RUN_DIR/keepalive.log"
PIDFILE="$RUN_DIR/keepalive.pid"
LOCKFILE="$RUN_DIR/keepalive.lock"
RESTART_LOCK="$RUN_DIR/restart.lock"
LAST_RESTART=0

mkdir -p "$RUN_DIR"

log() { printf '%s [keepalive] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
say() { printf '%s\n' "$*"; }

rotate_log() {
  if [[ -f "$LOG" ]] && (( $(stat -c '%s' "$LOG" 2>/dev/null || echo 0) > 1048576 )); then
    mv -f "$LOG" "$LOG.1"
  fi
}

alive() {
  local file="${1:-}" pid state
  [[ -s "$file" ]] || return 1
  pid="$(cat "$file" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo X)"
  [[ "$state" != "Z" ]]
}

node_port() {
  if [[ -s "$RUN_DIR/port" ]]; then
    cat "$RUN_DIR/port"
  elif [[ -s "$RUN_DIR/server.json" ]]; then
    grep -oE '"listen_port": *[0-9]+' "$RUN_DIR/server.json" | grep -oE '[0-9]+' | head -1
  fi
}

public_host() {
  if [[ -s "$RUN_DIR/public_host" ]]; then
    cat "$RUN_DIR/public_host"
  elif [[ -s "$RUN_DIR/tunnel_host" ]]; then
    cat "$RUN_DIR/tunnel_host"
  fi
}

http_code() {
  local out
  out="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null || true)"
  [[ -n "$out" ]] && echo "$out" || echo "000"
}

check_local() {
  local port; port="$(node_port)"
  [[ -n "$port" ]] || { echo "noport"; return; }
  http_code "http://127.0.0.1:$port/"
}

check_public() {
  local host; host="$(public_host)"
  [[ -n "$host" ]] || { echo "nohost"; return; }
  http_code "https://$host/"
}

healthy_code() { [[ "$1" == "400" || "$1" == "404" ]]; }

restart_node() {
  local reason="$1" now rc
  now="$(date +%s)"
  if (( now - LAST_RESTART < RESTART_COOLDOWN )); then
    log "跳过重启（冷却中，距上次 $((now - LAST_RESTART))s）：$reason"
    return 1
  fi
  LAST_RESTART="$now"
  log "触发重启：$reason"

  (
    flock -w 120 8 || { log "拿不到重启锁，跳过"; exit 1; }
    timeout 180 "$NODE" restart >> "$LOG" 2>&1 9>&-
    rc=$?
    log "重启结束 rc=$rc"
  ) 8>"$RESTART_LOCK"
}

watch_loop() {
  log "看门狗启动 (pid $$, 进程检查 ${INTERVAL}s, 体检 ${HEALTH_EVERY}s)"
  local last_tick fails=0 last_health=0 now gap force lc pc
  last_tick="$(date +%s)"

  while true; do
    sleep "$INTERVAL" 9>&- & wait $! 2>/dev/null || true
    now="$(date +%s)"
    gap=$((now - last_tick))
    last_tick="$now"
    force=0
    if (( gap > INTERVAL * 3 + 5 )); then
      log "检测到冻结/恢复（时间跳变 ${gap}s），立即体检"
      force=1
    fi

    if ! alive "$RUN_DIR/sing-box.pid"; then
      restart_node "sing-box 进程不存在"
      fails=0
      last_health="$now"
      continue
    fi
    if ! alive "$RUN_DIR/cloudflared.pid"; then
      restart_node "cloudflared 进程不存在"
      fails=0
      last_health="$now"
      continue
    fi

    if (( force || now - last_health >= HEALTH_EVERY )); then
      last_health="$now"
      lc="$(check_local)"
      pc="$(check_public)"
      if healthy_code "$lc" && healthy_code "$pc"; then
        if (( fails > 0 )); then
          log "健康恢复（local=$lc public=$pc）"
        fi
        fails=0
      else
        fails=$((fails + 1))
        log "体检失败 #$fails（local=$lc public=$pc）"
        if (( fails >= FAIL_LIMIT )); then
          restart_node "连续 $fails 次体检失败"
          fails=0
        fi
      fi
    fi
  done
}

cmd_run() {
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    say "看门狗已在运行"
    exit 0
  fi
  echo $$ > "$PIDFILE"
  printf 'interval=%ss health=%ss fail=%s cooldown=%ss\n' \
    "$INTERVAL" "$HEALTH_EVERY" "$FAIL_LIMIT" "$RESTART_COOLDOWN" \
    > "$RUN_DIR/keepalive.params"
  trap 'log "收到退出信号"; rm -f "$PIDFILE"; exit 0' TERM INT
  rotate_log
  watch_loop
}

cmd_start() {
  if alive "$PIDFILE"; then
    say "看门狗已在运行 (pid $(cat "$PIDFILE"))"
    return 0
  fi
  rotate_log
  setsid nohup "$0" run >> "$LOG" 2>&1 < /dev/null &
  local i
  for i in $(seq 1 20); do
    sleep 0.3
    alive "$PIDFILE" && break
  done
  if alive "$PIDFILE"; then
    say "看门狗已启动 (pid $(cat "$PIDFILE"))"
    say "日志: $LOG"
  else
    say "启动失败，日志末尾："
    tail -10 "$LOG" 2>/dev/null || true
    return 1
  fi
}

cmd_stop() {
  if ! alive "$PIDFILE"; then
    rm -f "$PIDFILE"
    say "看门狗未运行"
    return 0
  fi
  local pid i
  pid="$(cat "$PIDFILE")"
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 20); do
    alive "$PIDFILE" || break
    sleep 0.25
  done
  if alive "$PIDFILE"; then
    kill -KILL -- -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  # 等锁释放，避免紧接着 start 拿不到 flock
  for i in $(seq 1 15); do
    flock -n "$LOCKFILE" true 2>/dev/null && break
    sleep 0.2
  done
  say "看门狗已停止（sing-box / cloudflared 不受影响）"
}

cmd_status() {
  if alive "$PIDFILE"; then
    say "watchdog : running (pid $(cat "$PIDFILE"))"
  else
    say "watchdog : stopped"
  fi
  if [[ -s "$RUN_DIR/keepalive.params" ]]; then
    say "params   : $(cat "$RUN_DIR/keepalive.params")"
  else
    say "params   : interval=${INTERVAL}s health=${HEALTH_EVERY}s fail=${FAIL_LIMIT} cooldown=${RESTART_COOLDOWN}s"
  fi
  say "local    : $(check_local) (127.0.0.1:$(node_port))"
  say "public   : $(check_public) ($(public_host || echo unknown))"
  say "log      : $LOG"
  say "--- 最近日志 ---"
  tail -6 "$LOG" 2>/dev/null || true
}

cmd_once() {
  local lc pc
  lc="$(check_local)"
  pc="$(check_public)"
  say "local  (127.0.0.1:$(node_port)) : $lc"
  say "public ($(public_host || echo unknown)) : $pc"
  if healthy_code "$lc" && healthy_code "$pc"; then
    say "结论: healthy"
  else
    say "结论: unhealthy"
  fi
}

case "${1:-start}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; sleep 1; cmd_start ;;
  status)  cmd_status ;;
  once)    cmd_once ;;
  run)     cmd_run ;;
  *) say "用法: $0 {start|stop|restart|status|once}"; exit 1 ;;
esac
