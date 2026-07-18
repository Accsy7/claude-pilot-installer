[CmdletBinding()]
param(
    [string]$ExpectedUserSid = '',

    [string]$DataRoot = '',

    [switch]$AuditOnly,

    [switch]$NoLaunch
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

$paths = Resolve-PilotDeploymentPaths -BundleRoot $bundleRoot -RequestedDataRoot $DataRoot -Mode Uninstall
$logicalPath = Join-Path $env:LOCALAPPDATA 'Claude-3p'
$legacyTarget = $paths.ClaudeUserDataTarget
$statePath = $paths.StatePath
$logRoot = Join-Path $paths.DataRoot 'Logs'
$minimumFreeBytes = 20GB
$script:ServiceWasRunning = $false

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
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-Argument $PSCommandPath) -ExpectedUserSid $(Quote-Argument $sid) -DataRoot $(Quote-Argument $paths.DataRoot)"
    if ($NoLaunch) { $arguments += ' -NoLaunch' }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

function Assert-ExpectedUser {
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid)) { return }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($currentSid -ne $ExpectedUserSid) {
        throw 'UAC 切换到了另一个 Windows 账号。为避免迁移错误用户的 Claude 数据，修复已停止。请让实际使用 Claude 的账号临时具备管理员权限。'
    }
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )
    $a = [IO.Path]::GetFullPath($First).TrimEnd('\')
    $b = [IO.Path]::GetFullPath($Second).TrimEnd('\')
    return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ReparseTarget {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) { return $null }
    $property = $item.PSObject.Properties['Target']
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    $target = [string](@($property.Value)[0])
    if ([string]::IsNullOrWhiteSpace($target)) { return $null }
    if ([IO.Path]::IsPathRooted($target)) { return [IO.Path]::GetFullPath($target) }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Path) $target))
}

function Get-LayoutInfo {
    $item = Get-Item -LiteralPath $logicalPath -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        return [pscustomobject]@{ Status = 'Missing'; Ready = $false; Target = ''; Detail = $logicalPath }
    }
    if (-not $item.PSIsContainer) {
        return [pscustomobject]@{ Status = 'PathIsFile'; Ready = $false; Target = ''; Detail = $logicalPath }
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        return [pscustomobject]@{ Status = 'PhysicalLocalAppData'; Ready = $true; Target = $logicalPath; Detail = $logicalPath }
    }
    $target = Get-ReparseTarget $logicalPath
    if ($target -and (Test-SamePath $target $legacyTarget) -and (Test-Path -LiteralPath $legacyTarget -PathType Container)) {
        return [pscustomobject]@{ Status = 'LegacyManagedJunction'; Ready = $false; Target = $target; Detail = "$logicalPath -> $target" }
    }
    return [pscustomobject]@{ Status = 'ForeignOrBrokenLink'; Ready = $false; Target = [string]$target; Detail = if ($target) { "$logicalPath -> $target" } else { "$logicalPath 的链接目标无法读取" } }
}

function Stop-ClaudeComponents {
    foreach ($process in Get-Process -Name claude -ErrorAction SilentlyContinue) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch {}
    }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*Office-McpServer.ps1*' } |
        ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null }

    $service = Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue
    if ($service) {
        $script:ServiceWasRunning = ($service.Status -eq 'Running')
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name CoworkVMService -Force -ErrorAction Stop
            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
        }
        $service.Dispose()
    }
    Start-Sleep -Seconds 2
}

function Start-ClaudeComponents {
    $service = Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Running') {
        try {
            Start-Service -Name CoworkVMService -ErrorAction Stop
            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
        }
        catch {
            Write-Warning "CoworkVMService 暂未启动：$($_.Exception.Message)。如果刚启用 VirtualMachinePlatform，请先重启 Windows。"
        }
        finally {
            $service.Dispose()
        }
    }
    if (-not $NoLaunch -and (Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe -ArgumentList 'shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude'
    }
}

function Set-ClaudeRuntimeAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    foreach ($identity in @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'))
    )) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $full, $inheritance, $propagation, $allow)
        $acl.SetAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function Update-DeploymentStorageState {
    $state = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    else { $null }
    if (-not $state) {
        Write-Warning "未找到部署状态记录，存储已经修复，但没有更新状态文件：$statePath"
        return
    }
    if ($null -eq $state.PSObject.Properties['Storage']) {
        Set-JsonProperty $state 'Storage' ([pscustomobject]@{})
    }
    Set-JsonProperty $state 'SchemaVersion' 6
    Set-JsonProperty $state.Storage 'CompanyRoot' $paths.DataRoot
    Set-JsonProperty $state.Storage 'DataRoot' $paths.DataRoot
    Set-JsonProperty $state.Storage 'CoworkWorkFiles' $paths.CoworkRoot
    Set-JsonProperty $state.Storage 'Layout' 'PhysicalLocalAppData'
    Set-JsonProperty $state.Storage 'ClaudeUserDataPath' $logicalPath
    Set-JsonProperty $state.Storage 'ClaudeUserDataTarget' $logicalPath
    Set-JsonProperty $state.Storage 'LegacyClaudeUserDataTarget' $legacyTarget
    Set-JsonProperty $state.Storage 'LegacyCopyPreserved' (Test-Path -LiteralPath $legacyTarget -PathType Container)
    Set-JsonProperty $state.Storage 'LegacyCopyPreservedAt' (Get-Date).ToString('o')
    Set-JsonProperty $state.Storage 'LinkCreatedByPilot' $false
    Set-JsonProperty $state.Storage 'LocalDataCreatedByPilot' $true
    Set-JsonProperty $state.Storage 'TargetFileSystem' 'NTFS'
    Set-JsonProperty $state.Storage 'StorageReadyAt' (Get-Date).ToString('o')
    Write-PilotJsonAtomic -Path $statePath -Value $state
    $deploymentId = [string](Get-PilotPropertyValue $state 'DeploymentId' '')
    $sid = [string](Get-PilotPropertyValue $state 'WindowsUserSid' '')
    if ($deploymentId -and $sid) {
        Write-PilotDeploymentMetadata -DataRoot $paths.DataRoot -StatePath $statePath -DeploymentId $deploymentId -WindowsUserSid $sid
    }
}

function Invoke-RobocopyPass {
    param([switch]$ListOnly)
    $arguments = @($legacyTarget, $logicalPath, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:1', '/XJ', '/SL', '/MT:8', '/NFL', '/NDL', '/NP')
    if ($ListOnly) {
        $arguments += @('/L', '/NJH', '/NJS')
    }
    & robocopy.exe @arguments | Out-Host
    $code = [int]$LASTEXITCODE
    return $code
}

function Write-RepairReport {
    param([string]$Status, [string]$Detail)
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $report = [ordered]@{
        CompletedAt = (Get-Date).ToString('o')
        Status = $Status
        Detail = $Detail
        WindowsUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        ActivePath = $logicalPath
        ActiveLayout = 'PhysicalLocalAppData'
        LegacyCopy = $legacyTarget
        LegacyCopyPreserved = (Test-Path -LiteralPath $legacyTarget -PathType Container)
        ApiKeyRecorded = $false
    }
    $reportPath = Join-Path $logRoot ("cowork-storage-repair-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-PilotJsonAtomic -Path $reportPath -Value $report
    Write-Host "脱敏修复报告：$reportPath" -ForegroundColor Green
}

Write-Host '=== Claude Cowork 存储兼容修复 ===' -ForegroundColor Cyan
Write-Host '本脚本不会读取或显示 API Key；D 盘旧副本在 Cowork 验收前不会删除。' -ForegroundColor DarkGray
Write-Host "活动路径：$logicalPath"
Write-Host "旧版数据盘目标：$legacyTarget"

$layout = Get-LayoutInfo
Write-Host "当前布局：$($layout.Status) | $($layout.Detail)"
if ($AuditOnly) {
    if ($layout.Status -eq 'LegacyManagedJunction') { exit 1 }
    if ($layout.Status -eq 'PhysicalLocalAppData') { exit 0 }
    exit 2
}

if (-not (Test-IsAdministrator)) {
    Invoke-ElevatedSelf
}
Assert-ExpectedUser

if ($layout.Status -eq 'PhysicalLocalAppData') {
    Set-ClaudeRuntimeAcl -Path $logicalPath
    Update-DeploymentStorageState
    Write-RepairReport -Status 'AlreadyRepaired' -Detail '活动目录已经是 C 盘真实目录。'
    Start-ClaudeComponents
    Write-Host 'Cowork 活动目录已经是受支持的真实目录，无需复制。' -ForegroundColor Green
    exit 0
}
if ($layout.Status -ne 'LegacyManagedJunction') {
    throw "拒绝自动修复不受管布局：$($layout.Detail)"
}

$driveRoot = [IO.Path]::GetPathRoot($logicalPath).TrimEnd('\')
$escapedDrive = $driveRoot.Replace("'", "''")
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$escapedDrive'" -ErrorAction Stop
if ([int]$disk.DriveType -ne 3 -or [string]$disk.FileSystem -ne 'NTFS') {
    throw "$driveRoot 必须是本地固定 NTFS 磁盘。"
}
if ([int64]$disk.FreeSpace -lt $minimumFreeBytes) {
    throw ('C 盘空间不足。安全迁回至少要求 {0:N0} GB，当前仅 {1:N1} GB。' -f ($minimumFreeBytes / 1GB), ([int64]$disk.FreeSpace / 1GB))
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$renamedLink = "$logicalPath.legacy-junction-$stamp"
$failedCopy = "$logicalPath.failed-copy-$stamp"
$cutoverComplete = $false
$renamed = $false
$createdPhysical = $false

try {
    Stop-ClaudeComponents
    $layout = Get-LayoutInfo
    if ($layout.Status -ne 'LegacyManagedJunction' -or -not (Test-SamePath $layout.Target $legacyTarget)) {
        throw "停止组件后联接状态发生变化，拒绝继续：$($layout.Detail)"
    }
    if (Test-Path -LiteralPath $renamedLink) { throw "临时联接路径已存在：$renamedLink" }

    [IO.Directory]::Move($logicalPath, $renamedLink)
    $renamed = $true
    $renamedTarget = Get-ReparseTarget $renamedLink
    if (-not $renamedTarget -or -not (Test-SamePath $renamedTarget $legacyTarget)) {
        throw '联接改名后的目标校验失败。'
    }
    if (-not (Test-Path -LiteralPath $legacyTarget -PathType Container)) {
        throw '联接改名后 D 盘源目录丢失。'
    }

    New-Item -ItemType Directory -Path $logicalPath -Force | Out-Null
    $createdPhysical = $true
    Set-ClaudeRuntimeAcl -Path $logicalPath

    Write-Host '正在把 Cowork 运行时复制回 C 盘真实目录；D 盘源数据保持不变。' -ForegroundColor Cyan
    $copyCode = Invoke-RobocopyPass
    if ($copyCode -gt 7) { throw "robocopy 复制失败，返回代码 $copyCode。" }

    $verifyCode = Invoke-RobocopyPass -ListOnly
    if ($verifyCode -ne 0) {
        throw "复制后差异校验未通过，robocopy 列表模式返回代码 $verifyCode。"
    }

    $activeItem = Get-Item -LiteralPath $logicalPath -Force
    if (($activeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw '复制目标仍是重解析点，拒绝切换。'
    }
    if (-not (Test-Path -LiteralPath $legacyTarget -PathType Container)) {
        throw '复制后 D 盘源目录丢失，拒绝切换。'
    }

    [IO.Directory]::Delete($renamedLink, $false)
    $renamed = $false
    if (-not (Test-Path -LiteralPath $legacyTarget -PathType Container)) {
        throw '移除旧联接后 D 盘源数据不可见。'
    }
    $cutoverComplete = $true

    Set-ClaudeRuntimeAcl -Path $logicalPath
    Update-DeploymentStorageState
    Write-RepairReport -Status 'Repaired' -Detail 'Cowork 活动目录已迁回 C 盘真实目录，D 盘旧副本保留待验收。'
    Start-ClaudeComponents

    Write-Host ''
    Write-Host '修复完成：Cowork 活动目录现在是 C 盘真实目录。' -ForegroundColor Green
    Write-Host "D 盘旧副本仍保留：$legacyTarget" -ForegroundColor Yellow
    Write-Host '请先完成 Cowork 真实任务验收；在明确确认前不要删除旧副本。' -ForegroundColor Yellow
}
catch {
    $failure = $_
    if (-not $cutoverComplete -and $renamed -and (Test-Path -LiteralPath $renamedLink)) {
        try {
            if ($createdPhysical -and (Test-Path -LiteralPath $logicalPath)) {
                [IO.Directory]::Move($logicalPath, $failedCopy)
            }
            [IO.Directory]::Move($renamedLink, $logicalPath)
            Write-Host "修复失败，旧联接已恢复。未完成副本如存在位于：$failedCopy" -ForegroundColor Yellow
            Start-ClaudeComponents
        }
        catch {
            Write-Warning "自动回滚未完成：$($_.Exception.Message)"
        }
    }
    throw $failure
}
