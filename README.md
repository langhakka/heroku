# v2ray-heroku

> ~~貌似新建的app有些需要科学访问~~，如果需要，请使用cloudflare worker CDN 或者 cloudflare tunnel 套一层。

> 切换到最新的 VLESS 协议。具体客户端配置请看 config 章节。

> v2ray-heroku 是我为了体验 github action 的产物，也是我的主力 backup，我会日常维护它。加入或者修改一些我认为好的配置。但这一般会导致客户端配置需要些许修改。 不过具体配置都会体现在 [详细 VLESS websocket 客户端配置](#vless-websocket-客户端配置)

> 有问题请开 issue 或者 discussions。

## **请大家不要跑速度测试，请用 youtube 测试。**


## Change log

应需求，加上首页伪装，如果你有想法，请自己把想要的html放入到 项目html 文件，然后后续 action 部署会自动拿到。

## !!!!!!! **对于老用户是 breaking change, 对ws 新加了path, 请注意查看客户端配置**

## !!!!!!! **对于老用户是 breaking change, 对ws 新加了path, 请注意查看客户端配置**

## !!!!!!! **对于老用户是 breaking change, 对ws 新加了path, 请注意查看客户端配置**

首先查看别人的 [youtube 教程](https://www.youtube.com/watch?v=xHZyDsFYdvA)，了解怎么配置 v2ray-heroku。**本项目使用最新 VLESS 协议，请在客户端配置选择 VLESS**。  
[详细 VLESS websocket 客户端配置](#vless-websocket-客户端配置) 。

如果你还想自动化你的 heroku，请查看下面的教程。

本项目是包含，

- 一键部署 V2ray 到 heroku。
- 利用 Github action 实现 [重新部署](#重新部署)/[停止](#停止)/[启动](#启动)/[删除](#删除)。
- 支持 heroku 的区域（us 和 eu）
- **支持[多app和多账户](#使用-environments-实现-多账户多app-secrets-管理) [重新部署](#重新部署)/[停止](#停止)/[启动](#启动)/[删除](#删除)。**

- 利用 cloudflare CDN 进行加速。
- **利用 [cloudflare tunnel](https://www.cloudflare.com/products/tunnel/) 进行加速。**

```text
项目Dockerfile是基于V2fly 官方镜像制作。仅仅增加生产配置文件的脚本。重新部署就可以更新到最新的v2ray。
基于官方镜像，这也是v2fly 推荐的做法。
```

> 保持安全最简单的方式就是，保持软件更新。

## 一键部署

[![Deploy](https://www.herokucdn.com/deploy/button.svg)](https://heroku.com/deploy)

> 貌似在这个 repo 下 点击 一键部署貌似 heroku 提示违反某些原则，但是action 正常工作！！建议 fork 时候，项目名字，尽量不要带有 v2ray 关键字。

> 如果被heroku 提示错误，请用 github action 来部署。

> 部署成功后，可以先用浏览器访问 ***.herokuapp.com， 查看页面是否能正常访问。

## Github Actions 管理

请 Fork 本项目到自己的账户下。 Actions 需要以下 Secrets 才能正常工作，这些 Secrets 会被 workflow 中的 [akhileshns/heroku-deploy](https://github.com/AkhileshNS/heroku-deploy) 使用。

具体实现细节，请查看 [workflow 配置文件](./.github/workflows/main.yml). 如何配置， 请查看，[Github Secrets](#github-secrets)

| Name              | Description                                |
| ----------------- | ------------------------------------------ |
| APP_NAME          | 就是你 heroku 项目的名字. 如果你是第一次创建APP，**请确保名字是唯一的**|
| EMAIL             | heroku 账户的 email                      |
| HEROKU_API_KEY    | heroku API key，在 account 设置下可以找到 |
| HEROKU_V2RAY_UUID | V2rayUUID                                |
| HEROKU_TUNNEL_TOKEN | **可选** cloudflare tunnel 的 token    |

> 这样Token一定必须是大写。。请在 heroku 网站创建app，来确保项目的名字的唯一性。

HEROKU_TUNNEL_TOKEN 是可选项，可以忽略. 详细说明，请查看章节 《建立-cloudflare-tunnel-（可选）》

> 请务必生成新的 UUID。使用已有的 UUID 会使自己 V2ray 暴露在危险之下。


PowerShell:

```powershell
PS C:\Users\> New-Guid
```

Shell:

```bash
xxx@xxx:/mnt/c/Users/$ uuidgen
```

### Github Secrets

路径

```text
项目Setting-->Secrets
```

![Secrets](./readme-data/GithubSecrets.gif)

### Heroku API key

路径

```text
heroku Account settings-->API key
```

![Secrets](./readme-data/herokuapikey.gif)

### Github Actions 界面

```text
Actions
```

![Actions](./readme-data/githubactions.gif)

### 重新部署

点击 `Run workflow`, 输入 deploy。 然后就会重新 deploy。

这里可以**选择区域**，但是请确保app没有被创建过。如果要切换区域，请先使用 destroy 删除应用。

![deploy](./readme-data/deploy.png)

### 停止

点击 `Run workflow`, 输入 stop。 然后就会 stop，不在计入小时数。
![stop](./readme-data/stop.jpg)

### 启动

点击 `Run workflow`, 输入 start。 然后就会启动。

![start](./readme-data/start.jpg)

### 删除

点击 `Run workflow`, 输入 destroy  然后就会删除。

![delete](./readme-data/delete-app.png)


## 建立 cloudflare worker （可选）

如果遇到创建的app在正常网络下不能访问，请尝试这个。

可以参考 开头的视频。代码如下。

```javascript
addEventListener("fetch", (event) => {
  let url = new URL(event.request.url);
  url.hostname = "你的heroku的hostname";
  let request = new Request(url, event.request);
  event.respondWith(fetch(request));
});
```

为 worker 选择速度更快的 IP。
https://github.com/badafans/better-cloudflare-ip

## 建立 cloudflare tunnel （可选）

项目集成 cloudflare tunnel， 在配置 Secrets `HEROKU_TUNNEL_TOKEN` 之后生效。具体怎么配置，请查看 [cloudflare tunnel](./cloudflared-tunnel.md)。

## 使用 Environments 实现 多账户/多app Secrets 管理

文档介绍： https://docs.github.com/en/actions/deployment/using-environments-for-deployment

### 建立 Environments, 并添加 Secrets

1. 创建 Environments
![Environments](./readme-data/Environments.png)
2. 添加 Secrets
![EnvironmentsSercet](./readme-data/EnvironmentsSercet.png)

### 输入环境名字
**一定要确保环境名字是对的，要不然就会用主的Secrets。**
![EnvironmentsDeploy](./readme-data/EnvironmentsDeploy.png)

## VLESS websocket 客户端配置

### JSON

```json
"outbounds": [
        {
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "***.herokuapp.com", // heroku app URL 或者 cloudflare worker url/ip
                        "port": 443,
                        "users": [
                            {
                                "id": "", // 填写你的 UUID
                                "encryption": "none"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "/ws"  // 这里是新加的
                },
                "security": "tls",
                "tlsSettings": {
                    "serverName": "***.herokuapp.com" // heroku app host 或者 cloudflare worker host
                }
              }
          }
    ]
```

### v2rayN

path 是 **/ws**

换成 [V2rayN](https://github.com/2dust/v2rayN)

别人的配置教程参考，https://v2raytech.com/v2rayn-config-tutorial/.

![v2rayN](/readme-data/V2rayN.jpg)

## 自建 VPS 的 VLESS 节点（独立方案）

不想用 Heroku、只想在自己的 VPS 上开一个节点？见 [vless/README.md](./vless/README.md)。

```bash
sudo bash vless/deploy.sh --domain node.example.com --email you@example.com
```

脚本会自动安装 Xray-core、生成 UUID 和随机 WS 路径、签发 Let's Encrypt 证书、配置 systemd 开机自启，并直接打印可导入客户端的 `vless://` 链接；支持 `--ws` 模式（套 Cloudflare CDN）和 `--print-only`（只在本地打印配置，不动系统）。

协议只用 **VLESS + WebSocket + TLS**：VMess 的请求头里带「加密方式」字段，客户端填错或丢失时服务端只能拒绝（`unknown security type: UNKNOWN`），表现是"能连上但流量全废"，VLESS 没有这个字段，少一类坑。

## 容器内临时节点（掉线/重建后一键恢复）

沙箱或临时机器（没有 systemd）里想马上拿到一条「手机能连」的链路，用这个：

```bash
bash vless/test/demo-node.sh            # 起节点 + Cloudflare 临时隧道，打印 vless:// 链接
bash vless/test/demo-node.sh --status   # 看进程/域名/当前链接
bash vless/test/demo-node.sh --stop     # 全停
```

恢复（容器被重建、进程全没了）就再跑一次同一条命令：

```bash
bash vless/test/demo-node.sh            # 沿用 .cache 里的 UUID/路径，重新拉隧道
```

行为说明：

| 情况 | 结果 |
| --- | --- |
| 进程还在，只是掉线 | 守护进程（默认自动启动）15 秒内拉起，域名/链接不变 |
| 容器被重建（`.cache` 丢失） | 无参重跑 = 新 UUID + 新路径 + 新 `trycloudflare.com` 域名，旧客户端配置需重新导入 |
| 想恢复成和以前一模一样 | 把 UUID/路径/端口 + 命名隧道 token 存到容器外，重跑时喂回去：`bash vless/test/demo-node.sh --port 8001 --uuid <原UUID> --path <原路径> --tunnel-token <CF token> --tunnel-host <固定域名>` |

守护进程（xray 挂了自动拉起、隧道坏了自动重建并重写链接）：

```bash
bash vless/test/watchdog.sh start      # 后台守护（demo-node.sh 默认已帮你起好）
bash vless/test/watchdog.sh status     # 守护/节点/隧道 + 101 自检 + 当前链接
bash vless/test/watchdog.sh stop --all
```

自检状态含义：`101 Switching Protocols` = Cloudflare 边缘 → 节点的 WebSocket 升级正常；WS 路径就是凭据之一，路径不对会直接 502/404。

