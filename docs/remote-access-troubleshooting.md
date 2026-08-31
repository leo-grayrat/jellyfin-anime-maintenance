# Jellyfin 当前公网入口排错

当前正式链路：

```text
Jellyfin 127.0.0.1:8096
  -> Windows 无窗口 SSH 反向中继
  -> Azure 127.0.0.1:18096
  -> Azure Caddy :443
  -> https://<PUBLIC_HOST>/
```

旧家庭 IPv6 / `:9443` 直连与 WireGuard 都不是当前正式入口。它们只保留为历史资料。

## 最短检查顺序

| 顺序 | 位置 | 测试 | 成功意味着 |
| --- | --- | --- | --- |
| 1 | Windows | `curl.exe -I http://127.0.0.1:8096/` | Jellyfin 本体正常 |
| 2 | Windows | `Get-ScheduledTask -TaskName 'Jellyfin-SSH-Relay-v5'` | 无窗口 SSH 监督器正常 |
| 3 | Azure | `curl -I --max-time 6 http://127.0.0.1:18096/` | SSH 回源接到 Jellyfin |
| 4 | Azure | `curl -I --max-time 8 https://<PUBLIC_HOST>/` | Caddy 与 TLS 正常 |
| 5 | 外部网络 | 手机移动数据访问正式域名 | 完整公网链路正常 |

先定位“最后一个成功层级”和“第一个失败层级”，只处理两者之间的问题。

## 第 0 层：Jellyfin 本机

Windows：

```powershell
curl.exe -I http://127.0.0.1:8096/
Get-NetTCPConnection -State Listen -LocalPort 8096
```

根路径通常返回 `302` 或 `200`。若失败，先修 Jellyfin，不要检查 Azure、Caddy 或 DNS。

## 第 1 层：Windows 无窗口中继

计划任务 `Jellyfin-SSH-Relay-v5` 应为 `Running`，进程链应为 `wscript.exe -> ssh.exe`。不应出现可被关闭的空白控制台窗口。

若任务未运行：

1. 确认 Windows 已以运行 Jellyfin 的用户登录；
2. 检查计划任务指向的 SSH 私钥和 `known_hosts`；
3. 查看任务最近运行结果；
4. 不要把手工打开的 SSH 窗口当成长期修复。

## 第 2 层：Azure 回源端口

```bash
ss -ltn | grep 18096
curl -I --max-time 6 http://127.0.0.1:18096/
```

只应监听 `127.0.0.1:18096`，绝不能是 `0.0.0.0:18096`。超时或端口不存在时，回到 Windows 中继排查。

## 第 3 层：Azure Caddy

```caddy
<PUBLIC_HOST> {
    reverse_proxy 127.0.0.1:18096
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl status caddy --no-pager
```

第 2 层成功而此处失败，才检查 Caddy 日志、证书、DNS 与 Azure 443；不要改回 WireGuard。

## WireGuard 说明

现场已复现 WireGuard 可短暂连通后双向失联，Azure 只看到自身发出的握手包；同一时段普通 UDP 包仍可到达 Azure。这不足以精确归责某台设备，却足以说明该路径不适合生产回源。详见 [2026-08-31 复盘](history/2026-08-31-wireguard-failure-and-ssh-relay.md)。


## Apple 客户端与 HTTP/3

2026-08-31 曾出现 iPhone Safari 与 iPad Firefox 均提示“网络连接已中断”，而 Android 客户端可访问。Jellyfin 本机、SSH 回源和普通 HTTPS 检查当时均正常。

排查确认 Caddy 默认监听 UDP 443，并在响应中发送：

```text
Alt-Svc: h3=":443"
```

即向客户端宣传 HTTP/3/QUIC；Azure 的公开入口设计只放行 TCP 443。关闭 Caddy 的 HTTP/3、仅保留 HTTP/1.1 与 HTTP/2 后，两台 Apple 设备立即恢复。当前 Caddyfile 顶部必须保留：

```caddy
{
    servers :443 {
        protocols h1 h2
    }
}
```

不要在未确认 Azure UDP 443 端到端可用前恢复 `h3`。

另有独立陷阱：Apple Firefox 的地址自动补全曾给出 `http://<PUBLIC_HOST>`。当前正式入口只应使用 `https://<PUBLIC_HOST>/`；访问 HTTP 会失败，不能把它误判为 Jellyfin 或 SSH 中继故障。
