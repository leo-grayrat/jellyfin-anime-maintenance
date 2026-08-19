# Jellyfin 网络连接性排查

这份文档用于处理“Jellyfin 突然打不开”的情况。

当前远程访问链路涉及 Jellyfin 本机服务、Windows 网络监听、局域网、IPv6、DDNS、HTTPS、浏览器代理、家庭路由器和运营商公网路径。排错时不要一上来重配证书、DNS 或 Jellyfin；应当**从最近的一层开始逐层向外测试，找到最后一个成功的层级和第一个失败的层级**。

这份文档特别强调一个容易误判的点：

> **“设备拥有 IPv6 地址”“同 Wi-Fi 能访问服务器的全球 IPv6”“浏览器的 IPv6 测试网页显示正常”都不能单独证明家庭宽带的直连 IPv6 Internet 正常。**

必须把本机服务、局域网 IPv6、服务器主动访问公网 IPv6、以及公网主动访问服务器这几件事拆开测试。

## 地址约定

本文使用：

```text
本机 HTTP：
http://127.0.0.1:8096

局域网 HTTP：
http://<LAN_IP>:8096

服务器当前全球 IPv6：
<CURRENT_PUBLIC_IPV6>

IPv6 HTTP：
http://[<CURRENT_PUBLIC_IPV6>]:8096

正式 HTTPS：
https://<PUBLIC_HOST>:9443
```

当前正式入口是 IPv6-only：访问端本身必须具有真正可用的 IPv6 路径。

---

## 最短检查顺序

如果只想尽快判断坏在哪一层，建议按下面顺序做。不要跳过第 6 步的“服务器主动访问公网 IPv6”，它可以区分“只有公网入站失败”和“家庭 IPv6 Internet 本身已经异常”。

| 顺序 | 测试 | 主要证明什么 |
| --- | --- | --- |
| 1 | 服务器本机 `http://127.0.0.1:8096` | Jellyfin 进程和 HTTP 服务是否活着 |
| 2 | 服务器本机 `http://<LAN_IP>:8096` | Jellyfin 是否正常监听网络接口 |
| 3 | 同 Wi-Fi 其他设备 `http://<LAN_IP>:8096` | 局域网通信和 Windows 入站是否正常 |
| 4 | 服务器本机 / 同 Wi-Fi 设备访问 `[<CURRENT_PUBLIC_IPV6>]` | 当前全球 IPv6 地址与 Jellyfin IPv6 服务在本地/LAN 是否可用；**不证明公网入站** |
| 5 | `Resolve-DnsName <PUBLIC_HOST> -Type AAAA` | DDNS 是否已经指向当前 IPv6 |
| 6 | 服务器用 `curl --noproxy "*" -6` 主动访问真正的公网 IPv6 服务 | 家庭宽带的直连 IPv6 Internet 是否正常 |
| 7 | 服务器 `https://<PUBLIC_HOST>:9443` | 域名、9443、TLS 和证书是否正常 |
| 8 | 同 Wi-Fi 手机正式入口 | 客户端 Wi-Fi IPv6 / DNS / 代理是否正常 |
| 9 | 手机关闭 Wi-Fi、仅移动数据访问，同时服务器抓包 | 真正的公网 IPv6 入站是否抵达 Windows |

只要某一步失败，就先在这一层解决，不要同时修改其他层。

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

应当能看到与当前 Jellyfin 配置相符的端口处于 `LISTENING`。Windows 的双栈监听显示方式可能不同，下面只是可能的例子，不要求四行必须同时出现：

```text
0.0.0.0:8096    LISTENING
[::]:8096       LISTENING
0.0.0.0:9443    LISTENING
[::]:9443       LISTENING
```

如果端口看起来在监听，但行为和 Jellyfin 不一致，不要默认占用端口的一定是 Jellyfin。记录最后一列 PID，再确认进程：

```powershell
tasklist /FI "PID eq <PID>"
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

如果只有 loopback 监听，优先检查 Jellyfin 网络监听配置。

如果已经监听网络接口，则检查：

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
Jellyfin                  OK
服务器网络监听             OK
局域网基本通信             OK
Windows 对 8096 的 LAN 入站 OK
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

## 第 3 层：服务器当前全球 IPv6 与 Jellyfin 的 IPv6 服务是否正常

先查看服务器当前 IPv6：

```powershell
Get-NetIPAddress -AddressFamily IPv6 |
Format-Table InterfaceAlias,IPAddress,AddressState,PrefixLength,SuffixOrigin
```

重点找当前网卡上处于 `Preferred` 状态的全球 IPv6，而不是 `fe80::/10` link-local 地址或 `::1`。

然后测试当前地址：

```powershell
curl.exe -g -v "http://[<CURRENT_PUBLIC_IPV6>]:8096/"
curl.exe -g -vk "https://[<CURRENT_PUBLIC_IPV6>]:9443/"
```

裸 IPv6 访问 HTTPS 时，证书是签发给域名而不是 IP，所以 `-k` 只用于测试 TCP/TLS 服务是否能连上。不要拿裸 IP 的证书名称不匹配去判断正式证书坏了。

### 很重要：这一步不能证明“公网已经通”

服务器访问自己的全球 IPv6，或者同一 Wi-Fi 的手机访问服务器的全球 IPv6，都可能仍然只发生在本机 / 家庭 LAN 内。

家庭网络中的设备如果处在同一个 IPv6 前缀，可以直接通过局域网互相访问全球 IPv6 地址，并不需要先绕到运营商公网再回来。

因此：

```text
同 Wi-Fi 手机 -> [服务器全球 IPv6] 成功
```

只能证明：

```text
手机 LAN IPv6                 OK
服务器当前全球 IPv6 地址       OK
Jellyfin 对 IPv6 的服务路径     OK
```

**不能据此证明：**

```text
Internet -> 家庭公网 IPv6 入站 OK
```

这条边界非常重要。真正的公网入站必须在手机关闭 Wi-Fi、使用独立外部网络时测试。

### 当前全球 IPv6 访问失败

如果局域网 IPv4 正常，而服务器连自己的当前全球 IPv6 都失败，再检查：

```powershell
netstat -ano | findstr ":8096"
netstat -ano | findstr ":9443"
```

以及当前 IPv6 地址是否仍处于 `Preferred`。

此时优先查服务器 IPv6 地址 / 接口 / Windows 网络栈 / 监听，不要先查 DDNS，因为裸地址已经失败。

---

## 第 4 层：电脑重启后先核对当前 IPv6 与 DDNS

本项目当前机器存在一个稳定现象：**电脑重新开机后，服务器的全球 IPv6 会变化。**

因此“昨天能开、今天开机后正式域名打不开”时，不要先怀疑 Jellyfin 或证书，先比较：

```powershell
Get-NetIPAddress -AddressFamily IPv6
Resolve-DnsName <PUBLIC_HOST> -Type AAAA
```

### 情况 A：当前 IPv6 已变化，但 AAAA 仍是旧地址

此时使用新的当前 IPv6 直接访问 Jellyfin可能正常，而正式域名仍会失败。

处理顺序：

1. 确认服务器当前真正使用的全球 IPv6；
2. 更新 DuckDNS AAAA；
3. 等待数分钟；
4. 重复运行：

```powershell
Resolve-DnsName <PUBLIC_HOST> -Type AAAA
```

直到返回值与当前服务器 IPv6 一致，再测试正式域名。

### 为什么“网页已经改了”仍可能暂时打不开

本项目实测出现过：DuckDNS 网页已经明确改成新 IPv6，但随后几次 DNS 查询仍然返回旧 IPv6；等待几分钟并重复查询后才切换到新地址。

所以：

```text
DDNS 网页已更新
```

并不等于：

```text
当前客户端 DNS 查询已经拿到新地址
```

在 `Resolve-DnsName` 仍返回旧地址时，不要因为正式域名失败就去改 9443 或重签证书。

### 情况 B：AAAA 已经等于当前 IPv6

这时 DDNS 已经排除。继续检查 HTTPS、代理和真正的 IPv6 Internet。

---

## 第 5 层：9443 / HTTPS / 证书是否正常

### 先验证 Jellyfin 本机 HTTPS

使用正式域名做本机强制回环：

```powershell
curl.exe -vk --resolve <PUBLIC_HOST>:9443:127.0.0.1 https://<PUBLIC_HOST>:9443/
```

如果 TCP/TLS 成功并收到 Jellyfin 的 HTTP 响应，就说明：

- Jellyfin HTTPS 服务存在；
- Kestrel 9443 能工作；
- 当前 PFX 至少能够被 Jellyfin加载并提供 TLS。

Jellyfin 根路径在当前实例中曾返回：

```text
HTTP/1.1 302 Found
Location: web/
```

但排错时不应机械要求必须是 302；**能完成 TLS 并收到 Jellyfin 的 HTTP 响应即可证明这一层服务存在。**

### `netstat` 显示 9443 LISTENING，但本机 HTTPS 仍失败

确认监听 PID：

```powershell
netstat -ano | findstr ":9443"
tasklist /FI "PID eq <PID>"
```

不要因为端口处于 LISTENING 就自动假定 HTTPS 服务一定正常，也不要自动假定占用者一定是 Jellyfin。

### `-k` 成功，正常校验失败

再运行：

```powershell
curl.exe --noproxy "*" -v https://<PUBLIC_HOST>:9443/
```

如果 `-k` 成功，而正常校验失败，才重点检查：

- 证书过期；
- 域名与证书不匹配；
- 证书链异常；
- Jellyfin 加载了错误的证书。

### 本项目已经遇到过的 8920 / PFX 问题

当前 Windows 环境中，Jellyfin 默认 HTTPS 端口 8920 落在系统 excluded port range `8841-8940` 内，曾导致 Kestrel `SocketException (10013)`；因此当前改用 9443。

原无密码 PFX 本体可以被系统工具解析，但 Jellyfin/.NET 加载时出现过兼容问题；重新封装为明确带密码的 PFX 后恢复。

这两项是历史上真实出现过的故障，但只有在本机 HTTPS 这一层失败时才值得重新检查。不要因为网站打不开就先重做证书。

---

## 第 6 层：服务器能否“直连”真正的 IPv6 Internet

这是旧版文档最容易跳过的一层，也是区分两类故障的关键：

```text
A. 家庭 IPv6 Internet 正常，只是公网主动入站被挡
B. 家庭宽带的直连 IPv6 Internet 本身已经异常
```

如果不做这一层，就很容易把 B 误判成 A。

### 先做 IPv4 / IPv6 对照

使用同一个正常公网 HTTPS 站点测试：

```powershell
curl.exe --noproxy "*" -4 -I https://www.cloudflare.com/
curl.exe --noproxy "*" -6 -I https://www.cloudflare.com/
```

这里的关键不是 Cloudflare，而是：

1. 同一个目标；
2. 强制分别使用 IPv4 / IPv6；
3. 使用 `--noproxy "*"`，禁止代理替你完成连接。

如果结果是：

```text
-4  成功
-6  失败
```

说明“普通互联网正常”不能证明 IPv6 正常，当前应该继续查家庭 IPv6 WAN / 路由，而不是 Jellyfin。

### 再测一个明确的外部 IPv6 TCP 目标

本项目排错时使用过：

```powershell
Test-NetConnection 2606:4700:4700::1111 -Port 853 -InformationLevel Detailed
```

输出里重点看：

```text
SourceAddress
NetRoute (NextHop)
TcpTestSucceeded
```

即使：

```text
SourceAddress = 一个全球 IPv6
NetRoute       = 有 IPv6 下一跳
```

也只说明 Windows **拥有 IPv6 地址并选出了路由**，不等于端到端 IPv6 Internet 一定能成功。

如果 `TcpTestSucceeded : False`，再换一个无关的 IPv6 目标做交叉验证，避免把单个网站 / 单个端口故障误判成整个 IPv6 故障。

本项目还使用过：

```powershell
Test-NetConnection 240c::6666 -Port 53 -InformationLevel Detailed
```

如果多个无关 IPv6 目标都失败，而 IPv4 正常，才有理由把范围收敛到 IPv6 公网路径。

### 使用 traceroute 看故障大致发生在哪一段

```powershell
tracert -6 -d 2606:4700:4700::1111
```

本项目一次故障中得到过：

```text
第 1 跳   成功
第 2 跳   成功
第 3 跳以后持续超时
```

这说明数据至少离开了 Windows 并走过前两跳，但**不能机械地说“第 3 跳就是坏点”**。中间路由器可能不回应 traceroute 所依赖的 ICMPv6。

正确的用法是把它和真实业务测试结合：

```text
curl -6 真实连接失败
多个 IPv6 TCP 目标失败
tracert -6 只能走到前几跳
```

三者同时出现时，才说明问题已经明显超出 Jellyfin 本机，应该检查家庭路由器 IPv6 WAN / 运营商 IPv6 路由状态。

### “电脑有 IPv6 地址”为什么仍可能公网失败

完全可能出现：

```text
电脑获得全球 IPv6        OK
IPv6 默认下一跳存在       OK
家庭 LAN IPv6             OK
真正 IPv6 Internet        FAIL
```

因此不要把 `ipconfig` / `Get-NetIPAddress` 看到一个 `2xxx:` 地址当成 IPv6 公网健康证明。

---

## 第 7 层：浏览器显示“IPv6 正常”时，先确认它是不是代理测出来的

这是本项目已经实际踩过的一个很隐蔽的坑。

### 现象

命令行直连测试出现：

```text
curl -4  成功
curl -6  失败
```

但浏览器打开 IPv6 测试网页，却显示 IPv6 正常。

乍看互相矛盾，实际可能完全不矛盾：**浏览器请求被代理 / VPN / 代理扩展接管，测试网页测到的是代理出口的 IPv6 能力，而不是家庭宽带的直连 IPv6。**

### 如何揭穿这种“假正常”

对同一个 IPv6-only 测试目标，用 curl 强制 IPv6并绕过代理。

本项目使用过：

```powershell
curl.exe --noproxy "*" -6 -v http://ipv6.test-ipv6.com/ -o NUL
```

如果：

```text
浏览器 IPv6 测试       OK
curl --noproxy "*" -6  FAIL
```

应当相信后者对“家庭宽带直连 IPv6”的判断。

这时浏览器测试页并没有证明家庭 IPv6 正常，它只证明浏览器经由当前代理路径能够访问 IPv6 目标。

### 同样的原则也适用于 Jellyfin

如果：

```text
curl 直连正常 + 浏览器失败
```

优先检查浏览器代理，把 `<PUBLIC_HOST>` 加入：

```text
DIRECT
No Proxy
不使用代理
```

如果：

```text
浏览器“网络测试”正常 + curl --noproxy 直连失败
```

则不要反过来拿浏览器结果否定命令行直连测试。

---

## 第 8 层：同 Wi-Fi 手机的 IPv6 测试

同一 Wi-Fi 的手机可以做三项对照：

```text
http://<LAN_IP>:8096
http://[<CURRENT_PUBLIC_IPV6>]:8096
https://<PUBLIC_HOST>:9443
```

### 情况 A：LAN IPv4 成功，当前全球 IPv6 和正式域名都失败

先检测手机当前 Wi-Fi 会话是否真的有 IPv6 connectivity。

本项目曾发生过一次：手机可以正常访问 IPv4 网站和 Jellyfin LAN 地址，但该次 Wi-Fi 会话实际没有 IPv6 连通性。关闭并重新打开 Wi-Fi 后，IPv6 重新建立，正式域名立即恢复。

因此先做：

1. 确认手机当前 Wi-Fi 是否存在 IPv6 connectivity；
2. 如果没有，断开 / 重新连接 Wi-Fi；
3. 重连后再次测试当前全球 IPv6 和正式域名。

如果经常重复发生，再调查路由器 RA / 手机 IPv6 网络状态，而不是反复修改 Jellyfin。

### 情况 B：LAN IPv4 和当前全球 IPv6成功，正式域名失败

```text
LAN IPv4          OK
当前全球 IPv6      OK
正式域名           FAIL
```

手机到服务器的 LAN IPv6 路径正常。优先检查：

- DuckDNS AAAA 是否已更新到当前地址；
- 手机 DNS / Private DNS / Secure DNS；
- 手机代理或 VPN；
- 域名解析缓存。

### 情况 C：三项都成功

只能确认家庭内部到服务器这一条路径正常。

**仍然不能因为同 Wi-Fi 访问全球 IPv6 成功，就宣布公网入站正常。**

真正的公网验收必须让手机离开家庭 Wi-Fi。

---

## 第 9 层：手机移动数据失败时，用 pktmon 判断包到底有没有到 Windows

手机关闭 Wi-Fi，只使用移动数据，然后尝试：

```text
http://[<CURRENT_PUBLIC_IPV6>]:8096
https://[<CURRENT_PUBLIC_IPV6>]:9443
https://<PUBLIC_HOST>:9443
```

如果全部失败，而手机自身也确实具有 IPv6，不要立刻猜证书或 DuckDNS。直接在服务器上抓 8096 / 9443 的 TCP 包。

管理员终端：

```powershell
pktmon filter remove
pktmon filter add JF8096 -t TCP -p 8096
pktmon filter add JF9443 -t TCP -p 9443
pktmon start --capture --log-mode real-time
```

然后：

1. 手机保持移动数据，访问 8096；
2. 再访问 9443；
3. 观察服务器窗口；
4. 再把手机切回 Wi-Fi，访问同一地址做对照；
5. `Ctrl+C` 结束。

### 情况 A：移动数据访问时完全没有包，切回 Wi-Fi 后马上出现大量包

这是非常有价值的结果。

它证明：

```text
pktmon 抓包本身            OK
Jellyfin / Windows LAN 路径 OK
移动网络发起的连接没有抵达 Windows
```

此时不要继续查 Jellyfin、PFX、9443 的应用层配置，因为 TCP SYN 都还没到应用程序。

但此时还不能立刻说“只是公网入站防火墙”。必须回到第 6 层，检查服务器自己能否直连真正的 IPv6 Internet。

#### 如果服务器主动 IPv6 出站正常

例如：

```text
curl --noproxy "*" -6 到公网成功
多个外部 IPv6 TCP 目标成功
```

但移动网络入站仍完全抓不到包，那么重点才是：

- 家庭路由器 IPv6 入站防火墙 / ACL；
- 运营商家庭宽带入站过滤；
- 移动网络到家庭前缀的路由 / 互联；
- 其他位于 Windows 之前的公网入站路径。

#### 如果服务器主动 IPv6 出站也失败

例如：

```text
curl -4                         OK
curl --noproxy "*" -6          FAIL
Test-NetConnection 多个 IPv6    FAIL
移动数据访问服务器              无包到达
```

那么故障已经不适合描述成“只有公网入站失败”。

更准确的判断是：

> **家庭 LAN IPv6 仍可用，但家庭宽带当前的直连 IPv6 Internet / WAN 路径已经异常。**

这时应优先检查：

- 家庭路由器 IPv6 WAN 状态；
- 当前 IPv6 前缀 / 默认路由；
- 宽带重新拨号或路由器重启后是否恢复；
- 运营商 IPv6 接入 / 路由状态。

不要继续围着 Jellyfin 转。

### 情况 B：能看到手机发来的 SYN，但服务器没有 SYN,ACK

说明公网包已经抵达 Windows。

此时才检查：

- Windows 防火墙；
- 监听是否仍存在；
- 端口对应 PID；
- Windows 网络栈。

### 情况 C：能看到 SYN 和服务器的 SYN,ACK，但手机没有继续 ACK

说明请求能到服务器，服务器也尝试回包，但连接没有完成。

重点转向：

- 回程 IPv6 路由；
- 移动网络侧路径；
- 运营商间 IPv6 互联。

### 情况 D：TCP 三次握手完成，随后才卡住

这时才进入更高层：

- TLS；
- HTTP；
- MTU / PMTU；
- Jellyfin 应用层。

不要在“连 SYN 都没有”的阶段提前检查这些。

---

## 第 10 层：路由器防火墙关闭不等于 IPv6 WAN 一定健康

本项目历史上已经通过开 / 关对照确认过：TC7102 总防火墙开启时会阻断公网 IPv6 入站，关闭后曾经可以从移动网络访问 Jellyfin。

但是这只证明**那个时间点**的阻断点是路由器防火墙。

新的故障中，即使路由器防火墙明确处于关闭状态，也可能同时存在另一类问题：

```text
家庭 LAN IPv6             OK
路由器防火墙              OFF
服务器直连公网 IPv6        FAIL
公网移动数据入站           FAIL
```

这种情况下，继续反复开关防火墙意义不大。应该检查 IPv6 WAN / 运营商路径。

如果准备重启路由器或重新建立宽带连接，建议先保存重启前的：

```powershell
curl.exe --noproxy "*" -4 -I https://www.cloudflare.com/
curl.exe --noproxy "*" -6 -I https://www.cloudflare.com/
Test-NetConnection 2606:4700:4700::1111 -Port 853 -InformationLevel Detailed
tracert -6 -d 2606:4700:4700::1111
```

恢复后再运行同一组测试。

如果出现：

```text
重启前：IPv6 公网出站 FAIL / 移动入站 FAIL
重启后：IPv6 公网出站 OK   / 移动入站 OK
```

就能把故障进一步收敛到家庭路由器 IPv6 WAN / 宽带 IPv6 会话 / 运营商接入状态，而不是 Jellyfin。

---

## 已经实际遇到过的故障模式

### 1. 电脑重启后 IPv6 地址变化，DuckDNS 仍暂时指向旧地址

特征：

```text
当前新 IPv6 直接访问       OK
Resolve-DnsName 返回旧 IPv6
正式域名                   FAIL
```

处理：更新 DuckDNS，等待数分钟，直到 AAAA 查询真正变成当前地址。

### 2. Firefox / 浏览器代理接管 IPv6-only 域名

特征：

```text
curl 直连正式域名          OK
浏览器                     FAIL
```

处理：将正式域名设为 DIRECT / No Proxy。

### 3. 浏览器 IPv6 测试显示正常，但家庭直连 IPv6 实际失败

特征：

```text
浏览器 IPv6 测试           OK
curl --noproxy "*" -6      FAIL
```

根因：浏览器测试请求走了代理，测试到的是代理出口而不是家庭直连 IPv6。

### 4. 手机某次 Wi-Fi 会话丢失 IPv6

特征：

```text
手机 LAN IPv4             OK
手机 Wi-Fi IPv6           FAIL
正式 IPv6-only 域名        FAIL
```

处理：重新连接 Wi-Fi；若反复发生再查 RA / 路由器 LAN IPv6。

### 5. TC7102 IPv6 入站防火墙阻断公网连接

历史实测：

```text
防火墙 ON   -> 移动网络无法进入
防火墙 OFF  -> 移动网络可以进入
```

这是一个已经确认过的故障模式，但不能因此把以后每次失败都直接归因于防火墙。

### 6. 家庭 LAN IPv6 正常，但直连 IPv6 Internet 失败

一次新故障中观察到：

```text
服务器有全球 IPv6 地址                         YES
IPv6 下一跳存在                                YES
同 Wi-Fi 访问服务器当前全球 IPv6                OK
手机移动数据访问服务器                         FAIL，Windows 抓不到包
curl -4 到公网                                 OK
curl --noproxy "*" -6 到公网                  FAIL
Test-NetConnection 到多个公网 IPv6             FAIL
tracert -6 前两跳可见，后续超时
浏览器 IPv6 测试                               表面 OK
绕过代理后的 IPv6 测试                         FAIL
```

最终确认浏览器测试被代理路径干扰，因此并不与命令行直连结果矛盾。

这类故障的正确方向是 IPv6 WAN / 上游路由，而不是 Jellyfin、证书或 DDNS。

### 7. Jellyfin 默认 8920 落入 Windows excluded port range

表现为 Kestrel 绑定失败 / `SocketException (10013)`。当前改用 9443。

### 8. 无密码 PFX 在 Jellyfin/.NET 中加载异常

PFX 本体可被系统工具解析，但 Jellyfin 加载失败；重新封装为明确带密码的 PFX 后恢复。

---

## 按结果快速判断

```text
连 127.0.0.1 都打不开
→ Jellyfin 本机故障

127.0.0.1 能开，服务器 LAN IP 不能
→ Jellyfin 监听 / Windows 网络层

服务器 LAN IP 能开，同 Wi-Fi 其他设备 LAN IP 不能
→ 局域网 / Windows 入站

服务器/同 Wi-Fi 能访问当前全球 IPv6
→ 只能证明本机/LAN IPv6 与服务绑定正常；不能证明公网入站

当前 IPv6 能用，但 Resolve-DnsName 仍是旧地址
→ DDNS 更新 / DNS 缓存时序

AAAA 已正确，curl 直连成功，但浏览器失败
→ 浏览器代理 / VPN / DNS 路径

浏览器 IPv6 测试正常，但 curl --noproxy "*" -6 失败
→ 浏览器测试很可能走了代理；家庭直连 IPv6 仍异常

curl -4 成功、curl --noproxy "*" -6 失败，多个 IPv6 目标都失败
→ 家庭宽带 IPv6 WAN / 运营商 IPv6 路径

同 Wi-Fi 一切正常，手机移动数据失败，pktmon 完全无包
→ 外部连接没有抵达 Windows；再结合服务器 IPv6 出站判断是单纯入站问题还是整个 IPv6 WAN 问题

移动数据访问时 pktmon 有 SYN、没有 SYN,ACK
→ Windows 防火墙 / 监听 / 本机网络栈

pktmon 有 SYN 和 SYN,ACK，但连接不完成
→ 回程 / 移动网络 / 运营商互联

移动网络也能正常访问
→ 整条公网链路正常
```

---

## 每个测试到底证明了什么

排错中最容易犯的错误不是命令不会用，而是**把某个测试的证明范围说大了**。

| 测试结果 | 能证明 | 不能证明 |
| --- | --- | --- |
| `netstat` 显示 `[::]:9443 LISTENING` | 有进程占着 IPv6 9443 socket | 证书正确、公网可达、占用者一定是 Jellyfin |
| 服务器访问自己的全球 IPv6 成功 | 当前地址 / 本地 IPv6 服务路径可用 | 家庭公网入站正常 |
| 同 Wi-Fi 手机访问全球 IPv6 成功 | 家庭 LAN IPv6 到服务器正常 | 移动网络 / Internet 能进入家庭网络 |
| `Get-NetIPAddress` 有全球 IPv6 | 主机获得了 IPv6 地址 | 端到端 IPv6 Internet 正常 |
| `Test-NetConnection` 显示 SourceAddress / NextHop | Windows 找到了源地址和路由 | 目标一定可达 |
| 浏览器 IPv6 测试成功 | 浏览器当前请求路径能访问 IPv6 | 家庭宽带直连 IPv6 一定正常，尤其在代理开启时 |
| `curl --noproxy "*" -6` 成功 | 当前主机可以直连该 IPv6 目标 | 所有 IPv6 目标、反向入站也都正常 |
| pktmon 在移动数据测试时完全无包 | 连接没有抵达 Windows | 一定是路由器还是一定是运营商 |
| `tracert -6` 某一跳后超时 | 后续 hop 没有返回 traceroute 响应 | 第一个 `*` 就一定是故障路由器 |

---

## 排错原则

最重要的不是记住某个曾经出现过的故障，而是每次都回答：

> **最后一个真正成功的测试是哪一个？**
>
> **紧接着第一个真正失败的测试是哪一个？**
>
> **这个成功测试到底证明到哪一层，是否被代理、本地 on-link IPv6 或缓存绕开了真正想测的路径？**

不要因为以前出现过 PFX、端口、浏览器代理、手机 Wi-Fi IPv6、DuckDNS 延迟或路由器防火墙问题，就在新的故障里直接假定还是同一个原因。

先重新定位，再修改对应层。