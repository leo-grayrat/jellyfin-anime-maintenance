# 2026-08-16 远程访问：从公网 IPv6 到临时直连试运行

对应 Issue：#13。

> 隐私说明：本公开记录只保留技术过程和结论。公网域名、公网 IP、局域网精确地址、证书文件名/本机路径均使用占位符，不写入公开仓库。

## 起点

项目最初没有直接购买 NAS / 专用服务器，而是先使用现有 Windows 电脑和已有硬盘运行 Jellyfin。原因很简单：专用 NAS、硬盘和服务器硬件成本较高，在真实使用需求尚未得到验证前，不值得先投入一整套硬件。

因此最初的预期是：先把现有动画库整理好，再让少量动漫社成员远程访问。

## 实际遇到的问题

文件和元数据整理本身已经远超最初预期。720 个真实视频文件最终改为人工判定 manifest + hardlink 规范视图，避免继续依赖 Jellyfin 对字幕组命名、Season / Episode、Special 和 LocalAlternateVersion 的不稳定自动解释。

远程访问阶段又遇到新的问题：

- Tailscale 在移动端占用系统 VPN 通道，与用户原有代理冲突，因此不适合作为普通社员的默认观看方式；
- 家庭 Windows 主机具有全球 IPv6 地址，Jellyfin 也已确认监听 `[::]:8096`；
- 同一 Wi-Fi 下可以通过全球 IPv6 直接访问 Jellyfin；
- 手机切换到移动网络后无法访问；
- Windows 防火墙临时显式放行 TCP 8096 后仍无效；
- 华为 TC7102 中国电信版 `安全设置 -> 防火墙` 只有粗粒度总开关；
- 临时关闭该防火墙后，手机移动网络立即可以通过公网 IPv6 打开 Jellyfin。

因此公网 IPv6 链路实际上已经打通，阻断点由实机开关对照实验确认就是 TC7102 的 IPv6 入站防火墙。

问题不在于“网络技术天然复杂”这一件事本身。Jellyfin 文件解析 / 元数据匹配中的大量不可预测行为，以及 TC7102 把 IPv6 入站控制压缩成“全开或全关”，都属于产品实现和配置能力本身的问题，不能简单归结为用户没有理解底层网络。

## 不采用永久关闭家庭路由器防火墙

永久关闭 TC7102 防火墙虽然能直接访问，但会同时取消家庭网络对其他全球 IPv6 终端的统一公网入站保护。用户也不希望为了 Jellyfin 更换路由器。

因此最终不把“永久关闭总防火墙”作为正式方案。

## VPS 决策曾被考虑，随后暂缓

一度计划使用低配置公网 VPS 作为固定入口和中继：

```text
动漫社成员
    |
    | HTTPS
    v
公网 VPS
Caddy :443
    |
    | 反向隧道
    v
用户 Windows 电脑
127.0.0.1:8096
    |
    v
Jellyfin
```

这种设计的优点是：家庭 / 宿舍电脑主动向 VPS 建立连接，不依赖家庭公网 IPv4，也不依赖家庭 IPv6 入站；普通社员只需要访问普通 HTTPS 地址。

但考虑到离开学已不足一个月，而家庭公网 IPv6 在关闭 TC7102 总防火墙后已经实测可从移动网络直接访问，短期方案调整为：

- VPS 暂缓购买；
- 只在选定开放时段临时关闭 TC7102 IPv6 防火墙；
- Windows 主机继续承担端口级入站控制；
- 到校后根据校园网实际情况，再决定是否恢复 VPS / 反向隧道路线。

这不是把“永久关闭家庭总防火墙”重新定义为正式方案，而是一个明确有时间边界的短期试运行。

## DuckDNS 与 Caddy

为了避免让社员直接输入裸 IPv6，创建了 DuckDNS 地址 `<PUBLIC_HOST>`。

最初 DuckDNS 残留了一个错误的 IPv4 A 记录 `<STALE_IPV4>`，Let's Encrypt 因而优先去错误 IPv4 做验证；清除该 A 记录后，仅保留指向家庭主机 `<PUBLIC_IPV6>` 的 AAAA。

Caddy 本机反向代理 `localhost:8080 -> 127.0.0.1:8096` 已验证正常。但是 Caddy 自动 HTTPS 在公网 443 上的 ACME 验证失败：Let's Encrypt 已能找到正确 IPv6，却无法连接 TCP 443。期间围绕 `:443` 做的几次 HTTP/HTTPS 测试没有先充分确认 Caddy 自动 HTTPS 的端口语义，导致测试设计反复失效；该路径停止继续补丁式排错。

## 改测 Jellyfin 自带 HTTPS

为了把“443 端口是否存在特殊阻断”和“HTTPS 能否工作”分开，后续改用 Jellyfin 自带 HTTPS。

使用 win-acme 2.2.9 + Let's Encrypt `dns-01` 手工验证，通过 DuckDNS TXT API 完成域名所有权验证，成功得到 PFX，公开记录中记为 `<PFX_PATH>`。

当次 win-acme PFX 选择 `Password: None`。由于 win-acme 未以管理员身份运行且使用手工 DNS 验证，自动续期计划任务没有成功注册；对当前不足一个月的试运行没有实际影响。

Jellyfin 12.0.0 启用 HTTPS 后出现两个独立问题：

1. 证书加载失败：`The certificate data cannot be read with the provided password`；
2. 随后 Kestrel 绑定 HTTPS 监听时返回 `SocketException (10013)`，即 Windows 拒绝某个地址/端口的 bind。

当时 `network.xml` 的核心配置可概括为：

```xml
<EnableHttps>true</EnableHttps>
<RequireHttps>false</RequireHttps>
<CertificatePath><PFX_PATH></CertificatePath>
<CertificatePassword />
<InternalHttpPort>8096</InternalHttpPort>
<InternalHttpsPort>8920</InternalHttpsPort>
<PublicHttpPort>8096</PublicHttpPort>
<PublicHttpsPort>8920</PublicHttpsPort>
```

回滚为 `EnableHttps=false` 并清空证书字段后，Jellyfin 恢复正常启动，8096 再次 LISTENING。

## 根因确认：8920 被 Windows 排除，PFX 文件本体有效

后续实机检查把两个问题分别坐实：

- `netsh int ipv4 show excludedportrange protocol=tcp` 与 IPv6 结果都包含 `8841-8940`，所以 Jellyfin 默认 HTTPS 端口 `8920` 正好处于 Windows 的排除端口范围；此前 Kestrel 的 `SocketException (10013)` 因此有了明确根因。
- `certutil -dumpPFX <PFX_PATH>` 可以在不输入密码的情况下成功打印证书内容，说明 win-acme 生成的 PFX 文件本体和私钥链条是可读的。此前 Jellyfin 的证书加载失败，不应再解释成“证书损坏”，而应按 Jellyfin/.NET 对无密码 PFX 的加载兼容问题处理。

因此最短修复路径是：保留现有证书，不重新走 ACME；把 PFX 重新封装成一个明确设置密码的新 PFX，同时把 Jellyfin HTTPS 端口改到未被系统排除的 `9443`。

## 带密码 PFX 验证通过

原 PFX 重新封装为 `<PASSWORD_PROTECTED_PFX>`。

第一次直接执行 `certutil -dumpPFX` 时返回 `NTE_BAD_SIGNATURE / 无效签名`。这不是新 PFX 损坏，而是该命令没有提供密码；带密码 PFX 不能用无密码方式校验 MAC。

随后使用：

```powershell
$pwd = Read-Host '请输入刚才设置的 PFX 密码' -AsSecureString
Get-PfxData -FilePath '<PASSWORD_PROTECTED_PFX>' -Password $pwd
```

PowerShell 成功返回证书对象，无异常。由此确认：

- 新 PFX 可正常读取；
- 设置的密码正确；
- 不需要重新申请 Let's Encrypt 证书。

## 9443 与公网 IPv6 HTTPS 链路打通

Jellyfin 改为 9443 并使用带密码 PFX 后，Windows 防火墙显式放行 TCP 9443；`netstat` 确认同时监听：

```text
0.0.0.0:9443  LISTENING
[::]:9443     LISTENING
```

随后进行了分层实测：

1. 使用 `--resolve ...:127.0.0.1` 强制域名走 loopback，TLS 握手成功，Kestrel 返回 `HTTP/1.1 302 Found`、`Location: web/`；
2. 直接访问 `https://<PUBLIC_HOST>:9443/`，DuckDNS 解析到 `<PUBLIC_IPV6>`，TCP/TLS 建连成功，同样返回 Jellyfin 302；
3. 直接访问裸 IPv6 `https://[<PUBLIC_IPV6>]:9443/`，同样成功返回 Jellyfin 302。

因此确认：

- DuckDNS AAAA 正确；
- 目标全球 IPv6 当前有效；
- Windows 9443 入站与 Jellyfin 监听正常；
- Jellyfin HTTPS/TLS 服务本身正常；
- 域名到公网 IPv6 再到 Jellyfin 的实际连接链路已经打通。

## 正常证书校验通过

去掉 `-k` 后再次直接访问：

```powershell
curl.exe -v https://<PUBLIC_HOST>:9443/
```

结果仍然成功建立到 `<PUBLIC_IPV6>:9443` 的连接，Schannel 未返回证书错误，Kestrel 正常返回：

```text
HTTP/1.1 302 Found
Location: web/
```

由此可确认，当前直连方案的服务端和网络侧已经闭环：

- DuckDNS 解析正确；
- 公网 IPv6 可达；
- TCP 9443 可达；
- Windows 防火墙规则有效；
- Jellyfin HTTPS 正常；
- 带密码 PFX 正常；
- Let's Encrypt 证书链和域名校验正常。

## 浏览器代理问题

服务端链路和证书校验均通过后，Firefox 仍一度无法打开 `https://<PUBLIC_HOST>:9443`。将该域名加入 Firefox 的“不使用代理 / No Proxy”列表后，页面立即正常。

因此电脑浏览器端失败的根因不是 Jellyfin、证书、9443、DuckDNS 或 IPv6，而是浏览器代理规则把该域名送入了代理路径；该代理路径无法正常访问当前 IPv6-only 的家庭公网服务。

## 手机 Wi-Fi IPv6 会话偶发失效

手机同一 Wi-Fi 下曾再次出现无法访问域名、裸 IPv6 8096 与裸 IPv6 9443 的情况，但 `http://<LAN_IP>:8096` 仍然正常。因此局域网 IPv4、Jellyfin 与 Windows 防火墙没有回归。

随后单独检测手机当前 Wi-Fi 会话的 IPv6 connectivity，确认当时实际没有 IPv6 连通性。关闭再重新开启手机 Wi-Fi 后，IPv6 connectivity 立即恢复，`https://<PUBLIC_HOST>:9443` 也随即正常。

现有实机证据还不足以进一步确定究竟是手机端缓存/网络栈状态异常，还是 TC7102 偶发未正确下发/维持 IPv6 RA。后续如果再次出现，优先先做 IPv6 connectivity 对照测试；若仅该手机失效，先重连 Wi-Fi，而不要重新排查 Jellyfin HTTPS。

## 最终公网验收通过

手机 Wi-Fi IPv6 恢复后，同 Wi-Fi 直接访问 `https://<PUBLIC_HOST>:9443` 正常。

随后关闭手机 Wi-Fi、切换到移动网络，并按短期试运行约定临时关闭 TC7102 总防火墙，移动网络也成功打开同一 HTTPS 地址。至此当前临时公网直连方案完成最终实机验收：

- 域名解析正常；
- 访问端有 IPv6 时可直接访问；
- 公网移动网络可穿过家庭 IPv6 链路到达 Jellyfin 9443；
- HTTPS 与 Let's Encrypt 证书正常；
- Firefox 若启用不能访问该 IPv6/9443 的代理，需要把 `<PUBLIC_HOST>` 设为直连；
- 某些 Wi-Fi 会话若 IPv6 偶发失效，可能表现为其他 IPv4 网站正常而 Jellyfin 独自打不开，重连 Wi-Fi 可作为首要排查动作。

因此下一阶段不再继续修改公网入口技术栈，而是进入小范围动漫社成员发布与账号管理。当前仍维持时间边界：只在需要开放的时段关闭 TC7102 总防火墙；开学后根据校园网实际条件重新评估长期入口。
