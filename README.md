# Claude Pilot Installer Core

这是 Claude Pilot R3.5 自研安装器核心的公开构建透明度仓库。

本仓库用于：

- 从公开源码构建 `ClaudePilotSetup.exe`；
- 自动生成 SHA-256；
- 通过 GitHub Actions 生成构建来源证明（Artifact Attestation）；
- 公开安装器界面、部署编排、恢复、诊断、卸载和 Office MCP 的自研代码。

## 重要边界

本仓库**不包含**：

- Claude Desktop MSIX；
- Cowork 运行时或 Claude Code；
- Git 安装器；
- 第三方中文补丁；
- Flash Max 补丁资源；
- DeepSeek API Key、用户文件、日志、状态、诊断包或离线交付 ZIP。

GitHub 构建产物只是安装器核心，不是完整离线部署包。它需要合法取得并由用户单独提供的外部资源才能执行完整部署。

本项目是非官方社区工具，与 Anthropic 无隶属、授权或背书关系。Claude、Anthropic 及相关标识属于其各自权利人。

## 本地构建

要求 Windows x64 与 .NET SDK `8.0.423`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Build-PublicCore.ps1 -Clean
```

输出：

```text
artifacts/public/win-x64/ClaudePilotSetup.exe
artifacts/public/win-x64/SHA256SUMS.txt
artifacts/public/win-x64/BUILD-INFO.json
```

## 校验 SHA-256

```powershell
Get-FileHash .\ClaudePilotSetup.exe -Algorithm SHA256
```

将结果与同一 GitHub Release 中的 `SHA256SUMS.txt` 比较。

## 校验 GitHub 构建证明

安装 GitHub CLI 后执行：

```powershell
gh attestation verify .\ClaudePilotSetup.exe --repo Accsy7/claude-pilot-installer
```

构建证明说明该文件由本仓库指定提交和 GitHub Actions 工作流生成。它不是 Windows Authenticode 代码签名，不会把程序变成 Windows 的公共可信发布者，也不会自动消除 SmartScreen 提示。

## 源码公开与许可

当前发布用于源码审阅和构建来源验证，尚未授予 MIT、Apache-2.0 或其他开源许可证。除适用法律或第三方组件许可证另有允许外，保留所有权利。

第三方文件及许可信息见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。公开边界见 [SOURCE-BOUNDARY.md](SOURCE-BOUNDARY.md)。
