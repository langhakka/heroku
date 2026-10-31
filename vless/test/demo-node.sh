#!/usr/bin/env bash
# =============================================================================
# demo-node.sh - 一条命令起"临时测试节点"（VLESS + WS + Cloudflare 临时隧道）
#
#   bash test/demo-node.sh              # 起节点 + 隧道，打印 vless:// 链接
#   bash test/demo-node.sh --status     # 看状态和当前链接
#   bash test/demo-node.sh --stop       # 全部停掉
#
# 用途：沙箱/临时机器上快速拿到一条「手机能连」的测试链路。
# 注意：隧道域名每次重启都变，进程随机器销毁而消失 —— 长期使用请跑 deploy.sh
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR="${VLESS_DEMO_DIR:-$HERE/../.cache/vless-demo}"
XRAY_BIN="$STATE_DIR/xray"
CF_BIN="$STATE_DIR/cloudflared"
SRV_CFG="$STATE_DIR/server.json"
SRV_LOG="$STATE_DIR/server.log"
CF_LOG="$STATE_DIR/cloudflared.log"
SRV_PID="$STATE_DIR/server.pid"
CF_PID="$STATE_DIR/cloudflared.pid"
LINK_FILE="$STATE_DIR/link.txt"
HOST_FILE="$STATE_DIR/host.txt"

IDENT_FILE="$STATE_DIR/identity.env"   # 固定 UUID / WS 路径，重启后复用
TUNNEL_ENV="$STATE_DIR/tunnel.env"     # 命名隧道（固定域名）的参数
PORT=18308
PORT_SET=0
WS_PATH=""
UUID=""
ACTION=start
TUNNEL=1
WATCH=1
NEW_IDENT=0
FORGET_TUNNEL=0
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
TUNNEL_HOST="${TUNNEL_HOST:-}"

usage() {
    cat <<'USAGE'
用法: bash test/demo-node.sh [选项]

      --port <端口>   节点监听端口, 默认 18308
      --path <路径>   WS 路径, 默认随机
      --uuid <UUID>   UUID, 默认复用上次的（没有则随机）
      --new           强制换一套新的 UUID + 路径
      --tunnel-token <token>   用 Cloudflare 命名隧道（固定域名），需配合 --tunnel-host
      --tunnel-host <域名>     命名隧道对应的公网域名（CF 后台已配好指向该隧道）
      --no-tunnel     只起本地节点, 不开 Cloudflare 隧道
      --forget-tunnel 清除记住的命名隧道配置（tunnel.env），之后无参启动会退回临时隧道
      --no-watch      不起守护进程（默认会起，掉线自动拉起）
      --status        查看状态 + 当前链接
      --stop          停止节点和隧道
  -h, --help          帮助
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; PORT_SET=1; shift 2 ;;
        --path) WS_PATH="$2"; shift 2 ;;
        --uuid) UUID="$2"; shift 2 ;;
        --no-tunnel) TUNNEL=0; shift ;;
        --forget-tunnel) FORGET_TUNNEL=1; shift ;;
        --no-watch) WATCH=0; shift ;;
        --new) NEW_IDENT=1; shift ;;
        --tunnel-token) TUNNEL_TOKEN="$2"; shift 2 ;;
        --tunnel-host) TUNNEL_HOST="$2"; shift 2 ;;
        --status) ACTION=status; shift ;;
        --stop) ACTION=stop; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

doh_ip() { # $1=域名 -> 通过 DoH 解析 A 记录（绕开本地 DNS 负缓存）
    curl -sS -m 8 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null \
        | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(d["Answer"][0]["data"] if d.get("Answer") else "")
except Exception:
    print("")' 2>/dev/null
}

pid_of() { [[ -f "$1" ]] && cat "$1" 2>/dev/null || true; }
is_running() { local p; p=$(pid_of "$1"); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

stop_all() {
    for f in "$SRV_PID" "$CF_PID"; do
        local p; p=$(pid_of "$f")
        [[ -n "$p" ]] && kill "$p" 2>/dev/null && echo "已停止 $(basename "$f" .pid) pid=$p"
        rm -f "$f"
    done
    rm -f "$LINK_FILE" "$HOST_FILE"
}

status_all() {
    if is_running "$SRV_PID"; then
        echo "节点: 运行中 pid=$(pid_of "$SRV_PID") 端口=$(grep -o '\"port\": [0-9]*' "$SRV_CFG" | head -1 | grep -o '[0-9]*')"
        grep -o '\"path\": \"[^\"]*\"' "$SRV_CFG" | head -1
    else
        echo "节点: 未运行"
    fi
    if is_running "$CF_PID"; then
        echo "隧道: 运行中 pid=$(pid_of "$CF_PID") 域名=$(cat "$HOST_FILE" 2>/dev/null)"
    else
        echo "隧道: 未运行"
    fi
    [[ -f "$LINK_FILE" ]] && { echo; echo "当前链接:"; cat "$LINK_FILE"; }
}

# 清除记住的命名隧道配置（不动正在运行的节点/隧道）
if [[ $FORGET_TUNNEL -eq 1 ]]; then
    if [[ -f "$TUNNEL_ENV" ]]; then
        rm -f "$TUNNEL_ENV"
        echo "[+] 已删除 $TUNNEL_ENV（命名隧道配置已清除，之后无参启动会走临时隧道）"
    else
        echo "[i] 没有 $TUNNEL_ENV，无需清除"
    fi
    exit 0
fi

# 若之前配过命名隧道（tunnel.env 存在），自动沿用，避免重启后退回随机域名
if [[ $TUNNEL -eq 1 && -z "$TUNNEL_TOKEN" && -f "$TUNNEL_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$TUNNEL_ENV"
    [[ -z "$TUNNEL_HOST" ]] && TUNNEL_HOST="${TUNNEL_HOST:-}"
fi

# 命名隧道必须同时给域名，否则会拉起一个没有域名的连接（在停掉现有节点之前就拦掉）
if [[ -n "$TUNNEL_TOKEN" && -z "$TUNNEL_HOST" ]]; then
    echo "错误: 用了 --tunnel-token 必须同时指定 --tunnel-host（CF 后台已路由到该隧道的域名）" >&2
    exit 1
fi

[[ "$ACTION" == "stop" ]] && { stop_all; exit 0; }
[[ "$ACTION" == "status" ]] && { status_all; exit 0; }

mkdir -p "$STATE_DIR"

# ---- 准备二进制 -------------------------------------------------------------
arch_pkg() {
    case "$(uname -m)" in
        x86_64|amd64) echo "Xray-linux-64" ;;
        aarch64|arm64) echo "Xray-linux-arm64-v8a" ;;
        *) echo "" ;;
    esac
}
if [[ ! -x "$XRAY_BIN" ]]; then
    pkg=$(arch_pkg); [[ -n "$pkg" ]] || { echo "不支持的架构: $(uname -m)" >&2; exit 1; }
    echo "[+] 下载 Xray-core ..."
    curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${pkg}.zip" -o "$STATE_DIR/xray.zip" \
        && python3 -c "import zipfile;zipfile.ZipFile('$STATE_DIR/xray.zip').extractall('$STATE_DIR')" \
        && rm -f "$STATE_DIR/xray.zip" && chmod +x "$XRAY_BIN" || { echo "Xray 下载失败" >&2; exit 1; }
fi
if [[ $TUNNEL -eq 1 && ! -x "$CF_BIN" ]]; then
    echo "[+] 下载 cloudflared ..."
    case "$(uname -m)" in
        x86_64|amd64) cf_arch=amd64 ;;
        aarch64|arm64) cf_arch=arm64 ;;
        *) cf_arch=amd64 ;;
    esac
    curl -fsSL -m 180 -o "$CF_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" \
        && chmod +x "$CF_BIN" || { echo "cloudflared 下载失败" >&2; exit 1; }
fi
command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }

# ---- 启动节点 ---------------------------------------------------------------
stop_all
# 固定身份：重启后沿用同一 UUID / 路径，客户端配置就不用改了（--new 可强制换）
if [[ $NEW_IDENT -eq 0 && -f "$IDENT_FILE" ]]; then
    NODE_UUID=""; NODE_PATH=""
    # shellcheck disable=SC1090
    source "$IDENT_FILE"
    [[ -z "$UUID"    ]] && UUID="${NODE_UUID:-${UUID:-}}"
    [[ -z "$WS_PATH" ]] && WS_PATH="${NODE_PATH:-${WS_PATH:-}}"
    [[ $PORT_SET -eq 0 && -n "${NODE_PORT:-}" ]] && PORT="$NODE_PORT"
fi
[[ -n "$UUID" ]] || UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')
[[ -n "$WS_PATH" ]] || WS_PATH="/dl-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
WS_PATH="/${WS_PATH#/}"
printf 'NODE_UUID=%s\nNODE_PATH=%s\nNODE_PORT=%s\n' "$UUID" "$WS_PATH" "$PORT" > "$IDENT_FILE"
chmod 600 "$IDENT_FILE"

cat > "$SRV_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${PORT},
      "protocol": "vless",
      "settings": { "clients": [ { "id": "${UUID}", "level": 0, "flow": "" } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "${WS_PATH}" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": { "domainStrategy": "AsIs", "rules": [ { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" } ] }
}
EOF

"$XRAY_BIN" run -test -config "$SRV_CFG" >/dev/null 2>&1 || { echo "节点配置校验失败" >&2; exit 1; }
nohup "$XRAY_BIN" run -config "$SRV_CFG" > "$SRV_LOG" 2>&1 &
echo $! > "$SRV_PID"
sleep 1
is_running "$SRV_PID" || { echo "节点启动失败:" >&2; tail -5 "$SRV_LOG" >&2; exit 1; }

# ---- 起隧道，等域名 ---------------------------------------------------------
ADDR="127.0.0.1"
TLS_FLAG=()
if [[ $TUNNEL -eq 1 ]]; then
    host=""
    if [[ -n "$TUNNEL_TOKEN" ]]; then
        # 命名隧道: 域名固定（CF 后台已把该域名路由到这条隧道），不用再等随机域名
        if [[ -z "$TUNNEL_HOST" ]]; then
            echo "[!] 用了 --tunnel-token 就必须同时给 --tunnel-host" >&2; exit 1
        fi
        echo "[+] 使用 Cloudflare 命名隧道（固定域名 $TUNNEL_HOST）..."
        : > "$CF_LOG"
        nohup "$CF_BIN" tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" > "$CF_LOG" 2>&1 &
        echo $! > "$CF_PID"
        printf 'TUNNEL_TOKEN=%s\nTUNNEL_HOST=%s\n' "$TUNNEL_TOKEN" "$TUNNEL_HOST" > "$TUNNEL_ENV"
        chmod 600 "$TUNNEL_ENV"
        host="$TUNNEL_HOST"
        # 命名隧道的连接器注册需要几秒到几十秒，先等它注册成功再做自检
        echo -n "[+] 等待命名隧道连接"
        registered=0
        for _ in $(seq 1 40); do
            grep -qiE 'Registered tunnel connection' "$CF_LOG" && { registered=1; break; }
            grep -qiE 'token is not valid|invalid token|Unauthorized' "$CF_LOG" && break
            echo -n "."; sleep 1
        done
        echo
        if [[ $registered -eq 1 ]]; then
            echo "[+] 命名隧道已连接"
        elif grep -qiE 'token is not valid|invalid token|Unauthorized|failed to (parse|connect)' "$CF_LOG"; then
            echo "[!] 命名隧道连接失败（token 无效或后台未配置该域名）：" >&2
            grep -iE 'not valid|Unauthorized|invalid' "$CF_LOG" | head -2 >&2
            kill "$(cat "$CF_PID")" 2>/dev/null; rm -f "$CF_PID"
            host=""
            echo "[!] 已退回：只启动本地节点（未开隧道）" >&2
            echo "[!] 保留 $TUNNEL_ENV（换 token: --tunnel-token <新token>；清除: --forget-tunnel）" >&2
        else
            echo "[!] 命名隧道尚未确认连接，日志: $CF_LOG" >&2
        fi
    else
        echo "[+] 建立 Cloudflare 临时隧道 (http2) ..."
        : > "$CF_LOG"
        nohup "$CF_BIN" tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:${PORT}" > "$CF_LOG" 2>&1 &
        echo $! > "$CF_PID"
        for _ in $(seq 1 40); do
            host=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1 | sed 's#https://##')
            [[ -n "$host" ]] && break
            sleep 1
        done
        rm -f "$CF_PID"
        # 注意：这里**故意不删** tunnel.env。临时隧道跑一次不该把"固定域名"的配置抹掉，
        # 否则下次无参启动就再也回不到命名隧道了。要清除请用 --forget-tunnel。
        [[ -f "$TUNNEL_ENV" ]] && echo "[!] 已保留命名隧道配置 $TUNNEL_ENV（下次无参启动仍会走固定域名）"
    fi
    if [[ -z "$host" ]]; then
        echo "[!] 隧道建不起来（可能网络限制），只保留本地节点" >&2
        kill "$(cat "$CF_PID")" 2>/dev/null; rm -f "$CF_PID"
    else
        echo "$host" > "$HOST_FILE"
        ADDR="$host"
        TLS_FLAG=(--tls)
        # quick tunnel 的域名要过几秒到几十秒才出现在 DNS 里，等它生效再打印链接
        echo -n "[+] 等待域名 DNS 生效"
        ip=""
        for _ in $(seq 1 60); do
            ip=$(doh_ip "$host")
            [[ -n "$ip" ]] && break
            echo -n "."; sleep 1
        done
        echo
        if [[ -n "$ip" ]]; then
            echo "$ip" > "$STATE_DIR/ip.txt"
            echo "[+] 域名已解析: $host -> $ip"
        else
            echo "[!] 域名仍未解析，链接可能暂时连不上（云端 DNS 生效慢）" >&2
        fi
    fi
fi

# ---- 生成链接 ---------------------------------------------------------------
LPORT=$PORT
if [[ -n "$(cat "$HOST_FILE" 2>/dev/null)" ]]; then
    LPORT=443                      # 走隧道时客户端连 443，TLS 由 Cloudflare 边缘提供
fi
LINK=$(python3 "$HERE/gen-node-link.py" --add "$ADDR" --port "$LPORT" --id "$UUID" \
        --path "$WS_PATH" --host "$ADDR" --ps "demo-vless" ${TLS_FLAG[@]+"${TLS_FLAG[@]}"})
echo "$LINK" > "$LINK_FILE"

# ---- 自检：WS 握手应返回 101 ------------------------------------------------
# 说明: 某些环境本地 DNS 会有负缓存/解析不到 trycloudflare 域名，这里用 DoH 解析出 IP，
#       再通过 --resolve 直连，避免自检误报。
CHECK="跳过（未开隧道）"
HOST_ADDR=$(cat "$HOST_FILE" 2>/dev/null || true)
if [[ -n "$HOST_ADDR" ]]; then
    IP=$(cat "$STATE_DIR/ip.txt" 2>/dev/null || true)
    [[ -n "$IP" ]] || IP=$(doh_ip "$HOST_ADDR")
    KEY=$(head -c 16 /dev/urandom | base64)
    RESOLVE_ARG=()
    [[ -n "$IP" ]] && RESOLVE_ARG=(--resolve "${HOST_ADDR}:443:${IP}")
    # 注意: set -o pipefail 下 curl 会因 -m 超时返回非 0（连接保持不断，属正常），
    # 所以先抓取响应头再判断，而不是直接用管道退出码。
    RESP=""
    for _try in 1 2 3; do   # 刚连上隧道时可能有一两秒窗口，重试 3 次避免误报
        RESP=$(curl -sS -i -m 10 --http1.1 ${RESOLVE_ARG[@]+"${RESOLVE_ARG[@]}"} \
            -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
            -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $KEY" \
            "https://${HOST_ADDR}${WS_PATH}" 2>/dev/null | head -3)
        echo "$RESP" | grep -q ' 101' && break
        sleep 2
    done
    if echo "$RESP" | grep -q ' 101'; then
        CHECK="101 Switching Protocols（隧道 → 节点 正常）"
    else
        CHECK="握手未通过，查看 ${CF_LOG}"
    fi
fi

cat <<EOF

==================== 临时测试节点已就绪 ====================
监听     : 127.0.0.1:${PORT}
UUID     : ${UUID}
WS 路径  : ${WS_PATH}
隧道域名 : $(cat "$HOST_FILE" 2>/dev/null || echo "(未启用)")
握手自检 : ${CHECK}
状态目录 : ${STATE_DIR}

----- vless:// 链接（导入客户端）-----
${LINK}

----- 管理 -----
bash test/demo-node.sh --status
bash test/demo-node.sh --stop
============================================================
EOF

if [[ $WATCH -eq 1 ]]; then
    bash "$HERE/test/watchdog.sh" start 2>/dev/null | sed 's/^/[+] /'
    echo "[+] 守护已启动：进程掉了会自动拉起（bash test/watchdog.sh status / stop）"
fi
