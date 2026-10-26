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
import urllib.parse


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


def build_vless_link(args):
    host = args.host or args.sni or args.add
    params = {
        "encryption": "none",
        "security": "tls" if args.tls else "none",
        "type": args.net,
        "host": host,
        "path": args.path if args.net in ("ws", "h2", "grpc") else "",
    }
    if args.tls:
        params["sni"] = args.sni or host
        params["alpn"] = "http/1.1"
    query = "&".join(f"{k}={urllib.parse.quote(str(v), safe='')}" for k, v in params.items())
    name = urllib.parse.quote(args.ps or args.add, safe="")
    return f"vless://{args.id}@{args.add}:{args.port}?{query}#{name}"


def decode_vless_link(link):
    u = urllib.parse.urlparse(link)
    q = urllib.parse.parse_qs(u.query)
    flat = {k: v[0] for k, v in q.items()}
    return {
        "ps": urllib.parse.unquote(u.fragment),
        "add": u.hostname,
        "port": str(u.port),
        "id": u.username,
        "net": flat.get("type", "tcp"),
        "host": flat.get("host", ""),
        "path": flat.get("path", ""),
        "tls": flat.get("security", "none"),
        "sni": flat.get("sni", ""),
        "alpn": flat.get("alpn", ""),
        "encryption": flat.get("encryption", "none"),
    }


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
    p.add_argument("--vless", action="store_true", help="输出 vless:// 链接（无加密方式字段，兼容性更好）")
    args = p.parse_args()

    if args.decode:
        link = args.decode.strip()
        if link.startswith("vless://"):
            print(json.dumps(decode_vless_link(link), ensure_ascii=False, indent=2))
        else:
            print(json.dumps(decode_link(link), ensure_ascii=False, indent=2))
        return

    missing = [n for n in ("add", "id") if not getattr(args, n)]
    if missing:
        p.error("缺少参数: " + ", ".join("--" + m for m in missing))
    print(build_vless_link(args) if args.vless else build_link(args))


if __name__ == "__main__":
    sys.exit(main())
