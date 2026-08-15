# 对话交接入口

如果需要由新的 ChatGPT / AI 对话继续维护本仓库，请**不要只读一份技术摘要就开始写代码**。

当前最新交接以 2026-08-15 这两份为主：

1. [`2026-08-15-next-conversation.md`](./2026-08-15-next-conversation.md)
   - 当前仓库、Jellyfin 状态、已有脚本、关键实验结论；
   - 新的“人工/模型判定映射表 → 脚本机械执行 → 新硬链接库”主线；
   - C/D 盘路径、安全边界、已确认的动画归属规则；
   - 当前值得保留的 Jellyfin issue 候选；
   - 回答“现在在哪里、下一步具体做什么”。

2. [`2026-08-15-project-story.md`](./2026-08-15-project-story.md)
   - 从最小 NFO、LocalAlternateVersion、路径解析、View-v3，一直到 TVDB、Missing Episode Fetcher、元数据刷新死结的完整演变；
   - 为什么最终决定不再继续给旧 Jellyfin 库打补丁，而是先理解 720 个真实视频文件的语义；
   - 用户对协作方式的明确要求：不要反复确认、不要云端假验证、不要把重复粘贴当成重复执行；
   - 回答“为什么项目会走到今天、哪些弯路不要重走”。

前一阶段的详细历史仍保留：

- [`2026-08-14-next-conversation.md`](./2026-08-14-next-conversation.md)
- [`2026-08-14-project-story.md`](./2026-08-14-project-story.md)

如果需要追溯 243-target NFO、LocalAlternateVersion、最初硬链接 View 等细节，可以继续阅读 8 月 14 日的两份文档。

两份最新文档缺一不可。

这个项目的目标不是单纯“让脚本跑通”，而是在**不破坏用户原始动画收藏**的前提下，让整理层和 Jellyfin 长期、稳定、可维护地理解这套收藏。
