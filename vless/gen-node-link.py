#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 / 解析节点分享链接（默认 VLESS，v2rayN、v2rayNG、NekoBox、Shadowrocket 通用）

示例:
    # VLESS + WS + TLS（推荐）
    ./gen-node-link.py --add node.example.com --port 443 --id <UUID> --path /vless --tls

    # VLESS 套 CDN：add 填 CDN 域名，host 填回源域名
    ./gen-node-link.py --add cdn.example.com --port 443 --id <UUID> \
        --path /ws --host node.example.com --tls

    # 兼容老配置：生成 vmess:// 链接（不推荐）
    ./gen-node-link.py --vmess --add node.example.com --port 443 --id <UUID> --path /ws --tls

    # 解析
    ./gen-node-link.py --decode 'vless://uuid@host:443?...#name'
"""
import argparse
import base64
import json
import sys
import urllib.parse


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


def build_vmess_link(args):
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


def decode_vless_link(link):
    u = urllib.parse.urlparse(link)
    q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
    return {
        "protocol": "vless",
        "ps": urllib.parse.unquote(u.fragment),
        "add": u.hostname,
        "port": str(u.port),
        "id": u.username,
        "net": q.get("type", "tcp"),
        "host": q.get("host", ""),
        "path": q.get("path", ""),
        "tls": q.get("security", "none"),
        "sni": q.get("sni", ""),
        "alpn": q.get("alpn", ""),
        "encryption": q.get("encryption", "none"),
        "flow": q.get("flow", ""),
    }


def decode_vmess_link(link):
    body = link[len("vmess://"):].strip()
    body += "=" * (-len(body) % 4)  # 补齐 padding
    obj = json.loads(base64.b64decode(body).decode("utf-8"))
    obj["protocol"] = "vmess"
    return obj


def main():
    p = argparse.ArgumentParser(description="生成 / 解析 VLESS（或 VMess）分享链接")
    p.add_argument("--decode", metavar="LINK", help="解析一个 vless:// 或 vmess:// 链接")
    p.add_argument("--add", help="服务器地址 (域名或 IP)")
    p.add_argument("--port", type=int, default=443, help="端口, 默认 443")
    p.add_argument("--id", help="UUID")
    p.add_argument("--path", default="/ws", help="WebSocket 路径, 默认 /ws")
    p.add_argument("--ps", help="节点备注名")
    p.add_argument("--host", help="WS Host 头 / CDN 回源域名 (默认同 --add)")
    p.add_argument("--sni", help="TLS SNI (默认同 --host 或 --add)")
    p.add_argument("--net", default="ws", choices=["ws", "tcp", "h2", "grpc"], help="传输方式, 默认 ws")
    p.add_argument("--tls", action="store_true", help="启用 TLS")
    p.add_argument("--vmess", action="store_true", help="输出旧的 vmess:// 链接（兼容老客户端，不推荐）")
    args = p.parse_args()

    if args.decode:
        link = args.decode.strip()
        if link.startswith("vless://"):
            print(json.dumps(decode_vless_link(link), ensure_ascii=False, indent=2))
        elif link.startswith("vmess://"):
            print(json.dumps(decode_vmess_link(link), ensure_ascii=False, indent=2))
        else:
            raise SystemExit("错误: 链接必须以 vless:// 或 vmess:// 开头")
        return

    missing = [n for n in ("add", "id") if not getattr(args, n)]
    if missing:
        p.error("缺少参数: " + ", ".join("--" + m for m in missing))
    print(build_vmess_link(args) if args.vmess else build_vless_link(args))


if __name__ == "__main__":
    sys.exit(main())
