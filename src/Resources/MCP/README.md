# Claude Desktop 本地 Word / Excel MCP

这是一套仅依赖 Windows、Microsoft Office 和 PowerShell 的本地 MCP。它通过 Office 自带的 COM 自动化连接桌面版 Word 和 Excel，不下载或运行第三方 MCP 软件包。

## 安全边界

- 默认工作区：`D:\ClaudeDesktop\Cowork`
- 只允许 MCP 打开或另存到该目录内的 Office 文件。
- 修改当前文档或工作簿后默认不自动保存。
- “另存为”默认拒绝覆盖已有文件，只有显式传入 `overwrite=true` 才可覆盖。
- 单次读取或写入 Excel 最多 2,000 个单元格。
- Word 单次文本操作最多 100,000 个字符。
- MCP 直接控制本机 Office，因此仅适用于受信任的本机用户。

## 安装

关闭 Claude Desktop 后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Office-Mcp.ps1
```

安装器会：

1. 将运行文件复制到 `D:\ClaudeDesktop\MCP\Office`；
2. 将 Claude Desktop 配置备份到 `D:\ClaudeDesktop\Backups\OfficeMcp`；
3. 登记 `word` 和 `excel` 两个本地 MCP；
4. 保留原有 DeepSeek、Cowork 和偏好配置。

安装完成后必须完全退出并重新打开 Claude Desktop。

## 验证

不改动 Office 文件的协议自检：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Office-McpProtocol.ps1
```

在 Claude Desktop 普通聊天或 Code 中可尝试：

- “检查 Word 是否正在运行。”
- “检查 Excel 是否正在运行。”
- “读取当前 Excel 工作簿 Sheet1 的 A1:C10，不要修改。”

首次调用工具时，Claude 可能要求确认权限。

## 重要限制

通过 `claude_desktop_config.json` 登记的本地 MCP 可供 Claude Desktop 的本地会话使用，但不直接出现在 Cowork 中。若后续必须在 Cowork 内调用 Office，需要改为 Claude Desktop Extension 或远程 MCP 连接器方案。

## 卸载

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Remove-Office-Mcp.ps1
```

卸载脚本只移除 Claude 配置中的 `word`、`excel` 两项，默认保留运行文件与所有备份。
