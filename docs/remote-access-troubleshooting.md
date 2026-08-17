# Jellyfin 网络连接性排查

这份文档用于处理“Jellyfin 突然打不开”的情况。

当前远程访问链路涉及 Jellyfin 本机服务、Windows 网络监听、局域网、IPv6、DNS、HTTPS、浏览器代理以及家庭路由器公网入站等多个层级。排错时不要一上来重配证书、DNS 或 Jellyfin；应当**从最近的一层开始逐层向外测试，找到最后一个成功的层级和第一个失败的层级**。

> 隐私说明：公开仓库只使用占位符。实际排错时自行替换 `<LAN_IP>`、`<PUBLIC_IPV6>`、`<PUBLIC_HOST>`，不要把真实公网域名、公网 IP、局域网精确地址或证书本机路径写进公开 Issue / 日志。

## 地址约定

本文使用：

```text
本机 HTTP：
http://127.0.0.1:8096

局域网 HTTP：
http://<LAN_IP>:8096

公网 IPv6 HTTP：
http://[<PUBLIC_IPV6>]:8096

正式 HTTPS：
https://<PUBLIC_HOST>:9443
```

其中正式入口当前是 IPv6-only：访问端本身必须具有可用 IPv6。

## 最短检查顺序

如果只想快速判断坏在哪一层，依次完成下面六项：

| 顺序 | 测试 | 主要证明什么 |
| --- | --- | --- |
| 1 | 服务器本机 `http://127.0.0.1:8096` | Jellyfin 进程和 HTTP 服务是否活着 |
| 2 | 服务器本机 `http://<LAN_IP>:8096` | Jellyfin 是否正常监听网络接口 |
| 3 | 同 Wi-Fi 其他设备 `http://<LAN_IP>:8096` | 局域网通信和 Windows 入站是否正常 |
| 4 | 服务器本机 `http://[<PUBLIC_IPV6>]:8096` | 服务器当前 IPv6 是否正常 |
| 5 | 服务器本机 `https://<PUBLIC_HOST>:9443` | DNS、9443、TLS 和证书是否正常 |
| 6 | 手机移动网络 `https://<PUBLIC_HOST>:9443` | 真正的公网 IPv6 入站是否正常 |

另外，如果第 3 项成功，但同 Wi-Fi 手机无法访问公网 IPv6 / 正式域名，优先检查**手机当前 Wi-Fi 会话是否真的有 IPv6 connectivity**。本项目已经遇到过一次“IPv4 正常、IPv6 临时失效”的 Wi-Fi 会话，关闭并重新打开 Wi-Fi 后立即恢复。

---

## 第 0 层：Jellyfin 本机是否正常

在运行 Jellyfin 的服务器电脑上访问：

```text
http://127.0.0.1:8096
```

也可以运行：

```powershell
curl.exe -v http://127.0.0.1:8096/
```

### 如果失败

此时不要检查 DuckDNS、IPv6、路由器或浏览器代理。故障已经发生在服务器电脑内部。

先检查监听：

```powershell
netstat -ano | findstr ":8096"
netstat -ano | findstr ":9443"
```

正常情况下应能看到相应端口处于 `LISTENING`。外部监听通常类似：

```text
0.0.0.0:8096    LISTENING
[::]:8096       LISTENING
0.0.0.0:9443    LISTENING
[::]:9443       LISTENING
```

可能原因包括：

- Jellyfin 没有启动或启动失败；
- 端口没有监听；
- Jellyfin 网络配置异常；
- HTTPS 证书配置导致 Kestrel 启动失败；
- 端口被其他程序占用。

**先恢复 `127.0.0.1:8096`，再继续向外排查。**

---

## 第 1 层：服务器自己的局域网 IPv4 是否正常

在服务器电脑上访问：

```text
http://<LAN_IP>:8096
```

### `127.0.0.1` 成功，但 `<LAN_IP>` 失败

说明 Jellyfin 本身活着，但外部网络接口这一层有问题。

再次检查：

```powershell
netstat -ano | findstr ":8096"
```

如果只有 loopback 监听，而没有 `0.0.0.0:8096` / `[::]:8096`，优先检查 Jellyfin 网络监听配置。

如果已经监听所有接口，则检查：

- Windows 防火墙；
- Windows 当前网络状态；
- Jellyfin 网络设置。

此时仍然不需要检查 DNS 或公网 IPv6。

---

## 第 2 层：同一 Wi-Fi 的其他设备能否通过局域网 IPv4 访问

让手机或另一台电脑连接同一 Wi-Fi，访问：

```text
http://<LAN_IP>:8096
```

### 服务器本机能访问 `<LAN_IP>`，其他设备也能访问

可确认：

```text
Jellyfin                 OK
服务器网络监听            OK
局域网基本通信            OK
Windows 对该端口的入站    OK
```

继续检查 IPv6。

### 服务器本机能访问 `<LAN_IP>`，其他设备不能

问题位于局域网 / Windows 对其他设备的入站这一层，可能包括：

- Windows 防火墙规则变化；
- Wi-Fi 客户端隔离；
- 两台设备实际上不在同一个 LAN；
- 路由器局域网状态异常。

此时不要检查 DuckDNS、证书或公网 IPv6。

---

## 第 3 层：服务器自己的公网 IPv6 是否正常

先确认服务器当前拥有全球 IPv6：

```powershell
Get-NetIPAddress -AddressFamily IPv6
```

然后测试：

```text
http://[<PUBLIC_IPV6>]:8096
```

以及：

```text
https://[<PUBLIC_IPV6>]:9443
```

使用裸 IPv6 访问 HTTPS 时，证书签发给的是域名而不是 IP，因此浏览器出现“证书名称不匹配”属于预期现象。这一测试只用于确认连接能否抵达 Jellyfin，不作为正式访问方式。

### 局域网 IPv4 正常，但服务器自己的公网 IPv6 失败

问题收敛到服务器 IPv6 / Jellyfin IPv6 监听。

检查：

```powershell
netstat -ano | findstr ":8096"
netstat -ano | findstr ":9443"
```

应存在：

```text
[::]:8096
[::]:9443
```

同时确认服务器当前确实还有可用全球 IPv6。如果服务器本身已经失去 IPv6，后面的域名访问自然都会失败。

### 公网 IPv6 也正常

说明 Jellyfin、服务器 IPv6 和 9443 TLS 服务基本正常，可以继续检查正式域名。

---

## 第 4 层：服务器通过正式域名能否访问

运行：

```powershell
curl.exe -v https://<PUBLIC_HOST>:9443/
```

正常情况下 Jellyfin 根路径会返回类似：

```text
HTTP/1.1 302 Found
Location: web/
```

### 裸公网 IPv6 成功，但正式域名失败

主要检查三类问题。

#### 1. DNS / DDNS 指向错误

运行：

```powershell
Resolve-DnsName <PUBLIC_HOST> -Type AAAA
```

将返回的 AAAA 与服务器当前真正使用的公网 IPv6 对照。

如果：

```text
DNS AAAA != 当前服务器公网 IPv6
```

则更新 DDNS。

服务器可能同时具有多个全球 IPv6；以后自动更新 DDNS 时，不应简单选择命令输出中的第一个全球 IPv6，而应明确选择实际用于公开入口的地址。

#### 2. `curl` 成功，但浏览器失败

优先怀疑浏览器代理 / VPN / 代理扩展。

本项目已经实测遇到过：浏览器代理接管 IPv6-only 域名后无法抵达目标，而 `curl` 直接走 IPv6 正常。

处理方法：将 `<PUBLIC_HOST>` 加入代理软件或浏览器的：

```text
DIRECT
No Proxy
不使用代理
```

列表。

因此：

```text
curl 正常 + 浏览器失败
```

不要先重新配置 Jellyfin 或证书。

#### 3. `curl -k` 成功，但正常 `curl -v` 失败

这才应重点检查 TLS / 证书，例如：

- 证书过期；
- 域名与证书不匹配；
- 证书链异常；
- Jellyfin 加载了错误的证书。

只有这一层测试把问题明确缩到证书后，才重新处理证书。

---

## 第 5 层：同 Wi-Fi 的其他设备能否通过 IPv6 / 正式域名访问

在同一 Wi-Fi 的手机上依次对照：

```text
http://<LAN_IP>:8096
http://[<PUBLIC_IPV6>]:8096
https://<PUBLIC_HOST>:9443
```

这三项组合可以快速判断手机所在的网络层级。

### 情况 A：LAN IPv4 成功，公网 IPv6 和正式域名都失败

```text
LAN IPv4       OK
公网 IPv6      FAIL
正式域名        FAIL
```

优先检测手机当前 Wi-Fi 的 IPv6 connectivity。

本项目已经发生过一次：手机可以正常访问 IPv4 网站和 Jellyfin LAN 地址，但该次 Wi-Fi 会话实际没有 IPv6 连通性。关闭并重新打开 Wi-Fi 后，IPv6 重新建立，正式域名立即恢复。

因此首要修复动作是：

1. 确认手机当前 Wi-Fi 是否存在 IPv6 connectivity；
2. 如果没有，断开 / 重新连接 Wi-Fi；
3. 重连后再次测试正式域名。

如果经常重复发生，再进一步调查路由器 RA / 手机 IPv6 网络状态，而不是反复修改 Jellyfin。

### 情况 B：LAN IPv4 和公网 IPv6 成功，正式域名失败

```text
LAN IPv4       OK
公网 IPv6      OK
正式域名        FAIL
```

手机 IPv6 路径本身正常。优先检查：

- 手机 DNS / Private DNS / Secure DNS；
- 手机代理或 VPN；
- 域名解析缓存。

### 情况 C：LAN IPv4、公网 IPv6、正式域名全部失败

先处理局域网层，因为最靠近服务器的 LAN IPv4 都没有成功。不要从 DNS / 证书开始排查。

---

## 第 6 层：真正的公网访问

最后才做外部网络验收。

手机关闭 Wi-Fi，仅使用移动网络，访问：

```text
https://<PUBLIC_HOST>:9443
```

### 同 Wi-Fi 正常，但移动网络失败

此时已经证明：

```text
Jellyfin       OK
局域网          OK
服务器 IPv6     OK
DNS            OK
HTTPS / 证书    OK
```

故障位于公网入站这一层。

当前临时方案下，首先确认家庭路由器的 IPv6 入站防火墙是否处于计划中的开放状态。本项目已经通过开 / 关对照实测确认：路由器总防火墙开启时会阻断外部 IPv6 入站；短期试运行只有在选定开放时段临时关闭后，移动网络才能访问。

### 路由器已经处于开放状态，移动网络仍失败

再检查访问端移动网络是否具有 IPv6 connectivity。

当前正式入口是 IPv6-only。如果访问者所在的移动网络 / Wi-Fi 只有 IPv4，则其他互联网网站可能完全正常，但这个 Jellyfin 入口仍然无法访问。这属于当前架构的限制，而不是服务器本身故障。

---

## 按“最高成功层级”快速判断

```text
连 127.0.0.1 都打不开
→ Jellyfin 本机故障

127.0.0.1 能开，服务器 LAN IP 不能
→ Jellyfin 监听 / Windows 网络层

服务器 LAN IP 能开，同 Wi-Fi 其他设备 LAN IP 不能
→ 局域网 / Windows 入站

同 Wi-Fi LAN IPv4 能开，但该设备公网 IPv6 不能
→ 访问设备当前 IPv6 / Wi-Fi IPv6

公网 IPv6 能开，正式域名不能
→ DNS / 代理 / 证书；继续用 curl 对照缩小

服务器正式域名能开，同 Wi-Fi 手机不能
→ 手机 IPv6 / DNS / 代理

同 Wi-Fi 手机能开，移动网络不能
→ 家庭路由器公网入站 / 移动网络 IPv6

移动网络也能开
→ 整条公网链路正常
```

## 排错原则

最重要的不是记住某个曾经出现过的故障，而是每次都回答两个问题：

> **最后一个成功的测试是哪一个？**
>
> **紧接着第一个失败的测试是哪一个？**

故障应优先在这两层之间排查。

不要因为以前出现过 PFX、端口、浏览器代理或手机 IPv6 问题，就在新的故障里直接假定还是同一个原因。先用分层测试重新定位，再修改对应层。