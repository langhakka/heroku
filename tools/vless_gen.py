#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vless_gen.py —— 为 v2ray-heroku 生成 VLESS(ws+tls) 节点配置

输出：
  vless.txt            节点链接（可直接导入 v2rayN / Nekoray / Shadowrocket 等）
  subscription.txt     base64 订阅内容（把文件内容放到任意 HTTP 地址即为订阅）
  client-outbound.json 仅 outbound 片段，方便嵌入已有客户端配置
  client-config.json   完整客户端配置（本地 socks5://127.0.0.1:10808）
  server-config.json   服务端 Xray/V2Ray 配置（按仓库 config.json.tp 生成）
  node-info.json       本次生成的参数
  qr.png / qr.svg      节点链接二维码（需要 segno，未安装则跳过）

用法：
  python3 tools/vless_gen.py --host xxx.herokuapp.com
  python3 tools/vless_gen.py --host xxx.herokuapp.com --name 我的节点 --out ./node-out
  python3 tools/vless_gen.py --host xxx.herokuapp.com --uuid <已有UUID>   # 复用已有 UUID

注意：VLESS 链接等同于账号密码，泄露后任何人都能用你的节点，请勿公开分享。
"""

import argparse
import base64
import json
import os
import re
import sys
import uuid
from urllib.parse import quote

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def clean_host(value):
    """允许传入 https://host/、host:443 等写法，统一成纯 host。"""
    host = value.strip()
    host = re.sub(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", "", host)  # 去掉 scheme
    host = host.split("/")[0].split("?")[0]
    if host.count(":") == 1:  # 去掉误带的端口
        host = host.split(":")[0]
    if not host or " " in host:
        raise SystemExit("host 不合法：%r" % value)
    return host


def clean_path(value):
    path = value.strip() or "/ws"
    if not path.startswith("/"):
        path = "/" + path
    return path


def build_uri(host, port, uuid_str, path, name):
    query = "&".join([
        "encryption=none",
        "security=tls",
        "sni=" + quote(host, safe=""),
        "fp=chrome",
        "type=ws",
        "host=" + quote(host, safe=""),
        "path=" + quote(path, safe=""),
    ])
    return "vless://%s@%s:%d?%s#%s" % (
        uuid_str, host, port, query, quote(name, safe="")
    )


def build_outbound(host, port, uuid_str, path):
    return {
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": host,
                "port": port,
                "users": [{
                    "id": uuid_str,
                    "encryption": "none",
                    "level": 0
                }]
            }]
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "tlsSettings": {
                "serverName": host,
                "fingerprint": "chrome",
                "allowInsecure": False
            },
            "wsSettings": {
                "path": path,
                "headers": {"Host": host}
            }
        }
    }


def build_client_config(outbound):
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": 10808,
            "protocol": "socks",
            "settings": {"udp": True}
        }],
        "outbounds": [
            outbound,
            {"tag": "direct", "protocol": "freedom"}
        ]
    }


def build_server_config(uuid_str):
    """优先复用仓库的 config.json.tp，保持与服务端模板一致。"""
    template = os.path.join(REPO_ROOT, "config.json.tp")
    if os.path.exists(template):
        with open(template, "r", encoding="utf-8") as fh:
            text = fh.read().replace("$UUID", uuid_str)
        return json.loads(text)
    return {
        "inbounds": [{
            "port": 8080,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": uuid_str, "level": 0}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "ws",
                "security": "none",
                "wsSettings": {"path": "/ws"}
            }
        }],
        "outbounds": [{"protocol": "freedom"}]
    }


def make_qr(uri, outdir):
    try:
        import segno
    except ImportError:
        print("[!] 未安装 segno，跳过二维码（pip install segno）")
        return
    qr = segno.make(uri, error="m")
    qr.save(os.path.join(outdir, "qr.png"), scale=8, border=2)
    qr.save(os.path.join(outdir, "qr.svg"), scale=8, border=2)


def write(path, content):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    return path


def main():
    parser = argparse.ArgumentParser(
        description="为 v2ray-heroku 生成 VLESS (ws + tls) 节点配置",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：python3 tools/vless_gen.py --host myapp.herokuapp.com --name 我的节点",
    )
    parser.add_argument("--host", required=True,
                        help="节点域名，例如 myapp.herokuapp.com 或 worker.example.workers.dev")
    parser.add_argument("--uuid", default=None, help="复用已有 UUID；默认随机生成 v4")
    parser.add_argument("--port", type=int, default=443, help="端口，默认 443")
    parser.add_argument("--path", default="/ws", help="WebSocket 路径，默认 /ws（须与服务端一致）")
    parser.add_argument("--name", default="v2ray-heroku", help="节点显示名称")
    parser.add_argument("--out", default=os.path.join(REPO_ROOT, "node-out"),
                        help="输出目录，默认 <repo>/node-out")
    args = parser.parse_args()

    host = clean_host(args.host)
    path = clean_path(args.path)
    uuid_str = (args.uuid or str(uuid.uuid4())).strip()
    try:
        uuid.UUID(uuid_str)
    except ValueError:
        raise SystemExit("UUID 格式不正确：%r" % uuid_str)

    uri = build_uri(host, args.port, uuid_str, path, args.name)
    subscription = base64.b64encode(uri.encode("utf-8")).decode("ascii")
    outbound = build_outbound(host, args.port, uuid_str, path)

    outdir = os.path.abspath(args.out)
    os.makedirs(outdir, exist_ok=True)

    write(os.path.join(outdir, "vless.txt"), uri + "\n")
    write(os.path.join(outdir, "subscription.txt"), subscription + "\n")
    write(os.path.join(outdir, "client-outbound.json"),
          json.dumps(outbound, ensure_ascii=False, indent=2) + "\n")
    write(os.path.join(outdir, "client-config.json"),
          json.dumps(build_client_config(outbound), ensure_ascii=False, indent=2) + "\n")
    write(os.path.join(outdir, "server-config.json"),
          json.dumps(build_server_config(uuid_str), ensure_ascii=False, indent=2) + "\n")
    write(os.path.join(outdir, "node-info.json"), json.dumps({
        "host": host,
        "port": args.port,
        "uuid": uuid_str,
        "path": path,
        "name": args.name,
        "security": "tls",
        "network": "ws",
    }, ensure_ascii=False, indent=2) + "\n")
    make_qr(uri, outdir)

    print("=" * 72)
    print("节点参数")
    print("  host     :", host)
    print("  port     :", args.port)
    print("  uuid     :", uuid_str)
    print("  path     :", path)
    print("  security : tls / ws")
    print("-" * 72)
    print("VLESS 链接：")
    print(uri)
    print("-" * 72)
    print("订阅内容（base64）：")
    print(subscription)
    print("-" * 72)
    print("输出目录：", outdir)
    for name in sorted(os.listdir(outdir)):
        print("  -", name)
    print("=" * 72)
    print("提示：路径 /ws 必须与 nginx.template.conf、config.json.tp 保持一致；")
    print("      订阅内容可直接 base64 -d 解回上面的链接。")


if __name__ == "__main__":
    main()

