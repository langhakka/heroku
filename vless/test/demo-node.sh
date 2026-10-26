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
STATE_DIR="${VLESS_DEMO_DIR:-/tmp/vless-demo}"
XRAY_BIN="$STATE_DIR/xray"
CF_BIN="$STATE_DIR/cloudflared"
SRV_CFG="$STATE_DIR/server.json"
SRV_LOG="$STATE_DIR/server.log"
CF_LOG="$STATE_DIR/cloudflared.log"
SRV_PID="$STATE_DIR/server.pid"
CF_PID="$STATE_DIR/cloudflared.pid"
LINK_FILE="$STATE_DIR/link.txt"
HOST_FILE="$STATE_DIR/host.txt"

PORT=18308
WS_PATH=""
UUID=""
ACTION=start
TUNNEL=1

usage() {
    cat <<'USAGE'
用法: bash test/demo-node.sh [选项]

      --port <端口>   节点监听端口, 默认 18308
      --path <路径>   WS 路径, 默认随机
      --uuid <UUID>   UUID, 默认随机
      --no-tunnel     只起本地节点, 不开 Cloudflare 隧道
      --status        查看状态 + 当前链接
      --stop          停止节点和隧道
  -h, --help          帮助
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --path) WS_PATH="$2"; shift 2 ;;
        --uuid) UUID="$2"; shift 2 ;;
        --no-tunnel) TUNNEL=0; shift ;;
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
[[ -n "$UUID" ]] || UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')
[[ -n "$WS_PATH" ]] || WS_PATH="/dl-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
WS_PATH="/${WS_PATH#/}"

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
    echo "[+] 建立 Cloudflare 临时隧道 (http2) ..."
    nohup "$CF_BIN" tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:${PORT}" > "$CF_LOG" 2>&1 &
    echo $! > "$CF_PID"
    host=""
    for _ in $(seq 1 40); do
        host=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1 | sed 's#https://##')
        [[ -n "$host" ]] && break
        sleep 1
    done
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
    RESP=$(curl -sS -i -m 10 --http1.1 ${RESOLVE_ARG[@]+"${RESOLVE_ARG[@]}"} \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $KEY" \
        "https://${HOST_ADDR}${WS_PATH}" 2>/dev/null | head -3)
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
