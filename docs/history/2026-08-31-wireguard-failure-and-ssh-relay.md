# 2026-08-31：WireGuard 断链复现、SSH 中继迁移与自动化修正

> 隐私规则：本文不记录真实 Azure IP、家庭公网 IP、域名、SSH 密钥或 Windows 用户目录。

## 结论

Azure VPS 仍适合承担 Jellyfin 公网 HTTPS 入口；不可靠的是家庭 Windows 主机到 Azure 的 WireGuard UDP 回源。它曾短暂正常，随后稳定断链，因此不再作为生产传输层。

现行链路：

```text
公网 HTTPS -> Azure Caddy -> Azure 127.0.0.1:18096
           -> 已认证 SSH/TCP -> Windows Jellyfin 127.0.0.1:8096
```

## WireGuard 的实机证据

- 干净激活后最初约 20 次 ping 可达，RTT 约 105–116 ms，约半分钟后连续超时；
- 故障阶段 Windows 到 Azure 为 0/6，Azure 到 Windows 为 0/8；
- Azure 的最近握手时间停滞，抓包只看到它约每 5 秒发出 148 字节 WireGuard 握手包，却无 Windows 对应回包；
- 同一阶段 Windows 发往 Azure UDP 51820 的普通小 UDP 包，Azure 收到 5/5。

这不能严格证明是 DPI，也不能精确归责某台设备；但它排除了“UDP 51820 一概被封”。结合 Windows 曾在物理网卡发出 WireGuard 包、Azure 却未收到的记录，合理结论是该路径的 WireGuard 特征流量或 NAT/会话状态不稳定，不能承担生产回源。曾通过更换 WireGuard 本地端口获得短暂恢复，也符合新 UDP 流短时可用、随后再次失效的观察；现有证据不足以区分家庭 NAT/CGNAT、上游路径设备或协议识别的具体责任。

## SSH 接管

Windows 建立 SSH 反向转发后，同一时刻从 Azure 对照两条回源：

| Azure 回源 | 结果 |
| --- | --- |
| WireGuard `10.77.0.2:8096` | 超时，HTTP 000 |
| SSH `127.0.0.1:18096` | Jellyfin `302`，约 0.2–0.3 秒 |

Caddy 回源因此改为 `127.0.0.1:18096`，外部 HTTPS 同样返回 `302`。

## 自动化修正

首次计划任务直接启动 SSH：SSH 正常退出时返回码为 0，任务计划程序的失败重试没有触发；同时出现的空白控制台窗口被用户关闭后，Azure 的回源监听立即消失，公网入口也随之不可用。这是自动化实现缺陷，不能以“请用户别关窗口”作为修复。

最终版本 `Jellyfin-SSH-Relay-v5` 使用 `wscript.exe` 无窗口启动脚本；脚本等待 `ssh.exe` 退出后 5 秒重连。影子端口测试中，手工终止 SSH 子进程后约 7 秒出现新的子进程。SSH 启用 `ExitOnForwardFailure=yes`、存活检测、严格主机指纹校验，并把反向端口限制为 Azure 回环地址。

验收时存在 `wscript.exe -> ssh.exe` 进程链，Azure 本地回源和外部 HTTPS 均返回 Jellyfin `302`，且没有必须维持的空白控制台窗口。

## 后续加固

当前是 Windows/OpenSSH、Azure/OpenSSH 与 Caddy 的标准组合：密码认证关闭、私钥认证、严格主机指纹、反向端口仅回环绑定、Caddy 仅对外提供 HTTPS。

仍建议建立不带 sudo 的专用 Azure 中继账户与独立密钥，限制其仅能建立指定回环转发，并禁用交互 shell、X11、agent 等无关能力；同时禁用 root SSH 登录。
