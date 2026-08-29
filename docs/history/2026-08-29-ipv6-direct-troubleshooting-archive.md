# 家庭 IPv6 直连方案排错归档

这份文档归档 VPS 中继正式落地前使用的家庭 IPv6 直连排错方法。它记录的是旧入口：

```text
客户端
  -> DuckDNS AAAA
  -> 家庭公网 IPv6
  -> Jellyfin HTTPS :9443
```

当前正式公网入口已经迁移到 Azure VPS + WireGuard + Caddy；当前排错请看：

`docs/remote-access-troubleshooting.md`

完整 VPS 搭建请看：

`docs/remote-access-vps-relay.md`

以下内容保留旧方案中已经实机验证过的排错层级和故障模式。

---

## 1. 旧方案地址与入口

```text
Jellyfin 本机 HTTP：
http://127.0.0.1:8096

局域网 HTTP：
http://<LAN_IP>:8096

服务器当前全球 IPv6：
<CURRENT_PUBLIC_IPV6>

IPv6 HTTP：
http://[<CURRENT_PUBLIC_IPV6>]:8096

旧正式 HTTPS：
https://<PUBLIC_HOST>:9443
```

旧方案是 IPv6-only 公网入口，因此访问端必须具有真正可用的 IPv6 路径。

---

## 2. 旧方案最短检查顺序

| 顺序 | 测试 | 主要证明什么 |
| --- | --- | --- |
| 1 | `http://127.0.0.1:8096` | Jellyfin 进程和 HTTP 服务是否活着 |
| 2 | `http://<LAN_IP>:8096` | Jellyfin 是否监听网络接口 |
| 3 | 同 Wi-Fi 设备访问 `<LAN_IP>:8096` | 局域网和 Windows 入站是否正常 |
| 4 | 本机 / 同 Wi-Fi 设备访问 `[<CURRENT_PUBLIC_IPV6>]` | 本地 / LAN IPv6 路径是否正常，不证明公网入站 |
| 5 | `Resolve-DnsName <PUBLIC_HOST> -Type AAAA` | DuckDNS 是否指向当前 IPv6 |
| 6 | `curl --noproxy "*" -6` 访问真正公网 IPv6 | 家庭宽带直连 IPv6 Internet 是否正常 |
| 7 | `https://<PUBLIC_HOST>:9443` | 域名、9443、TLS 和证书 |
| 8 | 同 Wi-Fi 手机正式入口 | 手机 Wi-Fi IPv6 / DNS / 代理 |
| 9 | 手机移动数据访问并在 Windows 抓包 | 真正公网 IPv6 入站是否抵达 Windows |

核心原则一直是：找到最后一个成功层和第一个失败层，不要同时修改多个层。

---

## 3. 第 0 层：Jellyfin 本机

先在 Windows 主机：

```powershell
curl.exe -v http://127.0.0.1:8096/
```

失败时先检查：

```powershell
netstat -ano | findstr ":8096"
netstat -ano | findstr ":9443"
```

可能出现：

```text
0.0.0.0:8096    LISTENING
[::]:8096       LISTENING
0.0.0.0:9443    LISTENING
[::]:9443       LISTENING
```

如果端口存在但行为异常，记录 PID：

```powershell
tasklist /FI "PID eq <PID>"
```

这一层失败时不要检查 DuckDNS、路由器或公网 IPv6。

---

## 4. 第 1 层：Windows 的局域网 IPv4

测试：

```text
http://<LAN_IP>:8096
```

如果 `127.0.0.1` 成功而 LAN IP 失败，范围已经收敛到：

- Jellyfin 监听；
- Windows 防火墙；
- Windows 网络接口；
- Jellyfin 网络设置。

仍然没有必要查公网。

---

## 5. 第 2 层：同 Wi-Fi 其他设备

让另一台设备访问：

```text
http://<LAN_IP>:8096
```

如果成功，可以确认：

```text
Jellyfin                  OK
Windows 网络监听           OK
家庭 LAN                   OK
Windows 对 8096 的 LAN 入站 OK
```

如果 Windows 自己能开 LAN IP，而另一台设备不能，则重点检查 Windows 防火墙、客户端隔离和实际 LAN 状态。

---

## 6. 第 3 层：全球 IPv6 在家庭 LAN 内是否能用

查看 Windows IPv6：

```powershell
Get-NetIPAddress -AddressFamily IPv6 |
Format-Table InterfaceAlias,IPAddress,AddressState,PrefixLength,SuffixOrigin
```

找处于 `Preferred` 的全球 IPv6，不要把 `fe80::/10` link-local 或 `::1` 当作公网地址。

测试：

```powershell
curl.exe -g -v "http://[<CURRENT_PUBLIC_IPV6>]:8096/"
curl.exe -g -vk "https://[<CURRENT_PUBLIC_IPV6>]:9443/"
```

这里最容易产生过度结论。

即使：

```text
同 Wi-Fi 手机 -> 服务器全球 IPv6  成功
```

也只能证明：

```text
手机 LAN IPv6                 OK
服务器当前全球 IPv6 地址       OK
Jellyfin 的 IPv6 服务路径       OK
```

不能证明：

```text
Internet -> 家庭公网 IPv6 入站  OK
```

家庭同一 IPv6 前缀内的设备可以直接 on-link 通信，不必绕到运营商公网再回来。

---

## 7. 第 4 层：重启后 IPv6 变化与 DuckDNS

本项目实机确认过 Windows 主机重启后全球 IPv6 会变化。

因此旧入口“昨天能开，今天重启后打不开”时，先比较：

```powershell
Get-NetIPAddress -AddressFamily IPv6
Resolve-DnsName <PUBLIC_HOST> -Type AAAA
```

如果当前 IPv6 已变，而 AAAA 还是旧地址：

1. 获取当前全球 IPv6；
2. 更新 DuckDNS AAAA；
3. 等待数分钟；
4. 重复查询 AAAA；
5. 直到 DNS 查询真正返回当前地址后，再测试正式域名。

曾经出现过 DuckDNS 页面已经显示更新，但 DNS 查询还在短时间内返回旧地址的情况。因此“网页已经改了”不等于客户端立即拿到新记录。

---

## 8. 第 5 层：旧 Jellyfin 9443 HTTPS

旧方案最终使用 Jellyfin 自带 HTTPS 9443。

本机强制域名回环：

```powershell
curl.exe -vk --resolve <PUBLIC_HOST>:9443:127.0.0.1 https://<PUBLIC_HOST>:9443/
```

如果 TLS 成功并收到 Jellyfin HTTP 响应，说明：

- Jellyfin HTTPS 存在；
- Kestrel 9443 工作；
- PFX 至少能被 Jellyfin 加载。

当前实例曾正常返回：

```text
HTTP/1.1 302 Found
Location: web/
```

如果 `netstat` 显示 9443 LISTENING 但 HTTPS 失败，仍应确认监听 PID，而不是只凭端口存在判断应用层正常。

### 8920 excluded port range

Jellyfin 默认 HTTPS 端口 8920 曾落入 Windows excluded TCP range：

```text
8841-8940
```

Kestrel 因而出现过：

```text
SocketException (10013)
```

最终旧方案改用 9443。

### 无密码 PFX

win-acme 生成的无密码 PFX 本体可以被系统工具解析，但 Jellyfin/.NET 加载时出现过兼容异常。重新封装成明确带密码的 PFX 后恢复。

这两个故障都是真实发生过的，但只有本机 HTTPS 层失败时才值得重新查，不应该因为“公网打不开”就直接重做证书。

---

## 9. 第 6 层：服务器自身能否直连 IPv6 Internet

这是后期排错中最关键的一层。

先用同一公网服务做 IPv4 / IPv6 对照，并绕过代理：

```powershell
curl.exe --noproxy "*" -4 -I https://www.cloudflare.com/
curl.exe --noproxy "*" -6 -I https://www.cloudflare.com/
```

如果：

```text
-4  成功
-6  失败
```

说明“普通上网正常”不能证明家庭 IPv6 正常。

再检查真实外部 IPv6 TCP：

```powershell
Test-NetConnection 2606:4700:4700::1111 -Port 853 -InformationLevel Detailed
```

重点看：

```text
SourceAddress
NetRoute / NextHop
TcpTestSucceeded
```

即使 Windows 有全球 IPv6 源地址并能选出下一跳，也不等于端到端 IPv6 Internet 正常。

曾进一步交叉测试：

```powershell
Test-NetConnection 240c::6666 -Port 53 -InformationLevel Detailed
```

多个无关 IPv6 目标都失败，而 IPv4 正常，才能更有把握地把范围收敛到 IPv6 公网路径。

### traceroute

```powershell
tracert -6 -d 2606:4700:4700::1111
```

一次故障中：

```text
第 1 跳 成功
第 2 跳 成功
第 3 跳以后持续超时
```

不能机械地说第一个 `*` 就是坏点，因为中间路由器可能不回应 traceroute。需要与：

```text
真实 curl -6 失败
多个 IPv6 TCP 目标失败
tracert 只能看到前几跳
```

一起判断。

---

## 10. 第 7 层：浏览器 IPv6 测试可能被代理伪装

后期出现过：

```text
curl -4  成功
curl -6  失败
浏览器 IPv6 测试网页  显示正常
```

真正原因是浏览器请求被代理接管，网页测到的是代理出口的 IPv6 能力，而不是家庭宽带直连 IPv6。

用于揭穿这一点的测试：

```powershell
curl.exe --noproxy "*" -6 -v http://ipv6.test-ipv6.com/ -o NUL
```

如果：

```text
浏览器测试               OK
curl --noproxy "*" -6    FAIL
```

对“家庭宽带直连 IPv6 是否健康”这个问题，应相信直连测试。

反过来，如果：

```text
curl 直连正式域名  OK
Firefox            FAIL
```

则优先检查浏览器代理，把 `<PUBLIC_HOST>` 配为 DIRECT / No Proxy。

---

## 11. 第 8 层：手机 Wi-Fi IPv6 会话

旧方案同 Wi-Fi 手机常用三项对照：

```text
http://<LAN_IP>:8096
http://[<CURRENT_PUBLIC_IPV6>]:8096
https://<PUBLIC_HOST>:9443
```

曾发生：

```text
LAN IPv4          OK
全球 IPv6         FAIL
正式 IPv6 域名     FAIL
```

最后确认手机该次 Wi-Fi 会话实际没有 IPv6 connectivity。关闭再打开 Wi-Fi 后 IPv6 恢复，正式域名立即恢复。

所以这类现象不应立刻重配 Jellyfin。

如果 LAN IPv4 和当前全球 IPv6 都成功，而正式域名失败，则检查：

- DuckDNS AAAA；
- DNS / Private DNS / Secure DNS；
- 代理 / VPN；
- 域名缓存。

即使三项在同 Wi-Fi 下全部成功，仍然不代表真正公网入站成功。

---

## 12. 第 9 层：手机移动数据 + pktmon

真正公网验收时，手机关闭 Wi-Fi，仅使用移动数据。

Windows 管理员终端：

```powershell
pktmon filter remove
pktmon filter add JF8096 -t TCP -p 8096
pktmon filter add JF9443 -t TCP -p 9443
pktmon start --capture --log-mode real-time
```

然后手机依次访问旧入口，再切回 Wi-Fi 做对照。

### 移动数据完全没有包，Wi-Fi 马上有包

能够证明：

```text
pktmon 工作正常
Windows / Jellyfin 的家庭路径存在
公网发起的连接没有抵达 Windows
```

这时不要查 PFX 或 HTTP，因为 SYN 都没到应用层。

但还不能直接断言“只有入站防火墙坏了”，必须结合服务器自身 IPv6 出站。

如果服务器主动 IPv6 出站正常，而移动入站无包，再重点查：

- 路由器 IPv6 入站防火墙 / ACL；
- 运营商家庭宽带入站过滤；
- 移动网络到家庭前缀的互联。

如果服务器主动 IPv6 出站也失败，则更准确的判断是：

```text
家庭 LAN IPv6 仍正常
家庭宽带直连 IPv6 Internet / WAN 异常
```

### 有 SYN，没有 SYN,ACK

公网包已经抵达 Windows，再查：

- Windows 防火墙；
- 监听；
- 端口 PID；
- Windows 网络栈。

### SYN 和 SYN,ACK 都有，但连接不完成

转向：

- 回程 IPv6；
- 移动网络路径；
- 运营商互联。

### 三次握手已经完成，后面才卡

才进入：

- TLS；
- HTTP；
- MTU / PMTU；
- Jellyfin 应用层。

---

## 13. 第 10 层：TC7102 防火墙不是所有故障的统一答案

历史实测确实做过开关对照：

```text
TC7102 防火墙 ON   -> 移动网络无法进入
TC7102 防火墙 OFF  -> 移动网络可以进入
```

因此“TC7102 IPv6 入站防火墙曾经是阻断点”是确认过的事实。

但后续又出现：

```text
家庭 LAN IPv6          OK
TC7102 防火墙           OFF
服务器直连公网 IPv6     FAIL
移动数据入站            FAIL
```

这时继续反复开关防火墙已经无法解释全部现象，应该转向 IPv6 WAN / 上游路由。

重启路由器或重新拨号前可保存：

```powershell
curl.exe --noproxy "*" -4 -I https://www.cloudflare.com/
curl.exe --noproxy "*" -6 -I https://www.cloudflare.com/
Test-NetConnection 2606:4700:4700::1111 -Port 853 -InformationLevel Detailed
tracert -6 -d 2606:4700:4700::1111
```

重启后再做完全相同的测试，才能判断是否与 WAN / 宽带 IPv6 会话状态有关。

---

## 14. 已经实际出现过的旧方案故障模式

### 14.1 主机重启，全球 IPv6 变化，DuckDNS AAAA 仍是旧地址

```text
当前新 IPv6 直接访问       OK
Resolve-DnsName 返回旧 IPv6
正式域名                   FAIL
```

处理：更新 DuckDNS，等待 DNS 真正刷新。

### 14.2 Firefox 代理接管 IPv6-only 域名

```text
curl 直连  OK
浏览器     FAIL
```

处理：对正式域名使用 DIRECT / No Proxy。

### 14.3 浏览器测试说 IPv6 正常，但直连 IPv6 失败

```text
浏览器 IPv6 测试          OK
curl --noproxy "*" -6    FAIL
```

浏览器测到代理出口，不是家庭直连。

### 14.4 手机某次 Wi-Fi 会话没有 IPv6

```text
LAN IPv4       OK
Wi-Fi IPv6     FAIL
正式域名        FAIL
```

重连 Wi-Fi 后恢复。

### 14.5 TC7102 IPv6 入站防火墙

历史上通过 ON / OFF 对照明确确认过。

### 14.6 家庭 LAN IPv6 正常，但直连 IPv6 Internet 失败

一次典型组合：

```text
Windows 有全球 IPv6                         YES
IPv6 下一跳存在                             YES
同 Wi-Fi 访问服务器全球 IPv6                 OK
手机移动数据访问服务器                      FAIL，Windows 无包
curl -4                                     OK
curl --noproxy "*" -6                      FAIL
Test-NetConnection 多个公网 IPv6            FAIL
tracert -6 前两跳可见，后续超时
浏览器 IPv6 测试                            表面 OK
绕过代理后 IPv6 测试                        FAIL
```

最终范围已经明显超出 Jellyfin。

### 14.7 8920 落入 Windows excluded port range

表现为 Kestrel bind 失败 / `SocketException (10013)`，旧方案改用 9443。

### 14.8 无密码 PFX 在 Jellyfin/.NET 加载异常

PFX 本体可解析，Jellyfin 加载失败；重新封装带密码 PFX 后恢复。

---

## 15. 测试的证明边界

| 测试结果 | 能证明 | 不能证明 |
| --- | --- | --- |
| `[::]:9443 LISTENING` | 有进程占用 IPv6 9443 socket | 证书正确、公网可达、进程一定是 Jellyfin |
| 服务器访问自己的全球 IPv6 成功 | 本地 / 当前地址路径可用 | 公网入站正常 |
| 同 Wi-Fi 手机访问全球 IPv6 成功 | 家庭 LAN IPv6 正常 | Internet 能进入家庭网络 |
| Windows 有全球 IPv6 | 获得了 IPv6 地址 | 端到端 IPv6 Internet 正常 |
| `Test-NetConnection` 有 SourceAddress / NextHop | Windows 选出了源地址和路由 | 目标可达 |
| 浏览器 IPv6 测试成功 | 浏览器当前请求路径能访问 IPv6 | 家庭宽带直连 IPv6 正常 |
| `curl --noproxy "*" -6` 成功 | 主机可直连该 IPv6 目标 | 所有 IPv6 目标和反向入站都正常 |
| pktmon 移动测试完全无包 | 连接没有抵达 Windows | 一定是路由器或一定是运营商 |
| `tracert -6` 某跳后超时 | 后续 hop 没返回 traceroute 响应 | 第一个 `*` 就是故障路由器 |

旧方案最重要的经验不是某个具体命令，而是始终限制每个测试的证明范围。

---

## 16. 迁移后的地位

这些排错经验仍有价值，尤其适合分析 IPv6、代理、LAN 与公网路径的边界，但不再承担当前 Jellyfin 正式公网入口的日常运维。

2026-08-29 后，正式入口改为：

```text
公网客户端
  -> Azure Caddy :443
  -> WireGuard
  -> Windows Jellyfin :8096
```

因此新的优先排错顺序应从 WireGuard / Caddy 开始，而不是重新检查家庭公网 IPv6 和 9443。
