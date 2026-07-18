[CmdletBinding()]
param(
    [string]$ExpectedUserSid = '',

    [switch]$PlanOnly,

    [switch]$AuditOnly,

    [switch]$PurgeResiduals,

    [string]$Confirmation = '',

    [string]$ResultPath = '',

    [string]$DataRoot = '',

    [switch]$NonInteractive,

    [ValidateSet('PreserveWork', 'FullCleanup')]
    [string]$UninstallMode = 'PreserveWork',

    [switch]$RemoveGitRequested,

    [switch]$DisableVmpRequested
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$bundleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pathModule = Join-Path $PSScriptRoot 'Deployment-Paths.ps1'
if (-not (Test-Path -LiteralPath $pathModule -PathType Leaf)) {
    throw "Missing deployment path module: $pathModule"
}
. $pathModule
$deploymentPaths = Resolve-PilotDeploymentPaths -BundleRoot $bundleRoot -RequestedDataRoot $DataRoot -Mode Uninstall
$companyRoot = $deploymentPaths.DataRoot
$coworkRoot = $deploymentPaths.CoworkRoot
$runtimeRoot = $deploymentPaths.RuntimeRoot
$claudeUserDataLegacyDefaultTarget = $deploymentPaths.ClaudeUserDataTarget
$deploymentStatePath = $deploymentPaths.StatePath
$deploymentMarkerPath = $deploymentPaths.MarkerPath
$deploymentPointerPath = $deploymentPaths.PointerPath
$claudeUserDataPath = Join-Path $env:LOCALAPPDATA 'Claude-3p'
$claudeRoamingPath = Join-Path $env:APPDATA 'Claude'
$claudeRoaming3pPath = Join-Path $env:APPDATA 'Claude-3p'
$claudePackageDataPath = Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc'
$claudeServiceDataPath = Join-Path $env:ProgramData 'Claude'
$claudeLocalizationLegacyPath = Join-Path $env:LOCALAPPDATA 'ClaudeDesktopZhCn'
$script:RestartRequired = $false
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:ServiceDeletionPending = $false
if ($AuditOnly -and $PurgeResiduals) {
    throw 'AuditOnly cannot be combined with PurgeResiduals.'
}
if ($PurgeResiduals -and [string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $env:TEMP 'Claude-Purge-Residuals-result.txt'
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Argument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-ElevatedSelf {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-Argument $PSCommandPath) -ExpectedUserSid $(Quote-Argument $currentSid) -DataRoot $(Quote-Argument $companyRoot)"
    if ($PlanOnly) {
        $arguments += ' -PlanOnly'
    }
    if ($PurgeResiduals) {
        $arguments += " -PurgeResiduals -Confirmation $(Quote-Argument $Confirmation) -ResultPath $(Quote-Argument $ResultPath)"
    }
    if ($NonInteractive) {
        $arguments += " -NonInteractive -UninstallMode $UninstallMode"
        if ($RemoveGitRequested) { $arguments += ' -RemoveGitRequested' }
        if ($DisableVmpRequested) { $arguments += ' -DisableVmpRequested' }
        if ($Confirmation) { $arguments += " -Confirmation $(Quote-Argument $Confirmation)" }
    }
    if ($PurgeResiduals) {
        [IO.File]::WriteAllText($ResultPath, "PENDING`r`n等待用户确认 Windows 管理员提示。`r`n", (New-Object Text.UTF8Encoding($false)))
    }
    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        if ($PurgeResiduals) {
            $message = "FAIL`r`n未获得管理员权限：$($_.Exception.Message)`r`n"
            try { [IO.File]::WriteAllText($ResultPath, $message, (New-Object Text.UTF8Encoding($false))) } catch {}
        }
        throw '没有获得管理员权限，未执行删除。请在 Windows 用户账户控制窗口中选择“是”后重试。'
    }
    if ($PurgeResiduals -and -not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        [IO.File]::WriteAllText($ResultPath, "FAIL`r`n管理员子进程未写回结果。`r`n", (New-Object Text.UTF8Encoding($false)))
    }
    exit $process.ExitCode
}

function Assert-ExpectedUser {
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid)) {
        return
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($currentSid -ne $ExpectedUserSid) {
        throw 'UAC 切换到了另一个 Windows 账号。为避免遗漏实际使用者的 Claude 数据，卸载已停止。请让实际使用 Claude 的账号临时具备管理员权限后重试。'
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$DefaultYes = $false
    )
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }
        if ($answer -match '^[Yy]$') { return $true }
        if ($answer -match '^[Nn]$') { return $false }
        Write-Host '请输入 Y 或 N。' -ForegroundColor Yellow
    }
}

function Get-PropertyValue {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )
    if ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name]) {
        return $InputObject.PSObject.Properties[$Name].Value
    }
    return $DefaultValue
}

function Get-DeploymentState {
    if (-not (Test-Path -LiteralPath $deploymentStatePath -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $deploymentStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $script:Warnings.Add("部署状态记录无法读取，将按旧部署处理：$($_.Exception.Message)")
        return $null
    }
}

function Get-PathSize {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [int64]0
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        return [int64]$item.Length
    }
    [int64]$total = 0
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue) {
        $total += [int64]$file.Length
    }
    return $total
}

function Format-ByteSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes bytes"
}

function Get-ClaudePackage {
    return Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Get-GitInfo {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('HKLM:\Software\GitForWindows', 'HKCU:\Software\GitForWindows')) {
        $record = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        $installPath = if ($record -and $record.PSObject.Properties['InstallPath']) { [string]$record.InstallPath } else { '' }
        if ($installPath) {
            $candidates.Add((Join-Path $installPath 'cmd\git.exe'))
        }
    }
    $candidates.Add((Join-Path $env:ProgramFiles 'Git\cmd\git.exe'))
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($command) {
        $candidates.Add($command.Source)
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        try {
            $versionText = [string](& $candidate --version 2>$null)
            if ($LASTEXITCODE -eq 0 -and $versionText) {
                return [pscustomobject]@{
                    Path = $candidate
                    VersionText = $versionText.Trim()
                }
            }
        }
        catch {}
    }
    return $null
}

function Get-GitUninstallEntry {
    $registryPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -match '^Git version ' -and
            -not [string]::IsNullOrWhiteSpace([string]$_.UninstallString)
        } |
        Select-Object -First 1
}

function Get-VirtualMachinePlatformState {
    try {
        return [string](Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State
    }
    catch {
        $feature = Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction SilentlyContinue
        if ($feature) {
            if ([int]$feature.InstallState -eq 1) { return 'Enabled' }
            if ([int]$feature.InstallState -eq 2) { return 'Disabled' }
        }
        $script:Warnings.Add("无法读取 VirtualMachinePlatform 状态：$($_.Exception.Message)")
        return 'Unknown'
    }
}

function Get-ReparseTarget {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        return $null
    }
    $targetProperty = $item.PSObject.Properties['Target']
    if ($null -eq $targetProperty -or $null -eq $targetProperty.Value) {
        return $null
    }
    $target = [string](@($targetProperty.Value)[0])
    if ([IO.Path]::IsPathRooted($target)) {
        return [IO.Path]::GetFullPath($target)
    }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Path) $target))
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )
    $firstPath = [IO.Path]::GetFullPath($First).TrimEnd('\')
    $secondPath = [IO.Path]::GetFullPath($Second).TrimEnd('\')
    return $firstPath.Equals($secondPath, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeClaudeRemovalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowedExact = @(
        $claudeUserDataPath,
        $claudeRoamingPath,
        $claudeRoaming3pPath,
        $claudePackageDataPath,
        $claudeServiceDataPath,
        $claudeLocalizationLegacyPath,
        $companyRoot
    )
    foreach ($allowed in $allowedExact) {
        if (Test-SamePath $resolved $allowed) {
            return
        }
    }
    $companyPrefix = [IO.Path]::GetFullPath($companyRoot).TrimEnd('\') + '\'
    if ($resolved.StartsWith($companyPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    throw "拒绝删除非 Claude 受管路径：$resolved"
}

function Get-NestedReparsePointsSafe {
    param([Parameter(Mandatory = $true)][string]$Path)

    $found = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push([IO.Path]::GetFullPath($Path))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $attributes = [IO.File]::GetAttributes($child)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $found.Add($child)
                continue
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push($child)
            }
        }
    }
    return $found.ToArray()
}

function Remove-LongDirectoryTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-SafeClaudeRemovalPath $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "长路径清理只接受普通目录：$Path"
    }
    $reparsePoints = @(Get-NestedReparsePointsSafe -Path $Path)
    if ($reparsePoints.Count -gt 0) {
        throw "目录内存在 $($reparsePoints.Count) 个重解析点，拒绝使用镜像清理以免越界：$Path"
    }

    $emptyRoot = Join-Path ([IO.Path]::GetTempPath()) ("Claude-Uninstall-Empty-{0}" -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $emptyRoot -Force)
    try {
        & robocopy.exe $emptyRoot $Path /MIR /XJ /SL /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        $code = $LASTEXITCODE
        if ($code -gt 7) {
            throw "robocopy 长路径清理返回代码 $code。"
        }
        [IO.Directory]::Delete($Path, $false)
    }
    finally {
        if (Test-Path -LiteralPath $emptyRoot) {
            [IO.Directory]::Delete($emptyRoot, $true)
        }
    }
}

function Remove-ExactPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-SafeClaudeRemovalPath $Path
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        try {
            $item = Get-Item -LiteralPath $Path -Force
            if ($item.PSIsContainer -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                [IO.Directory]::Delete($item.FullName)
            }
            else {
                if ($item.PSIsContainer) {
                    $nestedReparsePoints = @(Get-NestedReparsePointsSafe -Path $item.FullName)
                    if ($nestedReparsePoints.Count -gt 0) {
                        throw "目录内存在 $($nestedReparsePoints.Count) 个重解析点，拒绝递归删除：$Path"
                    }
                }
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            }
            if (-not (Test-Path -LiteralPath $Path)) {
                return
            }
            throw '删除后路径仍然存在。'
        }
        catch {
            $removeError = $_.Exception.Message
            if ($attempt -eq 1 -and (Test-Path -LiteralPath $Path -PathType Container)) {
                $remainingItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                if ($remainingItem -and (($remainingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
                    try {
                        Remove-LongDirectoryTree $Path
                        if (-not (Test-Path -LiteralPath $Path)) {
                            return
                        }
                    }
                    catch {
                        Write-Host "长路径清理未完成：$($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }
            }
            if ($attempt -ge 3) {
                throw "连续 3 次无法删除 $Path：$removeError"
            }
            Stop-ClaudeComponents
            Start-Sleep -Seconds 2
        }
    }
}

function Remove-PathSet {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Paths
    )
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($Paths) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        try {
            Write-Host "正在删除：$path" -ForegroundColor Cyan
            Remove-ExactPath $path
        }
        catch {
            $failures.Add("$path | $($_.Exception.Message)")
            Write-Host "删除失败：$path" -ForegroundColor Red
        }
    }
    return $failures.ToArray()
}

function Restore-PilotPatchSettings {
    param(
        $State,
        [switch]$ForcePilotDefaults
    )
    $patchState = Get-PropertyValue $State 'Patches'
    $effortChanged = [bool](Get-PropertyValue $patchState 'EffortLevelChangedByPilot' $false)
    $effortBefore = Get-PropertyValue $patchState 'EffortLevelBefore' $null
    $currentEffort = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'User')
    if ($effortChanged) {
        [Environment]::SetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', $effortBefore, 'User')
        Write-Host '已恢复部署前的 CLAUDE_CODE_EFFORT_LEVEL 用户环境变量。' -ForegroundColor Green
    }
    elseif ($ForcePilotDefaults -and $currentEffort -eq 'max') {
        [Environment]::SetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', $null, 'User')
        Write-Host '已清理旧版部署留下的 Flash Max 用户环境变量。' -ForegroundColor Green
    }
    elseif ($currentEffort -eq 'max') {
        $script:Warnings.Add('检测到 CLAUDE_CODE_EFFORT_LEVEL=max，但旧状态文件无法证明其归属，因此没有自动删除。')
    }

    $policyPath = 'HKCU:\SOFTWARE\Policies\Claude'
    $policyChanged = [bool](Get-PropertyValue $patchState 'AutoUpdatePolicyChangedByPilot' $false)
    $policyExistedBefore = [bool](Get-PropertyValue $patchState 'DisableAutoUpdatesExistedBefore' $false)
    $policyBefore = Get-PropertyValue $patchState 'DisableAutoUpdatesBefore' $null
    if ($policyChanged -and (Test-Path -LiteralPath $policyPath)) {
        if ($policyExistedBefore) {
            New-ItemProperty -LiteralPath $policyPath -Name 'disableAutoUpdates' -Value $policyBefore -PropertyType DWord -Force | Out-Null
        }
        else {
            Remove-ItemProperty -LiteralPath $policyPath -Name 'disableAutoUpdates' -ErrorAction SilentlyContinue
        }
        Write-Host '已恢复部署前的 Claude 自动更新策略。' -ForegroundColor Green
    }
    elseif ($ForcePilotDefaults -and (Test-Path -LiteralPath $policyPath)) {
        Remove-ItemProperty -LiteralPath $policyPath -Name 'disableAutoUpdates' -ErrorAction SilentlyContinue
    }
}

function Copy-DirectoryWithRobocopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        return
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Write-Host "正在备份：$Source" -ForegroundColor Cyan
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /MT:8 /NFL /NDL /NP
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw "备份失败：robocopy 返回代码 $code（$Source）。"
    }
}

function Stop-ClaudeComponents {
    $managedMcpServer = Join-Path $companyRoot 'MCP\Office\Office-McpServer.ps1'
    foreach ($process in Get-Process -Name claude -ErrorAction SilentlyContinue) {
        $path = ''
        try { $path = [string]$process.Path } catch {}
        if ($path -like '*\WindowsApps\Claude_*' -or
            $path -like "$claudeUserDataPath*" -or
            $path -like "$claudeUserDataLegacyDefaultTarget*") {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq 'powershell.exe' -and
            $_.CommandLine -and
            $_.CommandLine.IndexOf($managedMcpServer, [StringComparison]::OrdinalIgnoreCase) -ge 0
        } |
        ForEach-Object {
            Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
        }

    $service = Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue
    if ($service) {
        try {
            Stop-Service -Name CoworkVMService -Force -ErrorAction SilentlyContinue
            try { $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(15)) } catch {}
        }
        finally {
            $service.Dispose()
        }
    }
    Start-Sleep -Seconds 2
}

function Remove-ClaudeNativeMessagingKeys {
    $paths = @(
        'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_browser_extension',
        'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.anthropic.claude_browser_extension',
        'HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.anthropic.claude_browser_extension',
        'HKCU:\Software\Chromium\NativeMessagingHosts\com.anthropic.claude_browser_extension',
        'HKCU:\Software\ArcBrowser\Arc\NativeMessagingHosts\com.anthropic.claude_browser_extension',
        'HKCU:\Software\Vivaldi\NativeMessagingHosts\com.anthropic.claude_browser_extension',
        'HKCU:\Software\Opera Software\Opera Stable\NativeMessagingHosts\com.anthropic.claude_browser_extension'
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

function Uninstall-GitForWindows {
    param($GitInfo)
    $entry = Get-GitUninstallEntry
    if (-not $entry) {
        $script:Warnings.Add('用户选择卸载 Git，但没有找到官方 Git for Windows 卸载记录；未自动删除任何 Git 文件。')
        return $false
    }

    $uninstallString = [string]$entry.UninstallString
    $uninstaller = ''
    if ($uninstallString -match '^\s*"([^"]+\.exe)"') {
        $uninstaller = $matches[1]
    }
    elseif ($uninstallString -match '^\s*(.+?\.exe)(?:\s|$)') {
        $uninstaller = $matches[1].Trim()
    }
    if (-not $uninstaller -or -not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
        $script:Warnings.Add("Git 卸载程序不存在，未删除 Git：$uninstallString")
        return $false
    }
    if ([IO.Path]::GetFileName($uninstaller) -notmatch '^unins\d*\.exe$') {
        $script:Warnings.Add("Git 卸载程序名称异常，出于安全原因未执行：$uninstaller")
        return $false
    }

    if ($GitInfo) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $GitInfo.Path)
        $resolvedUninstaller = [IO.Path]::GetFullPath($uninstaller)
        $resolvedGitRoot = [IO.Path]::GetFullPath($gitRoot).TrimEnd('\') + '\'
        if (-not $resolvedUninstaller.StartsWith($resolvedGitRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $script:Warnings.Add("Git 卸载程序不在检测到的 Git 目录内，未执行：$uninstaller")
            return $false
        }
    }

    Write-Host "正在卸载 $($entry.DisplayName)：$uninstaller" -ForegroundColor Cyan
    $arguments = @('/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES')
    $process = Start-Process -FilePath $uninstaller -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        $script:Warnings.Add("Git 卸载程序返回代码 $($process.ExitCode)。")
        return $false
    }
    if ($process.ExitCode -eq 3010) {
        $script:RestartRequired = $true
    }
    Start-Sleep -Seconds 2
    return $true
}

function Invoke-ResidualCleanup {
    if ($Confirmation -cne 'PURGE-CLAUDE-RESIDUALS') {
        throw '残留清理模式需要显式确认令牌 PURGE-CLAUDE-RESIDUALS。'
    }
    if (@(Get-AppxPackage -AllUsers -Name Claude -ErrorAction SilentlyContinue).Count -gt 0) {
        throw '至少一个 Windows 用户仍注册 Claude Desktop；残留清理模式拒绝运行。'
    }
    if (Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue) {
        throw 'CoworkVMService 仍存在；残留清理模式拒绝运行，请先完成服务卸载或重启。'
    }

    Write-Host '=== Claude 已卸载后的残留清理 ===' -ForegroundColor Cyan
    Write-Host '只清理固定 Claude 路径；保留 Git 和 VirtualMachinePlatform。' -ForegroundColor DarkGray
    $state = Get-DeploymentState
    Stop-ClaudeComponents
    $targets = @(
        $claudeUserDataPath,
        $claudeRoamingPath,
        $claudeRoaming3pPath,
        $claudePackageDataPath,
        $claudeServiceDataPath,
        $claudeLocalizationLegacyPath,
        $companyRoot
    )
    $deleteFailures = @(Remove-PathSet -Paths $targets)
    Remove-ClaudeNativeMessagingKeys
    Restore-PilotPatchSettings -State $state -ForcePilotDefaults

    $remaining = @($targets | Where-Object { Test-Path -LiteralPath $_ })
    $rows = foreach ($target in $targets) {
        [pscustomobject]@{
            Path = $target
            Status = if (Test-Path -LiteralPath $target) { 'FAIL' } else { 'PASS' }
        }
    }
    $rows | Format-Table -AutoSize -Wrap
    if ($remaining.Count -gt 0 -or $deleteFailures.Count -gt 0) {
        $detail = if ($deleteFailures.Count -gt 0) { $deleteFailures -join '; ' } else { $remaining -join '; ' }
        throw "仍有 Claude 残留：$detail"
    }
    Remove-PilotDeploymentPointer
    Write-Host 'Claude 固定路径残留已清理；Git 与 VirtualMachinePlatform 未改动。' -ForegroundColor Green
}

if (-not $PlanOnly -and -not $AuditOnly -and -not (Test-IsAdministrator)) {
    Invoke-ElevatedSelf
}
Assert-ExpectedUser
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$rootOwnership = Get-PilotDataRootOwnership -DataRoot $companyRoot -ExpectedUserSid $currentSid
$isLegacyDefaultRoot = Test-SamePath $companyRoot 'D:\ClaudeDesktop'
if ($NonInteractive -and -not $rootOwnership.Trusted) {
    throw "R3 graphical uninstall requires a trusted deployment ownership record: $companyRoot ($($rootOwnership.Status))."
}
if ((Test-Path -LiteralPath $companyRoot) -and -not $rootOwnership.Trusted) {
    throw "部署目录归属无法验证，拒绝删除：$companyRoot（$($rootOwnership.Status)）。自定义路径必须同时具备匹配的指针、状态文件和归属标记。"
}
[void](Assert-PilotDataRootSafety -DataRoot $companyRoot -BundleRoot $bundleRoot -MinimumFreeBytes 0 -AllowExistingManaged -ExpectedUserSid $currentSid)

if ($PurgeResiduals) {
    try {
        Invoke-ResidualCleanup
        [IO.File]::WriteAllText($ResultPath, "PASS`r`n", (New-Object Text.UTF8Encoding($false)))
        exit 0
    }
    catch {
        $message = "FAIL`r`n$($_.Exception.Message)`r`n"
        try { [IO.File]::WriteAllText($ResultPath, $message, (New-Object Text.UTF8Encoding($false))) } catch {}
        Write-Error $_
        exit 2
    }
}

Write-Host '=== Claude Desktop 交互式完整卸载 ===' -ForegroundColor Cyan
Write-Host '本脚本只处理当前 Windows 用户部署的 Claude；不会读取或显示 API Key。' -ForegroundColor DarkGray
Write-Host "已识别数据根目录：$companyRoot（$($rootOwnership.Status)）" -ForegroundColor Cyan
if ($PlanOnly) {
    Write-Host '当前为仅预览模式：允许清点和选择，但不会停止进程、卸载或删除任何内容。' -ForegroundColor Yellow
}
if ($AuditOnly) {
    Write-Host '当前为只读发现模式：仅核对路径归属和组件状态，不进入任何删除提问。' -ForegroundColor Yellow
}

$state = Get-DeploymentState
$deploymentId = [string](Get-PropertyValue $state 'DeploymentId' '')
if (-not $deploymentId -and $rootOwnership.Marker) {
    $deploymentId = [string](Get-PropertyValue $rootOwnership.Marker 'DeploymentId' '')
}
$package = Get-ClaudePackage
$service = Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue
$legacyResidualOnly = (-not $state -and -not $package -and -not $service)
$git = Get-GitInfo
$vmpState = Get-VirtualMachinePlatformState
$reparseTarget = Get-ReparseTarget $claudeUserDataPath

$gitState = Get-PropertyValue $state 'Git'
$vmpStateRecord = Get-PropertyValue $state 'VirtualMachinePlatform'
$storageState = Get-PropertyValue $state 'Storage'
$gitInstalledByPilot = [bool](Get-PropertyValue $gitState 'InstalledByPilot' $false)
$gitPresentBefore = [bool](Get-PropertyValue $gitState 'PresentBefore' $false)
$vmpEnabledByPilot = [bool](Get-PropertyValue $vmpStateRecord 'EnabledByPilot' $false)
$recordedStorageLayout = [string](Get-PropertyValue $storageState 'Layout' '')
$recordedUserDataTarget = [string](Get-PropertyValue $storageState 'ClaudeUserDataTarget' '')
$recordedLegacyUserDataTarget = [string](Get-PropertyValue $storageState 'LegacyClaudeUserDataTarget' '')
if ([string]::IsNullOrWhiteSpace($recordedLegacyUserDataTarget) -and $recordedStorageLayout -eq 'ManagedJunction') {
    $recordedLegacyUserDataTarget = $recordedUserDataTarget
}
$managedLegacyUserDataTarget = $null
foreach ($candidate in @($reparseTarget, $recordedLegacyUserDataTarget)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    try {
        if (Test-SamePath ([string]$candidate) $claudeUserDataLegacyDefaultTarget) {
            $managedLegacyUserDataTarget = [IO.Path]::GetFullPath([string]$candidate)
            break
        }
    }
    catch {}
}
$profileSourcePath = if ($reparseTarget) { $reparseTarget } elseif (Test-Path -LiteralPath $claudeUserDataPath) { $claudeUserDataPath } elseif ($managedLegacyUserDataTarget) { $managedLegacyUserDataTarget } else { $claudeUserDataPath }
$profileBytes = (Get-PathSize $profileSourcePath) + (Get-PathSize $claudeRoamingPath) + (Get-PathSize $claudeRoaming3pPath) + (Get-PathSize $claudePackageDataPath)
$workBytes = Get-PathSize $coworkRoot

$rows = @(
    [pscustomobject]@{ Item = 'Claude Desktop'; Present = [bool]$package; Detail = if ($package) { "$($package.Version) | $($package.InstallLocation)" } else { '未安装或当前用户未注册' } },
    [pscustomobject]@{ Item = 'Cowork VM service'; Present = [bool]$service; Detail = if ($service) { [string]$service.Status } else { '未注册' } },
    [pscustomobject]@{ Item = 'Claude 用户配置/运行时'; Present = ($profileBytes -gt 0); Detail = "$(Format-ByteSize $profileBytes) | 逻辑=$claudeUserDataPath | 实际=$profileSourcePath" },
    [pscustomobject]@{ Item = '旧版 D 盘运行时副本'; Present = [bool]($managedLegacyUserDataTarget -and (Test-Path -LiteralPath $managedLegacyUserDataTarget)); Detail = if ($managedLegacyUserDataTarget) { $managedLegacyUserDataTarget } else { '未检测到受管旧副本' } },
    [pscustomobject]@{ Item = 'Cowork 工作文件'; Present = (Test-Path -LiteralPath $coworkRoot); Detail = "$(Format-ByteSize $workBytes) | $coworkRoot" },
    [pscustomobject]@{ Item = 'Git'; Present = [bool]$git; Detail = if ($git) { "$($git.VersionText) | $($git.Path) | 部署包首次安装=$gitInstalledByPilot" } else { '未检测到' } },
    [pscustomobject]@{ Item = 'VirtualMachinePlatform'; Present = ($vmpState -ne 'Disabled'); Detail = "$vmpState | 部署包启用=$vmpEnabledByPilot" }
)
$rows | Format-Table -AutoSize -Wrap
if ($service) {
    $service.Dispose()
    $service = $null
}
if ($reparseTarget) {
    Write-Host "Claude 用户目录当前是重解析链接，目标：$reparseTarget" -ForegroundColor Cyan
}
if (-not $state) {
    Write-Host '未找到 deployment-state.json：这可能是旧版部署。Git/VMP 将保持最保守的默认选项。' -ForegroundColor Yellow
}
if ($AuditOnly) {
    Write-Host '卸载发现检查完成；没有修改电脑。' -ForegroundColor Green
    exit 0
}

$preserveWork = ($NonInteractive -and $UninstallMode -eq 'PreserveWork')
if (-not $NonInteractive -and (Test-Path -LiteralPath $coworkRoot -PathType Container)) {
    $preserveWork = Read-YesNo "是否保留 $coworkRoot 中的用户工作文件？" $true
}

$preserveProfile = $false
$backupRoot = $null
if (-not $NonInteractive -and $profileBytes -gt 0) {
    Write-Host 'Claude 用户配置可能包含会话、Cookie 和 API Key；若选择保留，将完整复制后再删除活动目录。' -ForegroundColor Yellow
    $preserveProfile = Read-YesNo "是否另存一份完整 Claude 用户配置（约 $(Format-ByteSize $profileBytes)）？" $false
    if ($preserveProfile) {
        $dataVolumeRoot = [IO.Path]::GetPathRoot($companyRoot)
        $backupBase = if (Test-Path -LiteralPath $dataVolumeRoot) { Join-Path $dataVolumeRoot 'Claude-Uninstall-Backup' } else { Join-Path $env:USERPROFILE 'Documents\Claude-Uninstall-Backup' }
        $backupRoot = Join-Path $backupBase (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
}

$removeGit = $false
if ($git) {
    if ($gitPresentBefore -and -not $gitInstalledByPilot) {
        Write-Host '状态记录显示：部署前已经存在 Git。通常应保留。' -ForegroundColor Yellow
    }
    elseif ($gitInstalledByPilot) {
        Write-Host '状态记录显示：Git 是本部署包首次安装的，但仍可能已被其他软件使用。' -ForegroundColor Yellow
    }
    else {
        Write-Host '无法确认 Git 的安装归属。默认保留。' -ForegroundColor Yellow
    }
    if ($NonInteractive) {
        if ($RemoveGitRequested -and (-not $gitInstalledByPilot -or $gitPresentBefore)) {
            throw '状态记录不能证明 Git 由 R3 首次安装；拒绝非交互式卸载 Git。'
        }
        $removeGit = [bool]$RemoveGitRequested
    }
    else {
        $removeGit = Read-YesNo '是否同时卸载 Git for Windows？' $false
    }
}

$disableVmp = $false
if ($vmpState -in @('Enabled', 'EnablePending')) {
    Write-Host '关闭 VirtualMachinePlatform 会影响 WSL2、Docker Desktop、部分安卓模拟器及其他虚拟化软件。' -ForegroundColor Yellow
    if ($NonInteractive) {
        if ($DisableVmpRequested -and -not $vmpEnabledByPilot) {
            throw '状态记录不能证明 VirtualMachinePlatform 由 R3 启用；拒绝非交互式关闭。'
        }
        $disableVmp = [bool]$DisableVmpRequested
    }
    else {
        $disableVmp = Read-YesNo '是否同时关闭 VirtualMachinePlatform？' $false
    }
}

Write-Host ''
Write-Host '=== 即将执行的操作 ===' -ForegroundColor Cyan
Write-Host '- 卸载当前 Windows 用户的 Claude Desktop MSIX'
Write-Host '- 删除活动中的 DeepSeek 配置、Cowork 运行时、缓存、MCP、日志和补丁备份'
$workAction = if ($preserveWork) { "- 保留工作文件：$coworkRoot" } else { "- 删除工作文件：$coworkRoot" }
$profileAction = if ($preserveProfile) { "- 完整用户配置备份到：$backupRoot（其中可能含敏感凭据）" } else { '- 不保留 Claude 用户配置备份' }
$gitAction = if ($removeGit) { '- 卸载 Git for Windows' } else { '- 保留 Git' }
$vmpAction = if ($disableVmp) { '- 关闭 VirtualMachinePlatform，完成后必须重启' } else { '- 保留 VirtualMachinePlatform' }
Write-Host $workAction
Write-Host $profileAction
Write-Host $gitAction
Write-Host $vmpAction
Write-Host ''
if ($PlanOnly) {
    Write-Host '仅预览完成；没有修改电脑。去掉 -PlanOnly 后重新运行，才会要求输入 UNINSTALL 并执行。' -ForegroundColor Green
    exit 0
}
if ($NonInteractive) {
    if ($Confirmation -cne 'UNINSTALL') {
        throw 'Non-interactive uninstall requires the exact confirmation token UNINSTALL.'
    }
}
else {
    $confirmation = (Read-Host '确认以上清单后，输入 UNINSTALL 才会继续').Trim()
    if ($confirmation -cne 'UNINSTALL') {
        Write-Host '已取消；没有修改电脑。' -ForegroundColor Yellow
        exit 0
    }
}

Stop-ClaudeComponents
Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ClaudePilotR3Resume' -ErrorAction SilentlyContinue

if ($preserveProfile) {
    $requiredBytes = $profileBytes + 1GB
    $backupDriveName = ([IO.Path]::GetPathRoot($backupRoot)).TrimEnd('\').TrimEnd(':')
    $backupDrive = Get-PSDrive -Name $backupDriveName -ErrorAction Stop
    if ([int64]$backupDrive.Free -lt $requiredBytes) {
        throw "备份目标空间不足：需要至少 $(Format-ByteSize $requiredBytes)，可用 $(Format-ByteSize ([int64]$backupDrive.Free))。尚未卸载 Claude。"
    }
    Copy-DirectoryWithRobocopy $profileSourcePath (Join-Path $backupRoot 'Claude-3p')
    Copy-DirectoryWithRobocopy $claudeRoamingPath (Join-Path $backupRoot 'Roaming-Claude')
    Copy-DirectoryWithRobocopy $claudeRoaming3pPath (Join-Path $backupRoot 'Roaming-Claude-3p')
    Copy-DirectoryWithRobocopy $claudePackageDataPath (Join-Path $backupRoot 'PackageData-Claude_pzs8sxrjxfjjc')
    $backupMetadata = [ordered]@{
        CreatedAt = (Get-Date).ToString('o')
        WindowsUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        ContainsPotentialCredentials = $true
        Sources = @($profileSourcePath, $claudeRoamingPath, $claudeRoaming3pPath, $claudePackageDataPath)
    }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $backupRoot 'BACKUP-INFO.json'), ($backupMetadata | ConvertTo-Json -Depth 5) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

$package = Get-ClaudePackage
if ($package) {
    Write-Host "正在卸载 Claude Desktop $($package.Version)..." -ForegroundColor Cyan
    Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
}

$remainingAllUserPackages = @(Get-AppxPackage -AllUsers -Name Claude -ErrorAction SilentlyContinue)
$removeSharedClaudeData = ($remainingAllUserPackages.Count -eq 0)
if ($remainingAllUserPackages.Count -eq 0) {
    $remainingService = Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue
    if ($remainingService) {
        Stop-Service -Name CoworkVMService -Force -ErrorAction SilentlyContinue
        try { $remainingService.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(15)) } catch {}
        $remainingService.Dispose()
        & sc.exe delete CoworkVMService | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $script:ServiceDeletionPending = $true
            $script:RestartRequired = $true
        }
        else {
            $script:Warnings.Add("CoworkVMService 自动删除失败，sc.exe 返回代码 $LASTEXITCODE。")
        }
    }
}
else {
    $script:Warnings.Add('其他 Windows 用户仍注册了 Claude，因此没有强制删除共享 CoworkVMService；需登录对应账号分别卸载。')
    $script:Warnings.Add("其他 Windows 用户仍注册了 Claude，因此保留共享服务数据：$claudeServiceDataPath")
}
Stop-ClaudeComponents

if ($reparseTarget -and -not $managedLegacyUserDataTarget) {
    $script:Warnings.Add("Claude-3p 指向非受管目标；只移除链接，不自动删除目标：$reparseTarget")
}

$dataDeleteFailures = @(Remove-PathSet -Paths @(
    $claudeUserDataPath,
    $managedLegacyUserDataTarget,
    $claudeRoamingPath,
    $claudeRoaming3pPath,
    $claudePackageDataPath,
    $(if ($removeSharedClaudeData) { $claudeServiceDataPath }),
    $claudeLocalizationLegacyPath
))
foreach ($failure in $dataDeleteFailures) {
    $script:Warnings.Add("删除失败：$failure")
}
Remove-ClaudeNativeMessagingKeys
Restore-PilotPatchSettings -State $state -ForcePilotDefaults:$legacyResidualOnly

if (Test-Path -LiteralPath $companyRoot -PathType Container) {
    if ($preserveWork) {
        $nonWorkPaths = @(
            Get-ChildItem -LiteralPath $companyRoot -Force |
                Where-Object { $_.Name -notin @('Cowork', '.claude-pilot-r3-managed.json') } |
                ForEach-Object { $_.FullName }
        )
        $nonWorkFailures = @(Remove-PathSet -Paths $nonWorkPaths)
        foreach ($failure in $nonWorkFailures) {
            $script:Warnings.Add("删除失败：$failure")
        }
        if ($nonWorkFailures.Count -eq 0) {
            if (-not $deploymentId) {
                $deploymentId = [Guid]::NewGuid().ToString('D')
            }
            Write-PilotPreservedWorkMarker -DataRoot $companyRoot -DeploymentId $deploymentId -WindowsUserSid $currentSid
        }
    }
    else {
        foreach ($failure in @(Remove-PathSet -Paths @($companyRoot))) {
            $script:Warnings.Add("删除失败：$failure")
        }
        if (-not (Test-Path -LiteralPath $companyRoot)) {
            Remove-PilotDeploymentPointer
        }
    }
}
elseif (-not $preserveWork) {
    Remove-PilotDeploymentPointer
}

if (-not $preserveWork) {
    $consentPath = Join-Path $env:LOCALAPPDATA 'ClaudePilotR3\ui-consent.json'
    Remove-Item -LiteralPath $consentPath -Force -ErrorAction SilentlyContinue
    $consentParent = Split-Path -Parent $consentPath
    if (Test-Path -LiteralPath $consentParent -PathType Container) {
        $remainingConsentItems = Get-ChildItem -LiteralPath $consentParent -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $remainingConsentItems) {
            Remove-Item -LiteralPath $consentParent -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($removeGit) {
    [void](Uninstall-GitForWindows $git)
}

if ($disableVmp) {
    Write-Host '正在关闭 VirtualMachinePlatform...' -ForegroundColor Cyan
    $featureResult = Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
    if ([bool]$featureResult.RestartNeeded) {
        $script:RestartRequired = $true
    }
    else {
        $script:RestartRequired = $true
    }
}

$packageRemaining = [bool](Get-ClaudePackage)
$serviceRemaining = [bool](Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue)
$activeDataRemaining = @(
    $claudeUserDataPath,
    $managedLegacyUserDataTarget,
    $claudeRoamingPath,
    $claudeRoaming3pPath,
    $claudePackageDataPath,
    $(if ($removeSharedClaudeData) { $claudeServiceDataPath }),
    $claudeLocalizationLegacyPath
) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath $_) }
$gitRemaining = [bool](Get-GitInfo)
$vmpAfter = Get-VirtualMachinePlatformState
$workStatus = if ($preserveWork) {
    if (Test-Path -LiteralPath $coworkRoot) { 'KEEP' } else { 'WARN' }
}
else {
    if (Test-Path -LiteralPath $coworkRoot) { 'FAIL' } else { 'PASS' }
}
$companyResiduals = if ($preserveWork -and (Test-Path -LiteralPath $companyRoot -PathType Container)) {
    @(Get-ChildItem -LiteralPath $companyRoot -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Cowork', '.claude-pilot-r3-managed.json') })
}
elseif (-not $preserveWork -and (Test-Path -LiteralPath $companyRoot)) {
    @((Get-Item -LiteralPath $companyRoot -Force))
}
else {
    @()
}

$verification = @(
    [pscustomobject]@{ Item = 'Claude 当前用户包'; Status = if ($packageRemaining) { 'FAIL' } else { 'PASS' }; Detail = if ($packageRemaining) { '仍已注册' } else { '未注册' } },
    [pscustomobject]@{ Item = 'CoworkVMService'; Status = if ($serviceRemaining -and $script:ServiceDeletionPending) { 'RESTART' } elseif ($serviceRemaining -and $remainingAllUserPackages.Count -eq 0) { 'FAIL' } elseif ($serviceRemaining) { 'KEEP' } else { 'PASS' }; Detail = if ($serviceRemaining -and $script:ServiceDeletionPending) { '已标记删除，重启后复核' } elseif ($serviceRemaining) { '仍存在' } else { '不存在' } },
    [pscustomobject]@{ Item = '活动 Claude 数据'; Status = if (@($activeDataRemaining).Count -gt 0) { 'FAIL' } else { 'PASS' }; Detail = if (@($activeDataRemaining).Count -gt 0) { $activeDataRemaining -join '; ' } else { '已清除' } },
    [pscustomobject]@{ Item = '共享 Claude 服务数据'; Status = if ($removeSharedClaudeData -and (Test-Path -LiteralPath $claudeServiceDataPath)) { 'FAIL' } elseif ($removeSharedClaudeData) { 'PASS' } else { 'KEEP' }; Detail = $claudeServiceDataPath },
    [pscustomobject]@{ Item = 'Cowork 工作文件'; Status = $workStatus; Detail = if ($preserveWork) { $coworkRoot } else { '按用户选择删除' } },
    [pscustomobject]@{ Item = '数据盘部署目录'; Status = if (@($companyResiduals).Count -gt 0) { 'FAIL' } elseif ($preserveWork) { 'KEEP' } else { 'PASS' }; Detail = if (@($companyResiduals).Count -gt 0) { (@($companyResiduals | ForEach-Object { $_.FullName }) -join '; ') } elseif ($preserveWork) { '仅保留 Cowork 与归属标记' } else { '已清除' } },
    [pscustomobject]@{ Item = '部署路径指针'; Status = if ($preserveWork -and (Test-Path -LiteralPath $deploymentPointerPath)) { 'KEEP' } elseif (Test-Path -LiteralPath $deploymentPointerPath) { 'FAIL' } else { 'PASS' }; Detail = $deploymentPointerPath },
    [pscustomobject]@{ Item = 'Claude 配置备份'; Status = if ($preserveProfile -and (Test-Path -LiteralPath $backupRoot)) { 'KEEP' } elseif ($preserveProfile) { 'FAIL' } else { 'PASS' }; Detail = if ($preserveProfile) { [string]$backupRoot } else { '未保留' } },
    [pscustomobject]@{ Item = 'Git'; Status = if ($removeGit -and $gitRemaining) { 'WARN' } elseif ($removeGit) { 'PASS' } else { 'KEEP' }; Detail = if ($gitRemaining) { (Get-GitInfo).Path } else { '未检测到' } },
    [pscustomobject]@{ Item = 'VirtualMachinePlatform'; Status = if ($disableVmp -and $vmpAfter -notin @('Disabled', 'DisablePending')) { 'WARN' } elseif ($disableVmp) { 'PASS' } else { 'KEEP' }; Detail = $vmpAfter }
)

Write-Host ''
Write-Host '=== 卸载验收 ===' -ForegroundColor Cyan
$verification | Format-Table -AutoSize -Wrap
foreach ($warning in $script:Warnings) {
    Write-Host "WARN: $warning" -ForegroundColor Yellow
}
Write-Host '本机配置被删除并不等于云端 Key 失效；不再使用此电脑时，请在 DeepSeek 后台撤销该设备专用 Key。' -ForegroundColor Yellow

$failed = @($verification | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0
$warned = @($verification | Where-Object { $_.Status -eq 'WARN' }).Count -gt 0 -or $script:Warnings.Count -gt 0
if ($script:RestartRequired) {
    Write-Host '需要重启 Windows 才能完成服务或虚拟机平台状态变更。' -ForegroundColor Yellow
}
if ($failed) {
    exit 2
}
if ($warned) {
    # Exit 3 is reserved for a completed uninstall with non-fatal warnings.
    # Exit 1 remains an unexpected PowerShell/process failure and must never be
    # presented by the graphical launcher as a successful uninstall.
    exit 3
}
Write-Host 'Claude Desktop 当前用户部署已按所选范围清理完成。' -ForegroundColor Green
exit 0
