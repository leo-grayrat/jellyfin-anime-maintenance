# Jellyfin Azure VPS 中继：从零创建到公网 HTTPS 的完整流程

本文记录当前 Jellyfin 公网入口的完整搭建流程。目标不是把 Jellyfin 或媒体文件迁移到云端，而是只用一台低配置 Azure Linux VM 作为固定公网入口：公网用户访问 Azure，Azure 再通过 WireGuard 隧道访问运行在 Windows 上的 Jellyfin。

最终链路：

```text
动漫社成员浏览器 / Jellyfin 客户端
        |
        | HTTPS :443
        v
Azure Ubuntu VPS
Caddy
        |
        | WireGuard
        | 10.77.0.1 <-> 10.77.0.2
        v
Windows 主机
Jellyfin HTTP :8096
```

这套架构的关键边界是：

- Jellyfin 仍运行在 Windows 主机；
- 动画文件仍保存在本地磁盘；
- Azure 不承担媒体存储和转码，只承担公网入口、TLS 和转发；
- Windows 主动建立到 Azure 的 WireGuard 连接，因此不依赖家庭公网 IPv4、家庭 IPv6 入站、家庭路由器端口映射或 DuckDNS AAAA；
- 普通访问者不需要安装 WireGuard、Tailscale 或其他 VPN，只访问普通 HTTPS 域名。

本文按本次真实搭建顺序记录。不要把其中的层级验证跳过，因为本次迁移能够顺利完成，核心原因就是每一步都先证明当前层已经正常，再继续下一层。

---

## 1. Azure 侧目标配置

本次使用 Azure for Students 创建一台 Ubuntu VM。创建完成后的核心资源为：

```text
订阅：Azure for Students
区域：East Asia
系统：Ubuntu Server 24.04 LTS - Gen2
架构：x64
规格：Standard B2ats v2，2 vCPU / 1 GiB
系统盘：64 GiB Premium SSD LRS
公网：Azure 公共 IPv4
登录：SSH 公钥
```

创建页面显示 VM 的正常按量单价为：

```text
0.0131 USD / 小时
```

同时页面显示“订阅额度适用”。这个创建页价格是 SKU 的标准价格展示，不应把它当成已经扣除学生订阅免费额度后的最终账单。VM 创建后仍应在 Azure Cost Management / 免费服务用量里单独确认实际计费，尤其留意公共 IPv4 和公网出站流量。

---

## 2. 创建 VM：基本

进入 Azure Portal，新建“虚拟机”。本次最终使用以下配置。

### 2.1 项目详细信息

```text
订阅：Azure for Students
资源组：(新) Jellyfin_group
```

资源组用于把这台中继 VM 相关的磁盘、网络接口、公共 IP、网络安全组等资源放在一起。

### 2.2 实例详细信息

```text
虚拟机名称：Jellyfin
区域：East Asia
可用性选项：无需基础结构冗余
安全类型：受信任启动虚拟机
启用安全启动：是
启用 vTPM：是
完整性监视：否
映像：Ubuntu Server 24.04 LTS - Gen2
VM 体系结构：x64
大小：Standard B2ats v2，2 vCPU / 1 GiB 内存
启用休眠：否
Azure 现成 VM / Spot：否
```

这里只创建一台低配中继 VM，不做多机高可用，因此没有配置可用性区域、负载均衡或容量预留。

### 2.3 管理员账户

```text
身份验证类型：SSH 公钥
用户名：azureuser
SSH 密钥格式：RSA
SSH 公钥源：生成新密钥对
密钥对名称：Jellyfin_key
```

不要改成密码登录。

### 2.4 入站端口

创建时只开放：

```text
TCP 22 / SSH
```

WireGuard、HTTP 和 HTTPS 在真正需要时再逐项加入，不在创建阶段一次性全部开放。

Azure 会提示 SSH 对 Internet 开放。当前使用的是公钥认证；后续如有需要可进一步限制 SSH 来源，但这不是首次部署的阻塞项。

---

## 3. 创建 VM：磁盘

最终配置：

```text
OS 磁盘大小：64 GiB
OS 磁盘类型：高级 SSD LRS
使用托管磁盘：是
使用 VM 删除 OS 磁盘：已启用
临时 OS 磁盘：否
密钥管理：平台托管
Ultra Disk：不启用
数据磁盘：无
```

中继机不保存动画文件，因此没有必要增加数据盘。

---

## 4. 创建 VM：网络

最终配置：

```text
虚拟网络：(新) Jellyfin-vnet
子网：(新) default，10.0.0.0/24
公共 IP：(新) Jellyfin-ip
NIC 网络安全组：Basic
公共入站：仅 SSH 22
加速网络：关
现有负载均衡：否
删除 VM 时删除公共 IP 和 NIC：已启用
```

“删除 VM 时删除公共 IP 和 NIC”应开启，避免以后删除 VM 后遗留不再使用的公网 IP 或网卡资源。

这里的 Azure VNet 与后面 WireGuard 的 `10.77.0.0/24` 是两套不同网络：

```text
Azure VNet：Azure 自己的虚拟网络
WireGuard 10.77.0.0/24：Azure 与 Windows 之间的专用隧道网络
```

不要混用两者的地址。

---

## 5. 创建 VM：管理

最终配置：

```text
Microsoft Defender for Cloud：基本（免费）
系统分配的托管标识：关
Microsoft Entra ID 登录：关
自动关机：关
备份：已禁用
启用定期评估：关
启用热补丁：关
补丁编排：映像默认
```

这台服务器需要作为长期在线入口，因此没有启用自动关机。

没有把 Azure Backup、托管身份、Entra ID 登录等企业管理功能引入这个简单中继方案。

---

## 6. 创建 VM：监视

最终配置：

```text
警报：关
启动诊断：关
OS 来宾诊断：关
应用程序运行状况监视：关
```

本次没有额外部署 Log Analytics、来宾监控或应用健康监控。对于这台配置简单、可以重新建立的中继服务器，先保持依赖最少。

---

## 7. 创建 VM：高级

最终配置：

```text
扩展：无
VM 应用程序：无
cloud-init / 自定义数据：否
用户数据：否
磁盘控制器：SCSI
邻近放置组：无
容量预留组：无
```

没有在 cloud-init 里一次性塞入 WireGuard 和 Caddy。第一次部署时逐层手工验证，比“创建后才发现某个初始化脚本失败”更容易定位问题。

---

## 8. 创建 VM：标记与最终审核

本次使用了：

```text
ACG = jellyfin
```

作为相关资源的标签。

“查看 + 创建”页面最终确认以下内容：

```text
Azure for Students
East Asia
Ubuntu Server 24.04 LTS - Gen2
x64
Standard B2ats v2，2 vCPU / 1 GiB
64 GiB Premium SSD LRS
SSH 公钥
公共 IPv4
无负载均衡
无 Backup
无自动关机
无额外监控
无扩展
无 cloud-init
```

创建时 Azure 会要求下载 SSH 私钥。保存：

```text
Jellyfin_key.pem
```

这个文件是服务器登录凭据，不要提交到仓库，也不要发送给其他人。

---

## 9. 第一次 SSH 登录 Azure VM

在 Windows 上把私钥放到本地 `.ssh` 目录，例如：

```powershell
New-Item -ItemType Directory -Force "$HOME\.ssh"
Move-Item "$HOME\Downloads\Jellyfin_key.pem" "$HOME\.ssh\Jellyfin_key.pem"
```

然后登录：

```powershell
ssh -i "$HOME\.ssh\Jellyfin_key.pem" azureuser@<AZURE_PUBLIC_IPV4>
```

第一次连接会询问是否接受主机指纹。确认连接的是刚创建的 VM 后输入：

```text
yes
```

本次成功进入：

```text
Ubuntu 24.04.4 LTS
x86-64
Virtualization: microsoft
```

### 9.1 先检查 VM 和网络，不急着安装服务

执行：

```bash
hostnamectl
ip -br addr
ip route
sudo apt update
```

本次验证到：

- VM 正常启动；
- `eth0` 正常；
- Azure VNet 默认路由存在；
- `apt update` 能正常从 Ubuntu Azure 软件源下载索引；
- 因而 VPS 自身 IPv4 Internet 出站正常。

曾使用：

```bash
curl -4I https://www.microsoft.com
```

遇到一次 HTTP/2 `INTERNAL_ERROR`，但同一时刻 `apt update` 正常高速下载，因此不能把单个网站一次 HTTP/2 会话异常误判成“Azure VPS 没网”。

---

## 10. Azure 安装 WireGuard

在 Azure SSH 中执行：

```bash
sudo apt install -y wireguard
```

确认：

```bash
wg --version
```

本次安装后为 `wireguard-tools v1.0.20210914`。

---

## 11. Azure 生成 WireGuard 密钥

创建目录并生成服务端密钥：

```bash
sudo mkdir -p /etc/wireguard
sudo chmod 700 /etc/wireguard
sudo sh -c 'umask 077; wg genkey > /etc/wireguard/server_private.key'
sudo sh -c 'wg pubkey < /etc/wireguard/server_private.key > /etc/wireguard/server_public.key'
```

查看 Azure 公钥：

```bash
sudo cat /etc/wireguard/server_public.key
```

只需要把公钥提供给 Windows 端。不要读取、复制或提交：

```text
/etc/wireguard/server_private.key
```

---

## 12. 创建 Azure WireGuard 接口

本项目固定使用：

```text
Azure：10.77.0.1/24
Windows：10.77.0.2/24
WireGuard UDP：51820
```

在 Azure 上直接由 shell 从私钥文件生成配置，避免把私钥复制进剪贴板：

```bash
sudo bash -c 'cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server_private.key)
EOF'
```

锁定权限：

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
```

启动并设置开机启动：

```bash
sudo systemctl enable --now wg-quick@wg0
```

检查：

```bash
ip -br addr show wg0
sudo wg show
```

应看到：

```text
wg0    UNKNOWN    10.77.0.1/24
```

并且 WireGuard 在：

```text
UDP 51820
```

监听。

---

## 13. Azure NSG 开放 WireGuard

在 Azure Portal 中进入 VM 的网络设置，新增入站规则：

```text
名称：Allow-WireGuard-51820
来源：Any
源端口：*
目标：Any
目标端口：51820
协议：UDP
操作：Allow
```

这里必须是：

```text
UDP 51820
```

不是 TCP。

此时暂时还没有必要开放 HTTP 80 / HTTPS 443。

---

## 14. Windows 安装并配置 WireGuard

在运行 Jellyfin 的 Windows 主机安装官方 WireGuard 客户端。

打开 WireGuard：

```text
添加隧道 -> 添加空隧道
```

WireGuard 会自动为 Windows 端生成密钥。保留自动生成的私钥，配置改为：

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

隧道名称：

```text
Jellyfin-Azure
```

这里的 `AllowedIPs` 只设置：

```text
10.77.0.1/32
```

因此 Windows 不会把自己的普通 Internet 流量全部送到 Azure；只有发往 Azure WireGuard 地址的流量进入隧道。

`PersistentKeepalive = 25` 让位于 NAT / 家庭网络后的 Windows 主机定期维持会话。

Windows 的 WireGuard 私钥不要提交。界面显示的 Windows WireGuard 公钥可以提供给 Azure。

---

## 15. 把 Windows Peer 加到 Azure

取得 Windows WireGuard 公钥后，在 Azure SSH 中追加：

```bash
sudo bash -c 'cat >> /etc/wireguard/wg0.conf <<EOF

[Peer]
PublicKey = <WINDOWS_WG_PUBLIC_KEY>
AllowedIPs = 10.77.0.2/32
EOF'
```

重启 WireGuard：

```bash
sudo systemctl restart wg-quick@wg0
```

检查：

```bash
sudo wg show
```

应该能看到 Windows peer：

```text
peer: <WINDOWS_WG_PUBLIC_KEY>
allowed ips: 10.77.0.2/32
```

然后在 Windows WireGuard 客户端激活：

```text
Jellyfin-Azure
```

再次在 Azure 运行：

```bash
sudo wg show
```

重点观察：

```text
latest handshake
transfer
```

只要出现最近握手时间和收发字节，说明 WireGuard 会话已经真正建立，而不是只有静态配置文件存在。

---

## 16. 第一项关键实测：Azure ping Windows

在 Azure 执行：

```bash
ping -c 4 10.77.0.2
```

本次真实结果为：

```text
4 packets transmitted, 4 received, 0% packet loss
平均 RTT 约 103 ms
```

这一层成功证明：

```text
Azure 10.77.0.1
        |
        | WireGuard
        v
Windows 10.77.0.2
```

已经双向连通。

这里的约 103 ms 是这次 East Asia Azure VM 到当前 Windows 所在网络的实际一次测量，不是固定性能指标。

---

## 17. 第二项关键实测：Azure 直接访问 Jellyfin 8096

在 Azure 执行：

```bash
curl -v http://10.77.0.2:8096/
```

本次真实返回：

```text
Connected to 10.77.0.2 port 8096
HTTP/1.1 302 Found
Server: Kestrel
Location: web/
```

这是整个迁移里最重要的后端里程碑。

它证明：

```text
Azure VPS
  -> WireGuard
  -> Windows
  -> Jellyfin :8096
```

整条后端链已经成立。

如果这里失败，就不要安装 Caddy、改 DNS 或申请证书；应先处理 WireGuard、Windows 防火墙或 Jellyfin 8096。只有这里成功，才继续做公网 HTTPS。

---

## 18. 为公网入口开放 80 和 443

确认 Azure 能访问 `10.77.0.2:8096` 后，再在 Azure NSG 新增：

```text
Allow-HTTP-80
协议：TCP
目标端口：80
操作：Allow
```

以及：

```text
Allow-HTTPS-443
协议：TCP
目标端口：443
操作：Allow
```

此时服务器需要的公开入站规则为：

```text
TCP 22      SSH
UDP 51820   WireGuard
TCP 80      HTTP / ACME
TCP 443     HTTPS
```

没有为 Jellyfin 8096 开 Azure 公网入站。8096 只存在于 Windows 与 WireGuard 后端链路中。

---

## 19. DuckDNS 从家庭 IPv6 切换到 Azure IPv4

旧直连方案使用 DuckDNS AAAA 指向家庭公网 IPv6。迁移后正式入口改成 Azure 公网 IPv4，所以需要：

```text
A     -> <AZURE_PUBLIC_IPV4>
AAAA  -> 无
```

DuckDNS 网页操作体验不稳定时，可以直接使用更新接口。

### 19.1 先清空现有记录

浏览器访问：

```text
https://www.duckdns.org/update?domains=<SUBDOMAIN>&token=<DUCKDNS_TOKEN>&clear=true&verbose=true
```

其中 `domains=` 只填写子域名本身。例如正式域名是：

```text
example.duckdns.org
```

则：

```text
domains=example
```

不要把 `.duckdns.org` 一起填进去。

### 19.2 再写 Azure IPv4

访问：

```text
https://www.duckdns.org/update?domains=<SUBDOMAIN>&token=<DUCKDNS_TOKEN>&ip=<AZURE_PUBLIC_IPV4>&verbose=true
```

DuckDNS token 不要提交到仓库。

### 19.3 DNS 验证

Windows PowerShell：

```powershell
Resolve-DnsName <PUBLIC_HOST> -Type A
Resolve-DnsName <PUBLIC_HOST> -Type AAAA
```

目标状态：

```text
A     = <AZURE_PUBLIC_IPV4>
AAAA  = 无记录
```

不要在 DNS 仍指向旧家庭地址时启动正式证书流程。

---

## 20. Azure 安装 Caddy

在 Azure SSH 中安装 Caddy 官方软件源所需组件：

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
```

导入仓库签名：

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
| sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
```

加入 Caddy 软件源：

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
| sudo tee /etc/apt/sources.list.d/caddy-stable.list
```

调整读取权限：

```bash
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
```

更新并安装：

```bash
sudo apt update
sudo apt install -y caddy
```

检查：

```bash
caddy version
systemctl status caddy --no-pager
```

安装包会创建 systemd 服务，因此后续直接管理 `caddy.service`。

---

## 21. 正确的 Caddyfile

当前正式入口使用标准 HTTPS 443。Caddyfile 应写成：

```caddy
<PUBLIC_HOST> {
    reverse_proxy 10.77.0.2:8096
}
```

写入：

```bash
sudo tee /etc/caddy/Caddyfile > /dev/null <<'EOF'
<PUBLIC_HOST> {
    reverse_proxy 10.77.0.2:8096
}
EOF
```

把 `<PUBLIC_HOST>` 替换成真实域名。

验证语法：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
```

然后：

```bash
sudo systemctl restart caddy
sudo systemctl status caddy --no-pager
sudo journalctl -u caddy -n 50 --no-pager
```

Caddy 会通过域名自动申请和维护 HTTPS 证书。

---

## 22. 本次实际踩到的 Caddy 端口错误：不要再写 `:9443`

迁移过程中第一次写成了：

```caddy
<PUBLIC_HOST>:9443 {
    reverse_proxy 10.77.0.2:8096
}
```

这个配置语法本身是合法的，因此：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
```

仍然返回：

```text
Valid configuration
```

Caddy 服务也正常 `active (running)`，Let's Encrypt 的 HTTP-01 验证甚至成功，日志中出现了：

```text
authorization finalized
validations succeeded
certificate obtained successfully
```

所以“证书已经拿到了”并不能证明公网 HTTPS 入口端口一定配置正确。

真正暴露问题的是日志中的：

```text
enabling HTTP/3 listener
addr: :9443
```

也就是说，旧直连方案的 `9443` 被错误带进了新 Caddy 配置，导致 Caddy 的 HTTPS 入口实际监听 9443，而当前 Azure NSG 和最终访问地址设计的是标准 443。

修正方法不是继续增加 9443 公网规则，而是把 Caddyfile 改回：

```caddy
<PUBLIC_HOST> {
    reverse_proxy 10.77.0.2:8096
}
```

然后：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo ss -ltnp | grep -E ':(80|443)\b'
```

目标是看到 Caddy 监听：

```text
:80
:443
```

而不是 `:9443`。

这个错误非常值得保留：从旧技术栈迁移时，最容易发生的不是新组件不会配置，而是把旧方案中的端口、证书或地址假设顺手复制进新方案。

---

## 23. 最终公网验证

Windows PowerShell：

```powershell
curl.exe -v https://<PUBLIC_HOST>/
```

这里不要再加 `:9443`。

然后手机关闭 Wi-Fi，只使用移动数据访问：

```text
https://<PUBLIC_HOST>
```

本次最终实测成功打开 Jellyfin。至此完成：

```text
公网客户端
    |
    | HTTPS 443
    v
DuckDNS A -> Azure 公网 IPv4
    |
    v
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

---

## 24. 当前正式方案与旧直连方案的关系

迁移完成后，正式公网访问不再依赖以下条件：

```text
家庭公网 IPv6
DuckDNS AAAA
家庭路由器 IPv6 公网入站
家庭公网 IPv6 地址是否变化
Jellyfin 自带 HTTPS 9443
家庭侧 PFX
客户端是否具备 IPv6
```

现在真正需要保持的链路是：

```text
Windows 能主动访问 Internet
Windows WireGuard 隧道处于激活状态
Azure WireGuard 正常
Azure 能访问 10.77.0.2:8096
DuckDNS A 指向 Azure 公网 IPv4
Caddy 80/443 正常
```

旧的家庭 IPv6 / 9443 配置可以暂时保留作为迁移期间的历史状态，但不再是正式公网入口。确认 VPS 中继长期稳定以后，可以再单独决定是否关闭 Jellyfin 自带 HTTPS 9443、删除旧证书配置以及恢复家庭路由器更严格的防火墙状态；不要在刚切换成功的同一时刻同时删除所有旧配置。

---

## 25. 当前最短故障定位顺序

如果以后正式域名突然打不开，不要从头重装 Caddy 或 WireGuard。按下面顺序找“最后一个成功层 / 第一个失败层”。

### 25.1 Windows 本机 Jellyfin

```powershell
curl.exe -v http://127.0.0.1:8096/
```

失败：先修 Jellyfin。

### 25.2 Windows WireGuard

确认 `Jellyfin-Azure` 已激活，并观察最近握手 / 收发数据。

### 25.3 Azure WireGuard

```bash
sudo wg show
ping -c 4 10.77.0.2
```

### 25.4 Azure 到 Jellyfin

```bash
curl -v http://10.77.0.2:8096/
```

如果这里能收到 Jellyfin HTTP 响应，则 Windows、WireGuard 和 Jellyfin 后端已经排除。

### 25.5 Caddy 本身

```bash
sudo systemctl status caddy --no-pager
sudo journalctl -u caddy -n 50 --no-pager
sudo ss -ltnp | grep -E ':(80|443)\b'
```

### 25.6 DNS

```powershell
Resolve-DnsName <PUBLIC_HOST> -Type A
Resolve-DnsName <PUBLIC_HOST> -Type AAAA
```

应为 Azure IPv4 A 记录，不应重新残留家庭 AAAA。

### 25.7 真正公网客户端

最后再用手机移动数据访问：

```text
https://<PUBLIC_HOST>
```

这种顺序可以把：

```text
Jellyfin
Windows
WireGuard
Azure
Caddy
DNS
公网客户端
```

逐层拆开，而不是在网站打不开时同时修改五六处配置。

---

## 26. 密钥与配置边界

以下内容不要提交到仓库：

```text
SSH 私钥 Jellyfin_key.pem
Azure WireGuard 私钥
Windows WireGuard 私钥
DuckDNS token
证书私钥
```

配置文档中使用：

```text
<AZURE_PUBLIC_IPV4>
<PUBLIC_HOST>
<DUCKDNS_TOKEN>
<AZURE_WG_PUBLIC_KEY>
<WINDOWS_WG_PUBLIC_KEY>
<WINDOWS_PRIVATE_KEY>
```

公钥可以在设备之间复制，私钥只留在各自设备。

---

## 27. 本次搭建的实际验收点

本次不是只完成了配置文件，而是逐层得到过以下真实结果：

```text
Azure VM 启动并可 SSH                    成功
Ubuntu apt update 公网出站               成功
Azure wg0 = 10.77.0.1/24                 成功
Windows = 10.77.0.2/24                   成功
WireGuard 双端握手                        成功
Azure ping Windows                        4/4，0% 丢包
Azure -> 10.77.0.2:8096                  成功
Jellyfin 返回 HTTP 302 / Location: web/  成功
DuckDNS A -> Azure IPv4                  成功
Let's Encrypt HTTP-01                    成功
Caddy 自动取得证书                        成功
修正 Caddy 从 :9443 到标准 :443          成功
外部 HTTPS 打开 Jellyfin                  成功
```

因此当前架构不是只停留在“理论上应该能工作”，而是已经完成从公网入口到家庭 Jellyfin 的端到端实机验收。
