# jellyfin-anime-maintenance

## **孩子们我只是想把服务器上动画规整一下怎么就变成了这个样子/(ㄒoㄒ)/\~\~**

> “为了省 NAS，结果最后还是买服务器，白折腾了。”
>
> 不是这样。**我们原本以为瓶颈是“有没有一台 NAS”，实际跑下来才发现，存储根本不是当前瓶颈；真正的瓶颈是媒体整理和公网入口。**
>
> 前一个已经基本解决了。后一个现在也已经定位到一个非常具体的解法。
>
> **恭喜，你不需要买一台贵服务器。**
>
> **你只需要先租一台便宜服务器。**
>
> 确实很有这几天整个项目的精神。

> 不，还没有结束（发出长崎素世的声音）
>
> 因为 **排ISSUE** 的事情还没做呢！

用于维护自己的 Jellyfin 动画媒体库。

当前方案不修改原始动画文件，而是在 ~~建立 NFO 本地元数据纠错脚本 *然而后续调查确认 NFO 可以修正集数自身的季号/集号，但**无法稳定撤销 Jellyfin 在读取 NFO 之前就建立的错误本地多版本关系***~~ 同一磁盘建立**文件名标准化**后的**硬链接**，让 Jellyfin 读取统一的作品、季和集目录结构。

> 基于本人电脑磁盘上的动画文件，不一定普适，但是希望脚本可能可以帮到遇到同样问题的人\~
>
> re：事实上……已经不是几个脚本那么简单了，可能之后会写一个简易的 jellyfin 排坑指南吧
>
> rere：最上面的服务器问题那更是一坨，但是和仓库内容关系不大了

关于网络连接性的排查，参见 [`docs/remote-access-troubleshooting.md`](docs/remote-access-troubleshooting.md)。

## 日常维护

### 新下载动画

下载新一集后先运行：

```powershell
python scripts\update_anime_incremental_view.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

确认没有需要人工判断的新视频后：

```powershell
python scripts\update_anime_incremental_view.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --apply
```

脚本只处理清单中**从未出现过的新文件**。已经记录过的旧文件后来即使被删除，也不会重新创建或阻塞本次更新。也**不处理剧场版动画**。

详细说明见 `docs/incremental-hardlink.md`。

### 新剧场版动画

由于剧场版命名复杂且不统一且数量少，故**直接创建硬链接**自己改名称路径。

```powershell
python scripts\create_hardlink.py `
  "D:\Gekijouban\原电影文件.mkv" `
  "D:\Resource\BangumiLink\View\剧场版\你自己决定的目录\你自己决定的文件名.mkv"
```

确认后 `--apply` 即可。

### IPv6 地址维护

已确认：服务器电脑每次重新开机后都会获得新的公网 IPv6。此时使用新的当前 IPv6 直接访问 Jellyfin 可以正常工作，而 DuckDNS 暂时会指向旧地址，等待几分钟即可。

> 更新：*不一定*每天/次开机都会重置！

#### 检查现有 IPv6

```powershell
Get-NetIPAddress -AddressFamily IPv6 |
Where-Object { $_.IPAddress -like '2*' } |
Format-Table InterfaceAlias,IPAddress,AddressState,PrefixLength,SuffixOrigin
```

#### 检查服务器对应 IPv6

```powershell
Resolve-DnsName <PUBLIC_HOST> -Type AAAA
```

或

```powershell
curl.exe -g -vk "https://<PUBLIC_HOST>:9443/"
# 然后查看命令行一开始显示的 IPv6 地址
# 也可依此判断联通状态，待返回 infant 后即大功告成
```

#### 修改服务器 IPv6 地址

访问：

```text
https://www.duckdns.org/update?domains=[DOMAIN]&token=[TOKEN]&ipv6=[IPv6]&verbose=true
```

## 大型维护

### 从清单重建硬链接视图

需要重新建立完整视图时：

```powershell
python scripts\apply_anime_decision_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv `
  --d-root "D:\Resource\BangumiLink\View"
```

确认试运行后加 `--apply`。

当前目标目录：

```text
C:\resource\video\anime
D:\Resource\BangumiLink\View
```

### 重建 Jellyfin 动画库

需要重新建立 Jellyfin 媒体库时：

```powershell
$env:JELLYFIN_API_KEY = "<API_KEY>"

python scripts\create_jellyfin_libraries_from_manifest.py `
  inputs\raw\anime-decision-manifest-complete-revised.csv
```

确认试运行后加 `--apply`。

脚本会按照清单中的“媒体库分组”建库，并自动处理跨 C、D 两个磁盘的媒体目录。

### 导出 Jellyfin 元数据核查

需要完整检查电视动画当前识别状态时：

```powershell
.\scripts\export_jellyfin_tv_audit_12.ps1 -ApiKey "<API_KEY>"
```

如果只想快速（让 AI）核查一般 Jellyfin 元数据，也可以继续使用 `docs/library-export.md` 中的通用导出脚本。

## 目录

- `scripts/`：实际维护脚本，以及早期调查阶段保留下来的工具
- `docs/`：当前使用说明、设计说明和历史记录
- `docs/history/`：项目调查、试验和方案演变存档
- `rules/`：早期 NFO 规则等结构化规则文件
- `reports/`：历史核查结果
- `experiments/`：一次性实验，不作为日常入口
- `samples/`：示例文件
- `tests/`：脚本测试
