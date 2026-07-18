[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Full', 'Preflight', 'Install', 'Configure', 'OptionalPatches', 'Verify')]
    [string]$Stage = 'Menu',

    [string]$ExpectedUserSid = '',

    [string]$DataRoot = '',

    [string]$SettingsPath = '',

    [string]$ApiKeyBlobPath = '',

    [switch]$NonInteractive,

    [switch]$ForceReinstall,

    [ValidateSet('Block', 'Allow')]
    [string]$UpdatePolicy = 'Block'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Security

$resourcesRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bundleRoot = $resourcesRoot
$pathModule = Join-Path $PSScriptRoot 'Deployment-Paths.ps1'
if (-not (Test-Path -LiteralPath $pathModule -PathType Leaf)) {
    throw "Missing deployment path module: $pathModule"
}
. $pathModule
$deploymentPaths = Resolve-PilotDeploymentPaths -BundleRoot $bundleRoot -RequestedDataRoot $DataRoot -SettingsPath $SettingsPath -Mode Install
$msixPath = Join-Path $resourcesRoot 'Claude\Claude-Desktop-x64.msix'
$expectedMsixHash = '893338C84197D717B65123F4BC2A43BE1F7F3541192FD556B9B8EEB7F8CB3A7C'
$expectedClaudeVersion = '1.21459.3.0'
$validatedPatchVersions = @('1.21459.3.0', '1.22209.0.0')
$gitInstallerPath = Join-Path $resourcesRoot 'Git\Git-2.55.0.3-64-bit.exe'
$expectedGitInstallerHash = 'AF12577D0FDFF74243A5988197AA49B957D5044EDC17004F6DDF0768996F1DCA'
$expectedGitVersion = [version]'2.55.0.3'
$companyRoot = $deploymentPaths.DataRoot
$coworkRoot = $deploymentPaths.CoworkRoot
$runtimeRoot = $deploymentPaths.RuntimeRoot
$claudeUserDataLink = Join-Path $env:LOCALAPPDATA 'Claude-3p'
$claudeUserDataTarget = $claudeUserDataLink
$legacyClaudeUserDataTarget = $deploymentPaths.ClaudeUserDataTarget
$logRoot = Join-Path $companyRoot 'Logs'
$deploymentStatePath = $deploymentPaths.StatePath
$deploymentMarkerPath = $deploymentPaths.MarkerPath
$deploymentPointerPath = $deploymentPaths.PointerPath
$coworkSeedRoot = Join-Path $resourcesRoot 'Cowork\claudevm.bundle'
$coworkSeedVersion = '6d1538ba6fecc4e5c5583993c4b30bb1875f0f5a'
$coworkCodeRoot = Join-Path $resourcesRoot 'Cowork'
$coworkCodeVersion = '2.1.209'
$coworkMinimumFreeBytes = 15GB
$claudeStorageMinimumFreeBytes = 20GB
$dataRootMinimumFreeBytes = 5GB
$script:SensitiveApiKey = ''
$coworkSeedFiles = @(
    [pscustomobject]@{ Name = 'rootfs.vhdx.zst'; Size = [int64]1336068767; Sha256 = '21237CA86D15885ED7DCBE1C66B8B3A464C914648B16300070B12B1E1212E451' },
    [pscustomobject]@{ Name = 'initrd.zst'; Size = [int64]74332074; Sha256 = '20214EFCD451B3B74DC53ED80218C6E616BB2A101CAFB18BC2C9BC91E559926B' },
    [pscustomobject]@{ Name = 'vmlinuz.zst'; Size = [int64]14745575; Sha256 = '1BB4BC3AA0C0C797A2CA6134D2B7034A196E05D4DEEA7BB20F064EE353781F3B' }
)
$coworkCodeFiles = @(
    [pscustomobject]@{ RelativePath = 'claude-code\2.1.209\.verified'; Size = [int64]64; Sha256 = '4A11FD2CE71728A6DC60410D816DFACD5F3DB6DB5B5C361ACE81357613A7677A' },
    [pscustomobject]@{ RelativePath = 'claude-code\2.1.209\claude.exe'; Size = [int64]251303072; Sha256 = 'B9D5E8542338A0918534E55D046A7C960AE4AF5EE214C7E4E80A89067B63EA2C' },
    [pscustomobject]@{ RelativePath = 'claude-code-vm\.sdk-version'; Size = [int64]7; Sha256 = '1BA363D36FE67BF6BA68B82E8291032AA126E69AB819E3C3A0855200B833DE6C' },
    [pscustomobject]@{ RelativePath = 'claude-code-vm\2.1.209\.verified'; Size = [int64]64; Sha256 = 'FCC6175028D7B9955021D668B68DF01F7767E98B63407190D30BAD097E22A04F' },
    [pscustomobject]@{ RelativePath = 'claude-code-vm\2.1.209\claude'; Size = [int64]259951416; Sha256 = 'B882F4B8B27772F897540DF50F24000206F43A9426E8F7D19BD065959B69E9DD' }
)

function Protect-DeploymentMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return '' }
    $safe = $Message
    if (-not [string]::IsNullOrWhiteSpace($script:SensitiveApiKey)) {
        $safe = $safe.Replace($script:SensitiveApiKey, '[REDACTED-KEY]')
    }
    $safe = [regex]::Replace($safe, '(?i)(Bearer\s+)[^\s,;]+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)sk-[A-Za-z0-9_-]{8,}', '[REDACTED-KEY]')
    $safe = [regex]::Replace($safe, '(?i)(api[_ -]?key\s*[:=]\s*)[^\s,;]+', '$1[REDACTED]')
    return $safe
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

function Invoke-ElevatedStage {
    param([Parameter(Mandatory = $true)][string]$TargetStage)
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-Argument $PSCommandPath) -Stage $TargetStage -ExpectedUserSid $(Quote-Argument $currentSid) -DataRoot $(Quote-Argument $companyRoot) -UpdatePolicy $UpdatePolicy"
    if (-not [string]::IsNullOrWhiteSpace($ApiKeyBlobPath)) {
        $arguments += " -ApiKeyBlobPath $(Quote-Argument $ApiKeyBlobPath)"
    }
    if ($NonInteractive) {
        $arguments += ' -NonInteractive'
    }
    if ($ForceReinstall) {
        $arguments += ' -ForceReinstall'
    }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "管理员阶段 $TargetStage 未成功完成，返回代码 $($process.ExitCode)。"
    }
}

function Assert-ExpectedUser {
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid)) {
        return
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($currentSid -ne $ExpectedUserSid) {
        throw 'UAC switched to a different Windows account. To prevent writing the API key into the administrator profile, deployment was stopped. Make the pilot account a temporary administrator or use the staged deployment procedure.'
    }
}

function Get-ClaudePackage {
    return Get-AppxPackage -Name Claude | Sort-Object Version -Descending | Select-Object -First 1
}

function Get-CoworkBundlePath {
    return Join-Path (Get-ClaudeUserDataPath) 'vm_bundles\claudevm.bundle'
}

function Get-ClaudeUserDataPath {
    return $claudeUserDataLink
}

function Get-ClaudeUserDataTargetPath {
    return $claudeUserDataTarget
}

function Get-ReparseTarget {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
        return $null
    }
    $targetProperty = $item.PSObject.Properties['Target']
    if ($null -eq $targetProperty -or $null -eq $targetProperty.Value) {
        return $null
    }
    $target = [string](@($targetProperty.Value)[0])
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }
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

function Test-DirectoryEmpty {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }
    return ($null -eq (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Select-Object -First 1))
}

function Get-ClaudeStorageDriveInfo {
    $deviceId = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($claudeUserDataLink)).TrimEnd('\')
    $escapedDeviceId = $deviceId.Replace("'", "''")
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$escapedDeviceId'" -ErrorAction SilentlyContinue
    if (-not $disk) {
        return $null
    }
    return [pscustomobject]@{
        DeviceId = [string]$disk.DeviceID
        DriveType = [int]$disk.DriveType
        FileSystem = [string]$disk.FileSystem
        FreeBytes = [int64]$disk.FreeSpace
    }
}

function Get-ClaudeUserDataLayoutInfo {
    $logicalItem = Get-Item -LiteralPath $claudeUserDataLink -Force -ErrorAction SilentlyContinue

    if ($logicalItem) {
        if (($logicalItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $actualTarget = Get-ReparseTarget $claudeUserDataLink
            if ($actualTarget -and (Test-SamePath $actualTarget $legacyClaudeUserDataTarget) -and
                (Test-Path -LiteralPath $legacyClaudeUserDataTarget -PathType Container)) {
                return [pscustomobject]@{
                    Ready = $false
                    Status = 'LegacyManagedJunction'
                    Detail = "$claudeUserDataLink -> $legacyClaudeUserDataTarget；Cowork 拒绝打开联接路径，请先运行根目录的 REPAIR-COWORK-STORAGE.cmd"
                }
            }
            return [pscustomobject]@{
                Ready = $false
                Status = 'ForeignOrBrokenLink'
                Detail = if ($actualTarget) { "$claudeUserDataLink -> $actualTarget" } else { "$claudeUserDataLink 的链接目标无法读取" }
            }
        }
        if (-not $logicalItem.PSIsContainer) {
            return [pscustomobject]@{ Ready = $false; Status = 'LogicalPathIsFile'; Detail = "$claudeUserDataLink 不是目录" }
        }
        return [pscustomobject]@{
            Ready = $true
            Status = 'PhysicalLocalAppData'
            Detail = "$claudeUserDataLink 是普通实体目录"
        }
    }

    return [pscustomobject]@{
        Ready = $true
        Status = 'FreshPhysicalDirectory'
        Detail = "$claudeUserDataLink 将创建为普通实体目录；不会建立符号链接或目录联接"
    }
}

function Assert-ClaudeStoragePreflight {
    $disk = Get-ClaudeStorageDriveInfo
    if (-not $disk) {
        throw "无法读取 $claudeUserDataLink 所在系统盘。"
    }
    if ($disk.DriveType -ne 3) {
        throw "$($disk.DeviceId) 不是固定本地磁盘，Cowork 运行时不能安全部署。"
    }
    if ($disk.FileSystem -ne 'NTFS') {
        throw "$($disk.DeviceId) 文件系统是 $($disk.FileSystem)，不是 NTFS。"
    }
    if ($disk.FreeBytes -lt $claudeStorageMinimumFreeBytes) {
        throw ('C 盘可用空间不足。Claude/Cowork 实体运行时至少要求 {0:N0} GB，当前仅 {1:N1} GB。' -f ($claudeStorageMinimumFreeBytes / 1GB), ($disk.FreeBytes / 1GB))
    }
    $layout = Get-ClaudeUserDataLayoutInfo
    if (-not $layout.Ready) {
        throw "Claude-3p 存储布局不安全：$($layout.Detail)"
    }
    return [pscustomobject]@{ Disk = $disk; Layout = $layout }
}

function Set-ClaudeRuntimeAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $fullControl = [Security.AccessControl.FileSystemRights]::FullControl
    $identities = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'))
    )
    foreach ($identity in $identities) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $fullControl, $inheritance, $propagation, $allow)
        $acl.SetAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Undo-ClaudeUserDataStorage {
    param($Setup)
    if (-not $Setup) { return }
    try {
        if ([bool]$Setup.CreatedLocalDirectory -and (Test-Path -LiteralPath $claudeUserDataLink -PathType Container)) {
            $item = Get-Item -LiteralPath $claudeUserDataLink -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and (Test-DirectoryEmpty $claudeUserDataLink)) {
                [IO.Directory]::Delete($claudeUserDataLink)
            }
            else {
                Write-Warning "部署失败后 $claudeUserDataLink 已包含数据，为避免误删已保留。"
            }
        }
        Write-Host 'Claude-3p 实体目录初始化已回滚或安全保留。' -ForegroundColor Yellow
    }
    catch {
        Write-Warning "受管存储回滚不完整：$($_.Exception.Message)"
    }
}

function Initialize-ClaudeUserDataStorage {
    [void](Assert-ClaudeStoragePreflight)
    $setup = [pscustomobject]@{
        CreatedLocalDirectory = $false
        ActivePath = $claudeUserDataLink
        LegacyPath = $legacyClaudeUserDataTarget
    }
    try {
        $layout = Get-ClaudeUserDataLayoutInfo
        if ($layout.Status -eq 'PhysicalLocalAppData') {
            Set-ClaudeRuntimeAcl -Path $claudeUserDataLink
            Write-Host "Claude-3p 实体运行时已经就绪：$claudeUserDataLink" -ForegroundColor Green
            return $setup
        }

        if (-not (Test-Path -LiteralPath $claudeUserDataLink -PathType Container)) {
            New-Item -ItemType Directory -Path $claudeUserDataLink -Force | Out-Null
            $setup.CreatedLocalDirectory = $true
        }
        $createdItem = Get-Item -LiteralPath $claudeUserDataLink -Force
        if (-not $createdItem.PSIsContainer -or (($createdItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Claude-3p 必须是普通实体目录，不能是符号链接或目录联接。'
        }
        Set-ClaudeRuntimeAcl -Path $claudeUserDataLink
        Write-Host "Claude-3p 实体运行时已创建：$claudeUserDataLink" -ForegroundColor Green
        return $setup
    }
    catch {
        Undo-ClaudeUserDataStorage $setup
        throw
    }
}

function Get-CoworkFreeBytes {
    $disk = Get-ClaudeStorageDriveInfo
    if (-not $disk) { return [int64]0 }
    return [int64]$disk.FreeBytes
}

function Test-CoworkSeedSource {
    foreach ($entry in $coworkSeedFiles) {
        $source = Join-Path $coworkSeedRoot $entry.Name
        $origin = Join-Path $coworkSeedRoot ('.{0}.origin' -f $entry.Name)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
            -not (Test-Path -LiteralPath $origin -PathType Leaf)) {
            return $false
        }
        if ((Get-Item -LiteralPath $source).Length -ne $entry.Size) {
            return $false
        }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.Sha256) {
            return $false
        }
        if ([IO.File]::ReadAllText($origin) -ne $coworkSeedVersion) {
            return $false
        }
    }
    return $true
}

function Test-CoworkCodeFileSet {
    param([Parameter(Mandatory = $true)][string]$Root)
    foreach ($entry in $coworkCodeFiles) {
        $path = Join-Path $Root $entry.RelativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Item -LiteralPath $path).Length -ne $entry.Size -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Sha256) {
            return $false
        }
    }
    return $true
}

function Test-CoworkCodeSource {
    if (-not (Test-CoworkCodeFileSet -Root $coworkCodeRoot)) {
        return $false
    }
    $hostBinary = Join-Path $coworkCodeRoot "claude-code\$coworkCodeVersion\claude.exe"
    $signature = Get-AuthenticodeSignature -LiteralPath $hostBinary
    return ($signature.Status -eq 'Valid' -and
        $signature.SignerCertificate.Subject -match 'Anthropic' -and
        (Get-Item -LiteralPath $hostBinary).VersionInfo.FileVersion -eq "$coworkCodeVersion.0")
}

function Test-CoworkCodeInstalled {
    $userData = Get-ClaudeUserDataPath
    if (-not (Test-CoworkCodeFileSet -Root $userData)) {
        return $false
    }
    $hostBinary = Join-Path $userData "claude-code\$coworkCodeVersion\claude.exe"
    $signature = Get-AuthenticodeSignature -LiteralPath $hostBinary
    return ($signature.Status -eq 'Valid' -and
        $signature.SignerCertificate.Subject -match 'Anthropic' -and
        (Get-Item -LiteralPath $hostBinary).VersionInfo.FileVersion -eq "$coworkCodeVersion.0")
}

function Test-CoworkRuntimeReady {
    $targetRoot = Get-CoworkBundlePath
    foreach ($name in @('rootfs.vhdx', 'initrd', 'vmlinuz')) {
        $target = Join-Path $targetRoot $name
        $origin = Join-Path $targetRoot ('.{0}.origin' -f $name)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            -not (Test-Path -LiteralPath $origin -PathType Leaf) -or
            [IO.File]::ReadAllText($origin) -ne $coworkSeedVersion) {
            return $false
        }
    }
    return $true
}

function Test-CoworkSeedInstalled {
    $targetRoot = Get-CoworkBundlePath
    foreach ($entry in $coworkSeedFiles) {
        $target = Join-Path $targetRoot $entry.Name
        $origin = Join-Path $targetRoot ('.{0}.origin' -f $entry.Name)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            -not (Test-Path -LiteralPath $origin -PathType Leaf) -or
            (Get-Item -LiteralPath $target).Length -ne $entry.Size -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $entry.Sha256 -or
            [IO.File]::ReadAllText($origin) -ne $coworkSeedVersion) {
            return $false
        }
    }
    return $true
}

function Install-CoworkOfflineSeed {
    if (-not (Test-CoworkSeedSource)) {
        throw 'Cowork 离线运行时缺失或哈希不匹配，拒绝继续。请重新复制完整部署包。'
    }
    $freeBytes = Get-CoworkFreeBytes
    if ($freeBytes -lt $coworkMinimumFreeBytes) {
        throw ('C 盘可用空间不足。Cowork 首次本地解压至少要求 {0:N0} GB，当前仅 {1:N1} GB。' -f ($coworkMinimumFreeBytes / 1GB), ($freeBytes / 1GB))
    }

    $targetRoot = Get-CoworkBundlePath
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    foreach ($entry in $coworkSeedFiles) {
        $expandedName = $entry.Name.Substring(0, $entry.Name.Length - 4)
        $expanded = Join-Path $targetRoot $expandedName
        $expandedOrigin = Join-Path $targetRoot ('.{0}.origin' -f $expandedName)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            if (-not (Test-Path -LiteralPath $expandedOrigin -PathType Leaf) -or
                [IO.File]::ReadAllText($expandedOrigin) -ne $coworkSeedVersion) {
                throw "发现其他版本的 Cowork 运行时：$expanded。为避免破坏现有会话，部署已停止。"
            }
        }

        $source = Join-Path $coworkSeedRoot $entry.Name
        $sourceOrigin = Join-Path $coworkSeedRoot ('.{0}.origin' -f $entry.Name)
        $target = Join-Path $targetRoot $entry.Name
        $targetOrigin = Join-Path $targetRoot ('.{0}.origin' -f $entry.Name)
        $copyRequired = $true
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $copyRequired = ((Get-Item -LiteralPath $target).Length -ne $entry.Size -or
                (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $entry.Sha256)
        }
        if ($copyRequired) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
        Copy-Item -LiteralPath $sourceOrigin -Destination $targetOrigin -Force
    }
    if (-not (Test-CoworkSeedInstalled)) {
        throw 'Cowork 离线运行时复制后的完整性校验失败。'
    }
    Write-Host "Cowork 离线运行时种子已就绪：$targetRoot" -ForegroundColor Green
    Write-Host '仅复制官方压缩运行时；未复制会话、Cookie、日志或 API Key。' -ForegroundColor Green
}

function Install-CoworkCodeOffline {
    if (-not (Test-CoworkCodeSource)) {
        throw 'Cowork Host/VM Code 离线组件缺失、签名无效或哈希不匹配，拒绝继续。请重新复制完整部署包。'
    }

    $userData = Get-ClaudeUserDataPath
    foreach ($entry in $coworkCodeFiles) {
        $source = Join-Path $coworkCodeRoot $entry.RelativePath
        $target = Join-Path $userData $entry.RelativePath
        $targetDirectory = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null

        $copyRequired = $true
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $copyRequired = ((Get-Item -LiteralPath $target).Length -ne $entry.Size -or
                (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $entry.Sha256)
        }
        if ($copyRequired) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }

    if (-not (Test-CoworkCodeInstalled)) {
        throw 'Cowork Host/VM Code 离线组件复制后的完整性校验失败。'
    }
    Write-Host "Cowork Host 与 VM Code $coworkCodeVersion 离线组件已就绪。" -ForegroundColor Green
    Write-Host '这些文件只供 Claude Desktop 内部使用；未注册 PATH，也未安装独立 CLI。' -ForegroundColor Green
}

function Assert-CoworkServiceRegistered {
    $service = Get-Service -Name 'CoworkVMService' -ErrorAction SilentlyContinue
    if (-not $service) {
        throw 'Claude Desktop 已安装，但 CoworkVMService 未注册。部署已停止，不能把桌面聊天可用误判为 Cowork 可用。'
    }
}

function Stop-ClaudeDesktop {
    $desktop = Get-Process -Name claude -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like 'C:\Program Files\WindowsApps\Claude_*\app\Claude.exe' }
    foreach ($process in $desktop) {
        try { [void]$process.CloseMainWindow() } catch {}
    }
    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = Get-Process -Name claude -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like 'C:\Program Files\WindowsApps\Claude_*\app\Claude.exe' }
    } while ($remaining -and (Get-Date) -lt $deadline)
    if ($remaining) {
        $remaining | Stop-Process -Force
    }
}

function Start-ClaudeDesktop {
    Start-Process explorer.exe -ArgumentList 'shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude'
}

function Read-ClaudeRuntimeLogDelta {
    param([string]$Path, [int64]$Offset)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($Offset -lt 0 -or $Offset -gt $stream.Length) { $Offset = 0 }
        [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        return $reader.ReadToEnd()
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Test-ClaudeDesktopRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$ValidationStage,
        [int]$TimeoutSeconds = 26
    )

    Stop-ClaudeDesktop
    $logPath = Join-Path $env:APPDATA 'Claude\logs\main.log'
    $offset = 0L
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $offset = [int64](Get-Item -LiteralPath $logPath).Length
    }
    $startedAt = Get-Date
    Start-ClaudeDesktop
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $failurePattern = '(?i)initial mainView load loadURL rejected|mainView not ready|ERR_FAILED|render-process-gone|GPU process isn''t usable'
    $failure = ''
    $windowReady = $false
    $rendererReady = $false

    do {
        Start-Sleep -Milliseconds 500
        $delta = Read-ClaudeRuntimeLogDelta -Path $logPath -Offset $offset
        if ($delta -match $failurePattern) {
            $failure = [string]$Matches[0]
            break
        }

        $desktopProcesses = @(
            Get-Process -Name claude -ErrorAction SilentlyContinue |
                Where-Object {
                    try { $_.Path -like 'C:\Program Files\WindowsApps\Claude_*\app\Claude.exe' }
                    catch { $false }
                }
        )
        $windowReady = @($desktopProcesses | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0
        $rendererReady = @(
            Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ExecutablePath -like 'C:\Program Files\WindowsApps\Claude_*\app\Claude.exe' -and
                    $_.CommandLine -match '(?i)--type=renderer'
                }
        ).Count -gt 0

        if ($windowReady -and $rendererReady -and ((Get-Date) - $startedAt).TotalSeconds -ge 14) {
            break
        }
    } while ((Get-Date) -lt $deadline)

    $delta = Read-ClaudeRuntimeLogDelta -Path $logPath -Offset $offset
    if (-not $failure -and $delta -match $failurePattern) { $failure = [string]$Matches[0] }
    $passed = (-not $failure -and $windowReady -and $rendererReady)
    Stop-ClaudeDesktop
    return [pscustomobject]@{
        Stage = $ValidationStage
        Passed = [bool]$passed
        Detail = if ($passed) { 'VisibleWindowAndRendererReady' } elseif ($failure) { "MainViewFailure:$failure" } elseif (-not $windowReady) { 'MainWindowNotReady' } else { 'RendererNotReady' }
        CheckedAt = (Get-Date).ToString('o')
    }
}

function Save-DeploymentRuntimeValidation {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Stock', 'DeepSeek', 'Localization', 'FlashMax')][string]$ValidationStage,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'ROLLED_BACK')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    $state = Read-DeploymentState
    if (-not $state) { return }
    if ($null -eq $state.PSObject.Properties['RuntimeValidation'] -or $null -eq $state.RuntimeValidation) {
        Set-JsonProperty $state 'RuntimeValidation' ([pscustomobject]@{})
    }
    Set-JsonProperty $state.RuntimeValidation $ValidationStage ([pscustomobject]@{
        Status = $Status
        Detail = (Protect-DeploymentMessage $Detail)
        CheckedAt = (Get-Date).ToString('o')
    })
    Save-DeploymentState $state
}

function Set-ManagedInstallCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][ValidateSet('IN_PROGRESS', 'PASS', 'ROLLED_BACK', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )
    $state = Read-DeploymentState
    if (-not $state) { return }
    if ($null -eq $state.PSObject.Properties['ManagedInstall'] -or $null -eq $state.ManagedInstall) {
        Set-JsonProperty $state 'ManagedInstall' ([pscustomobject]@{
            CurrentPhase = ''
            Status = ''
            UpdatedAt = $null
            History = @()
        })
    }
    elseif ($null -eq $state.ManagedInstall.PSObject.Properties['History']) {
        Set-JsonProperty $state.ManagedInstall 'History' @()
    }
    $now = (Get-Date).ToString('o')
    $safeDetail = Protect-DeploymentMessage $Detail
    $history = @($state.ManagedInstall.History) + [pscustomobject]@{
        Phase = $Phase
        Status = $Status
        Detail = $safeDetail
        At = $now
    }
    if ($history.Count -gt 32) { $history = @($history | Select-Object -Last 32) }
    Set-JsonProperty $state.ManagedInstall 'CurrentPhase' $Phase
    Set-JsonProperty $state.ManagedInstall 'Status' $Status
    Set-JsonProperty $state.ManagedInstall 'UpdatedAt' $now
    Set-JsonProperty $state.ManagedInstall 'History' $history
    Save-DeploymentState $state
}

function Assert-ClaudeRuntimeStage {
    param([Parameter(Mandatory = $true)][ValidateSet('Stock', 'DeepSeek', 'Localization', 'FlashMax')][string]$ValidationStage)
    Write-Host "Validating Claude Desktop runtime layer: $ValidationStage" -ForegroundColor Cyan
    $probe = Test-ClaudeDesktopRuntime -ValidationStage $ValidationStage
    Save-DeploymentRuntimeValidation -ValidationStage $ValidationStage -Status $(if ($probe.Passed) { 'PASS' } else { 'FAIL' }) -Detail $probe.Detail
    if (-not $probe.Passed) {
        throw "Claude runtime validation failed at $ValidationStage ($($probe.Detail))."
    }
    Write-Host "Claude Desktop runtime layer passed: $ValidationStage" -ForegroundColor Green
    return $probe
}

function New-DeepSeekConfigurationSnapshot {
    $userData = Get-ClaudeUserDataPath
    $backupRoot = Join-Path $companyRoot ("Backups\DeepSeek\Managed-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $entries = New-Object System.Collections.Generic.List[object]
    $sources = New-Object System.Collections.Generic.List[object]
    $library = Join-Path $userData 'configLibrary'
    if (Test-Path -LiteralPath $library -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $library -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            $sources.Add([pscustomobject]@{ Path = $file.FullName; RelativePath = "configLibrary\$($file.Name)" })
        }
    }
    $desktopConfig = Join-Path $userData 'claude_desktop_config.json'
    if (Test-Path -LiteralPath $desktopConfig -PathType Leaf) {
        $sources.Add([pscustomobject]@{ Path = $desktopConfig; RelativePath = 'claude_desktop_config.json' })
    }

    $index = 0
    foreach ($source in $sources) {
        $plain = $null
        $encrypted = $null
        try {
            $plain = [IO.File]::ReadAllBytes($source.Path)
            $encrypted = [Security.Cryptography.ProtectedData]::Protect($plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            $backupName = ('entry-{0:D3}.dpapi' -f $index)
            [IO.File]::WriteAllBytes((Join-Path $backupRoot $backupName), $encrypted)
            $entries.Add([pscustomobject]@{ RelativePath = $source.RelativePath; BackupName = $backupName })
            $index++
        }
        finally {
            if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
            if ($encrypted) { [Array]::Clear($encrypted, 0, $encrypted.Length) }
        }
    }
    $manifest = [ordered]@{
        SchemaVersion = 1
        CreatedAt = (Get-Date).ToString('o')
        UserDataRoot = $userData
        Entries = $entries.ToArray()
        ContainsPlaintextSecrets = $false
    }
    $manifestPath = Join-Path $backupRoot 'snapshot.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ ManifestPath = $manifestPath; BackupRoot = $backupRoot }
}

function Clear-ManagedClaudeConfiguration {
    $userData = Get-ClaudeUserDataPath
    $library = Join-Path $userData 'configLibrary'
    if (Test-Path -LiteralPath $library -PathType Container) {
        Get-ChildItem -LiteralPath $library -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction Stop
    }
    Remove-Item -LiteralPath (Join-Path $userData 'claude_desktop_config.json') -Force -ErrorAction SilentlyContinue
}

function Restore-DeepSeekConfigurationSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)
    if (-not $Snapshot -or -not (Test-Path -LiteralPath $Snapshot.ManifestPath -PathType Leaf)) {
        throw 'The encrypted Claude configuration snapshot is unavailable.'
    }
    $manifest = Get-Content -LiteralPath $Snapshot.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $userData = Get-ClaudeUserDataPath
    Clear-ManagedClaudeConfiguration
    foreach ($entry in @($manifest.Entries)) {
        $relative = [string]$entry.RelativePath
        if ($relative -ne 'claude_desktop_config.json' -and $relative -notmatch '^configLibrary\\[^\\]+\.json$') {
            throw "Unsafe configuration snapshot entry: $relative"
        }
        $source = Join-Path $Snapshot.BackupRoot ([string]$entry.BackupName)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Encrypted snapshot entry is missing: $relative" }
        $encrypted = $null
        $plain = $null
        try {
            $encrypted = [IO.File]::ReadAllBytes($source)
            $plain = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            $destination = Join-Path $userData $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            [IO.File]::WriteAllBytes($destination, $plain)
        }
        finally {
            if ($encrypted) { [Array]::Clear($encrypted, 0, $encrypted.Length) }
            if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
        }
    }
}

function Get-ClaudeConfigPath {
    $candidates = @(
        (Join-Path (Get-ClaudeUserDataPath) 'claude_desktop_config.json'),
        (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Test-DeepSeekConfigured {
    $library = Join-Path (Get-ClaudeUserDataPath) 'configLibrary'
    if (-not (Test-Path -LiteralPath $library -PathType Container)) {
        return $false
    }
    foreach ($file in Get-ChildItem -LiteralPath $library -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try {
            $raw = [IO.File]::ReadAllText($file.FullName)
            if ($raw.Contains('api.deepseek.com/anthropic')) {
                return $true
            }
        }
        catch {}
    }
    return $false
}

function Get-ClaudeUpdatePreference {
    $library = Join-Path (Get-ClaudeUserDataPath) 'configLibrary'
    $metaPath = Join-Path $library '_meta.json'
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$meta.appliedId)) {
                $configPath = Join-Path $library ("{0}.json" -f $meta.appliedId)
                $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $property = $config.PSObject.Properties['disableAutoUpdates']
                if ($null -ne $property) {
                    return [pscustomobject]@{
                        Mode = if ([bool]$property.Value) { 'Block' } else { 'Allow' }
                        Source = 'Active third-party configuration'
                    }
                }
            }
        }
        catch {}
    }

    $policy = Get-ClaudeAutoUpdatePolicySnapshot
    if ($policy.Exists) {
        return [pscustomobject]@{
            Mode = if ([int]$policy.Value -ne 0) { 'Block' } else { 'Allow' }
            Source = 'Windows policy'
        }
    }
    return [pscustomobject]@{ Mode = 'Default'; Source = 'No managed preference' }
}

function Get-ExistingDeepSeekApiKey {
    $library = Join-Path (Get-ClaudeUserDataPath) 'configLibrary'
    $metaPath = Join-Path $library '_meta.json'
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        return $null
    }
    try {
        $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$meta.appliedId)) {
            return $null
        }
        $configPath = Join-Path $library ("{0}.json" -f $meta.appliedId)
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config.inferenceGatewayBaseUrl -eq 'https://api.deepseek.com/anthropic' -and
            -not [string]::IsNullOrWhiteSpace([string]$config.inferenceGatewayApiKey)) {
            return [string]$config.inferenceGatewayApiKey
        }
    }
    catch {}
    return $null
}

function Read-DeepSeekApiKey {
    if ($NonInteractive) {
        throw 'DeepSeek API Key is required. Return to the graphical installer and enter the device key.'
    }
    Write-Host 'Enter the dedicated DeepSeek API Key for this pilot computer.' -ForegroundColor Cyan
    Write-Host 'The key is hidden while typing and is never written to the deployment log.' -ForegroundColor DarkGray
    $secure = Read-Host 'DeepSeek API Key' -AsSecureString
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ([string]::IsNullOrWhiteSpace($plain) -or $plain.Length -lt 10) {
            throw 'The DeepSeek API Key is empty or unexpectedly short.'
        }
        return $plain.Trim()
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Read-DeepSeekApiKeyTicket {
    if ([string]::IsNullOrWhiteSpace($ApiKeyBlobPath)) {
        return $null
    }
    Assert-ExpectedUser
    $ticket = [IO.Path]::GetFullPath($ApiKeyBlobPath)
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'ClaudePilotR3')).TrimEnd('\')
    if (-not $ticket.StartsWith($allowedRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($ticket) -ne '.dpapi') {
        throw 'The encrypted API Key ticket is outside the allowed temporary directory.'
    }
    if (-not (Test-Path -LiteralPath $ticket -PathType Leaf)) {
        throw 'The encrypted API Key ticket is missing or was already consumed.'
    }

    $encrypted = $null
    $clear = $null
    try {
        Add-Type -AssemblyName System.Security
        $encrypted = [IO.File]::ReadAllBytes($ticket)
        $clear = [Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $plain = [Text.Encoding]::UTF8.GetString($clear).Trim()
        if ([string]::IsNullOrWhiteSpace($plain) -or $plain.Length -lt 10) {
            throw 'The decrypted DeepSeek API Key is empty or unexpectedly short.'
        }
        return $plain
    }
    finally {
        if ($encrypted) { [Array]::Clear($encrypted, 0, $encrypted.Length) }
        if ($clear) { [Array]::Clear($clear, 0, $clear.Length) }
        Remove-Item -LiteralPath $ticket -Force -ErrorAction SilentlyContinue
    }
}

function Test-DeepSeekApiKey {
    param([Parameter(Mandatory = $true)][string]$ApiKey)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{
        'x-api-key' = $ApiKey
        'anthropic-version' = '2023-06-01'
    }
    foreach ($model in @('claude-opus-4-8', 'claude-sonnet-5')) {
        $body = @{
            model = $model
            max_tokens = 8
            messages = @(@{ role = 'user'; content = 'Reply with OK.' })
        } | ConvertTo-Json -Depth 8 -Compress
        try {
            $response = Invoke-RestMethod -Method Post -Uri 'https://api.deepseek.com/anthropic/v1/messages' -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 45
            if ($null -eq $response -or $null -eq $response.content) {
                throw 'The endpoint returned an unexpected response.'
            }
        }
        catch {
            $status = 'network/provider error'
            try { $status = "HTTP $([int]$_.Exception.Response.StatusCode)" } catch {}
            throw "DeepSeek connection test failed for $model ($status). The key was not saved."
        }
    }
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $Object.$Name = $Value
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

function Write-DeepSeekConfiguration {
    param([Parameter(Mandatory = $true)][string]$ApiKey)

    $userData = Get-ClaudeUserDataPath
    $library = Join-Path $userData 'configLibrary'
    New-Item -ItemType Directory -Path $library -Force | Out-Null

    $metaPath = Join-Path $library '_meta.json'
    $configId = $null
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
        try {
            $oldMeta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$oldMeta.appliedId -match '^[a-f0-9-]{36}$') {
                $configId = [string]$oldMeta.appliedId
            }
        }
        catch {}
    }
    if (-not $configId) {
        $configId = [guid]::NewGuid().ToString()
    }

    $deepSeekConfig = [ordered]@{
        inferenceGatewayBaseUrl = 'https://api.deepseek.com/anthropic'
        inferenceGatewayApiKey = $ApiKey
        inferenceGatewayAuthScheme = 'x-api-key'
        modelDiscoveryEnabled = $false
        inferenceModels = @(
            [ordered]@{
                name = 'claude-opus-4-8'
                labelOverride = 'DeepSeek V4 Pro (1M)'
                anthropicFamilyTier = 'opus'
                isFamilyDefault = $true
                supports1m = $true
            },
            [ordered]@{
                name = 'claude-sonnet-5'
                labelOverride = 'DeepSeek V4 Flash (1M)'
                anthropicFamilyTier = 'sonnet'
                isFamilyDefault = $true
                supports1m = $true
            }
        )
        inferenceProvider = 'gateway'
        inferenceCredentialKind = 'static'
    }
    $meta = [ordered]@{
        appliedId = $configId
        entries = @([ordered]@{ id = $configId; name = 'Default' })
    }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $library "$configId.json"), ($deepSeekConfig | ConvertTo-Json -Depth 12) + [Environment]::NewLine, $utf8)
    [IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 8) + [Environment]::NewLine, $utf8)

    $desktopConfigPath = Join-Path $userData 'claude_desktop_config.json'
    if (Test-Path -LiteralPath $desktopConfigPath -PathType Leaf) {
        $desktopConfig = Get-Content -LiteralPath $desktopConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    else {
        $desktopConfig = [pscustomobject]@{}
    }
    Set-JsonProperty $desktopConfig 'deploymentMode' '3p'
    Set-JsonProperty $desktopConfig 'coworkUserFilesPath' $coworkRoot
    [IO.File]::WriteAllText($desktopConfigPath, ($desktopConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine, $utf8)

    return $desktopConfigPath
}

function Assert-Installer {
    if (-not (Test-Path -LiteralPath $msixPath -PathType Leaf)) {
        throw "找不到 Claude 安装包：$msixPath"
    }
    $hash = (Get-FileHash -LiteralPath $msixPath -Algorithm SHA256).Hash
    if ($hash -ne $expectedMsixHash) {
        throw 'Claude MSIX 哈希不匹配，拒绝安装。请重新复制部署包。'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $msixPath
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Anthropic') {
        throw 'Claude MSIX 的 Anthropic 数字签名无效，拒绝安装。'
    }
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
            if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '(\d+)\.(\d+)\.(\d+)(?:\.windows\.(\d+))?') {
                continue
            }
            $revision = if ($matches[4]) { [int]$matches[4] } else { 0 }
            return [pscustomobject]@{
                Path = $candidate
                Version = [version]("{0}.{1}.{2}.{3}" -f $matches[1], $matches[2], $matches[3], $revision)
                VersionText = $versionText.Trim()
            }
        }
        catch {}
    }
    return $null
}

function Read-DeploymentState {
    if (-not (Test-Path -LiteralPath $deploymentStatePath -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $deploymentStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-DeploymentState {
    param([Parameter(Mandatory = $true)]$State)
    Write-PilotJsonAtomic -Path $deploymentStatePath -Value $State
    $deploymentId = [string](Get-PropertyValue $State 'DeploymentId' '')
    $userSid = [string](Get-PropertyValue $State 'WindowsUserSid' '')
    if ($deploymentId -and $userSid) {
        Write-PilotDeploymentMetadata -DataRoot $companyRoot -StatePath $deploymentStatePath -DeploymentId $deploymentId -WindowsUserSid $userSid
    }
}

function Get-ClaudeAutoUpdatePolicySnapshot {
    $path = 'HKCU:\SOFTWARE\Policies\Claude'
    $record = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    $property = if ($record) { $record.PSObject.Properties['disableAutoUpdates'] } else { $null }
    return [pscustomobject]@{
        Exists = ($null -ne $property)
        Value = if ($null -ne $property) { $property.Value } else { $null }
    }
}

function Initialize-DeploymentState {
    $existing = Read-DeploymentState
    if ($existing) {
        Set-JsonProperty $existing 'SchemaVersion' 7
        Set-JsonProperty $existing 'Product' 'Claude Pilot R3.5'
        Set-JsonProperty $existing 'PackageVersion' 'R3.5-20260718'
        if (-not [string](Get-PropertyValue $existing 'DeploymentId' '')) {
            Set-JsonProperty $existing 'DeploymentId' ([Guid]::NewGuid().ToString('D'))
        }
        if ($null -eq $existing.PSObject.Properties['Storage']) {
            Set-JsonProperty $existing 'Storage' ([pscustomobject]@{})
        }
        Set-JsonProperty $existing.Storage 'CompanyRoot' $companyRoot
        Set-JsonProperty $existing.Storage 'DataRoot' $companyRoot
        Set-JsonProperty $existing.Storage 'CoworkWorkFiles' $coworkRoot
        Set-JsonProperty $existing.Storage 'Layout' 'PhysicalLocalAppData'
        Set-JsonProperty $existing.Storage 'ClaudeUserDataPath' $claudeUserDataLink
        Set-JsonProperty $existing.Storage 'ClaudeUserDataTarget' $claudeUserDataLink
        Set-JsonProperty $existing.Storage 'LegacyClaudeUserDataTarget' $legacyClaudeUserDataTarget
        Set-JsonProperty $existing.Storage 'LegacyCopyPreserved' (Test-Path -LiteralPath $legacyClaudeUserDataTarget -PathType Container)
        Set-JsonProperty $existing.Storage 'LinkCreatedByPilot' $false
        if ($null -eq $existing.Storage.PSObject.Properties['LocalDataCreatedByPilot']) {
            Set-JsonProperty $existing.Storage 'LocalDataCreatedByPilot' $false
        }
        if ($null -eq $existing.PSObject.Properties['Patches']) {
            $currentPolicy = Get-ClaudeAutoUpdatePolicySnapshot
            Set-JsonProperty $existing 'Patches' ([pscustomobject]@{
                BaselineKnown = $false
                EffortLevelBefore = $null
                EffortLevelAfter = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'User')
                EffortLevelChangedByPilot = $false
                DisableAutoUpdatesExistedBefore = $false
                DisableAutoUpdatesBefore = $null
                DisableAutoUpdatesExistsAfter = [bool]$currentPolicy.Exists
                DisableAutoUpdatesAfter = $currentPolicy.Value
                AutoUpdatePolicyChangedByPilot = $false
            })
        }
        Save-DeploymentState $existing
        return Read-DeploymentState
    }

    $gitBefore = Get-GitInfo
    $vmpBefore = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    $claudeBefore = Get-ClaudePackage
    $policyBefore = Get-ClaudeAutoUpdatePolicySnapshot
    $state = [ordered]@{
        SchemaVersion = 7
        Product = 'Claude Pilot R3.5'
        PackageVersion = 'R3.5-20260718'
        Status = 'Installing'
        Phase = 'Initialize'
        DeploymentId = [Guid]::NewGuid().ToString('D')
        BaselineRecordedAt = (Get-Date).ToString('o')
        LastCompletedAt = $null
        WindowsUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        WindowsUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Claude = [ordered]@{
            PresentBefore = [bool]$claudeBefore
            VersionBefore = if ($claudeBefore) { [string]$claudeBefore.Version } else { '' }
            InstalledByPilot = $false
            VersionAfter = ''
        }
        Git = [ordered]@{
            PresentBefore = [bool]$gitBefore
            VersionBefore = if ($gitBefore) { [string]$gitBefore.VersionText } else { '' }
            PathBefore = if ($gitBefore) { [string]$gitBefore.Path } else { '' }
            InstalledByPilot = $false
            ChangedByPilot = $false
            VersionAfter = ''
            PathAfter = ''
        }
        VirtualMachinePlatform = [ordered]@{
            StateBefore = [string]$vmpBefore.State
            EnabledByPilot = $false
            StateAfter = [string]$vmpBefore.State
        }
        Storage = [ordered]@{
            CompanyRoot = $companyRoot
            DataRoot = $companyRoot
            CoworkWorkFiles = $coworkRoot
            Layout = 'PhysicalLocalAppData'
            ClaudeUserDataPath = $claudeUserDataLink
            ClaudeUserDataTarget = $claudeUserDataLink
            LegacyClaudeUserDataTarget = $legacyClaudeUserDataTarget
            LegacyCopyPreserved = (Test-Path -LiteralPath $legacyClaudeUserDataTarget -PathType Container)
            LinkCreatedByPilot = $false
            TargetCreatedByPilot = $false
            LocalDataCreatedByPilot = $false
            TargetFileSystem = 'NTFS'
            StorageReadyAt = $null
        }
        Patches = [ordered]@{
            BaselineKnown = $true
            EffortLevelBefore = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'User')
            EffortLevelAfter = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'User')
            EffortLevelChangedByPilot = $false
            DisableAutoUpdatesExistedBefore = [bool]$policyBefore.Exists
            DisableAutoUpdatesBefore = $policyBefore.Value
            DisableAutoUpdatesExistsAfter = [bool]$policyBefore.Exists
            DisableAutoUpdatesAfter = $policyBefore.Value
            AutoUpdatePolicyChangedByPilot = $false
        }
    }
    Save-DeploymentState $state
    return Read-DeploymentState
}

function Update-DeploymentStorageState {
    param([Parameter(Mandatory = $true)]$StorageSetup)
    $state = Read-DeploymentState
    if (-not $state) {
        throw '部署状态记录丢失，无法记录受管运行时布局。'
    }
    if ($null -eq $state.PSObject.Properties['Storage']) {
        Set-JsonProperty $state 'Storage' ([pscustomobject]@{})
    }
    Set-JsonProperty $state 'SchemaVersion' 7
    Set-JsonProperty $state.Storage 'CompanyRoot' $companyRoot
    Set-JsonProperty $state.Storage 'DataRoot' $companyRoot
    Set-JsonProperty $state.Storage 'CoworkWorkFiles' $coworkRoot
    Set-JsonProperty $state.Storage 'Layout' 'PhysicalLocalAppData'
    Set-JsonProperty $state.Storage 'ClaudeUserDataPath' $claudeUserDataLink
    Set-JsonProperty $state.Storage 'ClaudeUserDataTarget' $claudeUserDataLink
    Set-JsonProperty $state.Storage 'LegacyClaudeUserDataTarget' $legacyClaudeUserDataTarget
    Set-JsonProperty $state.Storage 'LegacyCopyPreserved' (Test-Path -LiteralPath $legacyClaudeUserDataTarget -PathType Container)
    Set-JsonProperty $state.Storage 'LinkCreatedByPilot' $false
    $oldLocalCreated = if ($null -ne $state.Storage.PSObject.Properties['LocalDataCreatedByPilot']) { [bool]$state.Storage.LocalDataCreatedByPilot } else { $false }
    Set-JsonProperty $state.Storage 'LocalDataCreatedByPilot' ($oldLocalCreated -or [bool]$StorageSetup.CreatedLocalDirectory)
    Set-JsonProperty $state.Storage 'TargetFileSystem' 'NTFS'
    Set-JsonProperty $state.Storage 'StorageReadyAt' (Get-Date).ToString('o')
    Save-DeploymentState $state
    return Read-DeploymentState
}

function Update-DeploymentPatchState {
    $state = Read-DeploymentState
    if (-not $state -or $null -eq $state.PSObject.Properties['Patches']) {
        throw '部署状态记录缺少补丁基线，拒绝把 Flash Max 标记为可自动回滚。'
    }
    $patches = $state.Patches
    $effortAfter = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'User')
    $policyAfter = Get-ClaudeAutoUpdatePolicySnapshot
    Set-JsonProperty $patches 'EffortLevelAfter' $effortAfter
    Set-JsonProperty $patches 'DisableAutoUpdatesExistsAfter' ([bool]$policyAfter.Exists)
    Set-JsonProperty $patches 'DisableAutoUpdatesAfter' $policyAfter.Value
    Set-JsonProperty $patches 'RequestedUpdatePolicy' $UpdatePolicy
    if ([bool](Get-PropertyValue $patches 'BaselineKnown' $false)) {
        $effortBefore = Get-PropertyValue $patches 'EffortLevelBefore' $null
        $policyExistedBefore = [bool](Get-PropertyValue $patches 'DisableAutoUpdatesExistedBefore' $false)
        $policyBefore = Get-PropertyValue $patches 'DisableAutoUpdatesBefore' $null
        Set-JsonProperty $patches 'EffortLevelChangedByPilot' ($effortAfter -ne $effortBefore)
        Set-JsonProperty $patches 'AutoUpdatePolicyChangedByPilot' (
            ([bool]$policyAfter.Exists -ne $policyExistedBefore) -or
            ([bool]$policyAfter.Exists -and $policyAfter.Value -ne $policyBefore)
        )
    }
    Save-DeploymentState $state
    return Read-DeploymentState
}

function Record-DeploymentFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $state = Read-DeploymentState
    if (-not $state) { return }
    try {
        $gitNow = Get-GitInfo
        if ($gitNow -and $null -ne $state.PSObject.Properties['Git']) {
            $state.Git.InstalledByPilot = (-not [bool]$state.Git.PresentBefore)
            $state.Git.ChangedByPilot = (
                [bool]$state.Git.PresentBefore -and
                ([string]$state.Git.VersionBefore -ne [string]$gitNow.VersionText -or
                 [string]$state.Git.PathBefore -ne [string]$gitNow.Path)
            )
            $state.Git.VersionAfter = [string]$gitNow.VersionText
            $state.Git.PathAfter = [string]$gitNow.Path
        }
        $vmpNow = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
        if ($null -ne $state.PSObject.Properties['VirtualMachinePlatform']) {
            if ([string]$state.VirtualMachinePlatform.StateBefore -notin @('Enabled', 'EnablePending') -and
                [string]$vmpNow.State -in @('Enabled', 'EnablePending')) {
                $state.VirtualMachinePlatform.EnabledByPilot = $true
            }
            $state.VirtualMachinePlatform.StateAfter = [string]$vmpNow.State
        }
        if ($null -ne $state.PSObject.Properties['Patches']) {
            $patches = $state.Patches
            $effortAfter = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'User')
            $policyAfter = Get-ClaudeAutoUpdatePolicySnapshot
            Set-JsonProperty $patches 'EffortLevelAfter' $effortAfter
            Set-JsonProperty $patches 'DisableAutoUpdatesExistsAfter' ([bool]$policyAfter.Exists)
            Set-JsonProperty $patches 'DisableAutoUpdatesAfter' $policyAfter.Value
            if ([bool](Get-PropertyValue $patches 'BaselineKnown' $false)) {
                $effortBefore = Get-PropertyValue $patches 'EffortLevelBefore' $null
                $policyExistedBefore = [bool](Get-PropertyValue $patches 'DisableAutoUpdatesExistedBefore' $false)
                $policyBefore = Get-PropertyValue $patches 'DisableAutoUpdatesBefore' $null
                Set-JsonProperty $patches 'EffortLevelChangedByPilot' ($effortAfter -ne $effortBefore)
                Set-JsonProperty $patches 'AutoUpdatePolicyChangedByPilot' (
                    ([bool]$policyAfter.Exists -ne $policyExistedBefore) -or
                    ([bool]$policyAfter.Exists -and $policyAfter.Value -ne $policyBefore)
                )
            }
        }
    }
    catch {}
    Set-JsonProperty $state 'LastFailedAt' (Get-Date).ToString('o')
    Set-JsonProperty $state 'LastFailure' (Protect-DeploymentMessage $Message)
    Save-DeploymentState $state
}

function Update-DeploymentState {
    param(
        [Parameter(Mandatory = $true)]$GitAfter,
        [Parameter(Mandatory = $true)][bool]$VmpEnabledByPilot,
        [Parameter(Mandatory = $true)]$ClaudeAfter
    )
    $state = Read-DeploymentState
    if (-not $state) {
        throw '部署状态记录丢失，无法可靠记录 Git 与虚拟机平台的原始状态。'
    }

    $state.LastCompletedAt = (Get-Date).ToString('o')
    $state.Claude.InstalledByPilot = (-not [bool]$state.Claude.PresentBefore -and [bool]$ClaudeAfter)
    $state.Claude.VersionAfter = [string]$ClaudeAfter.Version
    $state.Git.InstalledByPilot = (-not [bool]$state.Git.PresentBefore -and [bool]$GitAfter)
    $state.Git.ChangedByPilot = (
        [bool]$state.Git.PresentBefore -and
        ([string]$state.Git.VersionBefore -ne [string]$GitAfter.VersionText -or
         [string]$state.Git.PathBefore -ne [string]$GitAfter.Path)
    )
    $state.Git.VersionAfter = [string]$GitAfter.VersionText
    $state.Git.PathAfter = [string]$GitAfter.Path
    if ($VmpEnabledByPilot) {
        $state.VirtualMachinePlatform.EnabledByPilot = $true
    }
    $state.VirtualMachinePlatform.StateAfter = [string](Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State
    Save-DeploymentState $state
    return Read-DeploymentState
}

function Test-GitInstaller {
    if (-not (Test-Path -LiteralPath $gitInstallerPath -PathType Leaf)) {
        return $false
    }
    if ((Get-FileHash -LiteralPath $gitInstallerPath -Algorithm SHA256).Hash -ne $expectedGitInstallerHash) {
        return $false
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $gitInstallerPath
    return ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'Johannes Schindelin')
}

function Assert-GitInstaller {
    if (-not (Test-GitInstaller)) {
        throw 'Git for Windows 离线安装包缺失、哈希不匹配或官方数字签名无效，拒绝安装。'
    }
}

function Install-GitForCode {
    $git = Get-GitInfo
    if ($git -and $git.Version -ge $expectedGitVersion) {
        Write-Host "Git 已可供 Code 使用：$($git.VersionText) ($($git.Path))" -ForegroundColor Green
        return $git
    }

    Assert-GitInstaller
    if ($git) {
        Write-Host "检测到较旧的 $($git.VersionText)，正在升级到 Git for Windows 2.55.0(3)。" -ForegroundColor Cyan
    }
    else {
        Write-Host '正在离线安装 Git for Windows 2.55.0(3)，供 Claude Desktop Code 使用。' -ForegroundColor Cyan
    }

    $arguments = @(
        '/VERYSILENT',
        '/NORESTART',
        '/NOCANCEL',
        '/SP-',
        '/SUPPRESSMSGBOXES',
        '/CLOSEAPPLICATIONS',
        '/o:PathOption=Cmd'
    )
    $process = Start-Process -FilePath $gitInstallerPath -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Git for Windows 安装失败，返回代码 $($process.ExitCode)。"
    }

    $git = Get-GitInfo
    if (-not $git -or $git.Version -lt $expectedGitVersion) {
        throw 'Git 安装程序已退出，但未检测到预期版本的 git.exe。'
    }
    $gitDirectory = Split-Path -Parent $git.Path
    if (($env:Path -split ';') -notcontains $gitDirectory) {
        $env:Path = "$gitDirectory;$env:Path"
    }
    Write-Host "Git 已安装并加入 PATH：$($git.VersionText)" -ForegroundColor Green
    return $git
}

function Get-RegisteredApplicationPath {
    param([Parameter(Mandatory = $true)][string]$ExecutableName)
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExecutableName",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$ExecutableName",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExecutableName"
    )
    foreach ($registryPath in $registryPaths) {
        $record = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if (-not $record) { continue }
        $defaultProperty = $record.PSObject.Properties['(default)']
        if ($null -ne $defaultProperty -and -not [string]::IsNullOrWhiteSpace([string]$defaultProperty.Value)) {
            $candidate = [Environment]::ExpandEnvironmentVariables([string]$defaultProperty.Value).Trim('"')
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [IO.Path]::GetFullPath($candidate)
            }
        }
    }
    return $null
}

function Get-FirmwareVirtualizationStatus {
    try {
        $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $processor = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $hypervisorPresent = [bool](Get-PropertyValue $computerSystem 'HypervisorPresent' $false)
        $firmwareProperty = $processor.PSObject.Properties['VirtualizationFirmwareEnabled']
        $manufacturer = [string](Get-PropertyValue $computerSystem 'Manufacturer' '')
        $model = [string](Get-PropertyValue $computerSystem 'Model' '')
        $isVirtualMachine = ($manufacturer -match '(?i)VMware|innotek|QEMU|Xen|Parallels') -or ($model -match '(?i)Virtual Machine|VirtualBox|VMware|KVM|HVM|Parallels')
        $detail = "Manufacturer=$manufacturer; Model=$model; VirtualMachine=$isVirtualMachine; HypervisorPresent=$hypervisorPresent; VirtualizationFirmwareEnabled=$(if ($null -ne $firmwareProperty) { [string]$firmwareProperty.Value } else { 'Unavailable' })"

        # A VM can see the host hypervisor while still lacking nested virtualization.  Cowork
        # needs virtualization instructions exposed to the guest, so HypervisorPresent alone
        # is acceptable only on physical hardware.
        if ($isVirtualMachine) {
            if ($null -ne $firmwareProperty -and $null -ne $firmwareProperty.Value -and [bool]$firmwareProperty.Value) {
                return [pscustomobject]@{ Status = 'PASS'; Detail = $detail }
            }
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "$detail；当前虚拟机未获得嵌套虚拟化，不能部署 Cowork。" }
        }
        if ($hypervisorPresent) {
            return [pscustomobject]@{ Status = 'PASS'; Detail = $detail }
        }
        if ($null -eq $firmwareProperty -or $null -eq $firmwareProperty.Value) {
            return [pscustomobject]@{ Status = 'WARN'; Detail = '系统未提供 VirtualizationFirmwareEnabled；请在任务管理器 CPU 页或 BIOS 复核' }
        }
        if ([bool]$firmwareProperty.Value) {
            return [pscustomobject]@{ Status = 'PASS'; Detail = $detail }
        }
        return [pscustomobject]@{ Status = 'FAIL'; Detail = "$detail；BIOS/UEFI 虚拟化未启用，请启用 Intel VT-x/AMD-V 后再部署 Cowork。" }
    }
    catch {
        return [pscustomobject]@{ Status = 'WARN'; Detail = "无法自动读取 BIOS 虚拟化状态：$($_.Exception.Message)" }
    }
}

function Get-WindowsCompatibilityStatus {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $build = 0
        [void][int]::TryParse([string]$os.BuildNumber, [ref]$build)
        $caption = [string]$os.Caption
        if ($caption -match 'Windows 10' -and $build -lt 19045) {
            return [pscustomobject]@{ Status = 'WARN'; Detail = "$caption | Build $build；可继续试点，但建议先更新到 Windows 10 22H2/19045" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "$caption | Build $build" }
    }
    catch {
        return [pscustomobject]@{ Status = 'WARN'; Detail = "无法读取 Windows 版本：$($_.Exception.Message)" }
    }
}

function Invoke-Preflight {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rootSafety = Assert-PilotDataRootSafety -DataRoot $companyRoot -BundleRoot $bundleRoot -MinimumFreeBytes $dataRootMinimumFreeBytes -AllowExistingManaged -ExpectedUserSid $currentSid
    $wordPath = Get-RegisteredApplicationPath 'WINWORD.EXE'
    $excelPath = Get-RegisteredApplicationPath 'EXCEL.EXE'
    $powerPointPath = Get-RegisteredApplicationPath 'POWERPNT.EXE'
    $git = Get-GitInfo
    $gitInstallerValid = Test-GitInstaller
    $package = Get-ClaudePackage
    $vmp = Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction SilentlyContinue
    $coworkService = Get-Service -Name 'CoworkVMService' -ErrorAction SilentlyContinue
    $coworkSeedValid = Test-CoworkSeedSource
    $coworkCodeValid = Test-CoworkCodeSource
    $coworkFreeBytes = Get-CoworkFreeBytes
    $storageDisk = Get-ClaudeStorageDriveInfo
    $storageLayout = Get-ClaudeUserDataLayoutInfo
    $storageDiskReady = ($storageDisk -and $storageDisk.DriveType -eq 3 -and $storageDisk.FileSystem -eq 'NTFS')
    $storageDiskDetail = if ($storageDisk) { "$($storageDisk.DeviceId) | $($storageDisk.FileSystem) | DriveType=$($storageDisk.DriveType) | Runtime=$claudeUserDataLink" } else { '无法读取 C 盘信息' }
    $firmwareVirtualization = Get-FirmwareVirtualizationStatus
    $windowsCompatibility = Get-WindowsCompatibilityStatus
    $signatureStatus = 'Missing'
    $hashMatch = $false
    if (Test-Path -LiteralPath $msixPath -PathType Leaf) {
        $signatureStatus = [string](Get-AuthenticodeSignature -LiteralPath $msixPath).Status
        $hashMatch = ((Get-FileHash -LiteralPath $msixPath -Algorithm SHA256).Hash -eq $expectedMsixHash)
    }

    $rows = @(
        [pscustomobject]@{ Item = 'Windows x64'; Status = if ([Environment]::Is64BitOperatingSystem) { 'PASS' } else { 'FAIL' }; Detail = [Environment]::OSVersion.VersionString },
        [pscustomobject]@{ Item = 'Administrator token'; Status = if (Test-IsAdministrator) { 'PASS' } else { 'WARN' }; Detail = if (Test-IsAdministrator) { '已提升' } else { '图形安装阶段会请求 UAC；不得切换到另一个 Windows 账号' } },
        [pscustomobject]@{ Item = 'Windows support level'; Status = $windowsCompatibility.Status; Detail = $windowsCompatibility.Detail },
        [pscustomobject]@{ Item = 'BIOS virtualization'; Status = $firmwareVirtualization.Status; Detail = $firmwareVirtualization.Detail },
        [pscustomobject]@{ Item = 'DataRoot fixed NTFS'; Status = if ($rootSafety.DriveType -eq 3 -and $rootSafety.FileSystem -eq 'NTFS') { 'PASS' } else { 'FAIL' }; Detail = "$($rootSafety.DeviceId) | $($rootSafety.FileSystem) | Root=$companyRoot" },
        [pscustomobject]@{ Item = 'DataRoot free space'; Status = if ($rootSafety.FreeBytes -ge $dataRootMinimumFreeBytes) { 'PASS' } else { 'FAIL' }; Detail = ('{0:N1} GB free; {1:N0} GB required' -f ($rootSafety.FreeBytes / 1GB), ($dataRootMinimumFreeBytes / 1GB)) },
        [pscustomobject]@{ Item = 'C: runtime fixed NTFS'; Status = if ($storageDiskReady) { 'PASS' } else { 'FAIL' }; Detail = $storageDiskDetail },
        [pscustomobject]@{ Item = 'C: runtime free space'; Status = if ($coworkFreeBytes -ge $claudeStorageMinimumFreeBytes) { 'PASS' } else { 'FAIL' }; Detail = ('{0:N1} GB free; {1:N0} GB required' -f ($coworkFreeBytes / 1GB), ($claudeStorageMinimumFreeBytes / 1GB)) },
        [pscustomobject]@{ Item = 'Claude-3p physical layout'; Status = if ($storageLayout.Ready) { 'PASS' } else { 'FAIL' }; Detail = "$($storageLayout.Status) | $($storageLayout.Detail)" },
        [pscustomobject]@{ Item = 'Claude MSIX hash'; Status = if ($hashMatch) { 'PASS' } else { 'FAIL' }; Detail = $msixPath },
        [pscustomobject]@{ Item = 'Claude MSIX signature'; Status = if ($signatureStatus -eq 'Valid') { 'PASS' } else { 'FAIL' }; Detail = $signatureStatus },
        [pscustomobject]@{ Item = 'Git offline installer'; Status = if ($gitInstallerValid) { 'PASS' } else { 'FAIL' }; Detail = 'Git for Windows 2.55.0(3)' },
        [pscustomobject]@{ Item = 'Cowork offline seed'; Status = if ($coworkSeedValid) { 'PASS' } else { 'FAIL' }; Detail = $coworkSeedVersion },
        [pscustomobject]@{ Item = 'Cowork Host/VM Code'; Status = if ($coworkCodeValid) { 'PASS' } else { 'FAIL' }; Detail = $coworkCodeVersion },
        [pscustomobject]@{ Item = 'Microsoft Word'; Status = if ($wordPath) { 'PASS' } else { 'WARN' }; Detail = [string]$wordPath },
        [pscustomobject]@{ Item = 'Microsoft Excel'; Status = if ($excelPath) { 'PASS' } else { 'WARN' }; Detail = [string]$excelPath },
        [pscustomobject]@{ Item = 'Microsoft PowerPoint'; Status = if ($powerPointPath) { 'PASS' } else { 'WARN' }; Detail = if ($powerPointPath) { "$powerPointPath（仅检测，不提供 MCP）" } else { '未检测到；仅提示，不影响 Claude 部署' } },
        [pscustomobject]@{ Item = 'Git (Code tab)'; Status = if ($git) { 'PASS' } else { 'INFO' }; Detail = if ($git) { "$($git.VersionText) | $($git.Path)" } else { '完整部署时离线安装' } },
        [pscustomobject]@{ Item = 'Virtual Machine Platform'; Status = if ($vmp -and $vmp.InstallState -eq 1) { 'PASS' } else { 'WARN' }; Detail = if ($vmp) { "InstallState=$($vmp.InstallState)" } else { '无法读取' } },
        [pscustomobject]@{ Item = 'Claude installed'; Status = if ($package) { 'PASS' } else { 'INFO' }; Detail = if ($package) { [string]$package.Version } else { '尚未安装' } },
        [pscustomobject]@{ Item = 'Cowork VM service'; Status = if ($coworkService) { 'PASS' } elseif ($package) { 'FAIL' } else { 'INFO' }; Detail = if ($coworkService) { [string]$coworkService.Status } elseif ($package) { 'Claude 已安装但服务缺失' } else { '安装后检查' } },
        [pscustomobject]@{ Item = 'DeepSeek configured'; Status = if (Test-DeepSeekConfigured) { 'PASS' } else { 'INFO' }; Detail = '只检测地址，不读取或显示密钥' }
    )
    $rows | Format-Table -AutoSize -Wrap
    if (@($rows | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) {
        throw '预检存在 FAIL 项，请先处理后再安装。'
    }
}

function Invoke-Install {
    Assert-ExpectedUser
    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedStage 'Install'
        return
    }
    Assert-Installer
    Assert-GitInstaller
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    [void](Assert-PilotDataRootSafety -DataRoot $companyRoot -BundleRoot $bundleRoot -MinimumFreeBytes $dataRootMinimumFreeBytes -AllowExistingManaged -ExpectedUserSid $currentSid)
    [void](Assert-ClaudeStoragePreflight)
    [void](Initialize-DeploymentState)

    $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    $restartRequired = $false
    $vmpEnabledByPilot = $false
    if ($vmp.State -ne 'Enabled') {
        $featureResult = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
        $restartRequired = [bool]$featureResult.RestartNeeded
        $vmpEnabledByPilot = $true
        Write-Host '已启用 Cowork 所需的 Virtual Machine Platform。' -ForegroundColor Green
    }

    $storageSetup = $null
    $packageInstalledThisRun = $false
    try {
        $storageSetup = Initialize-ClaudeUserDataStorage
        [void](Update-DeploymentStorageState -StorageSetup $storageSetup)

        $package = Get-ClaudePackage
        if ($package -and [version]$package.Version -gt [version]$expectedClaudeVersion -and [string]$package.Version -notin $validatedPatchVersions) {
            throw "电脑已有更高版本 Claude $($package.Version)。核心功能可用，但本部署包的汉化与 Flash 补丁未验证，已停止覆盖。"
        }
        if (-not $package) {
            Add-AppxPackage -Path $msixPath
            $packageInstalledThisRun = $true
            $package = Get-ClaudePackage
        }
        if (-not $package) {
            throw 'Claude Desktop 安装后未能注册到当前 Windows 用户。'
        }
        if ([string]$package.Version -ne $expectedClaudeVersion) {
            throw "安装版本 $($package.Version) 与部署包版本 $expectedClaudeVersion 不一致。"
        }

        Stop-ClaudeDesktop
        $gitInfo = Install-GitForCode
        Install-CoworkOfflineSeed
        Install-CoworkCodeOffline
        Assert-CoworkServiceRegistered
        [void](Update-DeploymentState -GitAfter $gitInfo -VmpEnabledByPilot $vmpEnabledByPilot -ClaudeAfter $package)

        Write-Host "Claude Desktop $($package.Version) 安装完成。" -ForegroundColor Green
        if ($restartRequired) {
            Write-Host '必须先重启 Windows，然后打开 Claude 配置 DeepSeek。' -ForegroundColor Yellow
        }
        else {
            Start-ClaudeDesktop
            Write-Host 'Claude Desktop 已打开。现在请按现场指南手动录入试点专用 DeepSeek Key。' -ForegroundColor Yellow
        }
    }
    catch {
        $failure = $_
        Record-DeploymentFailure -Message $failure.Exception.Message
        if ($packageInstalledThisRun) {
            try {
                Stop-ClaudeDesktop
                Stop-Service -Name CoworkVMService -Force -ErrorAction SilentlyContinue
                $rollbackPackage = Get-ClaudePackage
                if ($rollbackPackage) {
                    Remove-AppxPackage -Package $rollbackPackage.PackageFullName -ErrorAction Stop
                }
                Write-Host '本轮新安装的 Claude Desktop 已回滚。' -ForegroundColor Yellow
            }
            catch {
                Write-Warning "Claude Desktop 自动回滚失败：$($_.Exception.Message)"
            }
        }
        Undo-ClaudeUserDataStorage $storageSetup
        throw $failure
    }
}

function Set-WorkspaceIcon {
    $refreshScript = Join-Path $PSScriptRoot 'Refresh-WorkspaceIcon.ps1'
    if (-not (Test-Path -LiteralPath $refreshScript -PathType Leaf)) {
        throw "Workspace icon helper is missing: $refreshScript"
    }
    & $refreshScript -DataRoot $companyRoot -SettingsPath $deploymentPaths.SettingsPath
}

function Invoke-Configure {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    [void](Assert-PilotDataRootSafety -DataRoot $companyRoot -BundleRoot $bundleRoot -MinimumFreeBytes $dataRootMinimumFreeBytes -AllowExistingManaged -ExpectedUserSid $currentSid)
    $configPath = Get-ClaudeConfigPath
    if (-not $configPath) {
        throw '尚未找到 Claude Desktop 配置。请先启动 Claude，在开发者模式中完成 DeepSeek 连接，完全退出 Claude 后再运行本阶段。'
    }
    if (-not (Test-DeepSeekConfigured)) {
        throw '尚未检测到 https://api.deepseek.com/anthropic。为防止配错 Windows 用户，本阶段已停止。'
    }

    Stop-ClaudeDesktop
    foreach ($path in @($companyRoot, $coworkRoot, (Join-Path $companyRoot 'MCP'), (Join-Path $companyRoot 'Backups'), $logRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    Set-WorkspaceIcon

    $configBackupRoot = Join-Path $companyRoot 'Backups\DesktopConfig'
    New-Item -ItemType Directory -Path $configBackupRoot -Force | Out-Null
    $configBackup = Join-Path $configBackupRoot ("before-workspace-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $configPath -Destination $configBackup -Force
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $config.PSObject.Properties['coworkUserFilesPath']) {
        Add-Member -InputObject $config -MemberType NoteProperty -Name 'coworkUserFilesPath' -Value $coworkRoot
    }
    else {
        $config.coworkUserFilesPath = $coworkRoot
    }
    $json = $config | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($configPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

    $officeInstaller = Join-Path $resourcesRoot 'MCP\Install-Office-Mcp.ps1'
    $officeResult = (& $officeInstaller -ClaudeConfigPath $configPath -InstallRoot (Join-Path $companyRoot 'MCP\Office') -AllowedRoot $coworkRoot -BackupRoot (Join-Path $companyRoot 'Backups\OfficeMcp')) | ConvertFrom-Json

    Start-ClaudeDesktop
    Write-Host ("工作目录已配置；Word MCP={0}，Excel MCP={1}，PowerPoint 仅检测={2}。" -f $officeResult.Word.Configured, $officeResult.Excel.Configured, $officeResult.PowerPoint.Detected) -ForegroundColor Green
    Write-Host '本阶段没有读取、复制或记录 DeepSeek API Key。' -ForegroundColor Green
}

function Invoke-OptionalPatches {
    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedStage 'OptionalPatches'
        return
    }
    $package = Get-ClaudePackage
    if (-not $package -or [string]$package.Version -notin $validatedPatchVersions) {
        throw "汉化与 Flash Max 只验证过 Claude $($validatedPatchVersions -join '、')。"
    }
    [void](Initialize-DeploymentState)
    Stop-ClaudeDesktop

    $localization = Join-Path $resourcesRoot '汉化\Install-ZhCN-Portable.ps1'
    & $localization -Elevated -UpdatePolicy $UpdatePolicy -DataRoot $companyRoot

    Stop-ClaudeDesktop
    $flash = Join-Path $resourcesRoot '配置\FlashMax\Install-Flash-Max.ps1'
    & $flash -BackupRoot (Join-Path $companyRoot 'Backups\FlashMax')
    [void](Update-DeploymentPatchState)

    Start-ClaudeDesktop
    Write-Host '简体中文兼容模式与 Flash Max 已安装，Claude Desktop 已重新打开。' -ForegroundColor Green
    if ($UpdatePolicy -eq 'Block') {
        Write-Host '稳定模式：自动更新已禁用；手动更新后请再次运行本修复入口。' -ForegroundColor Yellow
    }
    else {
        Write-Host '更新模式：允许自动更新；每次更新后都必须再次运行兼容修复，未知版本会安全停止。' -ForegroundColor Yellow
    }
}

function Invoke-FullDeployment {
    Assert-ExpectedUser
    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedStage 'Full'
        return
    }

    Write-Host '=== Claude Desktop complete pilot deployment ===' -ForegroundColor Cyan
    Invoke-Preflight
    Assert-Installer
    Assert-GitInstaller

    $installed = Get-ClaudePackage
    if ($installed -and [version]$installed.Version -gt [version]$expectedClaudeVersion -and [string]$installed.Version -notin $validatedPatchVersions) {
        throw "A newer Claude Desktop version is installed: $($installed.Version). Localization and Flash Max are only verified on: $($validatedPatchVersions -join ', ')."
    }

    $apiKey = Read-DeepSeekApiKeyTicket
    if ($apiKey) {
        Write-Host 'The encrypted key ticket was opened for this Windows user and deleted.' -ForegroundColor Cyan
    }
    else {
        $apiKey = Get-ExistingDeepSeekApiKey
    }
    if ($apiKey -and [string]::IsNullOrWhiteSpace($ApiKeyBlobPath)) {
        Write-Host 'An existing DeepSeek credential was found in this Windows account and will be reused without displaying it.' -ForegroundColor Cyan
    }
    elseif (-not $apiKey) {
        $apiKey = Read-DeepSeekApiKey
    }
    $script:SensitiveApiKey = [string]$apiKey

    $storageSetup = $null
    $configurationSnapshot = $null
    $configurationSuspended = $false
    $packageInstalledThisRun = $false
    $packageReregisterStarted = $false
    $localizationEnabled = $false
    $flashEnabled = $false
    try {
        Write-Host 'Testing DeepSeek V4 Pro and V4 Flash before changing the computer...' -ForegroundColor Cyan
        try {
            Test-DeepSeekApiKey -ApiKey $apiKey
        }
        catch {
            if (Test-DeepSeekConfigured) {
                Write-Host 'The existing DeepSeek credential failed. Enter a replacement key.' -ForegroundColor Yellow
                $apiKey = Read-DeepSeekApiKey
                $script:SensitiveApiKey = [string]$apiKey
                Test-DeepSeekApiKey -ApiKey $apiKey
            }
            else {
                throw
            }
        }
        Write-Host 'DeepSeek V4 Pro and V4 Flash connection tests passed.' -ForegroundColor Green

        [void](Assert-ClaudeStoragePreflight)
        [void](Initialize-DeploymentState)
        Set-ManagedInstallCheckpoint -Phase 'PrepareStorage' -Status 'IN_PROGRESS'
        $storageSetup = Initialize-ClaudeUserDataStorage
        [void](Update-DeploymentStorageState -StorageSetup $storageSetup)
        foreach ($path in @($companyRoot, $coworkRoot, (Join-Path $companyRoot 'MCP'), (Join-Path $companyRoot 'Backups'), $logRoot)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        $configurationSnapshot = New-DeepSeekConfigurationSnapshot
        Clear-ManagedClaudeConfiguration
        $configurationSuspended = $true
        Set-ManagedInstallCheckpoint -Phase 'PrepareStorage' -Status 'PASS' -Detail 'Encrypted configuration snapshot created; managed configuration temporarily suspended.'
        Set-ManagedInstallCheckpoint -Phase 'RegisterStockClaude' -Status 'IN_PROGRESS'
        Stop-ClaudeDesktop
        $gitInfo = Install-GitForCode

        $restartRequired = $false
        $vmpEnabledByPilot = $false
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
        if ($vmp.State -ne 'Enabled') {
            $featureResult = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
            $restartRequired = [bool]$featureResult.RestartNeeded
            $vmpEnabledByPilot = $true
            Write-Host 'Virtual Machine Platform was enabled for Cowork.' -ForegroundColor Green
        }

        $package = Get-ClaudePackage
        if ($package) {
            $packageReregisterStarted = $true
            Write-Host "Re-registering Claude Desktop $($package.Version) from the verified offline package." -ForegroundColor Cyan
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
            Add-AppxPackage -Path $msixPath
            $package = Get-ClaudePackage
        }
        elseif (-not $package) {
            Add-AppxPackage -Path $msixPath
            $packageInstalledThisRun = $true
            $package = Get-ClaudePackage
        }
        if (-not $package -or [string]$package.Version -notin $validatedPatchVersions) {
            throw "A validated Claude Desktop build was not registered for the current Windows account. Expected one of: $($validatedPatchVersions -join ', ')."
        }
        Install-CoworkOfflineSeed
        Install-CoworkCodeOffline
        Assert-CoworkServiceRegistered
        Write-Host "Claude Desktop $($package.Version) is installed." -ForegroundColor Green
        Set-WorkspaceIcon

        [void](Assert-ClaudeRuntimeStage -ValidationStage 'Stock')
        Set-ManagedInstallCheckpoint -Phase 'RegisterStockClaude' -Status 'PASS' -Detail 'Stock Claude visible window and renderer passed.'
        Restore-DeepSeekConfigurationSnapshot -Snapshot $configurationSnapshot
        $configurationSuspended = $false
        $desktopConfigPath = Write-DeepSeekConfiguration -ApiKey $apiKey
        Write-Host 'DeepSeek Pro/Flash 1M configuration was written to the Claude user profile.' -ForegroundColor Green

        $officeInstaller = Join-Path $resourcesRoot 'MCP\Install-Office-Mcp.ps1'
        $officeResult = (& $officeInstaller -ClaudeConfigPath $desktopConfigPath -InstallRoot (Join-Path $companyRoot 'MCP\Office') -AllowedRoot $coworkRoot -BackupRoot (Join-Path $companyRoot 'Backups\OfficeMcp')) | ConvertFrom-Json
        Write-Host ("Office detection completed: Word={0}/MCP={1}; Excel={2}/MCP={3}; PowerPoint={4} (detection only)." -f $officeResult.Word.Detected, $officeResult.Word.Configured, $officeResult.Excel.Detected, $officeResult.Excel.Configured, $officeResult.PowerPoint.Detected) -ForegroundColor Green

        try {
            Set-ManagedInstallCheckpoint -Phase 'ConfigureDeepSeek' -Status 'IN_PROGRESS'
            [void](Assert-ClaudeRuntimeStage -ValidationStage 'DeepSeek')
            Set-ManagedInstallCheckpoint -Phase 'ConfigureDeepSeek' -Status 'PASS' -Detail 'DeepSeek configuration passed runtime validation.'
        }
        catch {
            $deepSeekFailure = $_
            Restore-DeepSeekConfigurationSnapshot -Snapshot $configurationSnapshot
            $recoveryProbe = Test-ClaudeDesktopRuntime -ValidationStage 'Stock'
            if (-not $recoveryProbe.Passed) {
                Clear-ManagedClaudeConfiguration
                $recoveryProbe = Test-ClaudeDesktopRuntime -ValidationStage 'Stock'
            }
            Set-ManagedInstallCheckpoint -Phase 'ConfigureDeepSeek' -Status 'FAIL' -Detail $deepSeekFailure.Exception.Message
            throw $deepSeekFailure
        }

        $localization = Join-Path $resourcesRoot '汉化\Install-ZhCN-Portable.ps1'
        try {
            Set-ManagedInstallCheckpoint -Phase 'ApplyLocalization' -Status 'IN_PROGRESS'
            & $localization -Elevated -UpdatePolicy $UpdatePolicy -DataRoot $companyRoot
            [void](Assert-ClaudeRuntimeStage -ValidationStage 'Localization')
            $localizationEnabled = $true
            Set-ManagedInstallCheckpoint -Phase 'ApplyLocalization' -Status 'PASS'
        }
        catch {
            $localizationFailure = Protect-DeploymentMessage $_.Exception.Message
            $restoreEnglish = Join-Path $resourcesRoot '汉化\Restore-English-Portable.ps1'
            & $restoreEnglish -Elevated
            $recoveryProbe = Test-ClaudeDesktopRuntime -ValidationStage 'DeepSeek'
            if (-not $recoveryProbe.Passed) {
                throw "Localization rollback did not restore a working Claude runtime ($($recoveryProbe.Detail))."
            }
            Save-DeploymentRuntimeValidation -ValidationStage 'Localization' -Status 'ROLLED_BACK' -Detail $localizationFailure
            Set-ManagedInstallCheckpoint -Phase 'ApplyLocalization' -Status 'ROLLED_BACK' -Detail $localizationFailure
            Write-Warning '中文适配启动验收失败，已自动恢复英文界面。'
        }

        $flash = Join-Path $resourcesRoot '配置\FlashMax\Install-Flash-Max.ps1'
        $flashBackupRoot = Join-Path $companyRoot 'Backups\FlashMax'
        $flashManifestsBefore = @()
        if (Test-Path -LiteralPath $flashBackupRoot -PathType Container) {
            $flashManifestsBefore = @(Get-ChildItem -LiteralPath $flashBackupRoot -Filter 'restore.json' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
        $flashManifestPath = ''
        try {
            Set-ManagedInstallCheckpoint -Phase 'ApplyFlashMax' -Status 'IN_PROGRESS'
            & $flash -BackupRoot $flashBackupRoot
            $flashManifest = Get-ChildItem -LiteralPath $flashBackupRoot -Filter 'restore.json' -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notin $flashManifestsBefore } |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
            if (-not $flashManifest) {
                throw 'Flash Max did not create a transaction-specific restore manifest.'
            }
            $flashManifestPath = $flashManifest.FullName
            [void](Assert-ClaudeRuntimeStage -ValidationStage 'FlashMax')
            $flashEnabled = $true
            Set-ManagedInstallCheckpoint -Phase 'ApplyFlashMax' -Status 'PASS' -Detail 'Flash Max passed runtime validation and has an exact restore manifest.'
            Write-Host 'Flash Max reasoning was enabled.' -ForegroundColor Green
        }
        catch {
            $flashFailure = Protect-DeploymentMessage $_.Exception.Message
            $restoreFlash = Join-Path $resourcesRoot '配置\FlashMax\Restore-Flash-Default.ps1'
            if (-not $flashManifestPath -and (Test-Path -LiteralPath $flashBackupRoot -PathType Container)) {
                $newManifest = Get-ChildItem -LiteralPath $flashBackupRoot -Filter 'restore.json' -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notin $flashManifestsBefore } |
                    Sort-Object LastWriteTimeUtc -Descending |
                    Select-Object -First 1
                if ($newManifest) { $flashManifestPath = $newManifest.FullName }
            }
            if ($flashManifestPath) {
                & $restoreFlash -ManifestPath $flashManifestPath -BackupRoot $flashBackupRoot
            }
            else {
                Stop-ClaudeDesktop
                $patchedPackage = Get-ClaudePackage
                if (-not $patchedPackage) {
                    throw 'Flash Max failed without a restore manifest and Claude Desktop is no longer registered.'
                }
                Remove-AppxPackage -Package $patchedPackage.PackageFullName -ErrorAction Stop
                Add-AppxPackage -Path $msixPath -ErrorAction Stop
                if ($localizationEnabled) {
                    Save-DeploymentRuntimeValidation -ValidationStage 'Localization' -Status 'ROLLED_BACK' -Detail 'Stock package re-registration was required because Flash Max had no exact restore manifest.'
                    Set-ManagedInstallCheckpoint -Phase 'ApplyLocalization' -Status 'ROLLED_BACK' -Detail 'Stock package re-registration removed the localization layer during Flash Max recovery.'
                }
                $localizationEnabled = $false
                Write-Warning 'Flash Max 未生成精确回滚清单；已重新注册原版 Claude Desktop 以恢复受管文件。'
            }
            $stateBeforeFlash = Read-DeploymentState
            $patchBaseline = if ($stateBeforeFlash) { Get-PropertyValue $stateBeforeFlash 'Patches' } else { $null }
            $effortBefore = if ($patchBaseline) { Get-PropertyValue $patchBaseline 'EffortLevelBefore' $null } else { $null }
            [Environment]::SetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', $effortBefore, 'User')
            $recoveryStage = if ($localizationEnabled) { 'Localization' } else { 'DeepSeek' }
            $recoveryProbe = Test-ClaudeDesktopRuntime -ValidationStage $recoveryStage
            if (-not $recoveryProbe.Passed) {
                throw "Flash Max rollback did not restore a working Claude runtime ($($recoveryProbe.Detail))."
            }
            Save-DeploymentRuntimeValidation -ValidationStage 'FlashMax' -Status 'ROLLED_BACK' -Detail $flashFailure
            Set-ManagedInstallCheckpoint -Phase 'ApplyFlashMax' -Status 'ROLLED_BACK' -Detail $flashFailure
            Write-Warning 'Flash Max 启动验收失败，已自动恢复默认推理设置。'
        }

        [void](Update-DeploymentPatchState)
        $deploymentState = Update-DeploymentState -GitAfter $gitInfo -VmpEnabledByPilot $vmpEnabledByPilot -ClaudeAfter $package
        Set-ManagedInstallCheckpoint -Phase 'Completed' -Status 'PASS' -Detail $(if ($restartRequired) { 'Windows restart and automatic resume are pending.' } else { 'Managed installation completed without a pending restart.' })

        $report = [ordered]@{
            CompletedAt = (Get-Date).ToString('o')
            WindowsUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            ClaudeVersion = [string]$package.Version
            DataRoot = $companyRoot
            DataRootResolutionSource = $deploymentPaths.ResolutionSource
            ClaudeUserDataLayout = 'PhysicalLocalAppData'
            ClaudeUserDataLogicalPath = $claudeUserDataLink
            ClaudeUserDataPhysicalPath = $claudeUserDataLink
            LegacyClaudeUserDataTarget = $legacyClaudeUserDataTarget
            LegacyCopyPreserved = (Test-Path -LiteralPath $legacyClaudeUserDataTarget -PathType Container)
            UpdatePolicy = $UpdatePolicy
            DeepSeekBaseUrl = 'https://api.deepseek.com/anthropic'
            DeepSeekProProbe = 'PASS'
            DeepSeekFlashProbe = 'PASS'
            ApiKeyRecordedInReport = $false
            Models = @('DeepSeek V4 Pro (1M)', 'DeepSeek V4 Flash (1M)')
            Chinese = if ($localizationEnabled) { 'PASS' } else { 'ROLLED_BACK' }
            FlashMax = if ($flashEnabled) { 'PASS' } else { 'ROLLED_BACK' }
            RuntimeValidation = 'STAGED'
            CoworkPath = $coworkRoot
            CoworkOfflineSeed = 'PASS'
            CoworkBundleVersion = $coworkSeedVersion
            CoworkHostVmCode = 'PASS'
            CoworkCodeVersion = $coworkCodeVersion
            CoworkVMService = 'REGISTERED'
            GitForCode = 'PASS'
            GitVersion = $gitInfo.VersionText
            GitPath = $gitInfo.Path
            GitInstalledByPilot = [bool]$deploymentState.Git.InstalledByPilot
            GitPresentBeforeDeployment = [bool]$deploymentState.Git.PresentBefore
            VirtualMachinePlatformEnabledByPilot = [bool]$deploymentState.VirtualMachinePlatform.EnabledByPilot
            WordDetected = [bool]$officeResult.Word.Detected
            WordMcp = if ($officeResult.Word.Configured) { 'INSTALLED' } else { 'NOT_APPLICABLE' }
            ExcelDetected = [bool]$officeResult.Excel.Detected
            ExcelMcp = if ($officeResult.Excel.Configured) { 'INSTALLED' } else { 'NOT_APPLICABLE' }
            PowerPointDetected = [bool]$officeResult.PowerPoint.Detected
            PowerPointMcp = 'NOT_PROVIDED'
            RestartRequired = $restartRequired
            ForceReinstall = [bool]$ForceReinstall
            ManagedReregistration = $true
        }
        $reportPath = Join-Path $logRoot ("deployment-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

        if ($restartRequired) {
            Write-Host 'Complete deployment finished. Restart Windows once before opening Claude Desktop.' -ForegroundColor Yellow
        }
        else {
            Start-ClaudeDesktop
            Start-Sleep -Seconds 5
            Write-Host 'Claude Desktop was started with the complete configuration.' -ForegroundColor Green
        }
        Write-Host "Sanitized deployment report: $reportPath" -ForegroundColor Green
    }
    catch {
        $failure = $_
        try { Set-ManagedInstallCheckpoint -Phase 'Failed' -Status 'FAIL' -Detail $failure.Exception.Message } catch {}
        Record-DeploymentFailure -Message $failure.Exception.Message
        if ($configurationSuspended -and $configurationSnapshot) {
            try { Restore-DeepSeekConfigurationSnapshot -Snapshot $configurationSnapshot } catch { Write-Warning "Claude 配置自动恢复失败：$(Protect-DeploymentMessage $_.Exception.Message)" }
        }
        if ($packageReregisterStarted -and -not (Get-ClaudePackage)) {
            try {
                Add-AppxPackage -Path $msixPath -ErrorAction Stop
                Write-Host '安装失败后已重新注册原离线 Claude Desktop 包。' -ForegroundColor Yellow
            }
            catch {
                Write-Warning "Claude Desktop 重新注册回滚失败：$($_.Exception.Message)"
            }
        }
        if ($packageInstalledThisRun) {
            try {
                Stop-ClaudeDesktop
                Stop-Service -Name CoworkVMService -Force -ErrorAction SilentlyContinue
                $rollbackPackage = Get-ClaudePackage
                if ($rollbackPackage) {
                    Remove-AppxPackage -Package $rollbackPackage.PackageFullName -ErrorAction Stop
                }
                Write-Host '本轮新安装的 Claude Desktop 已回滚。' -ForegroundColor Yellow
            }
            catch {
                Write-Warning "Claude Desktop 自动回滚失败：$($_.Exception.Message)"
            }
        }
        Undo-ClaudeUserDataStorage $storageSetup
        throw $failure
    }
    finally {
        $apiKey = $null
        $script:SensitiveApiKey = ''
    }
}

function Invoke-Verify {
    if (Test-Path -LiteralPath $deploymentStatePath -PathType Leaf) {
        [void](Initialize-DeploymentState)
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ownership = Get-PilotDataRootOwnership -DataRoot $companyRoot -ExpectedUserSid $currentSid
    $package = Get-ClaudePackage
    $configPath = Get-ClaudeConfigPath
    $config = $null
    if ($configPath) {
        try { $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    $runtime = Join-Path $companyRoot 'MCP\Office\Office-McpServer.ps1'
    $wordPath = Get-RegisteredApplicationPath 'WINWORD.EXE'
    $excelPath = Get-RegisteredApplicationPath 'EXCEL.EXE'
    $powerPointPath = Get-RegisteredApplicationPath 'POWERPNT.EXE'
    $wordRegistered = $false
    $excelRegistered = $false
    if ($config -and $null -ne $config.PSObject.Properties['mcpServers']) {
        $wordRegistered = ($null -ne $config.mcpServers.PSObject.Properties['word'] -or $null -ne $config.mcpServers.PSObject.Properties['claude_pilot_word'])
        $excelRegistered = ($null -ne $config.mcpServers.PSObject.Properties['excel'] -or $null -ne $config.mcpServers.PSObject.Properties['claude_pilot_excel'])
    }
    $expectedMcpProcessCount = 0
    if ($wordRegistered) { $expectedMcpProcessCount++ }
    if ($excelRegistered) { $expectedMcpProcessCount++ }
    $chinesePresent = $false
    $flashMax = $false
    if ($package) {
        $zhPath = Join-Path $package.InstallLocation 'app\resources\ion-dist\i18n\zh-CN.json'
        $chinesePresent = Test-Path -LiteralPath $zhPath -PathType Leaf
        $assets = Join-Path $package.InstallLocation 'app\resources\ion-dist\assets\v1'
        if (Test-Path -LiteralPath $assets -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $assets -Filter '*.js' -File) {
                if ([IO.File]::ReadAllText($file.FullName).Contains('"claude-sonnet-5":"max"')) {
                    $flashMax = $true
                    break
                }
            }
        }
    }
    $serverProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*Office-McpServer.ps1*' })
    $coworkService = Get-Service -Name 'CoworkVMService' -ErrorAction SilentlyContinue
    $vmp = Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction SilentlyContinue
    $seedInstalled = Test-CoworkSeedInstalled
    $runtimeReady = Test-CoworkRuntimeReady
    $coworkCodeInstalled = Test-CoworkCodeInstalled
    $gitInfo = Get-GitInfo
    $storageLayout = Get-ClaudeUserDataLayoutInfo
    $storageDisk = Get-ClaudeStorageDriveInfo
    $updatePreference = Get-ClaudeUpdatePreference

    @(
        [pscustomobject]@{ Item = 'Claude Desktop'; Status = if ($package) { 'PASS' } else { 'FAIL' }; Detail = if ($package) { [string]$package.Version } else { '未安装' } },
        [pscustomobject]@{ Item = 'Managed DataRoot'; Status = if ($ownership.Trusted) { 'PASS' } else { 'FAIL' }; Detail = "$companyRoot | $($ownership.Status) | $($deploymentPaths.ResolutionSource)" },
        [pscustomobject]@{ Item = 'Deployment pointer'; Status = if (Test-Path -LiteralPath $deploymentPointerPath -PathType Leaf) { 'PASS' } else { 'FAIL' }; Detail = $deploymentPointerPath },
        [pscustomobject]@{ Item = 'Claude-3p physical layout'; Status = if ($storageLayout.Status -eq 'PhysicalLocalAppData') { 'PASS' } else { 'FAIL' }; Detail = "$($storageLayout.Status) | $($storageLayout.Detail)" },
        [pscustomobject]@{ Item = 'Claude-3p active path'; Status = if (Test-Path -LiteralPath $claudeUserDataLink -PathType Container) { 'PASS' } else { 'FAIL' }; Detail = if ($storageDisk) { "$claudeUserDataLink | $($storageDisk.FileSystem) | $([math]::Round($storageDisk.FreeBytes / 1GB, 1)) GB free" } else { $claudeUserDataLink } },
        [pscustomobject]@{ Item = 'Legacy D: runtime copy'; Status = 'INFO'; Detail = if (Test-Path -LiteralPath $legacyClaudeUserDataTarget -PathType Container) { "保留待人工确认：$legacyClaudeUserDataTarget" } else { '不存在' } },
        [pscustomobject]@{ Item = 'DeepSeek URL'; Status = if (Test-DeepSeekConfigured) { 'PASS' } else { 'FAIL' }; Detail = '不显示密钥' },
        [pscustomobject]@{ Item = 'Claude update mode'; Status = 'INFO'; Detail = "$($updatePreference.Mode) | $($updatePreference.Source)" },
        [pscustomobject]@{ Item = 'Virtual Machine Platform'; Status = if ($vmp -and $vmp.InstallState -eq 1) { 'PASS' } else { 'FAIL' }; Detail = if ($vmp) { "InstallState=$($vmp.InstallState)" } else { '无法读取' } },
        [pscustomobject]@{ Item = 'Cowork VM service'; Status = if ($coworkService) { 'PASS' } else { 'FAIL' }; Detail = if ($coworkService) { [string]$coworkService.Status } else { '未注册' } },
        [pscustomobject]@{ Item = 'Cowork offline seed'; Status = if ($seedInstalled) { 'PASS' } else { 'FAIL' }; Detail = $coworkSeedVersion },
        [pscustomobject]@{ Item = 'Cowork Host/VM Code'; Status = if ($coworkCodeInstalled) { 'PASS' } else { 'FAIL' }; Detail = $coworkCodeVersion },
        [pscustomobject]@{ Item = 'Git for Code'; Status = if ($gitInfo) { 'PASS' } else { 'FAIL' }; Detail = if ($gitInfo) { "$($gitInfo.VersionText) | $($gitInfo.Path)" } else { '未安装或不在可检测路径' } },
        [pscustomobject]@{ Item = 'Cowork expanded runtime'; Status = if ($runtimeReady) { 'PASS' } else { 'INFO' }; Detail = if ($runtimeReady) { '本地解压完成' } else { '首次进入 Cowork 后检查' } },
        [pscustomobject]@{ Item = 'Cowork path'; Status = if ($config -and $config.coworkUserFilesPath -eq $coworkRoot) { 'PASS' } else { 'FAIL' }; Detail = if ($config) { [string]$config.coworkUserFilesPath } else { '无配置' } },
        [pscustomobject]@{ Item = 'Word MCP'; Status = if ($wordPath -and $wordRegistered) { 'PASS' } elseif ($wordPath) { 'FAIL' } else { 'WARN' }; Detail = if ($wordPath) { "$wordPath | registered=$wordRegistered" } else { '未安装 Word；允许继续，后装 Office 后运行修复' } },
        [pscustomobject]@{ Item = 'Excel MCP'; Status = if ($excelPath -and $excelRegistered) { 'PASS' } elseif ($excelPath) { 'FAIL' } else { 'WARN' }; Detail = if ($excelPath) { "$excelPath | registered=$excelRegistered" } else { '未安装 Excel；允许继续，后装 Office 后运行修复' } },
        [pscustomobject]@{ Item = 'PowerPoint detection'; Status = if ($powerPointPath) { 'PASS' } else { 'WARN' }; Detail = if ($powerPointPath) { "$powerPointPath | 仅检测，不提供 MCP" } else { '未安装；不影响 Claude 部署' } },
        [pscustomobject]@{ Item = 'Office MCP runtime'; Status = if (($wordPath -or $excelPath) -and (Test-Path -LiteralPath $runtime)) { 'PASS' } elseif ($wordPath -or $excelPath) { 'FAIL' } else { 'INFO' }; Detail = $runtime },
        [pscustomobject]@{ Item = 'MCP processes'; Status = if ($expectedMcpProcessCount -eq 0) { 'INFO' } elseif ($serverProcesses.Count -ge $expectedMcpProcessCount) { 'PASS' } else { 'WARN' }; Detail = "$($serverProcesses.Count)（Claude 打开并调用工具后出现）" },
        [pscustomobject]@{ Item = 'Chinese resources'; Status = if ($chinesePresent) { 'PASS' } else { 'INFO' }; Detail = '可选项' },
        [pscustomobject]@{ Item = 'Flash Max'; Status = if ($flashMax -and [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'User') -eq 'max') { 'PASS' } else { 'INFO' }; Detail = '可选项' }
    ) | Format-Table -AutoSize -Wrap
}

if ($Stage -eq 'Menu') {
    Write-Host '=== Claude Desktop 单机试点部署 ===' -ForegroundColor Cyan
    Write-Host "数据根目录：$companyRoot（来源：$($deploymentPaths.ResolutionSource)）" -ForegroundColor Cyan
    Write-Host "更新策略：$UpdatePolicy（Block=稳定交付；Allow=允许更新后再修复）" -ForegroundColor Cyan
    Write-Host '[1] 完整自动部署（推荐：桌面端 + Cowork/Code + Git + DeepSeek + 汉化 + MCP）'
    Write-Host '[2] 部署前检查（不修改电脑）'
    Write-Host '[3] 仅安装 Claude Desktop、Cowork 系统组件与 Git'
    Write-Host '[4] 仅配置受管工作区、Word MCP、Excel MCP'
    Write-Host '[5] 仅安装简体中文与 Flash Max'
    Write-Host '[6] 验收状态'
    Write-Host '[Q] 退出'
    $selection = (Read-Host '请选择').Trim()
    switch -Regex ($selection) {
        '^1$' { Invoke-FullDeployment }
        '^2$' { Invoke-Preflight }
        '^3$' { Invoke-Install }
        '^4$' { Invoke-Configure }
        '^5$' { Invoke-OptionalPatches }
        '^6$' { Invoke-Verify }
        '^[Qq]$' { exit 0 }
        default { throw '无效选择。' }
    }
}
else {
    switch ($Stage) {
        'Full' { Invoke-FullDeployment }
        'Preflight' { Invoke-Preflight }
        'Install' { Invoke-Install }
        'Configure' { Invoke-Configure }
        'OptionalPatches' { Invoke-OptionalPatches }
        'Verify' { Invoke-Verify }
    }
}
