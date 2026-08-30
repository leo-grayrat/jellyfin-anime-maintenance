# Jellyfin Azure SSH 中继：当前正式架构与运维手册

> 所有地址、域名、用户名和密钥路径都必须使用占位符；不要提交真实公网 IP、域名、私钥、令牌或 `known_hosts` 内容。

## 当前架构

```text
公网客户端 HTTPS :443
  -> Azure Caddy
  -> Azure SSH 反向监听 127.0.0.1:18096
  -> 已认证 SSH/TCP（Windows 主动建立）
  -> Windows Jellyfin 127.0.0.1:8096
```

`8096` 和 `18096` 均不对公网开放。Caddy 不得再回源到 `10.77.0.2:8096`。

## 组件职责

| 组件 | 职责 |
| --- | --- |
| Windows Jellyfin | 提供 `127.0.0.1:8096` |
| 计划任务 `Jellyfin-SSH-Relay-v5` | 通过 `wscript.exe` 无窗口监督 SSH；退出后 5 秒重连 |
| Azure OpenSSH | 接受反向转发 |
| Azure Caddy | HTTPS 与反向代理 |
| DNS | 将正式域名指向 Azure IPv4 |

## 中继的安全与可靠性要求

SSH 必须使用：

- `-N -T`，只转发、不提供交互 shell；
- `ExitOnForwardFailure=yes`；
- `ServerAliveInterval=15` 与 `ServerAliveCountMax=3`；
- `StrictHostKeyChecking=yes` 和专用 `known_hosts`；
- `-R 127.0.0.1:18096:127.0.0.1:8096`。

监督器必须无条件在 SSH 退出后重试，不能根据 SSH 的退出码把服务误判为“已完成”。不应依赖用户不关闭空白命令窗口。

Windows 开机后仍需该用户登录：当前 Jellyfin 和中继都基于该交互用户运行，不是无人登录即可恢复的系统服务。

## Azure Caddy

```caddy
<PUBLIC_HOST> {
    reverse_proxy 127.0.0.1:18096
}
```

修改后：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

不得把转发绑定成 `0.0.0.0:18096`，也不得在 Azure NSG 开放 TCP 18096。

## 验收

```powershell
curl.exe -I http://127.0.0.1:8096/
curl.exe -I https://<PUBLIC_HOST>/
```

```bash
curl -I --max-time 6 http://127.0.0.1:18096/
curl -I --max-time 8 https://<PUBLIC_HOST>/
```

Jellyfin 根路径返回 `302 Found`（指向 `web/`）属于成功；最后还要用手机移动数据访问正式域名。

## 后续加固

创建不带 sudo 的独立 Azure 中继账户和独立密钥；只允许该密钥建立指定的回环转发，并禁用交互 shell、X11 与 agent 等无关能力。同时明确禁止 root SSH 登录。

历史资料：

- [WireGuard 断链与 SSH 迁移](history/2026-08-31-wireguard-failure-and-ssh-relay.md)
- [WireGuard 版搭建与验收](history/2026-08-29-azure-vps-relay.md)
- [旧 IPv6 直连排错](history/2026-08-29-ipv6-direct-troubleshooting-archive.md)
