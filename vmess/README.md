# VMess 节点（VPS 自建 · 一键部署）

在这个目录里给你一套完整、可验证的 VMess 搭建方案：

| 文件 | 作用 |
| --- | --- |
| `deploy.sh` | VPS 一键部署脚本：装 Xray-core、生成 UUID/路径、写配置、配 systemd、申请证书、输出 `vmess://` 链接 |
| `gen-vmess-link.py` | 生成 / 解析 `vmess://` 分享链接（离线可用） |
| `client-config.example.json` | 客户端 JSON 配置样例（手动配置 / 排查用） |
| `test/selftest.sh` | 本地自测：不用 VPS、不用 root，跑通 ws / tls 两种模式的完整链路 |

> 说明：本仓库根目录是 VLESS + WS 的 Heroku/PaaS 方案；本目录是**独立的自建 VPS 方案**，开箱即用，不依赖 Heroku。

## 两种模式

| 模式 | 命令 | 适用场景 |
| --- | --- | --- |
| `tls`（默认，推荐） | `sudo bash deploy.sh --domain node.example.com` | 公网 VPS 直连。VMess + WebSocket + TLS，Xray 直接监听 443，Let's Encrypt 自动签发证书 |
| `ws` | `sudo bash deploy.sh --ws --port 8080` | 套 Cloudflare CDN / Nginx 反代 / PaaS 平台时使用，明文 WebSocket 由外层负责 TLS |

## 前置条件

- 一台 VPS（Ubuntu 20.04+ / Debian 11+，或装有 `dnf`/`yum` 的系统），**root** 权限，能访问 `github.com` 与系统软件源
- `tls` 模式还需要：一个域名，A 记录已指向该 VPS，且 **80 端口**可从公网访问（申请证书用）
- 客户端：v2rayN（Windows）、v2rayNG（Android）、Shadowrocket（iOS）、NekoBox 等

## 一键部署（TLS 直连，推荐）

```bash
# 上传脚本或用 curl 拉下来
scp vmess/deploy.sh root@你的VPS:/root/

ssh root@你的VPS
sudo bash /root/deploy.sh --domain node.example.com --email you@example.com
```

跑完后终端会打印 `vmess://...` 链接，直接复制到客户端「从剪贴板导入」即可。参数说明：

| 参数 | 说明 |
| --- | --- |
| `--domain` | 你的域名（tls 模式必填，需已解析到本机） |
| `--email` | Let's Encrypt 注册邮箱（可省略） |
| `--uuid` | 节点 UUID，省略自动生成 |
| `--path` | WebSocket 路径，省略随机生成（如 `/vmess-46838417`） |
| `--port` | 监听端口，默认 `tls: 443` / `ws: 8080` |
| `--name` | 链接里显示的节点名 |
| `--ws` | ws 模式（明文 WebSocket，套 CDN / 反代用） |
| `--cert` / `--key` | 用自有证书（跳过 certbot） |
| `--print-only` | 只打印配置和链接，不安装、不改系统（本地试算用） |

## 套 Cloudflare CDN（可选，`ws` 模式）

```bash
# 1. 在 VPS 上以 ws 模式起服务（不占 80/443，交给 Cloudflare 代理）
sudo bash deploy.sh --ws --domain node.example.com --port 8080
```

2. Cloudflare 后台给 `node.example.com` 加 A 记录指向 VPS，**开启橙色小云朵（Proxied）**；
3. 用脚本打印的链接，但把 `add`（地址）改成 CDN 域名、`tls` 设为 `tls`、`host`/`sni` 填 CDN 域名：

```bash
./gen-vmess-link.py --add node.example.com --port 443 --id <UUID> \
    --path /vmess-xxxx --tls --ps "VMess-CDN"
```

Cloudflare 免费版支持 WebSocket，`--port 443` 走 CF 的 TLS，源站只看到明文 WS，无需证书。

## 客户端配置

**方式一：`vmess://` 链接** —— 复制脚本输出的链接，客户端里「从剪贴板导入」。

**方式二：手动填写**（以 v2rayN 为例）

| 项目 | 值 |
| --- | --- |
| 地址 | 域名 / IP（套 CDN 时填 CDN 域名） |
| 端口 | 443（tls）或 8080（ws） |
| 用户 ID | 脚本输出的 UUID |
| 额外 ID (alterId) | 0 |
| 加密方式 | auto |
| 传输协议 | ws |
| 路径 | 脚本输出的 WS 路径 |
| 传输层安全 | tls（ws 模式按外层情况选 none / tls） |
| SNI / Host | 域名（套 CDN 时填 CDN 域名） |
| 允许不安全 | 不认识的自签证书才勾选，正式证书**不要**勾 |

**方式三：JSON**，见 `client-config.example.json`，把 `address` / `id` / `path` / `host` 换成自己的即可。

> 自签证书（`--cert/--key` 传入自己签的证书）时，客户端要能验证它：图形界面客户端可勾选「允许不安全」；**Xray 26+ 内核已移除 `allowInsecure`**，改为 `tlsSettings.pinnedPeerCertSha256`（证书 DER 的 SHA256，**十六进制**字符串）：
>
> ```bash
> openssl x509 -in leaf.crt -outform der | sha256sum | cut -d' ' -f1
> ```
>
> 用 Let's Encrypt 正式证书则无需任何额外设置。

## 本机快速测试（不起服务、不动系统）

只想先验证链路通不通，不想装 systemd 服务：

```bash
bash test/local-node.sh          # 起临时节点 127.0.0.1:18308 + 本地 SOCKS5 127.0.0.1:1080
curl -sS --socks5-hostname 127.0.0.1:1080 https://api.ipify.org   # 能返回 IP 就说明通了
bash test/local-node.sh --status
bash test/local-node.sh --stop
```

脚本会打印一条 `vmess://` 链接，可直接导入客户端（该链接指向 127.0.0.1，供本机客户端使用）。

想让手机/其他机器连进来，用 Cloudflare 临时隧道（免账号，域名每次重启都变）：

```bash
# 1. 下载并启动隧道，指向本地节点
curl -fsSL -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared && ./cloudflared tunnel --no-autoupdate --url http://127.0.0.1:18308
# 日志里会出现 https://xxxx.trycloudflare.com

# 2. 用隧道域名生成 tls + ws 链接
bash gen-vmess-link.py --add xxxx.trycloudflare.com --port 443 --id <UUID> \
    --path <WS路径> --host xxxx.trycloudflare.com --tls
```

> 隧道方案仅用于连通性验证：延迟取决于本机网络，进程/域名随环境销毁而失效。

## 已验证（本地端到端自测）

不用 VPS 也能验证，直接跑：

```bash
bash test/selftest.sh        # 需要 curl、openssl、python3，会自动下载 Xray
```

当前实测结果（Linux + Xray 26.10.21）：`PASS=6 FAIL=0`，覆盖：

- `xray run -test -config` 校验 `tls` / `ws` 两种模式生成的配置 → `Configuration OK`
- `ws` 模式：客户端 SOCKS → VMess/WS → 服务端 → 外网，`curl https://api.ipify.org` 返回出口 IP
- 把脚本输出的 `vmess://` 链接解码、重建客户端配置后同样连通（证明链接参数与配置一致）
- 故意用错误 WS 路径 → 连接被重置、服务端未产生任何出站请求（路径即凭据之一）
- `tls` 模式：自签 CA 签发 `node.example.com` 证书，VMess/WS/TLS 握手成功并正常出网
- 部署产物实测：把脚本生成的 `config.json` + 复制后的证书直接启动，按链接参数配置客户端出网成功；模拟证书续期后钩子把新证书同步到 xray 可读目录并重启

> 关于证书：`xray.service` 以 `User=xray` 运行，而 `/etc/letsencrypt` 私钥默认仅 root 可读，所以脚本会把证书复制到 `/usr/local/etc/xray/certs/`（`xray:xray`、640）并指向该路径；续期由 `reload-xray.sh` 钩子负责同步 + 重启。配置文件的属主为 `root:xray`（640），保证服务能读。

## 运维

```bash
systemctl status xray          # 运行状态
journalctl -u xray -f          # 实时日志
xray run -test -config /usr/local/etc/xray/config.json   # 校验配置
systemctl restart xray         # 重启（改配置后）
certbot renew --dry-run        # 测试证书续期（已自动配置续期后重启 xray）
```

证书续期由 `/etc/letsencrypt/renewal-hooks/deploy/reload-xray.sh` 自动处理，不用手动管。

## 常见问题

| 现象 | 排查 |
| --- | --- |
| 客户端连不上，日志无记录 | 云厂商安全组 / `ufw` 是否放行端口：`ufw allow 443/tcp` |
| 证书申请失败 | 域名 A 记录未生效、80 端口被占（Nginx/Apache 先停）、或域名被墙；可先 `dig +short node.example.com` 核对 |
| TLS 握手失败 | 客户端 SNI/Host 必须与证书域名一致；`alpn` 用 `http/1.1`（h2 对 ws 不安全） |
| 能连但打不开网页 | 服务端 `freedom` 出站被机房限制，或目标站封 IP；先 `curl -I https://www.google.com` 在 VPS 上验证出网 |
| 换端口/路径后旧客户端失效 | 路径和端口是节点凭据的一部分，客户端必须同步更新 |

## 安全建议

- **务必新生成 UUID**，不要用别处见过的；`deploy.sh` 默认自动生成
- 路径不要用 `/ws` 这类默认值（脚本默认随机），降低被扫到的概率
- 定期更新：`bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install`
- 不要把节点链接发到公开群里——链接即凭据，泄露等于送人

## 协议说明

Xray 26.x 已把 **VMess** 与 **WS** 标记为 deprecated（仍可正常使用，`xray -test` 会打印 warning，属预期）。若你的目标是尽量抗封锁，建议后续迁移到 **VLESS + TLS/Reality**（本仓库根目录的 Heroku 方案用的是 VLESS）。本目录保持 VMess，是因为你要的是 VMess，且它对老客户端兼容性最好。
