# VLESS 节点（VPS 自建 · 一键部署）

在这个目录里给你一套完整、可验证的 **VLESS** 搭建方案（没有 VMess）：

| 文件 | 作用 |
| --- | --- |
| `deploy.sh` | VPS 一键部署脚本：装 Xray-core、生成 UUID/随机路径、写配置、配 systemd、申请证书、输出 `vless://` 链接 |
| `gen-node-link.py` | 生成 / 解析 `vless://`（含兼容用的 `vmess://`）分享链接，离线可用 |
| `client-config.example.json` | 客户端 JSON 配置样例（手动配置 / 排查用） |
| `test/selftest.sh` | 本地自测：不用 VPS、不用 root，跑通 ws / tls 两种模式的完整链路 |
| `test/local-node.sh` | 本机起临时节点（含本地 SOCKS5 客户端），一条命令验证链路 |

> 说明：本仓库根目录是 VLESS + WS 的 Heroku/PaaS 方案；本目录是**独立的自建 VPS 方案**，开箱即用，不依赖 Heroku。

## 为什么只有 VLESS，没有 VMess

VMess 的请求头里要带一个「加密方式」字节（auto / aes-128-gcm / chacha20-poly1305 / none / zero），客户端填错、或者客户端内核把这个字段丢了，服务端只能拒绝：

```
rejected proxy/vmess/encoding: unknown security type: UNKNOWN
```

这个错特别迷惑：TLS 握手、WebSocket 升级全都成功，隧道也是通的，看着像"网络问题"，实际上只差一个字段，表现为"测延迟正常、实际流量全废"。

VLESS 没有这个字段（`encryption: none`，安全完全靠传输层 TLS + UUID 身份），少一层协商就少一类坑；Xray 官方也早已把 VMess 标为 deprecated。所以本脚本只出 VLESS。

## 两种模式

| 模式 | 命令 | 适用场景 |
| --- | --- | --- |
| `tls`（默认，推荐） | `sudo bash deploy.sh --domain node.example.com` | 公网 VPS 直连。VLESS + WebSocket + TLS，Xray 直接监听 443，Let's Encrypt 自动签发证书 |
| `ws` | `sudo bash deploy.sh --ws --port 8080` | 套 Cloudflare CDN / Nginx 反代 / PaaS 平台：源站只跑明文 WS，TLS 由外层负责 |

## 前置条件

- 一台 VPS（Ubuntu 20.04+ / Debian 11+，或装有 `dnf`/`yum` 的系统），**root** 权限，能访问 `github.com` 与系统软件源
- `tls` 模式还需要：一个域名，A 记录已指向该 VPS，且 **80 端口**可从公网访问（申请证书用）
- 客户端：v2rayN（Windows）、v2rayNG（Android）、NekoBox、Shadowrocket（iOS）等，需支持 VLESS

## 一键部署（TLS 直连，推荐）

```bash
scp vless/deploy.sh root@你的VPS:/root/

ssh root@你的VPS
sudo bash /root/deploy.sh --domain node.example.com --email you@example.com
```

跑完终端会打印 `vless://...` 链接，复制到客户端「从剪贴板导入」即可。参数说明：

| 参数 | 说明 |
| --- | --- |
| `--domain` | 你的域名（tls 模式必填，需已解析到本机） |
| `--email` | Let's Encrypt 注册邮箱（可省略） |
| `--uuid` | 节点 UUID，省略自动生成 |
| `--path` | WebSocket 路径，省略随机生成（如 `/vless-46838417`） |
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
3. 用隧道/CDN 域名生成带 TLS 的客户端链接（源站不用证书，CF 边缘负责 TLS）：

```bash
./gen-node-link.py --add node.example.com --port 443 --id <UUID> \
    --path /vless-xxxx --tls --ps "VLESS-CDN"
```

## 客户端配置（VLESS）

**方式一：`vless://` 链接** —— 复制脚本输出的链接，客户端里「从剪贴板导入」。

**方式二：手动填写**（以 v2rayN 为例）

| 项目 | 值 |
| --- | --- |
| 协议 | **VLESS** |
| 地址 | 域名 / IP（套 CDN 时填 CDN 域名） |
| 端口 | 443（tls）或 8080（ws） |
| 用户 ID | 脚本输出的 UUID |
| 加密方式 | `none`（VLESS 只有这一项；**没有 alterId、没有 auto/aes-gcm 这些选项**） |
| 流控 flow | 留空（仅 Reality / Vision 才用 `xtls-rprx-vision`） |
| 传输协议 | ws |
| 路径 | 脚本输出的 WS 路径 |
| 传输层安全 | tls（ws 模式按外层情况选 none / tls） |
| SNI / Host | 域名（套 CDN 时填 CDN 域名） |
| ALPN | `http/1.1`（留空可能协商成 h2，WebSocket 会直接失败） |
| Mux（多路复用） | **关闭**（中继/隧道类出口对 mux 支持差，症状是"能连、下载为 0"） |

**方式三：JSON**，见 `client-config.example.json`，把 `address` / `id` / `path` / `host` 换成自己的即可。注意 VLESS 的 `users` 里只有 `id` + `encryption: "none"` + `flow: ""`，**不要再写 `alterId` 或 `security`**。

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
bash test/local-node.sh          # 起临时 VLESS 节点 127.0.0.1:18308 + 本地 SOCKS5 127.0.0.1:1080
curl -sS --socks5-hostname 127.0.0.1:1080 https://api.ipify.org   # 能返回 IP 就说明通了
bash test/local-node.sh --status
bash test/local-node.sh --stop
```

脚本会打印一条 `vless://` 链接（指向 127.0.0.1，供本机客户端使用）。

想让手机/其他机器连进来，用 Cloudflare 临时隧道（免账号，域名每次重启都变）：

```bash
# 1. 起隧道，指向本地节点
curl -fsSL -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared && ./cloudflared tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:18308
# 日志里会出现 https://xxxx.trycloudflare.com

# 2. 用隧道域名生成 tls + ws 链接（客户端是 TLS，源站仍是明文 WS）
bash gen-node-link.py --add xxxx.trycloudflare.com --port 443 --id <UUID> \
    --path <WS路径> --host xxxx.trycloudflare.com --tls
```

> 注意两点：①无 TLS 的公网入口不能跑 VLESS（Xray 26 只允许私有地址/回环上不加密），所以隧道场景必须由外层（CF）提供 TLS；②隧道方案仅用于连通性验证，延迟取决于本机网络，进程/域名随环境销毁而失效。

## 一键起「可分享的临时节点」（demo）

想马上拿到一条手机也能连的测试链路：

```bash
bash test/demo-node.sh            # 起 VLESS 节点 + Cloudflare 临时隧道，直接打印可分享链接
bash test/demo-node.sh --status   # 查看隧道域名与当前链接
bash test/demo-node.sh --stop     # 全部停掉
```

它会自动处理三个特别容易踩的坑（都是我实际踩过的）：

1. **等域名 DNS 真正生效**再打印链接——quick tunnel 的域名要 10~60 秒才出现在 DNS 里，太早生成的链接客户端会报"无法解析主机"；
2. **握手自检**：用 DoH 解析出 IP（绕开本地 DNS 负缓存），`--resolve` 直连做 WebSocket 升级，必须看到 `101 Switching Protocols` 才算成功；
3. **链接按客户端视角生成**：走隧道时端口填 443、`security=tls`（TLS 由 Cloudflare 边缘提供），源站保持明文 WS，不依赖任何证书。

> 域名每次重启都变、进程随机器销毁消失 —— 只适合临时验证，长期用 `deploy.sh`。
## 固定 UUID / 固定域名（想让客户端配置一次就不用再改）

### 1. 固定 UUID 与 WS 路径（已内置）

`demo-node.sh` 会把 UUID 和路径写进 `.cache/vless-demo/identity.env`，下次启动直接复用：

```bash
bash test/demo-node.sh            # 第二次启动 UUID/路径不变，只有隧道域名可能变
bash test/demo-node.sh --new      # 想换一套新的再换
```

实测：连续两次启动，UUID 与路径完全一致，只有 quick tunnel 的域名不同。

### 2. 固定域名：改用 Cloudflare 命名隧道

quick tunnel 的域名每次重连都变。命名隧道（named tunnel）可以把**你自己的域名**固定指向这台机器上的节点：

```bash
# Cloudflare 侧一次性配置（需要账号 + 托管在 CF 的域名）：
#   cloudflared tunnel login
#   cloudflared tunnel create vless-node          # 拿到 token
#   cloudflared tunnel route dns vless-node node.example.com
bash test/demo-node.sh \
  --tunnel-token "<TUNNEL_TOKEN>" \
  --tunnel-host  node.example.com
```

脚本会把 token/域名记到 `.cache/vless-demo/tunnel.env`（600 权限），watchdog 重连时也用命名隧道，**域名不会再变**。token 无效时会明确报错并退回"只起本地节点"，不会给你一条连不上的链接。

### 2.5 配好之后：一条无参命令即可原样恢复

命名隧道参数（`tunnel.env`）、UUID/路径/端口（`identity.env`）都会记住，所以容器重启后只需：

```bash
bash test/demo-node.sh      # 自动沿用 固定域名 + 固定 UUID/路径 + 原端口，链接与上次完全一致
```

实测：无参启动 → `监听 127.0.0.1:8001`、`UUID e1c5e5c8…`、`路径 /dl-bdbf98fa`、`域名 aida.adg007.kdns.fr`，自检 `101 Switching Protocols`，客户端配置无需任何改动。

> 踩坑记录：命名隧道（token 方式）的 Public Hostname 是**远端配置**，端口必须和本地节点一致（我这边实测你的是 `localhost:8001`，所以节点改用 8001）。连接器注册要 10~40 秒，脚本会先等 `Registered tunnel connection` 再做 101 自检，否则会误报握手失败。

### 3. 但要说清楚：固定域名 ≠ 自启

固定域名解决的是"客户端配置不用改"，**不解决进程随容器消失**。要做到"机器重启也自动回来"，仍然需要 systemd（真 VPS 上 `deploy.sh` 就是），容器里没有 systemd/cron。

> 另外提醒：Cloudflare 的服务条款不允许把 Tunnel/CDN 当通用代理长期跑流量，账号有被处理的风险；自建 VPS 直连没有这个顾虑。

## 掉线自动拉起（watchdog）

```bash
bash test/watchdog.sh start     # 后台守护（demo-node.sh 默认已经帮你起好）
bash test/watchdog.sh status    # 守护/节点/隧道状态 + 当前链接 + 最近事件
bash test/watchdog.sh stop --all
```

每 15 秒检查一次，能覆盖这些情况（都实测过）：

| 情况 | 守护行为 | 实测恢复时间 |
| --- | --- | --- |
| xray 进程挂了 | 用现有 `server.json` 重启，域名/链接不变 | ~1 秒 |
| cloudflared 挂了 | 重建 quick tunnel，**域名会变**，自动重写 `.cache/vless-demo/link.txt` | ~20 秒 |
| 隧道活着但握手坏了（每 5 分钟一次 101 自检） | 杀掉重建隧道并更新链接 | ≤ 20 秒 |

写这个守护时踩到两个坑，都已修（留给以后参考）：

1. **僵尸进程骗过存活检查**：`kill -0 <pid>` 对 defunct 进程也返回成功，必须再看 `/proc/<pid>/stat` 的状态位是不是 `Z`，否则守护以为节点还活着、永远不重启；
2. **旧日志污染新域名**：cloudflared 日志是追加写，grep 到的是上一次的域名，导致新隧道配了旧域名。重建前必须先把日志清空。

**它管不到的情况**：整个容器被重建（`/tmp` 清空、所有进程消失、uptime 归零）。容器里没有 systemd/cron（PID 1 是平台自己的进程），守护进程会一起消失，没有任何容器内自启手段。这种只能靠：新会话里跑一次 `bash test/watchdog.sh start`（或 `demo-node.sh`），或者用真 VPS。

> **状态目录为什么不在 /tmp**：`/tmp` 会被环境清理（我实测过一次容器重启后 `/tmp` 全空、节点进程全没了），所以两个测试脚本把二进制和配置放在仓库下的 `.cache/`（已在 `.gitignore` 里），重启后不必重新下载，恢复只需再跑一次 `bash test/demo-node.sh`。



## 已验证（本地端到端自测）

不用 VPS 也能验证，直接跑：

```bash
bash test/selftest.sh        # 需要 curl、openssl、python3，会自动下载 Xray
```

当前实测结果（Linux + Xray 26.10.21）：`PASS=6 FAIL=0`，覆盖：

- `xray run -test -config` 校验 `tls` / `ws` 两种模式生成的配置 → `Configuration OK`
- `ws` 模式：客户端 SOCKS → VLESS/WS → 服务端 → 外网，`curl https://api.ipify.org` 返回出口 IP
- 把脚本输出的 `vless://` 链接解码、重建客户端配置后同样连通（证明链接参数与配置一致）
- 故意用错误 WS 路径 → 连接被重置、服务端未产生任何出站请求（路径即凭据之一）
- `tls` 模式：自签 CA 签发 `node.example.com` 证书，VLESS/WS/TLS 握手成功并正常出网
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
| 客户端连不上，服务端日志无记录 | 云厂商安全组 / `ufw` 是否放行端口：`ufw allow 443/tcp` |
| 证书申请失败 | 域名 A 记录未生效、80 端口被占（Nginx/Apache 先停）、或域名被墙；先 `dig +short node.example.com` 核对 |
| TLS 握手失败 | 客户端 SNI/Host 必须与证书域名一致；ALPN 用 `http/1.1`（h2 下 WebSocket 会失败） |
| 能连但打不开网页、下载为 0 | 先关掉 Mux；再看服务端日志有没有 `accepted tcp:...` 记录——有记录说明请求已到服务端，问题在出站或目标站 |
| 日志出现 `unknown security type: UNKNOWN` | 这是 **VMess** 的报错（本方案已不用 VMess）。说明客户端还在用 VMess 连 VLESS 端口，换 `vless://` 链接或把协议改成 VLESS |
| `vless without TLS ... is prohibited` | Xray 26 禁止公网地址上的 VLESS 不加密：要么给服务端配 TLS（deploy.sh 默认），要么让外层（Cloudflare/反代）提供 TLS |
| 换端口/路径后旧客户端失效 | 路径和端口是节点凭据的一部分，客户端必须同步更新 |

## 安全建议

- **务必新生成 UUID**，不要用别处见过的；`deploy.sh` 默认自动生成
- 路径不要用 `/ws` 这类默认值（脚本默认随机），降低被扫到的概率
- 定期更新：`bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install`
- 不要把节点链接发到公开群里——链接即凭据，泄露等于送人

## 协议演进

- 当前：**VLESS + WebSocket + TLS**，兼容绝大多数客户端，套 CDN 最省事
- Xray 26.x 把 **WS** 也标成了 deprecated（功能正常，`xray -test` 会打 warning），后续可换 XHTTP / H2 / H3
- 若目标是抗封锁，下一步是 **VLESS + Reality**（无需证书、伪装真实 TLS 站点），需要时可以在 `deploy.sh` 里加 `--reality`

