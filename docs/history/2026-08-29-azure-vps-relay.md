# 2026-08-29：Jellyfin 公网入口迁移到 Azure VPS 中继

对应网络维护 Issue：#23。

这份记录保留 2026-08-29 从家庭 IPv6 直连切换到 Azure VPS 中继的实际推进过程。完整可复现操作手册见：

`docs/remote-access-vps-relay.md`

---

## 1. 为什么正式放弃继续修家庭 IPv6 直连

此前短期方案已经做到过：

```text
DuckDNS AAAA
    -> 家庭公网 IPv6
    -> Jellyfin HTTPS :9443
```

并且在部分时间段内，通过临时关闭 TC7102 总防火墙，手机移动网络确实能直接访问 Jellyfin。

但后续出现了另一类故障：

- Windows 仍有全球 IPv6；
- 家庭 LAN IPv6 仍然正常；
- 同 Wi-Fi 设备仍可访问服务器的全球 IPv6；
- 手机移动数据访问时，Windows 抓不到任何来自公网的 8096 / 9443 包；
- Windows 强制直连公网 IPv6 目标也失败；
- IPv4 公网访问正常；
- 浏览器中的 IPv6 测试一度显示正常，但绕过代理后才暴露出真正的 IPv6 直连失败。

这说明继续围绕家庭公网 IPv6、路由器防火墙、DuckDNS AAAA 和客户端 IPv6 状态做长期入口，维护成本已经超过收益。

因此正式切换到此前考虑过的 VPS 中继路线：

```text
公网访问者
    |
    | HTTPS IPv4
    v
Azure VPS
    |
    | WireGuard
    v
Windows Jellyfin :8096
```

关键变化是：Windows 主机主动向 Azure 建立连接。家庭网络不再需要接受公网主动入站。

---

## 2. Azure 订阅与 VM 方案

本次使用 Azure for Students。

一开始创建 VM 时曾遇到 `NotAvailableForSubscription`，即部分区域 / SKU 对当前订阅不可用。解决可用性问题后，最终在 Azure Portal 中成功使用以下组合：

```text
订阅：Azure for Students
资源组：Jellyfin_group
虚拟机名称：Jellyfin
区域：East Asia
可用性：无需基础结构冗余
系统：Ubuntu Server 24.04 LTS - Gen2
体系结构：x64
安全类型：受信任启动虚拟机
安全启动：开启
vTPM：开启
规格：Standard B2ats v2
CPU / 内存：2 vCPU / 1 GiB
Spot：关闭
```

创建页显示该 VM 标准价格：

```text
0.0131 USD / 小时
```

同时显示“订阅额度适用”。因此这里记录的是创建页观察到的 SKU 标价和订阅提示，不把该数字直接解释成已经应用学生额度后的最终账单。

---

## 3. Azure 创建向导实际配置

### 磁盘

```text
OS 磁盘：64 GiB
类型：Premium SSD LRS
托管磁盘：是
删除 VM 时删除 OS 磁盘：是
临时 OS 磁盘：否
额外数据盘：无
```

### 网络

```text
VNet：Jellyfin-vnet
子网：default，10.0.0.0/24
公共 IP：Jellyfin-ip
NSG：Basic
创建时公网入站：只开放 SSH 22
加速网络：关
负载均衡：无
删除 VM 时删除公共 IP 和 NIC：是
```

### 管理

```text
Defender for Cloud：基本免费
托管身份：关
Entra ID 登录：关
自动关机：关
备份：关
定期评估：关
热补丁：关
补丁编排：映像默认
```

### 监视

```text
警报：关
启动诊断：关
OS 来宾诊断：关
应用运行状况监视：关
```

### 高级

```text
扩展：无
VM 应用程序：无
cloud-init：无
用户数据：无
磁盘控制器：SCSI
邻近放置组：无
容量预留组：无
```

### 标签

本次使用：

```text
ACG = jellyfin
```

创建完成后下载 `Jellyfin_key.pem`，作为 `azureuser` 的 SSH 私钥。

---

## 4. 第一次进入 Azure Ubuntu

Windows PowerShell 使用：

```powershell
ssh -i "$HOME\.ssh\Jellyfin_key.pem" azureuser@<AZURE_PUBLIC_IPV4>
```

首次成功登录后显示：

```text
Ubuntu 24.04.4 LTS
GNU/Linux 6.17.0-1022-azure x86_64
```

`hostnamectl` 确认：

```text
Virtualization: microsoft
Architecture: x86-64
```

`ip -br addr` 与 `ip route` 也确认 VM 获得 Azure VNet 地址和默认路由。

一次：

```bash
curl -4I https://www.microsoft.com
```

返回 HTTP/2 `INTERNAL_ERROR`，但紧接着：

```bash
sudo apt update
```

成功下载约 33 MB 软件索引，吞吐约 8.6 MB/s。因此当时的实际判断是：Azure VM 的 IPv4 公网出站正常，不能拿单个站点一次 HTTP/2 会话异常反推整个 VPS 网络故障。

这一步之后才继续安装 WireGuard。

---

## 5. Azure 端 WireGuard

安装：

```bash
sudo apt install -y wireguard
```

确认版本：

```text
wireguard-tools v1.0.20210914
```

生成 Azure 端密钥，并把接口固定为：

```text
Azure WireGuard：10.77.0.1/24
ListenPort：51820/UDP
```

启动后：

```bash
ip -br addr show wg0
```

得到：

```text
wg0    UNKNOWN    10.77.0.1/24
```

`sudo wg show` 也确认服务端公钥存在、私钥隐藏、监听端口为 51820。

随后在 Azure NSG 新增：

```text
UDP 51820 Allow
```

这时仍没有提前开放 Jellyfin 8096。

---

## 6. Windows 端 WireGuard

Windows 安装 WireGuard 后创建 `Jellyfin-Azure` 隧道。

本次固定分配：

```text
Windows WireGuard：10.77.0.2/24
```

Windows peer 指向：

```text
Endpoint = <AZURE_PUBLIC_IPV4>:51820
AllowedIPs = 10.77.0.1/32
PersistentKeepalive = 25
```

这里没有配置 `0.0.0.0/0`，因此普通 Windows 网络不会被整机送入 Azure。

Azure 端增加 Windows 公钥后重启 `wg-quick@wg0`，Windows 激活隧道，双方开始出现 `latest handshake` 和 transfer 数据。

---

## 7. WireGuard 实测：真正双向连通

Azure 执行：

```bash
ping -c 4 10.77.0.2
```

实际返回：

```text
4 packets transmitted
4 received
0% packet loss
```

四次 RTT 大约均在 102-104 ms，平均约 103 ms。

因此可以确认：

```text
Azure 10.77.0.1
        |
        | WireGuard
        v
Windows 10.77.0.2
```

已经真正连通。

---

## 8. 最关键后端验收：Azure 访问 Jellyfin 8096

WireGuard ping 通过后，Azure 直接执行：

```bash
curl -v http://10.77.0.2:8096/
```

实际返回：

```text
Connected to 10.77.0.2 port 8096
HTTP/1.1 302 Found
Server: Kestrel
Location: web/
```

这一步证明的不是“VPN 看上去在线”，而是完整后端业务链已经成立：

```text
Azure
  -> WireGuard
  -> Windows
  -> Jellyfin Kestrel :8096
```

从这一刻开始，家庭 IPv6、家庭路由器公网入站和旧 9443 HTTPS 都不再是新架构必须解决的前置条件。

---

## 9. 开放 Azure HTTP / HTTPS

确认后端 8096 已通以后，才在 Azure NSG 增加：

```text
TCP 80  Allow
TCP 443 Allow
```

因此最终公网入站端口为：

```text
22/tcp      SSH
51820/udp   WireGuard
80/tcp      HTTP / ACME
443/tcp     HTTPS
```

8096 没有对 Azure 公网开放。

---

## 10. DuckDNS 改为 Azure IPv4

此前 DuckDNS 用 AAAA 指向家庭 IPv6。现在改为：

```text
A     -> <AZURE_PUBLIC_IPV4>
AAAA  -> 无
```

由于 DuckDNS 网页本身操作体验较差，本次继续使用其 HTTP 更新接口。

先清除：

```text
https://www.duckdns.org/update?domains=<SUBDOMAIN>&token=<DUCKDNS_TOKEN>&clear=true&verbose=true
```

再写 Azure IPv4：

```text
https://www.duckdns.org/update?domains=<SUBDOMAIN>&token=<DUCKDNS_TOKEN>&ip=<AZURE_PUBLIC_IPV4>&verbose=true
```

随后用：

```powershell
Resolve-DnsName <PUBLIC_HOST> -Type A
Resolve-DnsName <PUBLIC_HOST> -Type AAAA
```

确认 A 已切到 Azure，AAAA 不再存在。

---

## 11. Azure 安装 Caddy

在 Ubuntu 上加入 Caddy 官方软件源并安装 Caddy，随后设置反向代理。

正确目标：

```text
HTTPS <PUBLIC_HOST>:443
    -> Caddy
    -> http://10.77.0.2:8096
```

第一次配置时发生了一个非常典型的迁移错误。

---

## 12. 旧 9443 被错误带入 Caddy

第一次写出的 Caddyfile 是：

```caddy
<PUBLIC_HOST>:9443 {
    reverse_proxy 10.77.0.2:8096
}
```

之所以会写成 9443，是旧的家庭直连方案一直使用：

```text
https://<PUBLIC_HOST>:9443
```

这个旧端口习惯被顺手带到了新架构里。

麻烦在于，这个配置并不是语法错误。

`caddy validate` 返回：

```text
Valid configuration
```

`caddy.service` 也是：

```text
active (running)
```

而且 Let's Encrypt 的 HTTP-01 请求成功到达了 Azure，日志连续出现：

```text
served key authentication
authorization finalized
validations succeeded
certificate obtained successfully
```

这反过来也确认：

```text
DuckDNS -> Azure IPv4        正常
公网 TCP 80                  正常
Let's Encrypt -> Caddy       正常
证书签发                      正常
```

真正的问题藏在：

```text
enabling HTTP/3 listener
addr: :9443
```

Caddy 正在 9443 提供 HTTPS，而新架构真正想要的是标准 443。

因此没有去给 Azure 再开放 9443，而是修正 Caddyfile。

---

## 13. Caddy 修正到标准 443

最终配置：

```caddy
<PUBLIC_HOST> {
    reverse_proxy 10.77.0.2:8096
}
```

不显式写端口后，Caddy 自动使用标准 HTTPS 443，并用 80 处理 HTTP / ACME 和自动跳转。

修正后检查：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo ss -ltnp | grep -E ':(80|443)\b'
```

确认目标端口为 80 / 443。

---

## 14. 最终验收

Windows 直接测试：

```powershell
curl.exe -v https://<PUBLIC_HOST>/
```

随后手机关闭 Wi-Fi，仅使用移动数据打开：

```text
https://<PUBLIC_HOST>
```

最终 Jellyfin 正常打开。

这意味着以下整条链路已经完成实机闭环：

```text
移动网络 / 公网客户端
    |
    | HTTPS 443
    v
DuckDNS A
    |
    v
Azure 公网 IPv4
    |
    v
Caddy
    |
    v
10.77.0.1
    |
    | WireGuard
    v
10.77.0.2
    |
    v
Jellyfin :8096
```

---

## 15. 这次迁移真正消掉了什么依赖

此前每次正式入口失败，都需要在下面这些因素中判断：

- Windows 当前公网 IPv6 是否变化；
- DuckDNS AAAA 是否还在旧地址；
- TC7102 防火墙是否拦截；
- 家庭 IPv6 WAN 当前是否真的连得出去；
- 手机当前 Wi-Fi 是否还有 IPv6；
- 移动网络和家庭 IPv6 前缀是否互通；
- 浏览器测试是否被代理伪装；
- Jellyfin 9443 与 PFX 是否正常。

迁移后，这些都退出正式公网入口主链。

当前核心依赖变为：

```text
Windows 主机能主动上网
WireGuard 隧道存在
Azure VPS 正常
Caddy 正常
DuckDNS A 指向 Azure
Jellyfin 8096 正常
```

这比继续维护家庭公网 IPv6 入站稳定得多，也符合最初“不为了公网入口购买整台 NAS / 服务器”的方向：Azure VM 只负责入口，不替代本地媒体服务器。

---

## 16. 后续运维边界

迁移刚成功时，不立刻一次性删除旧直连方案的所有配置。先让新链路实际运行一段时间。

当前正式入口以 VPS 中继为准，排错优先顺序改为：

```text
Jellyfin 本机
-> Windows WireGuard
-> Azure WireGuard
-> Azure curl 10.77.0.2:8096
-> Caddy 80/443
-> DuckDNS A
-> 外部客户端
```

完整搭建和命令见：

`docs/remote-access-vps-relay.md`

家庭 IPv6 / 9443 的历史排错仍保留在：

`docs/remote-access-troubleshooting.md`

它们仍然有历史和网络诊断价值，但不再代表当前正式入口架构。
