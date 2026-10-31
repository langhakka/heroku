#!/usr/bin/env bash
# =============================================================================
# watchdog.sh - 守护临时节点：进程掉了自动拉起，隧道域名变了自动换链接
#
#   bash test/watchdog.sh start     # 后台启动守护（若节点没起会先拉起）
#   bash test/watchdog.sh status    # 看守护/节点/隧道状态 + 当前链接
#   bash test/watchdog.sh stop      # 停止守护（可选同时停节点: stop --all）
#   bash test/watchdog.sh once      # 只检查并修复一次（前台，便于排查）
#
# 能力边界（实测过的）：
#   ✅ 容器还在跑，但 xray 挂了 / cloudflared 掉了 / 隧道域名被回收 → 自动恢复，并重写链接
#   ✅ 隧道虽然活着但握手坏掉（101 自检失败）→ 自动重建隧道
#   ❌ 整个容器被重建（/tmp 清空、所有进程消失）→ 容器内的守护也一起没了，
#      只能靠外部（新会话里跑一次 start，或在真 VPS 上用 deploy.sh）
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR="${VLESS_DEMO_DIR:-$HERE/../.cache/vless-demo}"
XRAY_BIN="$STATE_DIR/xray"
CF_BIN="$STATE_DIR/cloudflared"
SRV_CFG="$STATE_DIR/server.json"
SRV_PID="$STATE_DIR/server.pid"
CF_PID="$STATE_DIR/cloudflared.pid"
CF_LOG="$STATE_DIR/cloudflared.log"
HOST_FILE="$STATE_DIR/host.txt"
IP_FILE="$STATE_DIR/ip.txt"
LINK_FILE="$STATE_DIR/link.txt"
TUNNEL_ENV="$STATE_DIR/tunnel.env"
WD_PID="$STATE_DIR/watchdog.pid"
LOG="$STATE_DIR/watchdog.log"
INTERVAL="${WATCH_INTERVAL:-15}"        # 检查间隔（秒）
CHECK_EVERY="${WATCH_CHECK_EVERY:-20}" # 每 N 轮做一次 101 握手自检

mkdir -p "$STATE_DIR"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG"; }
pid_of() { [[ -f "$1" ]] && cat "$1" 2>/dev/null || true; }
alive() { # 注意: 僵尸进程(DEFUNCT)的 kill -0 也返回成功, 必须看 /proc/<pid>/stat 的状态位
    local p st
    p=$(pid_of "$1")
    [[ -n "$p" ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
    [[ "$st" == "Z" ]] && return 1
    return 0
}

# 这个容器的 PID 1 是平台进程（不回收子进程），我们自己回收，否则每次重启
# xray/cloudflared 都会留下一个 <defunct>，越堆越多。
reap() {
    local p st
    for p in $(jobs -p 2>/dev/null); do
        st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
        [[ "$st" == "Z" ]] && wait "$p" 2>/dev/null
    done
}

# 日志轮转：这些日志都是 O_APPEND 打开，截断后下一次写会回到文件头，安全
rotate() {
    local f="$1" max="${2:-1048576}" sz=0
    [[ -f "$f" ]] || return 0
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    if (( sz > max )); then
        : > "$f"
        log "[rotate] $(basename "$f") 超过 $((max / 1024))KB，已截断"
    fi
}

doh_ip() {
    curl -sS -m 8 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null \
        | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(d["Answer"][0]["data"] if d.get("Answer") else "")
except Exception:
    print("")' 2>/dev/null
}

gen_link() { # 用现有 server.json 里的 uuid/path + host 重新生成链接
    python3 - "$STATE_DIR" "$HERE" "$1" <<'PY'
import json, os, subprocess, sys
state, here, host = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(os.path.join(state, "server.json")))
inb = cfg["inbounds"][0]
uuid = inb["settings"]["clients"][0]["id"]
path = inb["streamSettings"]["wsSettings"]["path"]
port = inb["port"]
out = subprocess.check_output([
    "python3", os.path.join(here, "gen-node-link.py"),
    "--add", host, "--port", "443" if host != "127.0.0.1" else str(port),
    "--id", uuid, "--path", path, "--host", host, "--ps", "demo-vless",
] + (["--tls"] if host != "127.0.0.1" else []), text=True)
print(out.strip())
PY
}

start_server() {
    if [[ ! -f "$SRV_CFG" ]]; then
        log "[bootstrap] 没有配置，调用 demo-node.sh 初始化"
        bash "$HERE/test/demo-node.sh" >>"$LOG" 2>&1
        return 0
    fi
    log "[restart] xray 未运行，正在拉起"
    nohup "$XRAY_BIN" run -config "$SRV_CFG" >>"$STATE_DIR/server.log" 2>&1 &
    echo $! > "$SRV_PID"
    sleep 1
    if alive "$SRV_PID"; then log "[ok] xray 已恢复 pid=$(pid_of "$SRV_PID")"; else log "[fail] xray 启动失败"; fi
}

start_tunnel() {
    local port host=""
    port=$(python3 -c "import json;print(json.load(open('$SRV_CFG'))['inbounds'][0]['port'])")
    : > "$CF_LOG"   # 清空旧日志，否则会 grep 到上一次的随机域名（quick tunnel 每次都不同）
    if [[ -f "$TUNNEL_ENV" ]]; then
        # 命名隧道：域名固定，重启只是重连，链接里的域名不变
        local TUNNEL_TOKEN="" TUNNEL_HOST=""
        # shellcheck disable=SC1090
        source "$TUNNEL_ENV"
        log "[restart] 命名隧道未运行，重连中（域名固定: ${TUNNEL_HOST}）"
        # token 走环境变量而不是 --token：argv 会被 ps 看到，env 只有同用户能读
        TUNNEL_TOKEN="$TUNNEL_TOKEN" nohup "$CF_BIN" tunnel --no-autoupdate run >>"$CF_LOG" 2>&1 &
        echo $! > "$CF_PID"
        for _ in $(seq 1 40); do
            grep -qiE 'Registered tunnel connection' "$CF_LOG" && break
            sleep 1
        done
        host="$TUNNEL_HOST"
    else
        log "[restart] cloudflared 未运行，重建 quick tunnel（域名会变）"
        nohup "$CF_BIN" tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:${port}" >>"$CF_LOG" 2>&1 &
        echo $! > "$CF_PID"
        for _ in $(seq 1 60); do
            host=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -1 | sed 's#https://##')
            [[ -n "$host" ]] && break
            sleep 1
        done
    fi
    if [[ -z "$host" ]]; then log "[fail] 隧道重建失败，稍后重试"; return 1; fi
    echo "$host" > "$HOST_FILE"
    local ip=""
    for _ in $(seq 1 60); do ip=$(doh_ip "$host"); [[ -n "$ip" ]] && break; sleep 1; done
    [[ -n "$ip" ]] && echo "$ip" > "$IP_FILE"
    gen_link "$host" > "$LINK_FILE"
    log "[ok] 隧道已恢复: $host (ip=${ip:-未知})，链接已更新"
    log "LINK $(cat "$LINK_FILE")"
}

handshake_ok() {
    local host ip key resp
    host=$(cat "$HOST_FILE" 2>/dev/null || true)
    [[ -n "$host" ]] || return 0                 # 没隧道就跳过
    ip=$(cat "$IP_FILE" 2>/dev/null || true)
    [[ -n "$ip" ]] || ip=$(doh_ip "$host")
    [[ -n "$ip" ]] || return 1
    key=$(head -c 16 /dev/urandom | base64)
    local path
    path=$(python3 -c "import json;print(json.load(open('$SRV_CFG'))['inbounds'][0]['streamSettings']['wsSettings']['path'])")
    resp=$(curl -sS -i -m 10 --http1.1 --resolve "${host}:443:${ip}" \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $key" \
        "https://${host}${path}" 2>/dev/null | head -3)
    echo "$resp" | grep -q ' 101'
}

loop() {
    log "[start] 守护启动 pid=$$ interval=${INTERVAL}s"
    local round=0 fails=0
    while true; do
        reap                                   # 回收已退出的子进程，别让僵尸堆积
        alive "$SRV_PID" || start_server
        alive "$CF_PID"  || start_tunnel
        round=$((round+1))
        if (( round % 40 == 0 )); then          # 约 10 分钟轮转一次超限日志
            rotate "$CF_LOG" 1048576
            rotate "$STATE_DIR/server.log" 1048576
            rotate "$LOG" 524288
        fi
        if (( round % CHECK_EVERY == 0 )) && alive "$CF_PID"; then
            if handshake_ok; then
                (( fails > 0 )) && log "[ok] 自检恢复正常"
                fails=0
            else
                fails=$((fails+1))
                log "[warn] 101 自检失败（连续 $fails 次）"
                if (( fails >= 3 )); then   # 连续 3 次才重建，避免抖动导致域名无谓变动
                    log "[warn] 连续失败，重建隧道"
                    local old; old=$(pid_of "$CF_PID")
                    [[ -n "$old" ]] && kill "$old" 2>/dev/null
                    rm -f "$CF_PID"; sleep 2
                    start_tunnel
                    fails=0
                fi
            fi
        fi
        sleep "$INTERVAL"
    done
}

case "${1:-start}" in
    start)
        if alive "$WD_PID"; then echo "守护已在运行 pid=$(pid_of "$WD_PID")"; exit 0; fi
        [[ -x "$XRAY_BIN" ]] || { echo "缺少 $XRAY_BIN，先跑一次 bash test/demo-node.sh" >&2; exit 1; }
        setsid nohup bash "$0" _loop >>"$STATE_DIR/watchdog.stderr" 2>&1 < /dev/null &
        echo $! > "$WD_PID"
        sleep 1
        echo "守护已启动 pid=$(pid_of "$WD_PID")"
        ;;
    _loop) loop ;;
    once)
        alive "$SRV_PID" || start_server
        alive "$CF_PID"  || start_tunnel
        if handshake_ok; then echo "自检: 101 OK"; else echo "自检: 失败（可跑 demo-node.sh 重建）"; fi
        [[ -f "$LINK_FILE" ]] && { echo "当前链接:"; cat "$LINK_FILE"; }
        ;;
    status)
        if alive "$WD_PID"; then echo "守护: 运行中 pid=$(pid_of "$WD_PID")"; else echo "守护: 未运行"; fi
        if alive "$SRV_PID"; then echo "节点: 运行中 pid=$(pid_of "$SRV_PID")"; else echo "节点: 未运行"; fi
        if alive "$CF_PID"; then echo "隧道: 运行中 pid=$(pid_of "$CF_PID") 域名=$(cat "$HOST_FILE" 2>/dev/null)"; else echo "隧道: 未运行"; fi
        echo "自检: $(handshake_ok && echo '101 OK' || echo '未通过')"
        [[ -f "$LINK_FILE" ]] && { echo "当前链接:"; cat "$LINK_FILE"; }
        echo "最近事件:"; tail -5 "$LOG" 2>/dev/null
        ;;
    stop)
        if alive "$WD_PID"; then kill "$(pid_of "$WD_PID")" 2>/dev/null && echo "守护已停止"; rm -f "$WD_PID"; else echo "守护未在运行"; fi
        if [[ "${2:-}" == "--all" ]]; then bash "$HERE/test/demo-node.sh" --stop; fi
        ;;
    *) echo "用法: $0 {start|status|stop [--all]|once}" >&2; exit 1 ;;
esac
