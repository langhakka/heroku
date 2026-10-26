#!/usr/bin/env bash
# =============================================================================
# deploy.sh - 在 VPS 上一键搭建 VMess 节点 (Xray-core)
#
#   模式 tls : VMess + WebSocket + TLS，Xray 直接监听 443（默认，推荐公网直连）
#   模式 ws  : VMess + WebSocket（明文），用于套 Cloudflare / 反向代理 / PaaS
#
# 用法:
#   sudo bash deploy.sh --domain node.example.com
#   sudo bash deploy.sh --ws --port 8080 --path /ws
#   sudo bash deploy.sh --print-only --domain node.example.com   # 只打印配置和链接
#
# 依赖: 需要 root、能访问 github.com 和包管理器源; tls 模式还需域名已解析到本机 80 端口
# =============================================================================
set -euo pipefail

MODE="tls"
DOMAIN=""
UUID=""
WS_PATH=""
PORT=""
EMAIL=""
NAME=""
CERT_FILE=""
KEY_FILE=""
PRINT_ONLY=0
XRAY_CONFIG="/usr/local/etc/xray/config.json"

usage() {
    cat <<'USAGE'
用法: sudo bash deploy.sh [选项]

  -d, --domain <域名>     tls 模式必填; 该域名需已解析到本机 (用于申请证书)
      --email <邮箱>      申请 Let's Encrypt 证书用的邮箱 (可省略)
  -u, --uuid <UUID>      节点 UUID, 省略则自动生成
  -p, --path <路径>      WebSocket 路径, 省略则随机生成
      --port <端口>      监听端口, 默认 tls:443 / ws:8080
  -n, --name <备注>      生成的 vmess:// 链接里的节点名, 默认 vmess-<域名|IP>
      --ws                ws 模式: 明文 WebSocket (套 CDN / 反代时用)
      --cert <路径>       自定义证书 fullchain (tls 模式, 跳过 certbot)
      --key <路径>        自定义私钥 (tls 模式, 跳过 certbot)
      --print-only        只生成配置和链接并打印, 不安装、不改系统
  -h, --help             显示帮助
USAGE
}

die() { echo "错误: $*" >&2; exit 1; }
log() { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*" >&2; }

rand_hex() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'; }
b64_nowrap() { base64 -w0 2>/dev/null || base64 | tr -d '\n'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        --email)     EMAIL="$2"; shift 2 ;;
        -u|--uuid)   UUID="$2"; shift 2 ;;
        -p|--path)   WS_PATH="$2"; shift 2 ;;
        --port)      PORT="$2"; shift 2 ;;
        -n|--name)   NAME="$2"; shift 2 ;;
        --ws|--no-tls) MODE="ws"; shift ;;
        --cert)      CERT_FILE="$2"; shift 2 ;;
        --key)       KEY_FILE="$2"; shift 2 ;;
        --print-only) PRINT_ONLY=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "未知参数: $1 (用 --help 查看用法)" ;;
    esac
done

# ---- 参数校验与默认值 -------------------------------------------------------
[[ -n "$UUID" ]] || UUID=$(gen_uuid)
[[ -n "$WS_PATH" ]] || WS_PATH="/vmess-$(rand_hex 4)"
WS_PATH="/${WS_PATH#/}"

if [[ "$MODE" == "tls" ]]; then
    [[ -n "$DOMAIN" ]] || die "tls 模式需要 --domain；若只想套 CDN/反代，请加 --ws"
    PORT="${PORT:-443}"
    [[ -z "$CERT_FILE" ]] && CERT_FILE="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    [[ -z "$KEY_FILE" ]]  && KEY_FILE="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    ADDR="$DOMAIN"; SNI="$DOMAIN"; TLS_FIELD="tls"; ALPN_FIELD="http/1.1"
else
    PORT="${PORT:-8080}"
    ADDR="${DOMAIN:-$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo 'YOUR_SERVER_IP')}"
    SNI="$DOMAIN"; TLS_FIELD="none"; ALPN_FIELD=""
fi
[[ -n "$NAME" ]] || NAME="vmess-${DOMAIN:-$ADDR}"

# ---- 生成服务端配置 ---------------------------------------------------------
render_config() {
    if [[ "$MODE" == "tls" ]]; then
        cat <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "id": "${UUID}", "alterId": 0, "level": 0 }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": { "path": "${WS_PATH}", "maxEarlyData": 2048 },
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "minVersion": "1.2",
          "certificates": [
            { "certificateFile": "${CERT_FILE}", "keyFile": "${KEY_FILE}" }
          ]
        }
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
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF
    else
        cat <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "id": "${UUID}", "alterId": 0, "level": 0 }
        ]
      },
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
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF
    fi
}

# ---- 生成 vmess:// 分享链接 (v2rayN / v2rayNG / Shadowrocket 通用) ----------
render_link() {
    local json
    json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"%s","sni":"%s","alpn":"%s","fp":""}' \
        "$NAME" "$ADDR" "$PORT" "$UUID" "$DOMAIN" "$WS_PATH" "$TLS_FIELD" "$SNI" "$ALPN_FIELD")
    printf 'vmess://%s\n' "$(printf '%s' "$json" | b64_nowrap)"
}

# ---- 生成客户端 outbound 配置 (手动配置 / 排查用) ---------------------------
render_client_json() {
    cat <<EOF
{
  "outbounds": [
    {
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "${ADDR}",
            "port": ${PORT},
            "users": [ { "id": "${UUID}", "alterId": 0, "security": "auto" } ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "${TLS_FIELD}",
        "wsSettings": { "path": "${WS_PATH}", "headers": { "Host": "${DOMAIN:-$ADDR}" } },
        "tlsSettings": { "serverName": "${SNI:-$ADDR}", "alpn": ["http/1.1"] }
      }
    }
  ]
}
EOF
}

# ---- 主流程 -----------------------------------------------------------------
if [[ $PRINT_ONLY -eq 1 ]]; then
    echo "===== ${XRAY_CONFIG} ====="
    render_config
    echo
    echo "===== vmess:// 分享链接 ====="
    render_link
    echo
    echo "===== 客户端 JSON (手动配置用) ====="
    render_client_json
    exit 0
fi

[[ $EUID -eq 0 ]] || die "请用 root 运行: sudo bash $0 ..."

# 1. 基础依赖
if command -v apt-get >/dev/null 2>&1; then
    PKG=apt-get
elif command -v dnf >/dev/null 2>&1; then
    PKG=dnf
elif command -v yum >/dev/null 2>&1; then
    PKG=yum
else
    die "仅支持 apt / dnf / yum 的系统"
fi

install_pkgs() {
    case "$PKG" in
        apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null ;;
        dnf) dnf install -y -q "$@" >/dev/null ;;
        yum) yum install -y -q "$@" >/dev/null ;;
    esac
}

log "安装依赖 (curl / openssl / ca-certificates)"
install_pkgs curl openssl ca-certificates

# 2. 安装 Xray-core (官方安装脚本, 已装则跳过)
if ! command -v xray >/dev/null 2>&1; then
    log "安装 Xray-core"
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
fi
command -v xray >/dev/null 2>&1 || die "Xray 安装失败"
log "Xray 版本: $(xray version | head -1)"

# 3. tls 模式: 准备证书
# 注意: xray.service 以 User=xray 运行, 而 /etc/letsencrypt 下的私钥默认仅 root 可读,
# 因此把证书复制到 xray 可读目录, 由续期钩子负责再次同步。
CERT_DIR=/usr/local/etc/xray/certs
if [[ "$MODE" == "tls" ]]; then
    if [[ ! -f "$CERT_FILE" ]]; then
        log "申请 Let's Encrypt 证书: $DOMAIN"
        install_pkgs certbot
        CERT_ARGS=(certonly --standalone --non-interactive --agree-tos --keep-until-expiring -d "$DOMAIN")
        if [[ -n "$EMAIL" ]]; then CERT_ARGS+=(-m "$EMAIL"); else CERT_ARGS+=(--register-unsafely-without-email); fi
        if ! certbot "${CERT_ARGS[@]}"; then
            die "证书申请失败。请确认 $DOMAIN 已解析到本机且 80 端口可访问；或改用 --ws 模式套 CDN"
        fi
    fi
    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || die "证书文件不存在: $CERT_FILE / $KEY_FILE"
    install -d -m 750 "$CERT_DIR" 2>/dev/null || mkdir -p "$CERT_DIR"
    SRC_CERT="$CERT_FILE"; SRC_KEY="$KEY_FILE"
    [[ "$SRC_CERT" -ef "$CERT_DIR/fullchain.pem" ]] || install -m 640 "$SRC_CERT" "$CERT_DIR/fullchain.pem"
    [[ "$SRC_KEY"  -ef "$CERT_DIR/privkey.pem"   ]] || install -m 640 "$SRC_KEY"  "$CERT_DIR/privkey.pem"
    chown -R xray:xray "$CERT_DIR" 2>/dev/null || true
    chmod 750 "$CERT_DIR"
    CERT_FILE="$CERT_DIR/fullchain.pem"; KEY_FILE="$CERT_DIR/privkey.pem"

    # 续期后把新证书同步过来并重启
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-xray.sh <<HOOK
#!/bin/sh
# 由 deploy.sh 生成: 同步证书到 xray 可读目录并重启
set -e
COPY() { [ -f "\$1" ] && install -m 640 "\$1" "\$2"; }
COPY "$SRC_CERT" "$CERT_DIR/fullchain.pem" || true
COPY "$SRC_KEY"  "$CERT_DIR/privkey.pem" || true
chown xray:xray "$CERT_DIR"/*.pem 2>/dev/null || true
systemctl restart xray 2>/dev/null || true
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-xray.sh
fi

# 4. 写入配置并做语法自检
CONFIG_JSON=$(render_config)
mkdir -p "$(dirname "$XRAY_CONFIG")"
printf '%s\n' "$CONFIG_JSON" > "$XRAY_CONFIG"
chown root:xray "$XRAY_CONFIG" 2>/dev/null || true
chmod 640 "$XRAY_CONFIG"
log "校验配置: $XRAY_CONFIG"
xray run -test -config "$XRAY_CONFIG" >/dev/null || die "配置校验未通过"

# 5. systemd 服务 (官方脚本已提供 xray.service, 确保启用并重启)
systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
    log "xray 服务已启动"
else
    journalctl -u xray -n 20 --no-pager || true
    die "xray 启动失败，见上面日志"
fi

# 6. 防火墙提示
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log "放行 ufw 端口 $PORT/tcp"
    ufw allow "${PORT}/tcp" >/dev/null || true
fi

# 7. 输出结果
LINK=$(render_link)
echo
cat <<EOF
==================== 部署完成 ====================
模式        : $MODE (VMess + WebSocket$( [[ "$MODE" == tls ]] && echo ' + TLS' ))
地址        : $ADDR
端口        : $PORT
UUID        : $UUID
WS 路径     : $WS_PATH
$( [[ "$MODE" == tls ]] && echo "证书        : $CERT_FILE" )
配置文件    : $XRAY_CONFIG
查看日志    : journalctl -u xray -f

----- vmess:// 分享链接 (复制到 v2rayN / v2rayNG / Shadowrocket) -----
$LINK

----- 客户端 JSON (手动配置用) -----
$(render_client_json)
==================================================
EOF
