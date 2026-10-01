# FRP 长期运行：内网服务器作为 HTTPS 入口

适用于 Debian/Ubuntu amd64 内网服务器。浏览器电脑不运行 FRP。

```text
浏览器（hosts 指向内网服务器）
  → 内网服务器 frpc visitor :443
  → 加密且校验证书的 STCP 通道
  → us.zipmm.com:443 / OpenResty ssl_preread
  → 公网服务器 frps 127.0.0.1:7000
  → 公网服务器 frpc service
  → OpenResty 127.0.0.1:443 按原始网站 SNI 转发
  → x.com:443
```

公网 443 按 `frp-tunnel.us.zipmm.com` 这个 TLS SNI 转到 FRP；网站 HTTPS
仍使用 18443。FRP 的 7000 仅监听回环地址。这个专用 SNI 不需要新增 DNS
记录：frpc 连接 `us.zipmm.com`，TLS 校验名另行配置，证书由隧道私有 CA 签发。
私有 CA 只供 FRP 使用，不需要安装到浏览器。浏览器验证的仍是 X 的真实证书。

## 一、公网服务器

以 root 执行，安装固定版本 FRP 0.71.0，验证官方发布文件的 SHA256：

```bash
curl -fsSLO https://raw.githubusercontent.com/qdog2012/myscripts/main/install-frp-tunnel.sh
FRP_SERVER_HOST=us.zipmm.com bash install-frp-tunnel.sh
```

需要已有本仓库初始化脚本配置的 1Panel OpenResty。安装器保留已有 SNI 映射，
增加专用隧道映射，检查 Nginx 配置后重载，并创建：

| 服务 | 配置 | 用途 |
|---|---|---|
| `frps` | `/serverdata/frp/frps.toml` | 回环 7000 接收加密隧道 |
| `frpc-service` | `/serverdata/frp/frpc-service.toml` | 发布本机 443 为 STCP 服务 |

两项服务使用专用 `frp` 系统用户，开机启动，异常退出 5 秒后重启。
`loginFailExit = false` 使 frpc 在启动时无网络或断线后持续重连。
启用双向 TLS 验证、随机认证 token 和随机 STCP 密钥。

生成的内网端安装包：

```text
/root/.config/frp-tunnel/visitor-client.tar.gz
```

包内有认证 token、STCP 密钥和访客私钥；通过 SSH/SCP 传输，保存在私有目录，
不要提交 Git。CA 私钥和服务端私钥不包含在包内。
重新运行安装器会保留认证信息和证书；证书有效期为 5 年，临近到期时需要重新签发
并分发客户端安装包，安装器会在距离到期不足 30 天时报告错误。

## 二、内网服务器

以 root 执行。下面 `192.168.19.25` 是示例，替换成这台服务器自己的内网 IP。
该 IP 的 TCP 443 必须空闲，并允许浏览器所在内网访问。

```bash
apt-get update
apt-get install -y curl ca-certificates python3 tar iproute2

curl -fsSLO https://raw.githubusercontent.com/qdog2012/myscripts/main/install-frp-visitor.sh
scp -P 2424 root@us.zipmm.com:/root/.config/frp-tunnel/visitor-client.tar.gz /root/
chmod 600 /root/visitor-client.tar.gz

FRP_VISITOR_BIND_ADDR=192.168.19.25 \
  bash install-frp-visitor.sh /root/visitor-client.tar.gz
```

SCP 使用该机器的 SSH 认证。如果内网服务器没有公网服务器的 SSH 密钥，可以先在
有 SSH 权限的机器上下载此私有包，再通过 SCP 上传到内网服务器的 `/root` 目录。

内网端配置为 `/serverdata/frp-visitor/visitor.toml`，服务名为 `frpc-visitor`。
服务使用 `CAP_NET_BIND_SERVICE` 绑定 443，进程以 `frp` 用户运行。
仅指定的内网 IP 监听；未设置 `FRP_VISITOR_BIND_ADDR` 时默认只监听 127.0.0.1。

关键配置形如（完整文件由安装器生成）：

```toml
serverAddr = "us.zipmm.com"
serverPort = 443
loginFailExit = false
auth.method = "token"
auth.token = "安装包中的随机认证 token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.tls.enable = true
transport.tls.disableCustomTLSFirstByte = true
transport.tls.serverName = "frp-tunnel.us.zipmm.com"
transport.tls.trustedCaFile = "/serverdata/frp-visitor/ca.crt"
transport.tls.certFile = "/serverdata/frp-visitor/visitor.crt"
transport.tls.keyFile = "/serverdata/frp-visitor/visitor.key"

[[visitors]]
name = "https-preread-visitor"
type = "stcp"
serverName = "https-preread"
secretKey = "安装包中的随机 STCP 密钥"
bindAddr = "192.168.19.25"
bindPort = 443
transport.useEncryption = true
```

必须保留 `disableCustomTLSFirstByte = true`，使外层连接成为普通 TLS ClientHello，
让 OpenResty 正确读出隧道的 SNI。访客的 `serverName = "https-preread"` 是 STCP
服务名称，`transport.tls.serverName` 才是外层 TLS 名称，两者用途不同。

## 三、浏览器电脑

将 hosts 中原来指向公网服务器的这两个域名改成内网 IP，删除重复映射：

```text
192.168.19.25 x.com abs.twimg.com
```

Windows hosts 位于 `C:\Windows\System32\drivers\etc\hosts`。管理员终端执行：

```powershell
ipconfig /flushdns
```

重新打开浏览器，访问 `https://x.com`。浏览器的 HTTP/SOCKS 代理可能绕过系统 hosts；
该方式需要让这两个域名直接连接内网服务器。

## 四、查看状态与验证

内网服务器上：

```bash
systemctl status frpc-visitor --no-pager
journalctl -u frpc-visitor -n 40 --no-pager
ss -lntp 'sport = :443'
curl --noproxy '*' --resolve x.com:443:192.168.19.25 https://x.com/ -I
```

日志应出现 `login to server success`、`start visitor success`。
公网服务器上：

```bash
systemctl status frps frpc-service --no-pager
journalctl -u frps -u frpc-service -n 40 --no-pager
```

已在测试公网服务器上验证 STCP 注册和转发：`https://x.com` 返回 HTTP 200，
网站 TLS 证书校验通过。内网机器到公网服务器的实际链路需要在内网端安装后验证。

该通道只转发 TCP HTTPS。新资源域名需要同时加入浏览器 hosts 和公网 OpenResty
的 SNI map，例如 X 的图片、视频域名；仅有 `x.com`、`abs.twimg.com` 不能保证完整
网站功能。普通 HTTP 80 和 QUIC/UDP 443 不经此隧道。

## 五、停用

内网服务器：`systemctl disable --now frpc-visitor`，并恢复浏览器电脑的 hosts。
公网服务器：`systemctl disable --now frpc-service frps`。删除 stream 配置中标注
`MyScripts FRP tunnel` 的那条映射，检查配置后重载 OpenResty。
首次安装前的 stream 配置备份为 `/root/.config/frp-tunnel/stream.before-frp.conf`；
只在确认没有后续修改时才整体恢复该备份。
