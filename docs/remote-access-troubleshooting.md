# Jellyfin 网络连接性排查

这份文档用于处理当前正式公网入口“Jellyfin 突然打不开”的情况。

2026-08-29 起，正式入口已经从家庭 IPv6 直连迁移到 Azure VPS 中继。当前主链为：

```text
公网客户端
    |
    | HTTPS :443
    v
<PUBLIC_HOST>
DuckDNS A -> <AZURE_PUBLIC_IPV4>
    |
    v
Azure Ubuntu VPS
Caddy
    |
    | reverse_proxy
    v
10.77.0.2:8096
    |
    | WireGuard
    v
Windows Jellyfin
```

完整从零搭建过程见：

`docs/remote-access-vps-relay.md`

2026-08-29 迁移实录见：

`docs/history/2026-08-29-azure-vps-relay.md`

旧家庭 IPv6 / DuckDNS AAAA / Jellyfin 9443 的完整排错经验已移到：

`docs/history/2026-08-29-ipv6-direct-troubleshooting-archive.md`

当前排错不要一上来重装 Caddy、重建 WireGuard、重签证书或重新研究家庭 IPv6。仍然遵循同一个原则：

> **找到最后一个真正成功的层，以及紧接着第一个真正失败的层。只修改失败层。**

---

## 1. 当前地址和端口约定

```text
Windows Jellyfin 本机：
http://127.0.0.1:8096

Windows WireGuard：
10.77.0.2/24

Azure WireGuard：
10.77.0.1/24

WireGuard 公网端口：
UDP 51820

Azure 公网 HTTP：
TCP 80

Azure 公网 HTTPS：
TCP 443

正式入口：
https://<PUBLIC_HOST>
```

当前正式入口**不使用 `:9443`**。

`9443` 属于旧家庭直连方案。当前 Caddyfile 应为：

```caddy
<PUBLIC_HOST> {
    reverse_proxy 10.77.0.2:8096
}
```

而不是：

```caddy
<PUBLIC_HOST>:9443 {
    reverse_proxy 10.77.0.2:8096
}
```

---

## 2. 当前最短检查顺序

网站打不开时按下面顺序走，不要跳层：

| 顺序 | 测试 | 主要证明什么 |
| --- | --- | --- |
| 1 | Windows `http://127.0.0.1:8096` | Jellyfin 本机是否活着 |
| 2 | Windows WireGuard 是否激活、是否有握手 | Windows 是否仍连着 Azure |
| 3 | Azure `sudo wg show` | Azure WireGuard peer 是否存在、是否有最近握手 |
| 4 | Azure `ping 10.77.0.2` | 隧道 IP 是否双向可达 |
| 5 | Azure `curl http://10.77.0.2:8096/` | Azure 是否真正能访问 Jellyfin |
| 6 | Azure 检查 Caddy、80/443 | 公网反向代理是否工作 |
| 7 | DNS 查询 A / AAAA | 域名是否仍指向 Azure IPv4 |
| 8 | 手机移动数据 `https://<PUBLIC_HOST>` | 整条公网链是否完成 |

只要第 N 步失败，就先停在第 N 步。后面的组件即使也可能有问题，也不要同时修改。

---

## 3. 第 0 层：Windows Jellyfin 本机

在运行 Jellyfin 的 Windows 主机：

```powershell
curl.exe -v http://127.0.0.1:8096/
```

当前实例正常时常见返回：

```text
HTTP/1.1 302 Found
Location: web/
Server: Kestrel
```

排错时不要求机械地必须是 302；只要能收到正常 Jellyfin HTTP 响应，就说明本机服务存在。

### 如果失败

先检查：

```powershell
netstat -ano | findstr ":8096"
```

如有监听，再确认 PID：

```powershell
tasklist /FI "PID eq <PID>"
```

这一层失败时：

```text
不要查 DuckDNS
不要查 Caddy
不要查 Azure 443
不要重建 WireGuard
```

因为 Azure 最终也只能反代到这个 8096。如果本机已经失败，外层不可能修好它。

---

## 4. 第 1 层：Windows WireGuard 是否仍在线

打开 Windows WireGuard 客户端，检查隧道：

```text
Jellyfin-Azure
```

应处于激活状态。

当前 Windows 配置的结构应为：

```ini
[Interface]
PrivateKey = <WINDOWS_PRIVATE_KEY>
Address = 10.77.0.2/24

[Peer]
PublicKey = <AZURE_WG_PUBLIC_KEY>
AllowedIPs = 10.77.0.1/32
Endpoint = <AZURE_PUBLIC_IPV4>:51820
PersistentKeepalive = 25
```

重点看：

- 隧道是否激活；
- 最近握手是否持续更新；
- 收发字节是否变化。

### 隧道没有激活

先激活 `Jellyfin-Azure`，不要修改 Azure Caddy。

### 已激活但一直没有握手

确认：

1. Windows 当前能正常访问 IPv4 Internet；
2. `Endpoint` 仍是当前 Azure 公网 IPv4；
3. Azure VM 正在运行；
4. Azure NSG 仍允许 UDP 51820；
5. Azure `wg-quick@wg0` 仍在运行。

不要把 `AllowedIPs` 临时改成 `0.0.0.0/0`。当前方案只需要 Windows 到 Azure WireGuard IP 的路由：

```text
10.77.0.1/32
```

---

## 5. 第 2 层：Azure WireGuard 服务

SSH 登录 Azure：

```powershell
ssh -i "$HOME\.ssh\Jellyfin_key.pem" azureuser@<AZURE_PUBLIC_IPV4>
```

检查服务：

```bash
sudo systemctl status wg-quick@wg0 --no-pager
```

检查接口：

```bash
ip -br addr show wg0
```

正常应有：

```text
wg0    UNKNOWN    10.77.0.1/24
```

检查 peer：

```bash
sudo wg show
```

应至少能看到：

```text
interface: wg0
listening port: 51820
peer: <WINDOWS_WG_PUBLIC_KEY>
allowed ips: 10.77.0.2/32
latest handshake: ...
transfer: ...
```

### 服务不在运行

先：

```bash
sudo systemctl restart wg-quick@wg0
sudo systemctl status wg-quick@wg0 --no-pager
```

不要先重写 `/etc/wireguard/wg0.conf`。

### 服务运行但没有 Windows peer

检查：

```bash
sudo cat /etc/wireguard/wg0.conf
```

配置应有：

```ini
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = <AZURE_PRIVATE_KEY>

[Peer]
PublicKey = <WINDOWS_WG_PUBLIC_KEY>
AllowedIPs = 10.77.0.2/32
```

实际检查时不要把 Azure 私钥复制到聊天、Issue 或仓库。

---

## 6. 第 3 层：Azure 能否 ping Windows WireGuard IP

执行：

```bash
ping -c 4 10.77.0.2
```

本次部署时曾真实得到：

```text
4 packets transmitted
4 received
0% packet loss
平均 RTT 约 103 ms
```

以后不要求延迟仍然是 103 ms；这里看的是是否真正收得到回包。

### `wg show` 有最近握手，但 ping 失败

说明“WireGuard 外层 UDP 会话存在”与“隧道内 IP 通信正常”之间出现断层。

检查：

- Windows WireGuard 是否确实拥有 `10.77.0.2/24`；
- Azure 是否是 `10.77.0.1/24`；
- 两端 `AllowedIPs` 是否仍分别指向对端；
- Windows 防火墙是否阻止 WireGuard 接口上的流量。

此时还不要查 Caddy。

---

## 7. 第 4 层：Azure 能否真正访问 Jellyfin 8096

这是当前架构最关键的后端测试：

```bash
curl -v http://10.77.0.2:8096/
```

首次部署时真实返回：

```text
Connected to 10.77.0.2 port 8096
HTTP/1.1 302 Found
Server: Kestrel
Location: web/
```

如果这一条成功，可以一次排除很多东西：

```text
Jellyfin 本机服务             OK
Windows 到 WireGuard 的路径    OK
WireGuard 隧道                OK
Azure 到 Windows              OK
Azure 能访问 Jellyfin 8096     OK
```

这时如果正式域名仍然失败，就不要再改 Windows 或 WireGuard，继续查 Caddy / DNS / Azure 公网入口。

### ping 成功，curl 8096 失败

范围通常收敛到：

- Jellyfin 是否只监听 loopback；
- Windows 防火墙是否允许 WireGuard 网络访问 8096；
- Jellyfin 8096 当前是否仍正常；
- Windows 上 8096 的监听进程是否还是 Jellyfin。

先在 Windows 回到：

```powershell
curl.exe -v http://127.0.0.1:8096/
netstat -ano | findstr ":8096"
```

不要因为 ping 通了就认为 TCP 8096 一定通。

---

## 8. 第 5 层：Caddy 服务和监听端口

先检查 Caddy：

```bash
sudo systemctl status caddy --no-pager
```

日志：

```bash
sudo journalctl -u caddy -n 50 --no-pager
```

监听：

```bash
sudo ss -ltnp | grep -E ':(80|443)\b'
```

当前目标是 Caddy 提供：

```text
TCP 80
TCP 443
```

Caddyfile：

```bash
sudo cat /etc/caddy/Caddyfile
```

应为：

```caddy
<PUBLIC_HOST> {
    reverse_proxy 10.77.0.2:8096
}
```

### Caddy 配置语法检查

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
```

修改后优先：

```bash
sudo systemctl reload caddy
```

如果服务状态异常再使用 restart。

---

## 9. 已经实际发生过的错误：Caddy 误监听 9443

第一次迁移时曾写成：

```caddy
<PUBLIC_HOST>:9443 {
    reverse_proxy 10.77.0.2:8096
}
```

这个错误有迷惑性，因为：

```text
caddy validate            成功
caddy.service             active
Let's Encrypt HTTP-01     成功
证书获取                   成功
```

日志甚至出现：

```text
authorization finalized
validations succeeded
certificate obtained successfully
```

但同时存在关键日志：

```text
enabling HTTP/3 listener
addr: :9443
```

这说明证书和 DNS 都没坏，真正问题只是 Caddy 被旧方案端口带偏。

当前正确处理是：

```caddy
<PUBLIC_HOST> {
    reverse_proxy 10.77.0.2:8096
}
```

而不是为了迁就这个错误去给 Azure 新开 9443。

所以以后如果出现：

```text
证书成功
Caddy active
https://<PUBLIC_HOST> 仍打不开
```

一定顺手看：

```bash
sudo ss -ltnp | grep -E ':(80|443|9443)\b'
```

确认没有又把旧 9443 带回来。

---

## 10. 第 6 层：Azure NSG

当前公网入站规则应至少包含：

```text
22/tcp      SSH
51820/udp   WireGuard
80/tcp      HTTP
443/tcp     HTTPS
```

其中：

```text
8096 不应该作为 Azure 公网入站开放
```

因为 Caddy 应通过 WireGuard 访问 Windows 的 8096。

### WireGuard 无握手

重点看 UDP 51820。

### Caddy 在本机监听 80/443，但公网连不上

重点看 Azure NSG 的 TCP 80/443。

不要把 UDP/TCP 协议写反。

---

## 11. 第 7 层：DuckDNS

当前 DuckDNS 正式状态：

```text
A     -> <AZURE_PUBLIC_IPV4>
AAAA  -> 无
```

Windows 查询：

```powershell
Resolve-DnsName <PUBLIC_HOST> -Type A
Resolve-DnsName <PUBLIC_HOST> -Type AAAA
```

### A 不是 Azure 公网 IPv4

先修 DNS，不要重签 Caddy 证书。

### 又出现 AAAA

当前正式架构没有要求客户端走家庭 IPv6。如果 AAAA 又指向家庭地址，可能导致支持 IPv6 的客户端选错路径。

用 DuckDNS 更新接口时，当前流程是先清记录：

```text
https://www.duckdns.org/update?domains=<SUBDOMAIN>&token=<DUCKDNS_TOKEN>&clear=true&verbose=true
```

再写 Azure IPv4：

```text
https://www.duckdns.org/update?domains=<SUBDOMAIN>&token=<DUCKDNS_TOKEN>&ip=<AZURE_PUBLIC_IPV4>&verbose=true
```

`domains=` 填子域名，不带 `.duckdns.org`。

DuckDNS token 不要写入公开文档或 Issue。

---

## 12. 第 8 层：真正公网验收

当前最终入口：

```text
https://<PUBLIC_HOST>
```

不要加：

```text
:9443
```

Windows 可先：

```powershell
curl.exe -v https://<PUBLIC_HOST>/
```

最终验收使用手机关闭 Wi-Fi、仅移动数据访问同一地址。

### Azure 自己能 curl `10.77.0.2:8096`，但公网域名失败

后端已经正常，范围只剩：

```text
Caddy
Azure NSG 80/443
DuckDNS A
公网客户端
```

不要回头折腾家庭 IPv6。

### Windows 电脑能打开正式域名，手机移动数据失败

继续检查：

- 手机解析到的 A 是否正确；
- 是否存在旧 AAAA；
- 手机代理 / VPN / Private DNS；
- Azure 443 是否对公网正常。

当前正式方案使用 IPv4 HTTPS，因此不再要求手机客户端具备 IPv6。

---

## 13. Windows / Azure 重启后的恢复检查

### Windows 重启后

依次确认：

1. Jellyfin 已启动；
2. `127.0.0.1:8096` 正常；
3. WireGuard `Jellyfin-Azure` 已激活；
4. Azure `sudo wg show` 出现最近握手；
5. Azure `curl http://10.77.0.2:8096/` 成功。

家庭公网 IPv6 是否变化已经不再影响正式入口。

### Azure VM 重启后

检查：

```bash
sudo systemctl status wg-quick@wg0 --no-pager
sudo systemctl status caddy --no-pager
```

安装时已经执行：

```bash
sudo systemctl enable --now wg-quick@wg0
```

Caddy 官方包也使用 systemd 服务，因此正常情况下两者都应随系统启动。

然后：

```bash
sudo wg show
curl -v http://10.77.0.2:8096/
sudo ss -ltnp | grep -E ':(80|443)\b'
```

---

## 14. 按现象快速判断

```text
127.0.0.1:8096 失败
-> Jellyfin 本机

Jellyfin 本机成功，Windows WireGuard 未激活
-> Windows WireGuard

Windows 已激活，但 Azure wg show 没有最近握手
-> UDP 51820 / Endpoint / Azure WireGuard / 外层网络

wg show 有握手，但 ping 10.77.0.2 失败
-> 隧道地址 / AllowedIPs / Windows WireGuard 接口 / 防火墙

ping 10.77.0.2 成功，但 curl 10.77.0.2:8096 失败
-> Windows 8096 监听 / Windows 防火墙 / Jellyfin 网络绑定

Azure curl 10.77.0.2:8096 成功，正式域名失败
-> 不再查 WireGuard；检查 Caddy / NSG / DNS

Caddy active、证书成功，但 443 不工作
-> 检查实际监听端口，特别防止又写成 :9443

Caddy 80/443 正常，但域名解析不是 Azure IPv4
-> DuckDNS A

A 正确，但同时残留家庭 AAAA
-> 清除 AAAA

所有服务器侧检查正常，Windows 能访问，手机移动数据失败
-> 客户端 DNS / 代理 / VPN / Azure 公网路径
```

---

## 15. 每个当前测试到底证明什么

| 测试结果 | 能证明 | 不能证明 |
| --- | --- | --- |
| Windows `127.0.0.1:8096` 成功 | Jellyfin 本机 HTTP 存在 | WireGuard / Azure / Caddy 正常 |
| `wg show` 有最近握手 | WireGuard 外层 UDP 会话建立 | 隧道内 8096 一定可达 |
| Azure ping `10.77.0.2` 成功 | WireGuard 隧道 IP 双向可达 | Jellyfin TCP 8096 正常 |
| Azure curl `10.77.0.2:8096` 成功 | 后端完整链路到 Jellyfin 正常 | 公网 Caddy / DNS 正常 |
| Caddy `active` | systemd 进程在运行 | 配置端口、证书、反代目标一定正确 |
| Caddy 成功取得证书 | DNS / ACME 验证至少在签发时成立 | Caddy 一定监听正确 HTTPS 端口 |
| `ss` 显示 `:443` | 本机有进程监听 443 | Azure NSG 一定放行公网 443 |
| DuckDNS A 正确 | DNS 指向 Azure IPv4 | Caddy / WireGuard / Jellyfin 正常 |
| 手机移动数据能打开正式域名 | 端到端公网正式链路工作 | 以后每个组件都永远不会故障 |

---

## 16. 当前架构不再依赖的旧项目

以下项目可能仍然存在于 Windows / 路由器历史配置里，但当前正式公网入口不依赖它们：

```text
家庭公网 IPv6
DuckDNS AAAA
TC7102 IPv6 公网入站
Jellyfin 自带 HTTPS :9443
家庭侧 PFX
客户端 IPv6
```

因此如果当前 `https://<PUBLIC_HOST>` 出现故障，不要因为过去曾经遇到过这些问题，就重新从家庭 IPv6 开始排查。

旧直连方案如果需要研究，使用归档：

`docs/history/2026-08-29-ipv6-direct-troubleshooting-archive.md`

---

## 17. 排错原则

当前链路比旧家庭 IPv6 方案更清晰，但仍然不要凭组件名称猜故障。

每次回答三个问题：

> **最后一个真正成功的测试是什么？**
>
> **紧接着第一个失败的测试是什么？**
>
> **成功测试到底证明到了哪一层？**

当前最有价值的边界测试仍然是：

```bash
curl -v http://10.77.0.2:8096/
```

它把系统明确切成两半：

```text
如果失败：
Windows / Jellyfin / WireGuard 后端

如果成功：
Caddy / Azure 公网 / DNS / 客户端前端
```

先找到边界，再改配置。