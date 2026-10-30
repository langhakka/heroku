#!/usr/bin/env bash
# =============================================================================
# restore-node.sh - 一条命令把节点恢复到「可连」状态（幂等，可反复跑）
#
#   bash test/restore-node.sh          # 开着就只打印链接，掉了就拉起来
#   bash test/restore-node.sh --status # 只看状态 + 当前链接（不做任何修复）
#   bash test/restore-node.sh --stop   # 全停（守护 + 节点 + 隧道）
#
# 恢复策略（按代价从低到高）：
#   1. xray / cloudflared 进程在     -> 什么都不动，只自检 + 打印链接
#   2. 进程没了，配置还在            -> 用现有 server.json 原样拉起（UUID/路径不变）
#   3. 隧道活着但握手坏了 / 隧道没了 -> 重建 quick tunnel（域名会变，链接自动重写）
#   4. 状态目录整个丢了（容器重建）  -> 交给 demo-node.sh 重新初始化（新 UUID/路径）
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR="${VLESS_DEMO_DIR:-$HERE/../.cache/vless-demo}"
XRAY_BIN="$STATE_DIR/xray"
CF_BIN="$STATE_DIR/cloudflared"
SRV_CFG="$STATE_DIR/server.json"
LINK_FILE="$STATE_DIR/link.txt"

case "${1:-}" in
    --status)
        bash "$HERE/test/watchdog.sh" status
        exit $?
        ;;
    --stop)
        bash "$HERE/test/watchdog.sh" stop --all
        exit $?
        ;;
    -h|--help)
        sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "") ;;
    *) echo "未知参数: $1（可用: --status / --stop / -h）" >&2; exit 1 ;;
esac

# 情况 4：状态目录里没有二进制/配置，说明是全新容器，走完整初始化
if [[ ! -x "$XRAY_BIN" || ! -x "$CF_BIN" || ! -f "$SRV_CFG" ]]; then
    echo "[+] 状态目录不完整（$STATE_DIR），按首次部署处理（会生成新的 UUID/路径）"
    bash "$HERE/test/demo-node.sh" || exit 1
    exit 0
fi

# 情况 2：进程掉了但配置在 —— 先按现有身份拉起，并做一次 101 自检
echo "[+] 用现有身份恢复（UUID/WS 路径保持不变）"
ONCE=$(bash "$HERE/test/watchdog.sh" once 2>&1)
echo "$ONCE"

# 情况 3：自检没过（隧道域名被回收 / 隧道半死），重建隧道；身份仍然沿用
if ! grep -q '自检: 101 OK' <<<"$ONCE"; then
    echo "[!] 自检未通过，重建 Cloudflare 隧道（域名会变，UUID/路径不变）"
    bash "$HERE/test/demo-node.sh" || exit 1
    exit 0
fi

# 守护没起就补起来，之后掉线会自动恢复
bash "$HERE/test/watchdog.sh" start | sed 's/^/[+] /'

echo
echo "----- 当前链接 -----"
cat "$LINK_FILE" 2>/dev/null || echo "(未找到链接文件: $LINK_FILE)"
