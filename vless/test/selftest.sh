#!/usr/bin/env bash
# =============================================================================
# selftest.sh - 不用 VPS、不用 root，本地跑通整条链路来验证方案是否可用
#
#   bash test/selftest.sh
#
# 做的事：
#   1. 用 deploy.sh --print-only 生成 ws / tls 两种服务端配置，交给 xray -test 校验
#   2. ws 模式：本地起服务端 + 客户端，通过 SOCKS 访问外网，验证能通
#   3. 错误 WS 路径：验证连接被拒绝（路径确实是凭据）
#   4. tls 模式：自签 CA 签发证书，客户端用 pinnedPeerCertSha256 校验并连通
#
# 需要: curl, openssl, python3, 可下载 Xray（或已装 xray / 用 XRAY_BIN 指定）
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
UUID="9b2f3c1d-4e5f-4a6b-8c7d-0e1f2a3b4c5d"
PATH_WS="/selftest-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PASS=0; FAIL=0
PIDS=()

cleanup() {
    for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { echo -e "  \033[32mPASS\033[0m  $*"; PASS=$((PASS+1)); }
bad()  { echo -e "  \033[31mFAIL\033[0m  $*"; FAIL=$((FAIL+1)); }
step() { echo -e "\n== $* =="; }

# ---- 准备 xray 二进制 -------------------------------------------------------
XRAY="${XRAY_BIN:-}"
if [[ -z "$XRAY" ]]; then
    if command -v xray >/dev/null 2>&1; then
        XRAY=$(command -v xray)
    else
        step "下载 Xray-core 到临时目录"
        arch=$(uname -m)
        case "$arch" in
            x86_64|amd64) pkg="Xray-linux-64" ;;
            aarch64|arm64) pkg="Xray-linux-arm64-v8a" ;;
            *) echo "不支持的架构: $arch" >&2; exit 1 ;;
        esac
        curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${pkg}.zip" -o "$WORK/xray.zip" \
            && python3 -c "import zipfile,sys;zipfile.ZipFile('$WORK/xray.zip').extractall('$WORK')" \
            && chmod +x "$WORK/xray" || { echo "Xray 下载失败" >&2; exit 1; }
        XRAY="$WORK/xray"
    fi
fi
echo "使用 xray: $XRAY ($("$XRAY" version | head -1))"

# ---- 从 deploy.sh 输出里切出 JSON -------------------------------------------
gen_cfg() { # $1=mode(ws|tls) $2=port -> 打印服务端配置 JSON
    local extra=()
    [[ "$1" == "ws" ]] && extra=(--ws)
    [[ "$1" == "tls" ]] && extra=(--domain node.example.com)
    bash "$HERE/deploy.sh" --print-only "${extra[@]}" --port "$2" --path "$PATH_WS" --uuid "$UUID" \
        | python3 -c '
import json,sys
text=sys.stdin.read()
start=text.index("{")
depth=0
for i,ch in enumerate(text[start:],start):
    if ch=="{": depth+=1
    elif ch=="}":
        depth-=1
        if depth==0:
            print(text[start:i+1]); break
'
}

gen_client() { # $1=mode $2=server_port $3=socks_port $4=pinned_hex(可选)
    local extra=()
    [[ "$1" == "ws" ]] && extra=(--ws)
    [[ "$1" == "tls" ]] && extra=(--domain node.example.com)
    bash "$HERE/deploy.sh" --print-only "${extra[@]}" --port "$2" --path "$PATH_WS" --uuid "$UUID" \
        | python3 -c '
import json,sys
text=sys.stdin.read()
obj=json.loads(text.split("客户端 JSON (手动配置用) =====")[1])
out=obj["outbounds"][0]
out["settings"]["vnext"][0]["address"]="127.0.0.1"
out["streamSettings"]["wsSettings"]["headers"]["Host"]="127.0.0.1"
tls=out["streamSettings"].get("tlsSettings")
pinned=sys.argv[1]
if pinned:
    if tls is None:
        tls=out["streamSettings"]["tlsSettings"]={}
    tls["serverName"]="node.example.com"
    tls["pinnedPeerCertSha256"]=pinned
elif tls is not None:
    tls["serverName"]="node.example.com"
cfg={"log":{"loglevel":"warning"},
     "inbounds":[{"listen":"127.0.0.1","port":int(sys.argv[2]),"protocol":"socks","settings":{"udp":False}}],
     "outbounds":[out]}
print(json.dumps(cfg,indent=2))
' "${4:-}" "$3"
}

start() { "$XRAY" run -config "$1" > "$2" 2>&1 & PIDS+=($!); }

wait_port() { # $1=port  $2=超时秒
    local i=0
    while (( i < $2 * 10 )); do
        (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null && { exec 3<&-; return 0; }
        sleep 0.1; i=$((i+1))
    done
    return 1
}

probe() { # $1=socks_port -> 0=通
    curl -sS -m 20 --socks5-hostname "127.0.0.1:$1" https://api.ipify.org >/dev/null 2>&1
}

# ---- 1. 配置生成 + xray -test 校验 ------------------------------------------
step "生成并校验配置 (ws / tls)"
gen_cfg ws 18601 > "$WORK/ws.json" && "$XRAY" run -test -config "$WORK/ws.json" >/dev/null 2>&1 \
    && ok "ws 模式配置通过 xray -test" || bad "ws 模式配置校验失败"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.crt" \
    -days 2 -subj "/CN=Selftest CA" -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/leaf.key" -out "$WORK/leaf.csr" \
    -subj "/CN=node.example.com" 2>/dev/null
printf 'subjectAltName=DNS:node.example.com\nbasicConstraints=CA:FALSE\n' > "$WORK/ext.cnf"
openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
    -CAcreateserial -out "$WORK/leaf.crt" -days 2 -extfile "$WORK/ext.cnf" 2>/dev/null
gen_cfg tls 18602 > "$WORK/tls.json"
python3 - "$WORK" <<'PY'
import json,sys,os
w=sys.argv[1]
d=json.load(open(os.path.join(w,'tls.json')))
t=d['inbounds'][0]
t['listen']='127.0.0.1'
t['streamSettings']['tlsSettings']['certificates'][0]={
    'certificateFile':os.path.join(w,'leaf.crt'),'keyFile':os.path.join(w,'leaf.key')}
json.dump(d,open(os.path.join(w,'tls.json'),'w'),indent=2)
PY
"$XRAY" run -test -config "$WORK/tls.json" >/dev/null 2>&1 \
    && ok "tls 模式配置通过 xray -test" || bad "tls 模式配置校验失败"

# ---- 2. ws 模式端到端 -------------------------------------------------------
step "ws 模式端到端 (SOCKS -> VLESS/WS -> 服务端 -> 外网)"
python3 - "$WORK" <<'PY'
import json,sys,os
w=sys.argv[1]
d=json.load(open(os.path.join(w,'ws.json')))
d['inbounds'][0]['listen']='127.0.0.1'
json.dump(d,open(os.path.join(w,'ws.json'),'w'),indent=2)
PY
gen_client ws 18601 18611 > "$WORK/ws_cli.json"
start "$WORK/ws.json" "$WORK/ws_srv.log"
start "$WORK/ws_cli.json" "$WORK/ws_cli.log"
if wait_port 18611 5 && wait_port 18601 5; then
    if probe 18611; then ok "ws 模式可以正常出网"; else bad "ws 模式无法出网"; fi
    if grep -q 'accepted' "$WORK/ws_srv.log"; then ok "服务端日志有出站记录"; else bad "服务端未产生出站记录"; fi
else
    bad "ws 模式端口未就绪"
fi

# ---- 3. 错误 WS 路径应被拒绝 -------------------------------------------------
step "错误 WS 路径应被拒绝"
python3 - "$WORK" <<'PY'
import json,sys,os
w=sys.argv[1]
d=json.load(open(os.path.join(w,'ws.json')))
d['inbounds'][0]['port']=18603
d['inbounds'][0]['streamSettings']['wsSettings']['path']='/wrong-path'
json.dump(d,open(os.path.join(w,'ws_bad.json'),'w'),indent=2)
c=json.load(open(os.path.join(w,'ws_cli.json')))
c['inbounds'][0]['port']=18613
out=c['outbounds'][0]
out['settings']['vnext'][0]['port']=18603
out['streamSettings']['wsSettings']['path']='/its-not-the-path'
json.dump(c,open(os.path.join(w,'ws_bad_cli.json'),'w'),indent=2)
PY
start "$WORK/ws_bad.json" "$WORK/ws_bad.log"
start "$WORK/ws_bad_cli.json" "$WORK/ws_bad_cli.log"
if wait_port 18613 5; then
    if probe 18613; then bad "错误路径竟然连通了 (路径未生效)"; else ok "错误路径被拒绝"; fi
else
    bad "错误路径测试的客户端未就绪"
fi

# ---- 4. tls 模式端到端 (证书 pinning) ---------------------------------------
step "tls 模式端到端 (VLESS + 自签 CA + pinnedPeerCertSha256)"
PIN=$(openssl x509 -in "$WORK/leaf.crt" -outform der | sha256sum | cut -d' ' -f1)
gen_client tls 18602 18612 "$PIN" > "$WORK/tls_cli.json"
start "$WORK/tls.json" "$WORK/tls_srv.log"
start "$WORK/tls_cli.json" "$WORK/tls_cli.log"
if wait_port 18612 5 && wait_port 18602 5; then
    if probe 18612; then ok "tls 模式可以正常出网"; else bad "tls 模式无法出网"; fi
else
    bad "tls 模式端口未就绪"
fi

# ---- 汇总 -------------------------------------------------------------------
echo
echo "==================== 结果: PASS=$PASS FAIL=$FAIL ===================="
[[ $FAIL -eq 0 ]] || { echo '失败日志:'; for f in "$WORK"/*.log; do echo "--- $f"; tail -5 "$f"; done; }
[[ $FAIL -eq 0 ]]
