# 2026-08-16 Jellyfin 直连 HTTPS 试验

对应 Issue：#13。

## 背景

在家庭公网 IPv6 已确认可用、但 Caddy `:443` 自动 HTTPS 验证未能打通后，临时改测 Jellyfin 自带 HTTPS，以分离“443 端口问题”和“HTTPS 本身能否工作”。

使用 DuckDNS 子域 `<PUBLIC_HOST>`，通过 win-acme 2.2.9 + Let's Encrypt `dns-01` 手工验证成功签发 PFX。

## 已确认问题

Jellyfin 12.0.0 首次按默认 HTTPS 端口 `8920` 启动时出现两个独立错误：

1. win-acme 首次导出的无密码 PFX 被 Jellyfin/.NET 拒绝，日志为 `The certificate data cannot be read with the provided password`；
2. Kestrel 绑定 HTTPS 端口时报 `SocketException (10013)`。

回滚 `EnableHttps=false` 后，Jellyfin 恢复正常，8096 再次 LISTENING。

随后检查 Windows excluded port range：IPv4 和 IPv6 均包含 `8841-8940`，因此 `8920` 正好属于系统排除端口，解释了 10013。后续改用未被排除的 `9443`。

原始无密码 PFX 可被 `certutil -dumpPFX` 成功解析，说明证书本体有效。之后使用 PowerShell 将现有 PFX 重新封装为明确带密码的 `<PASSWORD_PROTECTED_PFX>`，不重新申请证书。

## certutil 验证命令更正

对带密码 PFX，直接执行：

```text
certutil -dumpPFX file.pfx
```

会在没有提供密码的情况下尝试解析，可能以 `NTE_BAD_SIGNATURE / 无效签名` 失败；这一结果不能据此判定新 PFX 损坏。

正确验证方式应显式提供密码，或使用 PowerShell `Get-PfxData -Password` / `Get-PfxCertificate`。为了避免把密码直接写进命令历史，当前优先使用 `Read-Host -AsSecureString` + `Get-PfxData -Password`。

## 后续验证

1. PowerShell SecureString 已验证带密码 PFX 可读；
2. HTTPS 改用 TCP 9443；
3. Jellyfin 已同时监听 `0.0.0.0:9443` 与 `[::]:9443`；
4. 本机回环、真实域名、公网 IPv6 和正常证书校验均验证通过；
5. Firefox 曾因代理规则接管 IPv6-only 域名而无法访问，设为直连后恢复；
6. 手机 Wi-Fi 曾短暂失去 IPv6 connectivity，重连 Wi-Fi 后恢复；
7. 在短期试运行约定下，关闭 TC7102 总防火墙后，移动网络也可通过 HTTPS 访问。

本记录只保留排错结论；公网域名、公网 IP、局域网精确地址和证书本机路径均使用占位符，不写入公开仓库。
