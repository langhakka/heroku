#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 / 解析 vmess:// 分享链接（v2rayN、v2rayNG、Shadowrocket、NekoBox 通用格式）

示例:
    # 生成一个 VMess + WS + TLS 链接
    ./gen-vmess-link.py --add node.example.com --port 443 --id <UUID> \
        --path /vmess --ps 我的节点 --tls

    # 生成一个套 CDN 的 VMess + WS 链接
    ./gen-vmess-link.py --add cdn.example.com --port 443 --id <UUID> \
        --path /ws --host node.example.com --tls

    # 解析已有链接，用于核对参数
    ./gen-vmess-link.py --decode 'vmess://eyJ2IjoiMiIs...'
"""
import argparse
import base64
import json
import sys


def build_link(args):
    payload = {
        "v": "2",
        "ps": args.ps or args.add,
        "add": args.add,
        "port": str(args.port),
        "id": args.id,
        "aid": "0",
        "scy": "auto",
        "net": args.net,
        "type": "none",
        "host": args.host or args.sni or args.add,
        "path": args.path if args.net in ("ws", "h2", "grpc") else "",
        "tls": "tls" if args.tls else "none",
        "sni": (args.sni or (args.host or args.add)) if args.tls else "",
        "alpn": "http/1.1" if args.tls else "",
        "fp": "",
    }
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    return "vmess://" + base64.b64encode(raw).decode()


def decode_link(link):
    if not link.startswith("vmess://"):
        raise SystemExit("错误: 链接必须以 vmess:// 开头")
    body = link[len("vmess://"):].strip()
    body += "=" * (-len(body) % 4)  # 补齐 padding
    return json.loads(base64.b64decode(body).decode("utf-8"))


def main():
    p = argparse.ArgumentParser(description="生成 / 解析 vmess:// 分享链接")
    p.add_argument("--decode", metavar="LINK", help="解析一个 vmess:// 链接并打印 JSON")
    p.add_argument("--add", help="服务器地址 (域名或 IP)")
    p.add_argument("--port", type=int, default=443, help="端口, 默认 443")
    p.add_argument("--id", help="UUID")
    p.add_argument("--path", default="/ws", help="WebSocket 路径, 默认 /ws")
    p.add_argument("--ps", help="节点备注名")
    p.add_argument("--host", help="WS Host 头 / CDN 回源域名 (默认同 --add)")
    p.add_argument("--sni", help="TLS SNI (默认同 --host 或 --add)")
    p.add_argument("--net", default="ws", choices=["ws", "tcp", "h2", "grpc"], help="传输方式, 默认 ws")
    p.add_argument("--tls", action="store_true", help="启用 TLS")
    args = p.parse_args()

    if args.decode:
        obj = decode_link(args.decode)
        print(json.dumps(obj, ensure_ascii=False, indent=2))
        return

    missing = [n for n in ("add", "id") if not getattr(args, n)]
    if missing:
        p.error("缺少参数: " + ", ".join("--" + m for m in missing))
    print(build_link(args))


if __name__ == "__main__":
    sys.exit(main())
