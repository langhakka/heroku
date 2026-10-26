#!/usr/bin/env bash
# =============================================================================
# local-node.sh - 在本机起一个临时 VLESS 节点，用于本地测试
#
#   bash test/local-node.sh                 # 启动（WS 明文，127.0.0.1:18308）
#   bash test/local-node.sh --host 0.0.0.0  # 允许本机之外访问（如需端口转发）
#   bash test/local-node.sh --status        # 查看状态
#   bash test/local-node.sh --stop          # 停止
#
# 起来后会打印 vless:// 链接，以及一个本地 SOCKS5 端口，用 curl 即可验证链路是否真通。
# 注意: 这是测试用的临时节点（明文 WS、临时目录、随机器销毁而消失），长期使用请跑 deploy.sh
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR="${VLESS_LOCAL_DIR:-/tmp/vless-local}"
XRAY_BIN="$STATE_DIR/xray"
SRV_CFG="$STATE_DIR/server.json"
CLI_CFG="$STATE_DIR/client.json"
SRV_LOG="$STATE_DIR/server.log"
CLI_LOG="$STATE_DIR/client.log"
SRV_PID="$STATE_DIR/server.pid"
CLI_PID="$STATE_DIR/client.pid"

PORT=18308
SOCKS=1080
HOST_ARG=""
WS_PATH=""
UUID=""
ACTION=start

usage() {
    cat <<'USAGE'
用法: bash test/local-node.sh [选项]

      --port <端口>    节点监听端口, 默认 18308
      --socks <端口>   本地 SOCKS5 客户端端口, 默认 1080 (填 0 则不启动客户端)
      --host <地址>    服务端绑定地址, 默认 127.0.0.1; 需要外部访问用 0.0.0.0
                       (注意: Xray 26 只允许私有地址/本地回环上的 VLESS 不加密;
                        公网入口请用 Cloudflare 隧道或 deploy.sh 的 TLS 模式)
      --path <路径>    WS 路径, 默认随机
      --uuid <UUID>    UUID, 默认随机
      --status         查看运行状态
      --stop           停止节点和客户端
  -h, --help          显示帮助
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)   PORT="$2"; shift 2 ;;
        --socks)  SOCKS="$2"; shift 2 ;;
        --host)   HOST_ARG="$2"; shift 2 ;;
        --path)   WS_PATH="$2"; shift 2 ;;
        --uuid)   UUID="$2"; shift 2 ;;
        --status) ACTION=status; shift ;;
        --stop)   ACTION=stop; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

need_xray() {
    mkdir -p "$STATE_DIR"
    [[ -x "$XRAY_BIN" ]] && return 0
    echo "[+] 下载 Xray-core ..."
    case "$(uname -m)" in
        x86_64|amd64) pkg=Xray-linux-64 ;;
        aarch64|arm64) pkg=Xray-linux-arm64-v8a ;;
        *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
    esac
    curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${pkg}.zip" -o "$STATE_DIR/xray.zip" \
        && python3 -c "import zipfile;zipfile.ZipFile('$STATE_DIR/xray.zip').extractall('$STATE_DIR')" \
        && rm -f "$STATE_DIR/xray.zip" && chmod +x "$XRAY_BIN" || { echo "下载失败" >&2; exit 1; }
}

pid_of() { [[ -f "$1" ]] && cat "$1" 2>/dev/null || true; }
is_running() { local p; p=$(pid_of "$1"); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

stop_all() {
    for f in "$SRV_PID" "$CLI_PID"; do
        local p; p=$(pid_of "$f")
        [[ -n "$p" ]] && kill "$p" 2>/dev/null && echo "已停止 pid=$p ($(basename "$f" .pid))"
        rm -f "$f"
    done
}

cfg_port() { # $1=配置文件 -> 打印第一个 port 值
    [[ -f "$1" ]] && grep -o '"port": [0-9]*' "$1" | head -1 | grep -o '[0-9]*' || echo "?"
}

status_all() {
    if is_running "$SRV_PID"; then
        echo "服务端: 运行中 pid=$(pid_of "$SRV_PID") 端口=$(cfg_port "$SRV_CFG")"
        [[ -f "$SRV_CFG" ]] && grep -o '"path": "[^"]*"' "$SRV_CFG" | head -1
    else
        echo "服务端: 未运行"
    fi
    if is_running "$CLI_PID"; then
        echo "客户端: 运行中 pid=$(pid_of "$CLI_PID") SOCKS=127.0.0.1:$(cfg_port "$CLI_CFG")"
    else
        echo "客户端: 未运行"
    fi
}

[[ "$ACTION" == "stop" ]] && { stop_all; exit 0; }
[[ "$ACTION" == "status" ]] && { status_all; exit 0; }

need_xray
command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }

# 已有实例先停掉，避免端口冲突
stop_all

[[ -n "$UUID" ]] || UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')
[[ -n "$WS_PATH" ]] || WS_PATH="/local-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
WS_PATH="/${WS_PATH#/}"
LISTEN="${HOST_ARG:-127.0.0.1}"
if [[ "$LISTEN" == "0.0.0.0" ]]; then
    DIAL_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
    DIAL_HOST=${DIAL_HOST:-127.0.0.1}
else
    DIAL_HOST="$LISTEN"
fi
mkdir -p "$STATE_DIR"

cat > "$SRV_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "${LISTEN}",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {"clients": [ { "id": "${UUID}", "level": 0, "flow": "" } ], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "${WS_PATH}" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [ { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" } ]
  }
}
EOF

"$XRAY_BIN" run -test -config "$SRV_CFG" >/dev/null 2>&1 || { echo "服务端配置校验失败" >&2; exit 1; }
nohup "$XRAY_BIN" run -config "$SRV_CFG" > "$SRV_LOG" 2>&1 &
echo $! > "$SRV_PID"

if [[ "$SOCKS" != "0" ]]; then
    cat > "$CLI_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": ${SOCKS}, "protocol": "socks", "settings": { "udp": false } }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "127.0.0.1",
            "port": ${PORT},
            "users": [ { "id": "${UUID}", "encryption": "none", "flow": "" } ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "${WS_PATH}", "headers": { "Host": "127.0.0.1" } }
      }
    }
  ]
}
EOF
    nohup "$XRAY_BIN" run -config "$CLI_CFG" > "$CLI_LOG" 2>&1 &
    echo $! > "$CLI_PID"
fi

sleep 1.5
LINK=$(python3 "$HERE/gen-node-link.py" --add "$DIAL_HOST" --port "$PORT" --id "$UUID" \
        --path "$WS_PATH" --host "$DIAL_HOST" --ps "local-vless")
IP_ALL=$(hostname -I 2>/dev/null | xargs)
cat <<EOF

==================== 本机临时 VLESS 节点已启动 ====================
监听        : ${LISTEN}:${PORT}  (WS 明文, path=${WS_PATH})
UUID        : ${UUID}
本机 IP     : ${IP_ALL:-127.0.0.1}
状态目录    : ${STATE_DIR}
服务端日志  : ${SRV_LOG}
$( [[ "$SOCKS" != "0" ]] && echo "SOCKS 客户端: 127.0.0.1:${SOCKS}" )

----- vless:// 分享链接 -----
${LINK}

----- 立刻验证链路是否真通 -----
curl -sS --socks5-hostname 127.0.0.1:${SOCKS} https://api.ipify.org; echo

----- 管理 -----
bash test/local-node.sh --status
bash test/local-node.sh --stop
===================================================================
EOF
