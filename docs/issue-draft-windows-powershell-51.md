# Windows PowerShell 5.1 无法解析脚本

运行脚本时报错：

```text
所在位置 ...\scripts\jellyfin_tv_nfo_fix.ps1:72 字符: 1
} else {
~
表达式或语句中包含意外的标记“}”。

Write-Host "[Series 鐩綍涓嶅瓨鍦紝璺宠繃] ..."
数组索引表达式丢失或无效。
```

原因：脚本是 UTF-8 无 BOM，并包含中文源码；Windows PowerShell 5.1 会按旧代码页误读，导致乱码并进一步触发 ParserError。

修复：主 `.ps1` 源码保持 ASCII-only；中文/日文规则继续放在 JSON 中并显式按 UTF-8 读取。修复提交：`351f05b`。
