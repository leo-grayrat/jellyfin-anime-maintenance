# 2026-08-31：Apple 客户端 HTTP/3 断连与 HTTP 自动补全陷阱

## 现象

- iPad 上的 Firefox 提示“网络连接已中断”；截图中该设备同时启用了 VPN；
- 另一台 iPhone 的 Safari 在 5G 下也提示“已丢失网络连接”；
- iQOO Android 手机不论 Wi-Fi 或移动网络均可访问；
- 同时 Windows Jellyfin 本机、Windows SSH 监督任务、Azure `127.0.0.1:18096` 和 Caddy 均正常，正式域名连续 HTTPS 请求返回 Jellyfin `302`。

因此这不是 Jellyfin、SSH 回源或 DNS A 记录整体失效。多个公共 DNS 已确认只有正确的 IPv4 A 记录、没有旧 AAAA，排除了 Apple 客户端误走旧 IPv6。

## 根因与修正

Caddy 默认启用 HTTP/1.1、HTTP/2、HTTP/3。现场确认它：

- 同时监听 TCP 443 和 UDP 443；
- HTTPS 响应发送 `Alt-Svc: h3=":443"`，引导客户端尝试 HTTP/3/QUIC；
- Azure 公网入口的既有正式设计只放行 TCP 443。

iOS 客户端更积极使用被宣传的 HTTP/3 路径；Android 客户端能够使用/回退到 TCP HTTPS，因此出现平台差异。将 Caddy 明确限制为 `h1 h2` 后，UDP 443 监听和 `Alt-Svc: h3` 均消失；SSH 回源继续返回 `302`，正式域名连续请求继续返回 `302`，iPhone 和 iPad 随即恢复。

当前 Caddyfile 顶部：

```caddy
{
    servers :443 {
        protocols h1 h2
    }
}
```

原始配置备份保留在 Azure 的 `/etc/caddy/Caddyfile.before-disable-h3-20260831`。除非 Azure NSG 与实际公网路径已明确支持并验证 UDP 443，否则不要恢复 HTTP/3。

## 独立的 HTTP 地址问题

修复 HTTP/3 后，Apple Firefox 仍曾把域名自动补全为：

```text
http://<PUBLIC_HOST>
```

当前入口应始终显式使用：

```text
https://<PUBLIC_HOST>/
```

HTTP 自动补全不是本次 HTTP/3 断连的主因，但它会独立造成无法打开。向成员分发地址时必须带上 `https://`，并提醒不要使用浏览器填出的 HTTP 版本。
