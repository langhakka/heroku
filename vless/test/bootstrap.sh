#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - 幂等引导：确保"固定域名节点"在线（容器/进程重启后一条命令恢复）
#
#   bash vless/test/bootstrap.sh              # 不健康就恢复，健康则直接退出（0）
#   bash vless/test/bootstrap.sh --check      # 只体检：健康 exit 0，不健康 exit 2
#   bash vless/test/bootstrap.sh --force      # 即使健康也重建一遍
#   bash vless/test/bootstrap.sh --export     # 打印可保存到密钥管理器的 env 片段
#   bash vless/test/bootstrap.sh --no-tunnel  # 没有 token 时允许退回临时隧道
#
# 解析优先级：命令行参数 > 环境变量 > 状态目录(.cache/vless-demo) > 备份目录
#
# 为什么要有备份：`.cache/` 被 gitignore，容器重建时会丢。本脚本每次恢复成功后
# 会把 token/UUID/路径/端口同步到 $HOME/.config/vless-node/state.env（600）。
# 这样即使 .cache 清空，只要备份还在，一条命令就能恢复成"完全一样"的节点。
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)                 # vless/
REPO=$(cd "$HERE/.." && pwd)
STATE_DIR="${VLESS_STATE_DIR:-${VLESS_DEMO_DIR:-$REPO/.cache/vless-demo}}"
BACKUP_DIR="${VLESS_BACKUP_DIR:-$HOME/.config/vless-node}"
BACKUP_ENV="$BACKUP_DIR/state.env"
IDENT_FILE="$STATE_DIR/identity.env"
TUNNEL_ENV="$STATE_DIR/tunnel.env"
LINK_FILE="$STATE_DIR/link.txt"
HOST_FILE="$STATE_DIR/host.txt"
SRV_CFG="$STATE_DIR/server.json"
SRV_PID="$STATE_DIR/server.pid"
CF_PID="$STATE_DIR/cloudflared.pid"

CHECK_ONLY=0; FORCE=0; EXPORT=0; NO_TUNNEL=0; QUIET=0
TOKEN_FILE=""; HOST_ARG=""; PORT_ARG=""; UUID_ARG=""; PATH_ARG=""

# 先抓住环境变量里给的（后面 source 状态文件会覆盖同名变量，故先留底）
ENV_TOKEN="${TUNNEL_TOKEN:-}"
ENV_HOST="${TUNNEL_HOST:-}"
ENV_UUID="${VLESS_UUID:-}"
ENV_PATH="${VLESS_PATH:-}"
ENV_PORT="${VLESS_PORT:-}"

say() { [[ $QUIET -eq 1 ]] || echo "$@"; }
warn() { echo "$@" >&2; }

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --force) FORCE=1; shift ;;
        --export) EXPORT=1; shift ;;
        --no-tunnel) NO_TUNNEL=1; shift ;;
        -q|--quiet) QUIET=1; shift ;;
        --token-file) TOKEN_FILE="$2"; shift 2 ;;
        --host) HOST_ARG="$2"; shift 2 ;;
        --port) PORT_ARG="$2"; shift 2 ;;
        --uuid) UUID_ARG="$2"; shift 2 ;;
        --path) PATH_ARG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "未知参数: $1"; exit 1 ;;
    esac
done

# ---------- 基础工具 ---------------------------------------------------------
pid_of() { [[ -f "$1" ]] && cat "$1" 2>/dev/null || true; }

alive() {  # 僵尸进程的 kill -0 也返回成功，必须看 /proc/<pid>/stat 的状态位
    local p st
    p=$(pid_of "$1"); [[ -n "$p" ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
    [[ "$st" == "Z" ]] && return 1
    return 0
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

ws_ok() {  # $1=host $2=path -> WebSocket 升级返回 101 才算真的通
    local host="$1" path="$2" ip key resp i
    [[ -n "$host" && -n "$path" ]] || return 1
    ip=$(doh_ip "$host")
    key=$(head -c 16 /dev/urandom | base64)
    local resolve=()
    [[ -n "$ip" ]] && resolve=(--resolve "${host}:443:${ip}")
    for i in 1 2 3; do
        resp=$(curl -sS -i -m 10 --http1.1 ${resolve[@]+"${resolve[@]}"} \
            -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
            -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $key" \
            "https://${host}${path}" 2>/dev/null | head -3)
        echo "$resp" | grep -q ' 101' && return 0
        sleep 2
    done
    return 1
}

link_host() { [[ -f "$HOST_FILE" ]] && cat "$HOST_FILE" 2>/dev/null || true; }
link_path() {
    [[ -f "$SRV_CFG" ]] || return 0
    grep -o '"path": "*[^",]*' "$SRV_CFG" 2>/dev/null | head -1 | sed 's/.*: *"\{0,1\}//'
}

# 把"恢复所需的一切"写到备份目录（含 token，600 权限，工作目录之外）
save_backup() {
    local u="" p="" po=""
    if [[ -f "$IDENT_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$IDENT_FILE"
        u="${NODE_UUID:-}"; p="${NODE_PATH:-}"; po="${NODE_PORT:-}"
    fi
    u="${u:-$NODE_UUID}"; p="${p:-$NODE_PATH}"; po="${po:-$NODE_PORT}"
    mkdir -p "$BACKUP_DIR" 2>/dev/null && chmod 700 "$BACKUP_DIR" 2>/dev/null
    (
        umask 077
        {
            echo "# vless node backup $(date -u '+%Y-%m-%dT%H:%M:%SZ') — 含密钥，勿提交/勿外传"
            [[ -n "${TUNNEL_TOKEN:-}" ]] && echo "BK_TOKEN=$TUNNEL_TOKEN"
            [[ -n "${TUNNEL_HOST:-}"  ]] && echo "BK_HOST=$TUNNEL_HOST"
            echo "BK_UUID=$u"
            echo "BK_PATH=$p"
            echo "BK_PORT=$po"
        } > "$BACKUP_ENV"
    ) && chmod 600 "$BACKUP_ENV"
}

# 启动最外层保活（supervisor → watchdog → 节点）；幂等，已在跑就跳过
ensure_supervisor() {
    [[ -f "$HERE/test/supervise.sh" ]] || return 0
    if [[ $QUIET -eq 1 ]]; then
        bash "$HERE/test/supervise.sh" start >/dev/null 2>&1 || true
    else
        bash "$HERE/test/supervise.sh" start 2>/dev/null || true
    fi
}

# ---------- 收集各处记忆的参数 ------------------------------------------------
ST_UUID=""; ST_PATH=""; ST_PORT=""; ST_TOKEN=""; ST_HOST=""
BK_TOKEN=""; BK_HOST=""; BK_UUID=""; BK_PATH=""; BK_PORT=""

if [[ -f "$IDENT_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$IDENT_FILE"                     # NODE_UUID / NODE_PATH / NODE_PORT
    ST_UUID="${NODE_UUID:-}"; ST_PATH="${NODE_PATH:-}"; ST_PORT="${NODE_PORT:-}"
fi
if [[ -f "$TUNNEL_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$TUNNEL_ENV"                     # TUNNEL_TOKEN / TUNNEL_HOST
    ST_TOKEN="${TUNNEL_TOKEN:-}"; ST_HOST="${TUNNEL_HOST:-}"
fi
if [[ -f "$BACKUP_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$BACKUP_ENV"                     # BK_TOKEN / BK_HOST / BK_UUID / BK_PATH / BK_PORT
fi

FILE_TOKEN=""
if [[ -n "$TOKEN_FILE" && -f "$TOKEN_FILE" ]]; then
    FILE_TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
fi

# 逐项合并：命令行 > token 文件 > 环境变量 > 状态目录 > 备份
TUNNEL_TOKEN="${FILE_TOKEN:-${ENV_TOKEN:-${ST_TOKEN:-${BK_TOKEN:-}}}}"
TUNNEL_HOST="${HOST_ARG:-${ENV_HOST:-${ST_HOST:-${BK_HOST:-}}}}"
NODE_UUID="${UUID_ARG:-${ENV_UUID:-${ST_UUID:-${BK_UUID:-}}}}"
NODE_PATH="${PATH_ARG:-${ENV_PATH:-${ST_PATH:-${BK_PATH:-}}}}"
NODE_PORT="${PORT_ARG:-${ENV_PORT:-${ST_PORT:-${BK_PORT:-}}}}"
[[ -n "$NODE_PORT" ]] || NODE_PORT=8001      # 命名隧道默认对齐 CF 后台的 localhost:8001
[[ $NO_TUNNEL -eq 1 ]] && { TUNNEL_TOKEN=""; TUNNEL_HOST=""; }

# ---------- --export：把恢复所需的东西吐出来，方便存进密钥管理器 ---------------
if [[ $EXPORT -eq 1 ]]; then
    echo "# 存到 GitHub Secrets / 密码管理器 / 平台环境变量；不要提交进仓库"
    [[ -n "$TUNNEL_TOKEN" ]] && echo "export TUNNEL_TOKEN='$TUNNEL_TOKEN'"
    [[ -n "$TUNNEL_HOST"  ]] && echo "export TUNNEL_HOST='$TUNNEL_HOST'"
    [[ -n "$NODE_UUID"    ]] && echo "export VLESS_UUID='$NODE_UUID'"
    [[ -n "$NODE_PATH"    ]] && echo "export VLESS_PATH='$NODE_PATH'"
    [[ -n "$NODE_PORT"    ]] && echo "export VLESS_PORT='$NODE_PORT'"
    exit 0
fi

# ---------- 健康检查 ----------------------------------------------------------
healthy() {
    alive "$SRV_PID" || return 1
    alive "$CF_PID"  || return 1
    local h p
    h=$(link_host); p=$(link_path)
    [[ -n "$h" && -n "$p" ]] || return 1
    ws_ok "$h" "$p"
}

if healthy; then
    if [[ $CHECK_ONLY -eq 1 ]]; then
        say "[ok] 节点健康：$(link_host)（101 通过）"
        exit 0
    fi
    if [[ $FORCE -eq 0 ]]; then
        save_backup && say "[ok] 身份已同步到备份 $BACKUP_ENV"
        ensure_supervisor
        say "[ok] 节点已在线，无需重建：$(link_host)"
        [[ -f "$LINK_FILE" ]] && say "$(cat "$LINK_FILE")"
        exit 0
    fi
    say "[i] --force：强制重建"
elif [[ $CHECK_ONLY -eq 1 ]]; then
    say "[no] 节点不健康（进程缺失或 101 失败）"
    exit 2
fi

# ---------- 恢复 -------------------------------------------------------------
if [[ -z "$TUNNEL_TOKEN" ]]; then
    warn "[!] 没有命名隧道 token：本次只能起临时隧道（域名会变）。"
    warn "    拿到 token 后可用 TUNNEL_TOKEN=... 或 --token-file <文件>，再跑一次即可接回固定域名。"
fi

args=(--port "$NODE_PORT")
[[ -n "$NODE_UUID" ]] && args+=(--uuid "$NODE_UUID")
[[ -n "$NODE_PATH" ]] && args+=(--path "$NODE_PATH")
if [[ -n "$TUNNEL_TOKEN" && -n "$TUNNEL_HOST" ]]; then
    args+=(--tunnel-token "$TUNNEL_TOKEN" --tunnel-host "$TUNNEL_HOST")
fi

say "[+] 按记忆恢复：port=$NODE_PORT uuid=${NODE_UUID:-<沿用>} path=${NODE_PATH:-<沿用>} host=${TUNNEL_HOST:-<临时域名>}"
if [[ $QUIET -eq 1 ]]; then
    bash "$HERE/test/demo-node.sh" "${args[@]}" >/dev/null 2>&1
else
    bash "$HERE/test/demo-node.sh" "${args[@]}"
fi
rc=$?
if [[ $rc -ne 0 ]]; then
    warn "[x] 恢复失败（exit=$rc），看 $STATE_DIR/server.log 与 $STATE_DIR/cloudflared.log"
    exit 1
fi

h=$(link_host); p=$(link_path)
if ! ws_ok "$h" "$p"; then
    warn "[x] 进程起来了但 101 自检失败：host=$h path=$p（见 $STATE_DIR/cloudflared.log）"
    exit 1
fi

# ---------- 成功后把身份写回备份（下次 .cache 没了也能恢复）--------------------
[[ -f "$IDENT_FILE" ]] && { source "$IDENT_FILE"; NODE_UUID="${NODE_UUID:-}"; NODE_PATH="${NODE_PATH:-}"; NODE_PORT="${NODE_PORT:-}"; }
[[ -f "$TUNNEL_ENV" ]] && source "$TUNNEL_ENV"
save_backup && say "[ok] 恢复完成，身份已备份到 $BACKUP_ENV"
ensure_supervisor
say "$(cat "$LINK_FILE" 2>/dev/null)"
exit 0
