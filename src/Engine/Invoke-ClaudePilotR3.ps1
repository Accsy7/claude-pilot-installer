[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Preflight', 'Install', 'Repair', 'Verify', 'Resume', 'Uninstall')]
    [string]$Action,

    [string]$DataRoot = '',

    [string]$ExpectedUserSid = '',

    [string]$ApiKeyBlobPath = '',

    [string]$ProgressPath = '',

    [string]$ResultPath = '',

    [string]$SetupExePath = '',

    [ValidateSet('PreserveWork', 'FullCleanup')]
    [string]$UninstallMode = 'PreserveWork',

    [switch]$RemoveGit,

    [switch]$DisableVmp,

    [switch]$ForceReinstall,

    [ValidateSet('Block', 'Allow')]
    [string]$UpdatePolicy = 'Block'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

$script:PackageVersion = 'R3.5-20260718'
$script:ProductName = 'Claude Pilot R3.5'
$script:EngineRoot = $PSScriptRoot
$script:ResourcesRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ProgressPercent = 0
$script:MutationStarted = $false
$script:TransactionId = [guid]::NewGuid().ToString('D')
$script:StartedAt = Get-Date
$script:DataRootExistedBefore = $false

$pathModule = Join-Path $PSScriptRoot 'Deployment-Paths.ps1'
if (-not (Test-Path -LiteralPath $pathModule -PathType Leaf)) {
    throw "R3 path module is missing: $pathModule"
}
. $pathModule

function Set-R3Property {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function Protect-R3Message {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return '' }
    $safe = $Message
    $safe = [regex]::Replace($safe, '(?i)(Bearer\s+)[^\s,;]+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)sk-[A-Za-z0-9_-]{8,}', '[REDACTED-KEY]')
    $safe = [regex]::Replace($safe, '(?i)(api[_ -]?key\s*[:=]\s*)[^\s,;]+', '$1[REDACTED]')
    return $safe
}

function Get-R3TransientRoot {
    return [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'ClaudePilotR3')).TrimEnd('\')
}

function Assert-R3TransientPath {
    param([string]$Path, [string]$Purpose)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $full = [IO.Path]::GetFullPath($Path)
    $root = Get-R3TransientRoot
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Purpose path must be below the Claude Pilot R3.5 temporary directory."
    }
    return $full
}

if ($ProgressPath) { $ProgressPath = Assert-R3TransientPath $ProgressPath 'Progress' }
if ($ResultPath) { $ResultPath = Assert-R3TransientPath $ResultPath 'Result' }

function Write-R3Progress {
    param(
        [int]$Percent,
        [ValidateSet('INFO', 'PASS', 'WARN', 'FAIL')][string]$Level,
        [string]$Message
    )
    $Percent = [math]::Max(0, [math]::Min(100, $Percent))
    $script:ProgressPercent = $Percent
    $safe = Protect-R3Message $Message
    Write-Host $safe
    if (-not $ProgressPath) { return }
    $parent = Split-Path -Parent $ProgressPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $event = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        percent = $Percent
        level = $Level
        message = $safe
    }
    $line = ($event | ConvertTo-Json -Compress) + [Environment]::NewLine
    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($line)
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $stream = $null
        try {
            $stream = [IO.File]::Open(
                $ProgressPath,
                [IO.FileMode]::Append,
                [IO.FileAccess]::Write,
                [IO.FileShare]::ReadWrite
            )
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            return
        }
        catch [IO.IOException] {
            if ($attempt -ge 7) {
                Write-Warning '实时进度通道暂时不可写；部署主流程继续，最终结果仍以结果文件和验收报告为准。'
                return
            }
            Start-Sleep -Milliseconds (20 * ($attempt + 1))
        }
        finally {
            if ($stream) { $stream.Dispose() }
        }
    }
}

function Write-R3Result {
    param($Value)
    if (-not $ResultPath) { return }
    $parent = Split-Path -Parent $ResultPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ('.r3-result-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText(
            $temp,
            ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
            (New-Object Text.UTF8Encoding($false))
        )
        Move-Item -LiteralPath $temp -Destination $ResultPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Test-R3Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-R3ExpectedUser {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid)) {
        throw 'The graphical launcher did not provide the original Windows user SID.'
    }
    if ($currentSid -ne $ExpectedUserSid) {
        throw 'UAC switched to another Windows account. Deployment stopped before reading the API Key ticket or changing the target profile.'
    }
}

function New-R3Check {
    param(
        [string]$Name,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO', 'MANUAL')][string]$Status,
        [string]$Detail,
        [bool]$Blocking = $false
    )
    return [pscustomobject]@{
        name = $Name
        status = $Status
        detail = (Protect-R3Message $Detail)
        blocking = $Blocking
    }
}

function Get-R3RegisteredApplicationPath {
    param([Parameter(Mandatory = $true)][string]$ExecutableName)
    foreach ($registryPath in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExecutableName",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$ExecutableName",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExecutableName"
    )) {
        $record = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if (-not $record) { continue }
        $property = $record.PSObject.Properties['(default)']
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $candidate = [Environment]::ExpandEnvironmentVariables([string]$property.Value).Trim('"')
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [IO.Path]::GetFullPath($candidate)
            }
        }
    }
    $commonRoots = @(
        (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16'),
        (Join-Path $env:ProgramFiles 'Microsoft Office\Office16'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16' }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\Office16' }),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Office\root\Office16')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    foreach ($root in $commonRoots) {
        $candidate = Join-Path $root $ExecutableName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-R3ClaudePackage {
    return Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Get-R3GitInfo {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('HKLM:\Software\GitForWindows', 'HKCU:\Software\GitForWindows')) {
        $record = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($record -and $record.InstallPath) {
            $candidates.Add((Join-Path ([string]$record.InstallPath) 'cmd\git.exe'))
        }
    }
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }
    $candidates.Add((Join-Path $env:ProgramFiles 'Git\cmd\git.exe'))
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $versionText = (& $candidate --version 2>$null | Select-Object -First 1)
            if ($versionText -match '(\d+)\.(\d+)\.(\d+)(?:\.windows\.(\d+)|\.(\d+))?') {
                $revision = if ($matches[4]) { [int]$matches[4] } elseif ($matches[5]) { [int]$matches[5] } else { 0 }
                return [pscustomobject]@{
                    Path = [IO.Path]::GetFullPath($candidate)
                    Version = [version]("{0}.{1}.{2}.{3}" -f $matches[1], $matches[2], $matches[3], $revision)
                    VersionText = [string]$versionText
                }
            }
        }
        catch {}
    }
    return $null
}

function Get-R3ReparseTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) { return $null }
    $property = $item.PSObject.Properties['Target']
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    $target = [string](@($property.Value)[0])
    if ([string]::IsNullOrWhiteSpace($target)) { return $null }
    if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $Path) $target }
    return [IO.Path]::GetFullPath($target)
}

function Get-R3ClaudeLayout {
    param([string]$ResolvedDataRoot)
    $path = Join-Path $env:LOCALAPPDATA 'Claude-3p'
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        return [pscustomobject]@{ Status = 'FreshPhysicalDirectory'; Ready = $true; Path = $path; Target = ''; Detail = '将创建真实物理目录，不建立任何链接。' }
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $target = Get-R3ReparseTarget $path
        $legacy = Join-Path $ResolvedDataRoot 'Runtime\Claude-3p'
        $managed = $false
        try { if ($target) { $managed = Test-PilotSamePath $target $legacy } } catch {}
        if ($managed -and (Test-Path -LiteralPath $legacy -PathType Container)) {
            return [pscustomobject]@{ Status = 'LegacyManagedJunction'; Ready = $false; Path = $path; Target = $target; Detail = "$path -> $target；请使用修复/补齐组件。" }
        }
        return [pscustomobject]@{ Status = 'ForeignOrBrokenLink'; Ready = $false; Path = $path; Target = [string]$target; Detail = "$path 是未知或损坏的重解析点，禁止自动改写。" }
    }
    if (-not $item.PSIsContainer) {
        return [pscustomobject]@{ Status = 'LogicalPathIsFile'; Ready = $false; Path = $path; Target = ''; Detail = "$path 是文件而不是目录。" }
    }
    return [pscustomobject]@{ Status = 'PhysicalLocalAppData'; Ready = $true; Path = $path; Target = $path; Detail = "$path 是真实物理目录。" }
}

function Test-R3ResourceManifest {
    $manifestPath = Join-Path $script:ResourcesRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject]@{ Passed = $false; Detail = '资源 manifest.json 不存在。'; Count = 0 }
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$manifest.packageVersion -ne $script:PackageVersion) {
            return [pscustomobject]@{ Passed = $false; Detail = "资源版本是 $($manifest.packageVersion)，预期 $script:PackageVersion。"; Count = 0 }
        }
        $resourceRootFull = [IO.Path]::GetFullPath($script:ResourcesRoot).TrimEnd('\')
        $count = 0
        foreach ($entry in @($manifest.files)) {
            $relative = [string]$entry.path
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "manifest contains an unsafe path: $relative"
            }
            $path = [IO.Path]::GetFullPath((Join-Path $script:ResourcesRoot $relative))
            if (-not $path.StartsWith($resourceRootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "manifest path escapes the resource root: $relative"
            }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "resource is missing: $relative" }
            $item = Get-Item -LiteralPath $path
            if ([int64]$item.Length -ne [int64]$entry.size) { throw "resource size mismatch: $relative" }
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if ($hash -ne [string]$entry.sha256) { throw "resource hash mismatch: $relative" }
            $count++
        }
        $listed = @($manifest.files | ForEach-Object { [string]$_.path })
        $rootManifest = Join-Path $script:ResourcesRoot 'manifest.json'
        $rootSums = Join-Path $script:ResourcesRoot 'SHA256SUMS'
        $actual = @(
            Get-ChildItem -LiteralPath $script:ResourcesRoot -Recurse -File |
                Where-Object { $_.FullName -notin @($rootManifest, $rootSums) } |
                ForEach-Object { $_.FullName.Substring($resourceRootFull.Length + 1) }
        )
        if (@($listed | Select-Object -Unique).Count -ne $listed.Count) {
            throw 'manifest contains duplicate file paths.'
        }
        $unlisted = @($actual | Where-Object { $_ -notin $listed })
        $notOnDisk = @($listed | Where-Object { $_ -notin $actual })
        if ($unlisted.Count -gt 0 -or $notOnDisk.Count -gt 0) {
            throw "manifest coverage mismatch: unlisted=$($unlisted.Count), not-on-disk=$($notOnDisk.Count)"
        }
        return [pscustomobject]@{ Passed = $true; Detail = "$count 个资源文件逐项 SHA-256 通过。"; Count = $count }
    }
    catch {
        return [pscustomobject]@{ Passed = $false; Detail = (Protect-R3Message $_.Exception.Message); Count = 0 }
    }
}

function Test-R3DeepSeekReachability {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [void](Invoke-WebRequest -Uri 'https://api.deepseek.com' -Method Head -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop)
        return [pscustomobject]@{ Status = 'PASS'; Detail = 'DeepSeek API 域名可达；Key 将在安装时单独验证。' }
    }
    catch {
        if ($_.Exception.Response) {
            return [pscustomobject]@{ Status = 'PASS'; Detail = '已收到 DeepSeek HTTP 响应；Key 将在安装时单独验证。' }
        }
        return [pscustomobject]@{ Status = 'WARN'; Detail = '当前无法连接 DeepSeek；离线资源仍可检查，但安装前需恢复 API 网络。' }
    }
}

function Get-R3PreflightChecks {
    param($Paths)
    $checks = New-Object System.Collections.Generic.List[object]
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $build = 0
    if ($os) { [void][int]::TryParse([string]$os.BuildNumber, [ref]$build) }
    $supportedWindows = ([Environment]::Is64BitOperatingSystem -and $os -and ([string]$os.Caption -match 'Windows (10|11)') -and $build -ge 19045)
    $checks.Add((New-R3Check 'Windows x64 与版本' $(if ($supportedWindows) { 'PASS' } else { 'FAIL' }) $(if ($os) { "$($os.Caption) | Build $build | x64=$([Environment]::Is64BitOperatingSystem)" } else { '无法读取 Windows 版本。' }) (-not $supportedWindows)))

    $isAdmin = Test-R3Administrator
    $checks.Add((New-R3Check '管理员权限' $(if ($isAdmin) { 'PASS' } else { 'WARN' }) $(if ($isAdmin) { '当前进程已提升。' } else { '安装/修复/卸载时将请求 UAC；UAC 不得切换账号。' }) $false))
    $checks.Add((New-R3Check 'PowerShell 5.1' $(if ($PSVersionTable.PSVersion -ge [version]'5.1') { 'PASS' } else { 'FAIL' }) $PSVersionTable.PSVersion.ToString() ($PSVersionTable.PSVersion -lt [version]'5.1')))

    try {
        $rootSafety = Assert-PilotDataRootSafety -DataRoot $Paths.DataRoot -BundleRoot $script:ResourcesRoot -MinimumFreeBytes 5GB -AllowExistingManaged -ExpectedUserSid $currentSid
        $checks.Add((New-R3Check '数据目录固定 NTFS 与空间' 'PASS' ("{0} | {1} | {2:N1} GB 可用 | {3}" -f $rootSafety.DeviceId, $rootSafety.FileSystem, ($rootSafety.FreeBytes / 1GB), $Paths.DataRoot) $false))
    }
    catch {
        $checks.Add((New-R3Check '数据目录固定 NTFS 与空间' 'FAIL' $_.Exception.Message $true))
    }

    $runtimePath = Join-Path $env:LOCALAPPDATA 'Claude-3p'
    try {
        $device = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($runtimePath)).TrimEnd('\')
        $escaped = $device.Replace("'", "''")
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$escaped'" -ErrorAction Stop
        $runtimeDiskReady = ([int]$disk.DriveType -eq 3 -and [string]$disk.FileSystem -eq 'NTFS' -and [int64]$disk.FreeSpace -ge 20GB)
        $checks.Add((New-R3Check 'C 盘 Cowork 运行时空间' $(if ($runtimeDiskReady) { 'PASS' } else { 'FAIL' }) ("{0} | {1} | {2:N1} GB 可用；要求固定 NTFS 且至少 20 GB" -f $device, $disk.FileSystem, ([int64]$disk.FreeSpace / 1GB)) (-not $runtimeDiskReady)))
    }
    catch {
        $checks.Add((New-R3Check 'C 盘 Cowork 运行时空间' 'FAIL' $_.Exception.Message $true))
    }

    $layout = Get-R3ClaudeLayout $Paths.DataRoot
    $checks.Add((New-R3Check 'Claude-3p 物理目录' $(if ($layout.Ready) { 'PASS' } else { 'FAIL' }) ("{0} | {1}" -f $layout.Status, $layout.Detail) (-not $layout.Ready)))

    try {
        $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $isVirtualMachine = ([string]$system.Manufacturer -match '(?i)VMware|innotek|QEMU|Xen|Parallels') -or ([string]$system.Model -match '(?i)Virtual Machine|VirtualBox|VMware|KVM|HVM|Parallels')
        $virtualization = if ($isVirtualMachine) {
            [bool]$cpu.VirtualizationFirmwareEnabled
        }
        else {
            [bool]$system.HypervisorPresent -or [bool]$cpu.VirtualizationFirmwareEnabled
        }
        $detail = "Manufacturer={0}; Model={1}; VirtualMachine={2}; HypervisorPresent={3}; VirtualizationFirmwareEnabled={4}" -f $system.Manufacturer, $system.Model, $isVirtualMachine, $system.HypervisorPresent, $cpu.VirtualizationFirmwareEnabled
        $checks.Add((New-R3Check 'BIOS/UEFI 或嵌套虚拟化' $(if ($virtualization) { 'PASS' } else { 'FAIL' }) $detail (-not $virtualization)))
    }
    catch {
        $checks.Add((New-R3Check 'BIOS/UEFI 虚拟化' 'WARN' '系统未提供可靠状态；请在任务管理器 CPU 页或 BIOS 人工确认。' $false))
    }

    $vmp = Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction SilentlyContinue
    $checks.Add((New-R3Check 'VirtualMachinePlatform' $(if ($vmp -and [int]$vmp.InstallState -eq 1) { 'PASS' } else { 'WARN' }) $(if ($vmp) { "InstallState=$($vmp.InstallState)；未启用时安装器会启用并安排重启续装。" } else { '无法读取；安装阶段会再次检查。' }) $false))

    Write-R3Progress 8 'INFO' '正在逐项验证离线资源 SHA-256。'
    $manifestResult = Test-R3ResourceManifest
    $checks.Add((New-R3Check '离线资源完整性' $(if ($manifestResult.Passed) { 'PASS' } else { 'FAIL' }) $manifestResult.Detail (-not $manifestResult.Passed)))

    $msix = Join-Path $script:ResourcesRoot 'Claude\Claude-Desktop-x64.msix'
    $gitInstaller = Join-Path $script:ResourcesRoot 'Git\Git-2.55.0.3-64-bit.exe'
    $hostCode = Join-Path $script:ResourcesRoot 'Cowork\claude-code\2.1.209\claude.exe'
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'Claude MSIX 厂商签名'; Path = $msix; Pattern = 'Anthropic' },
        [pscustomobject]@{ Name = 'Git 安装器厂商签名'; Path = $gitInstaller; Pattern = 'Johannes Schindelin' },
        [pscustomobject]@{ Name = 'Cowork Host Code 厂商签名'; Path = $hostCode; Pattern = 'Anthropic' }
    )) {
        try {
            $signature = Get-AuthenticodeSignature -LiteralPath $entry.Path
            $passed = ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match $entry.Pattern)
            $checks.Add((New-R3Check $entry.Name $(if ($passed) { 'PASS' } else { 'FAIL' }) ("{0} | {1}" -f $signature.Status, $signature.SignerCertificate.Subject) (-not $passed)))
        }
        catch {
            $checks.Add((New-R3Check $entry.Name 'FAIL' $_.Exception.Message $true))
        }
    }

    $package = Get-R3ClaudePackage
    if ($package) {
        $version = [string]$package.Version
        $known = $version -in @('1.21459.3.0', '1.22209.0.0')
        $checks.Add((New-R3Check '已有 Claude Desktop' $(if ($known) { 'PASS' } else { 'FAIL' }) "$version | $($package.InstallLocation)" (-not $known)))
    }
    else {
        $checks.Add((New-R3Check '已有 Claude Desktop' 'INFO' '未安装；将从离线 MSIX 安装。' $false))
    }

    $git = Get-R3GitInfo
    if ($git) {
        $checks.Add((New-R3Check '已有 Git' $(if ($git.Version -ge [version]'2.55.0.3') { 'PASS' } else { 'WARN' }) "$($git.VersionText) | $($git.Path)" $false))
    }
    else {
        $checks.Add((New-R3Check '已有 Git' 'INFO' '未安装；将使用离线安装器。' $false))
    }

    $word = Get-R3RegisteredApplicationPath 'WINWORD.EXE'
    $excel = Get-R3RegisteredApplicationPath 'EXCEL.EXE'
    $powerPoint = Get-R3RegisteredApplicationPath 'POWERPNT.EXE'
    $checks.Add((New-R3Check 'Microsoft Word' $(if ($word) { 'PASS' } else { 'WARN' }) $(if ($word) { $word } else { '未检测到；跳过 Word MCP，但允许部署 Claude。' }) $false))
    $checks.Add((New-R3Check 'Microsoft Excel' $(if ($excel) { 'PASS' } else { 'WARN' }) $(if ($excel) { $excel } else { '未检测到；跳过 Excel MCP，但允许部署 Claude。' }) $false))
    $checks.Add((New-R3Check 'Microsoft PowerPoint' $(if ($powerPoint) { 'PASS' } else { 'WARN' }) $(if ($powerPoint) { "$powerPoint | 仅检测，不提供 MCP。" } else { '未检测到；不影响部署。' }) $false))

    $network = Test-R3DeepSeekReachability
    $checks.Add((New-R3Check 'DeepSeek API 网络' $network.Status $network.Detail $false))
    return $checks.ToArray()
}

function Get-R3Preview {
    param([string]$TargetAction, $Paths)
    switch ($TargetAction) {
        'Install' {
            return @(
                "安装或复用 Claude Desktop 1.21459.3.0 与 Git 2.55.0.3",
                "创建真实目录：$env:LOCALAPPDATA\Claude-3p（禁止联接/符号链接）",
                "复制 Cowork 离线运行时与内置 Host/VM Code，不安装独立 CLI",
                "必要时启用 VirtualMachinePlatform，并配置登录后自动续装",
                "写入 DeepSeek 网关、中文适配、Flash Max；Key 不进入日志/状态",
                "数据目录：$($Paths.DataRoot)；Word/Excel MCP 按检测结果选择性配置"
            )
        }
        'Repair' {
            return @(
                '修复已知 R2 旧联接并把 Cowork 核心运行时安全迁回 C 盘真实目录',
                '重新校验并补齐 Claude、Cowork、Git、中文、Flash Max 与 DeepSeek 配置',
                '重新检测 Office；后装 Word/Excel 时补齐 MCP，PowerPoint 仍只检测',
                '保留旧联接目标副本，直到真实 Cowork 任务人工验收完成'
            )
        }
        'Verify' { return @('执行结构化静态验收并生成脱敏报告；真实 Cowork/Office 任务仍标记为人工验收') }
        'Uninstall' {
            return @(
                $(if ($UninstallMode -eq 'PreserveWork') { "保留 $($Paths.CoworkRoot)，删除其他 R3 受管数据" } else { "完全删除受管数据目录 $($Paths.DataRoot)，包括 Cowork 工作文件" }),
                $(if ($RemoveGit) { '仅在状态证明由 R3 首次安装时卸载 Git' } else { '保留 Git' }),
                $(if ($DisableVmp) { '仅在状态证明由 R3 启用时关闭 VirtualMachinePlatform' } else { '保留 VirtualMachinePlatform' }),
                '删除本地配置不等于撤销云端 Key；设备退役后仍需在 DeepSeek 后台撤销'
            )
        }
    }
    return @()
}

function Read-R3State {
    param($Paths)
    if (-not (Test-Path -LiteralPath $Paths.StatePath -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Paths.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-R3State {
    param($Paths, $State)
    Set-R3Property $State 'SchemaVersion' 6
    Set-R3Property $State 'Product' $script:ProductName
    Set-R3Property $State 'PackageVersion' $script:PackageVersion
    Set-R3Property $State 'UpdatedAt' (Get-Date).ToString('o')
    Write-PilotJsonAtomic -Path $Paths.StatePath -Value $State
    $deploymentId = [string](Get-PilotPropertyValue $State 'DeploymentId' '')
    $sid = [string](Get-PilotPropertyValue $State 'WindowsUserSid' '')
    if ($deploymentId -and $sid) {
        Write-PilotDeploymentMetadata -DataRoot $Paths.DataRoot -StatePath $Paths.StatePath -DeploymentId $deploymentId -WindowsUserSid $sid
    }
}

function Update-R3StateStatus {
    param($Paths, [string]$Status, [string]$Phase, [string]$Failure = '', $Extra = $null)
    $state = Read-R3State $Paths
    if (-not $state) { return }
    Set-R3Property $state 'Status' $Status
    Set-R3Property $state 'Phase' $Phase
    if ($Failure) {
        Set-R3Property $state 'LastFailure' (Protect-R3Message $Failure)
        Set-R3Property $state 'LastFailedAt' (Get-Date).ToString('o')
    }
    if ($null -eq $state.PSObject.Properties['Transaction']) {
        Set-R3Property $state 'Transaction' ([pscustomobject]@{})
    }
    Set-R3Property $state.Transaction 'Id' $script:TransactionId
    Set-R3Property $state.Transaction 'StartedAt' $script:StartedAt.ToString('o')
    if ($Extra) {
        foreach ($property in $Extra.PSObject.Properties) {
            Set-R3Property $state $property.Name $property.Value
        }
    }
    Save-R3State $Paths $state
}

function Invoke-R3CapturedScript {
    param(
        [string]$ScriptPath,
        [hashtable]$Parameters,
        [int]$StartPercent,
        [int]$EndPercent
    )
    $script:ProgressPercent = $StartPercent
    $lineCount = 0
    & $ScriptPath @Parameters *>&1 | ForEach-Object {
        $line = Protect-R3Message ([string]$_)
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $lineCount++
            $span = [math]::Max(1, $EndPercent - $StartPercent)
            $percent = [math]::Min($EndPercent, $StartPercent + [math]::Min($span, [math]::Floor($lineCount / 2)))
            Write-R3Progress $percent 'INFO' $line
        }
    }
}

function Quote-R3NativeArgument {
    param([string]$Value)
    if ($Value -match '"') { throw 'Unexpected quote in child-process argument.' }
    return '"' + $Value + '"'
}

function Invoke-R3ChildPowerShell {
    param([string]$ScriptPath, [string[]]$Arguments, [int]$Percent)
    $all = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = (@($all | ForEach-Object { Quote-R3NativeArgument ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    foreach ($line in @((($stdout + [Environment]::NewLine + $stderr) -split '\r?\n'))) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { Write-R3Progress $Percent 'INFO' $line }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = (Protect-R3Message ($stdout + $stderr)) }
}

function Test-R3DeepSeekConfigured {
    $library = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
    if (-not (Test-Path -LiteralPath $library -PathType Container)) { return $false }
    foreach ($file in Get-ChildItem -LiteralPath $library -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try {
            if ([IO.File]::ReadAllText($file.FullName).Contains('api.deepseek.com/anthropic')) { return $true }
        }
        catch {}
    }
    return $false
}

function Test-R3McpRegistration {
    param($Config, [string]$Mode, [string]$RuntimePath)
    if (-not $Config -or $null -eq $Config.PSObject.Properties['mcpServers'] -or -not $Config.mcpServers) { return $false }
    foreach ($property in $Config.mcpServers.PSObject.Properties) {
        $entry = $property.Value
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['args']) { continue }
        $joined = @($entry.args) -join ' '
        if ($joined.IndexOf($RuntimePath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $joined -match ("(?i)-Mode\s+{0}(\s|$)" -f $Mode)) {
            return $true
        }
    }
    return $false
}

function Get-R3VerificationChecks {
    param($Paths, [switch]$AllowPendingRestart)
    $checks = New-Object System.Collections.Generic.List[object]
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ownership = Get-PilotDataRootOwnership -DataRoot $Paths.DataRoot -ExpectedUserSid $currentSid
    $checks.Add((New-R3Check 'R3 数据目录归属' $(if ($ownership.Trusted) { 'PASS' } else { 'FAIL' }) "$($ownership.Status) | $($ownership.TrustSource) | $($Paths.DataRoot)" (-not $ownership.Trusted)))
    $state = Read-R3State $Paths
    $runtimeValidation = if ($state) { Get-PilotPropertyValue $state 'RuntimeValidation' } else { $null }
    $deepSeekRuntime = if ($runtimeValidation) { Get-PilotPropertyValue $runtimeValidation 'DeepSeek' } else { $null }
    $runtimePassed = ($deepSeekRuntime -and [string](Get-PilotPropertyValue $deepSeekRuntime 'Status' '') -eq 'PASS')
    $checks.Add((New-R3Check 'Claude 真实启动' $(if ($runtimePassed) { 'PASS' } else { 'FAIL' }) $(if ($runtimePassed) { 'DeepSeek 配置层已完成真实窗口、渲染进程与主界面错误日志复核。' } else { '没有可用的分层启动验收记录。' }) (-not $runtimePassed)))

    $package = Get-R3ClaudePackage
    $packageVersion = if ($package) { [string]$package.Version } else { '' }
    $packageKnown = $packageVersion -in @('1.21459.3.0', '1.22209.0.0')
    $checks.Add((New-R3Check 'Claude Desktop' $(if ($package -and $packageKnown) { 'PASS' } else { 'FAIL' }) $(if ($package) { "$packageVersion | $($package.InstallLocation)" } else { '未安装。' }) (-not ($package -and $packageKnown))))

    if ($package) {
        $exe = Join-Path $package.InstallLocation 'app\Claude.exe'
        $signature = Get-AuthenticodeSignature -LiteralPath $exe
        $signed = ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'Anthropic')
        $checks.Add((New-R3Check '已安装 Claude 签名' $(if ($signed) { 'PASS' } else { 'FAIL' }) "$($signature.Status) | $($signature.SignerCertificate.Subject)" (-not $signed)))
    }

    $layout = Get-R3ClaudeLayout $Paths.DataRoot
    $checks.Add((New-R3Check 'Claude-3p 真实目录' $(if ($layout.Status -eq 'PhysicalLocalAppData') { 'PASS' } else { 'FAIL' }) "$($layout.Status) | $($layout.Detail)" ($layout.Status -ne 'PhysicalLocalAppData')))

    $vmp = Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction SilentlyContinue
    $vmpEnabled = ($vmp -and [int]$vmp.InstallState -eq 1)
    $vmpStatus = if ($vmpEnabled) { 'PASS' } elseif ($AllowPendingRestart) { 'WARN' } else { 'FAIL' }
    $vmpDetail = if ($vmpEnabled) { "InstallState=$($vmp.InstallState)" } elseif ($AllowPendingRestart) { '功能已请求启用，等待 Windows 重启后复核。' } elseif ($vmp) { "InstallState=$($vmp.InstallState)" } else { '无法读取。' }
    $checks.Add((New-R3Check 'VirtualMachinePlatform' $vmpStatus $vmpDetail ($vmpStatus -eq 'FAIL')))

    $service = Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue
    $checks.Add((New-R3Check 'CoworkVMService' $(if ($service) { 'PASS' } else { 'FAIL' }) $(if ($service) { [string]$service.Status } else { '未注册。' }) (-not $service)))

    $runtimeRoot = Join-Path $env:LOCALAPPDATA 'Claude-3p'
    $seedRoot = Join-Path $runtimeRoot 'vm_bundles\claudevm.bundle'
    $seedEntries = @(
        [pscustomobject]@{ Name = 'rootfs.vhdx.zst'; Size = [int64]1336068767; Hash = '21237CA86D15885ED7DCBE1C66B8B3A464C914648B16300070B12B1E1212E451' },
        [pscustomobject]@{ Name = 'initrd.zst'; Size = [int64]74332074; Hash = '20214EFCD451B3B74DC53ED80218C6E616BB2A101CAFB18BC2C9BC91E559926B' },
        [pscustomobject]@{ Name = 'vmlinuz.zst'; Size = [int64]14745575; Hash = '1BB4BC3AA0C0C797A2CA6134D2B7034A196E05D4DEEA7BB20F064EE353781F3B' }
    )
    $seedPassed = $true
    foreach ($entry in $seedEntries) {
        $path = Join-Path $seedRoot $entry.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $entry.Size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Hash) {
            $seedPassed = $false
            break
        }
    }
    $checks.Add((New-R3Check 'Cowork 离线种子' $(if ($seedPassed) { 'PASS' } else { 'FAIL' }) '固定 bundle 6d1538ba... 的三个压缩运行时文件。' (-not $seedPassed)))

    $codeEntries = @(
        [pscustomobject]@{ Path = 'claude-code\2.1.209\claude.exe'; Hash = 'B9D5E8542338A0918534E55D046A7C960AE4AF5EE214C7E4E80A89067B63EA2C' },
        [pscustomobject]@{ Path = 'claude-code-vm\2.1.209\claude'; Hash = 'B882F4B8B27772F897540DF50F24000206F43A9426E8F7D19BD065959B69E9DD' }
    )
    $codePassed = $true
    foreach ($entry in $codeEntries) {
        $path = Join-Path $runtimeRoot $entry.Path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Hash) { $codePassed = $false; break }
    }
    $checks.Add((New-R3Check 'Cowork Host/VM Code' $(if ($codePassed) { 'PASS' } else { 'FAIL' }) '2.1.209；仅供 Claude Desktop 内部使用，未注册独立 CLI。' (-not $codePassed)))

    $expandedReady = (Test-Path -LiteralPath (Join-Path $seedRoot 'rootfs.vhdx') -PathType Leaf)
    $checks.Add((New-R3Check 'Cowork 展开运行时' $(if ($expandedReady) { 'PASS' } else { 'INFO' }) $(if ($expandedReady) { '本地 VHDX 已展开。' } else { '首次进入 Cowork 后才会展开；不能据此判定真实任务失败。' }) $false))

    $git = Get-R3GitInfo
    $checks.Add((New-R3Check 'Git for Code' $(if ($git -and $git.Version -ge [version]'2.55.0.3') { 'PASS' } else { 'FAIL' }) $(if ($git) { "$($git.VersionText) | $($git.Path)" } else { '未检测到。' }) (-not $git)))

    $configPath = Join-Path $runtimeRoot 'claude_desktop_config.json'
    $config = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try { $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    $deepSeek = Test-R3DeepSeekConfigured
    $checks.Add((New-R3Check 'DeepSeek 网关' $(if ($deepSeek) { 'PASS' } else { 'FAIL' }) '只确认 https://api.deepseek.com/anthropic；未读取或显示 Key。' (-not $deepSeek)))
    $coworkPathReady = ($config -and [string]$config.coworkUserFilesPath -eq $Paths.CoworkRoot)
    $checks.Add((New-R3Check 'Cowork 工作目录' $(if ($coworkPathReady) { 'PASS' } else { 'FAIL' }) $(if ($config) { [string]$config.coworkUserFilesPath } else { '配置不存在。' }) (-not $coworkPathReady)))

    $runtime = Join-Path $Paths.DataRoot 'MCP\Office\Office-McpServer.ps1'
    $wordPath = Get-R3RegisteredApplicationPath 'WINWORD.EXE'
    $excelPath = Get-R3RegisteredApplicationPath 'EXCEL.EXE'
    $powerPointPath = Get-R3RegisteredApplicationPath 'POWERPNT.EXE'
    $wordMcp = Test-R3McpRegistration $config 'Word' $runtime
    $excelMcp = Test-R3McpRegistration $config 'Excel' $runtime
    $checks.Add((New-R3Check 'Word MCP' $(if ($wordPath -and $wordMcp) { 'PASS' } elseif ($wordPath) { 'FAIL' } else { 'WARN' }) $(if ($wordPath) { "$wordPath | configured=$wordMcp" } else { '未安装 Word；允许继续，后装后运行修复。' }) ($wordPath -and -not $wordMcp)))
    $checks.Add((New-R3Check 'Excel MCP' $(if ($excelPath -and $excelMcp) { 'PASS' } elseif ($excelPath) { 'FAIL' } else { 'WARN' }) $(if ($excelPath) { "$excelPath | configured=$excelMcp" } else { '未安装 Excel；允许继续，后装后运行修复。' }) ($excelPath -and -not $excelMcp)))
    $checks.Add((New-R3Check 'PowerPoint 检测' $(if ($powerPointPath) { 'PASS' } else { 'WARN' }) $(if ($powerPointPath) { "$powerPointPath | R3 不提供 PowerPoint MCP。" } else { '未安装；不影响部署。' }) $false))

    $chinese = $false
    $flash = $false
    if ($package) {
        $chinese = Test-Path -LiteralPath (Join-Path $package.InstallLocation 'app\resources\ion-dist\i18n\zh-CN.json') -PathType Leaf
        $assetRoot = Join-Path $package.InstallLocation 'app\resources\ion-dist\assets\v1'
        if (Test-Path -LiteralPath $assetRoot -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $assetRoot -Filter '*.js' -File) {
                if ([IO.File]::ReadAllText($file.FullName).Contains('"claude-sonnet-5":"max"')) { $flash = $true; break }
            }
        }
    }
    $localizationRuntime = if ($runtimeValidation) { Get-PilotPropertyValue $runtimeValidation 'Localization' } else { $null }
    $localizationRolledBack = ($localizationRuntime -and [string](Get-PilotPropertyValue $localizationRuntime 'Status' '') -eq 'ROLLED_BACK')
    $localizationStatus = if ($chinese) { 'PASS' } elseif ($localizationRolledBack) { 'WARN' } else { 'FAIL' }
    $checks.Add((New-R3Check '简体中文适配' $localizationStatus $(if ($localizationRolledBack) { '中文适配导致启动异常，已自动撤回；Claude 保持可用。' } else { '已通过资源与分层启动验收。' }) ($localizationStatus -eq 'FAIL')))
    $flashReady = ($flash -and [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'User') -eq 'max')
    $flashRuntime = if ($runtimeValidation) { Get-PilotPropertyValue $runtimeValidation 'FlashMax' } else { $null }
    $flashRolledBack = ($flashRuntime -and [string](Get-PilotPropertyValue $flashRuntime 'Status' '') -eq 'ROLLED_BACK')
    $flashStatus = if ($flashReady) { 'PASS' } elseif ($flashRolledBack) { 'WARN' } else { 'FAIL' }
    $checks.Add((New-R3Check 'Flash Max' $flashStatus $(if ($flashRolledBack) { 'Flash Max 导致启动异常，已自动撤回；Claude 保持可用。' } else { '已通过前端标记与分层启动验收。' }) ($flashStatus -eq 'FAIL')))

    $checks.Add((New-R3Check 'Cowork 真实任务' 'MANUAL' '需在 Claude 中完成一次真实只读文件任务并在重启后复测。' $false))
    if ($wordPath) { $checks.Add((New-R3Check 'Word 真实 MCP 任务' 'MANUAL' '需打开受管工作区内的测试文档执行一次真实只读调用。' $false)) }
    if ($excelPath) { $checks.Add((New-R3Check 'Excel 真实 MCP 任务' 'MANUAL' '需打开受管工作区内的测试工作簿执行一次真实只读调用。' $false)) }
    return $checks.ToArray()
}

function Write-R3AcceptanceReport {
    param($Paths, [string]$ReportAction, [object[]]$Checks)
    $trustedRoot = $false
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $trustedRoot = [bool](Get-PilotDataRootOwnership -DataRoot $Paths.DataRoot -ExpectedUserSid $sid).Trusted
    }
    catch {}
    $logRoot = if ($trustedRoot) {
        Join-Path $Paths.DataRoot 'Logs'
    }
    else {
        Join-Path (Get-R3TransientRoot) 'Reports'
    }
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $logRoot ("acceptance-$ReportAction-$stamp.json")
    $textPath = Join-Path $logRoot ("acceptance-$ReportAction-$stamp.txt")
    $summary = [ordered]@{
        action = $ReportAction
        generatedAt = (Get-Date).ToString('o')
        packageVersion = $script:PackageVersion
        windowsUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        dataRoot = $Paths.DataRoot
        apiKeyIncluded = $false
        failCount = @($Checks | Where-Object status -eq 'FAIL').Count
        warnCount = @($Checks | Where-Object status -eq 'WARN').Count
        manualCount = @($Checks | Where-Object status -eq 'MANUAL').Count
        checks = @($Checks)
    }
    Write-PilotJsonAtomic -Path $jsonPath -Value $summary
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Claude Pilot R3.5 验收报告 | $ReportAction")
    $lines.Add("生成时间：$($summary.generatedAt)")
    $lines.Add("数据目录：$($Paths.DataRoot)")
    $lines.Add('API Key：未写入本报告')
    $lines.Add('')
    foreach ($check in $Checks) {
        $lines.Add(("[{0}] {1} - {2}" -f $check.status, $check.name, $check.detail))
    }
    $lines.Add('')
    $lines.Add('说明：PASS 仅表示对应静态/状态检查通过；MANUAL 项必须在真实 Claude/Cowork/Office 会话中执行。')
    [IO.File]::WriteAllLines($textPath, $lines.ToArray(), (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ JsonPath = $jsonPath; TextPath = $textPath; Summary = $summary }
}

function Test-R3RestartRequired {
    param($Paths)
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
        if ([string]$feature.State -eq 'EnablePending') { return $true }
        if ([string]$feature.State -eq 'Enabled') { return $false }
    }
    catch {}
    $latest = Get-ChildItem -LiteralPath (Join-Path $Paths.DataRoot 'Logs') -Filter 'deployment-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latest) {
        try {
            $report = Get-Content -LiteralPath $latest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            return [bool]$report.RestartRequired
        }
        catch {}
    }
    return $false
}

function Start-R3ClaudeDesktop {
    Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude'
}

function Repair-R3PointerIfSafe {
    param($Paths)
    $repair = Repair-PilotDeploymentPointer -DataRoot $Paths.DataRoot -ExpectedUserSid $ExpectedUserSid
    if ($repair.Repaired) {
        Write-R3Progress ([math]::Max(3, $script:ProgressPercent)) 'PASS' '已自动恢复部署状态。'
    }
    return $repair
}

function Register-R3Resume {
    param($Paths)
    if (-not $SetupExePath -or -not (Test-Path -LiteralPath $SetupExePath -PathType Leaf)) {
        throw 'The setup executable path is unavailable; automatic resume cannot be registered safely.'
    }
    $supportRoot = Join-Path $Paths.DataRoot 'Support'
    $supportEngine = Join-Path $supportRoot 'Engine'
    New-Item -ItemType Directory -Path $supportEngine -Force | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $supportEngine $file.Name) -Force
    }
    $runner = Join-Path $supportRoot 'ClaudePilotSetup.exe'
    Copy-Item -LiteralPath $SetupExePath -Destination $runner -Force
    $engine = Join-Path $supportEngine 'Invoke-ClaudePilotR3.ps1'
    $command = '"' + $runner + '" --resume --engine "' + $engine + '" --data-root "' + $Paths.DataRoot + '"'
    $runOnce = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    New-Item -Path $runOnce -Force | Out-Null
    New-ItemProperty -LiteralPath $runOnce -Name 'ClaudePilotR3Resume' -PropertyType String -Value $command -Force | Out-Null

    $state = Read-R3State $Paths
    if ($state) {
        Set-R3Property $state 'Resume' ([pscustomobject]@{
            Required = $true
            Mechanism = 'HKCU RunOnce'
            RunnerPath = $runner
            EnginePath = $engine
            RegisteredAt = (Get-Date).ToString('o')
            CompletedAt = $null
        })
        Save-R3State $Paths $state
    }
    return [pscustomobject]@{ RunnerPath = $runner; EnginePath = $engine }
}

function Complete-R3Resume {
    param($Paths)
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ClaudePilotR3Resume' -ErrorAction SilentlyContinue
    $state = Read-R3State $Paths
    if ($state) {
        if ($null -eq $state.PSObject.Properties['Resume']) { Set-R3Property $state 'Resume' ([pscustomobject]@{}) }
        Set-R3Property $state.Resume 'Required' $false
        Set-R3Property $state.Resume 'CompletedAt' (Get-Date).ToString('o')
        Save-R3State $Paths $state
    }
}

function Invoke-R3BestEffortRollback {
    param($Paths)
    $actions = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $state = Read-R3State $Paths
    if (-not $state) {
        return [pscustomobject]@{ Complete = $true; Actions = @('未发现持久化变更基线；无需回滚。'); Errors = @() }
    }

    try {
        $claudeState = Get-PilotPropertyValue $state 'Claude'
        $presentBefore = [bool](Get-PilotPropertyValue $claudeState 'PresentBefore' $false)
        $package = Get-R3ClaudePackage
        if (-not $presentBefore -and $package) {
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
            $actions.Add('已移除本轮首次安装的 Claude Desktop。')
        }
    }
    catch { $errors.Add("Claude 回滚失败：$(Protect-R3Message $_.Exception.Message)") }

    try {
        $gitState = Get-PilotPropertyValue $state 'Git'
        $gitPresentBefore = [bool](Get-PilotPropertyValue $gitState 'PresentBefore' $false)
        $git = Get-R3GitInfo
        if (-not $gitPresentBefore -and $git) {
            $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Path)
            $uninstaller = Join-Path $gitRoot 'unins000.exe'
            if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw "Git uninstaller not found: $uninstaller" }
            $process = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES') -Wait -PassThru
            if ($process.ExitCode -notin @(0, 3010)) { throw "Git uninstaller returned $($process.ExitCode)." }
            $actions.Add('已调用官方卸载器移除本轮首次安装的 Git。')
        }
    }
    catch { $errors.Add("Git 回滚失败：$(Protect-R3Message $_.Exception.Message)") }

    try {
        $vmpState = Get-PilotPropertyValue $state 'VirtualMachinePlatform'
        $before = [string](Get-PilotPropertyValue $vmpState 'StateBefore' '')
        $enabledByPilot = [bool](Get-PilotPropertyValue $vmpState 'EnabledByPilot' $false)
        if ($enabledByPilot -and $before -notin @('Enabled', 'EnablePending')) {
            [void](Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction Stop)
            $actions.Add('已把本轮启用的 VirtualMachinePlatform 恢复为禁用待重启状态。')
        }
    }
    catch { $errors.Add("VirtualMachinePlatform 回滚失败：$(Protect-R3Message $_.Exception.Message)") }

    try {
        $storage = Get-PilotPropertyValue $state 'Storage'
        $created = [bool](Get-PilotPropertyValue $storage 'LocalDataCreatedByPilot' $false)
        $runtime = Join-Path $env:LOCALAPPDATA 'Claude-3p'
        if ($created -and -not (Get-R3ClaudePackage) -and (Test-Path -LiteralPath $runtime -PathType Container)) {
            $expected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Claude-3p')).TrimEnd('\')
            $actual = [IO.Path]::GetFullPath($runtime).TrimEnd('\')
            $item = Get-Item -LiteralPath $actual -Force
            if ($actual -ne $expected -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw 'Runtime path failed the exact-path/reparse safety check.'
            }
            Remove-Item -LiteralPath $actual -Recurse -Force -ErrorAction Stop
            $actions.Add('已删除本轮创建的 Claude-3p 物理运行时。')
        }
    }
    catch { $errors.Add("运行时回滚失败：$(Protect-R3Message $_.Exception.Message)") }

    if (-not $script:DataRootExistedBefore -and (Test-Path -LiteralPath $Paths.DataRoot -PathType Container)) {
        try {
            $allowed = @('Cowork', 'MCP', 'Backups', 'Logs', 'State', 'Support', 'claude.ico', 'desktop.ini', 'Claude Desktop.lnk', '.claude-pilot-r3-managed.json')
            $unexpected = @(Get-ChildItem -LiteralPath $Paths.DataRoot -Force | Where-Object { $_.Name -notin $allowed })
            $coworkHasData = (Test-Path -LiteralPath $Paths.CoworkRoot -PathType Container) -and ($null -ne (Get-ChildItem -LiteralPath $Paths.CoworkRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1))
            if ($unexpected.Count -eq 0 -and -not $coworkHasData) {
                $rootItem = Get-Item -LiteralPath $Paths.DataRoot -Force
                if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'DataRoot became a reparse point.' }
                Remove-Item -LiteralPath $Paths.DataRoot -Recurse -Force -ErrorAction Stop
                Remove-PilotDeploymentPointer
                $actions.Add('已删除本轮新建且未混入用户内容的数据目录。')
            }
            else {
                $errors.Add('数据目录包含既有或用户内容，已安全保留，需人工复核。')
            }
        }
        catch { $errors.Add("数据目录回滚失败：$(Protect-R3Message $_.Exception.Message)") }
    }
    return [pscustomobject]@{ Complete = ($errors.Count -eq 0); Actions = $actions.ToArray(); Errors = $errors.ToArray() }
}

$exitCode = 0
$result = $null
$paths = $null
try {
    Write-R3Progress 1 'INFO' "$script:ProductName $Action 已启动。"
    $paths = Resolve-PilotDeploymentPaths -BundleRoot $script:ResourcesRoot -RequestedDataRoot $DataRoot -Mode $(if ($Action -eq 'Uninstall') { 'Uninstall' } else { 'Install' })
    $script:DataRootExistedBefore = Test-Path -LiteralPath $paths.DataRoot

    switch ($Action) {
        'Preflight' {
            $checks = Get-R3PreflightChecks $paths
            $failCount = @($checks | Where-Object status -eq 'FAIL').Count
            $warnCount = @($checks | Where-Object status -eq 'WARN').Count
            $exitCode = if ($failCount -gt 0) { 2 } else { 0 }
            Write-R3Progress 100 $(if ($failCount -gt 0) { 'FAIL' } elseif ($warnCount -gt 0) { 'WARN' } else { 'PASS' }) "环境自检完成：FAIL=$failCount，WARN=$warnCount。"
            $result = [ordered]@{
                action = $Action
                success = ($failCount -eq 0)
                exitCode = $exitCode
                summary = "FAIL=$failCount; WARN=$warnCount"
                dataRoot = $paths.DataRoot
                checks = @($checks)
                preview = @(Get-R3Preview 'Install' $paths)
                apiKeyIncluded = $false
            }
        }
        'Install' {
            Assert-R3ExpectedUser
            if (-not (Test-R3Administrator)) { throw 'Installation must run in the elevated process started by the graphical launcher.' }
            [void](Repair-R3PointerIfSafe $paths)
            $checks = Get-R3PreflightChecks $paths
            $failures = @($checks | Where-Object status -eq 'FAIL')
            if ($failures.Count -gt 0) {
                $exitCode = 2
                Write-R3Progress 100 'FAIL' "安装前检查发现 $($failures.Count) 个需要处理的问题。"
                $result = [ordered]@{
                    action = $Action
                    success = $false
                    exitCode = $exitCode
                    dataRoot = $paths.DataRoot
                    error = "安装前检查发现 $($failures.Count) 个问题，请查看红色项目，处理后再试。"
                    checks = @($checks)
                    preview = @(Get-R3Preview 'Install' $paths)
                    apiKeyIncluded = $false
                }
                break
            }
            $script:MutationStarted = $true
            $parameters = @{
                Stage = 'Full'; ExpectedUserSid = $ExpectedUserSid; DataRoot = $paths.DataRoot;
                ApiKeyBlobPath = $ApiKeyBlobPath; NonInteractive = $true; UpdatePolicy = $UpdatePolicy;
                ForceReinstall = [bool]$ForceReinstall
            }
            Invoke-R3CapturedScript -ScriptPath (Join-Path $PSScriptRoot 'Deploy-Pilot.ps1') -Parameters $parameters -StartPercent 15 -EndPercent 88
            $restart = Test-R3RestartRequired $paths
            if ($restart) {
                [void](Register-R3Resume $paths)
                Update-R3StateStatus $paths 'AwaitingRestart' 'ResumeRegistered'
            }
            else {
                Update-R3StateStatus $paths 'Verifying' 'PostInstallVerification'
            }
            Write-R3Progress 90 'INFO' '正在生成结构化验收报告。'
            $verifyChecks = Get-R3VerificationChecks -Paths $paths -AllowPendingRestart:$restart
            $report = Write-R3AcceptanceReport $paths 'install' $verifyChecks
            $verifyFailCount = @($verifyChecks | Where-Object status -eq 'FAIL').Count
            if (-not $restart) {
                if ($verifyFailCount -eq 0) {
                    Update-R3StateStatus $paths 'Installed' 'Completed'
                }
                else {
                    Update-R3StateStatus $paths 'Failed' 'PostInstallVerification' "Post-install verification has $verifyFailCount failure(s)."
                }
            }
            $state = Read-R3State $paths
            if ($state) {
                Set-R3Property $state 'LastVerification' ([pscustomobject]@{ Summary = "FAIL=$verifyFailCount"; ReportPath = $report.JsonPath; CheckedAt = (Get-Date).ToString('o') })
                Save-R3State $paths $state
            }
            $installSuccess = ($verifyFailCount -eq 0)
            $exitCode = if ($installSuccess) { 0 } else { 2 }
            $installLevel = if (-not $installSuccess) { 'FAIL' } elseif ($restart) { 'WARN' } else { 'PASS' }
            Write-R3Progress 100 $installLevel $(if (-not $installSuccess) { "部署已执行，但静态验收仍有 $verifyFailCount 个 FAIL；请查看报告并运行修复。" } elseif ($restart) { '部署阶段完成；请重启 Windows，R3 将在登录后自动续装并复核。' } else { '部署与静态验收完成。' })
            $result = [ordered]@{
                action = $Action; success = $installSuccess; exitCode = $exitCode; dataRoot = $paths.DataRoot;
                restartRequired = $restart; reportPath = $report.TextPath; checks = @($verifyChecks);
                preview = @(Get-R3Preview 'Install' $paths); apiKeyIncluded = $false
            }
        }
        'Repair' {
            Assert-R3ExpectedUser
            if (-not (Test-R3Administrator)) { throw 'Repair must run in the elevated process started by the graphical launcher.' }
            [void](Repair-R3PointerIfSafe $paths)
            $layout = Get-R3ClaudeLayout $paths.DataRoot
            if ($layout.Status -eq 'LegacyManagedJunction') {
                $script:MutationStarted = $true
                Write-R3Progress 8 'WARN' '检测到 R2 旧受管联接，先执行保留源副本的迁回 C 盘修复。'
                $repairChild = Invoke-R3ChildPowerShell -ScriptPath (Join-Path $PSScriptRoot 'Repair-CoworkStorage.ps1') -Arguments @('-ExpectedUserSid', $ExpectedUserSid, '-DataRoot', $paths.DataRoot, '-NoLaunch') -Percent 12
                if ($repairChild.ExitCode -ne 0) { throw "Legacy storage repair returned $($repairChild.ExitCode). $($repairChild.Output)" }
            }
            elseif (-not $layout.Ready) {
                throw $layout.Detail
            }
            $checks = Get-R3PreflightChecks $paths
            $failures = @($checks | Where-Object status -eq 'FAIL')
            if ($failures.Count -gt 0) { throw ('Repair preflight has blocking failures: ' + (@($failures | ForEach-Object name) -join ', ')) }
            $script:MutationStarted = $true
            $parameters = @{
                Stage = 'Full'; ExpectedUserSid = $ExpectedUserSid; DataRoot = $paths.DataRoot;
                ApiKeyBlobPath = $ApiKeyBlobPath; NonInteractive = $true; UpdatePolicy = $UpdatePolicy;
                ForceReinstall = [bool]$ForceReinstall
            }
            Invoke-R3CapturedScript -ScriptPath (Join-Path $PSScriptRoot 'Deploy-Pilot.ps1') -Parameters $parameters -StartPercent 18 -EndPercent 88
            $restart = Test-R3RestartRequired $paths
            if ($restart) {
                [void](Register-R3Resume $paths)
                Update-R3StateStatus $paths 'AwaitingRestart' 'RepairResumeRegistered'
            }
            else {
                Update-R3StateStatus $paths 'Verifying' 'PostRepairVerification'
            }
            $verifyChecks = Get-R3VerificationChecks -Paths $paths -AllowPendingRestart:$restart
            $report = Write-R3AcceptanceReport $paths 'repair' $verifyChecks
            $verifyFailCount = @($verifyChecks | Where-Object status -eq 'FAIL').Count
            if (-not $restart) {
                if ($verifyFailCount -eq 0) {
                    Update-R3StateStatus $paths 'Installed' 'RepairCompleted'
                }
                else {
                    Update-R3StateStatus $paths 'Failed' 'PostRepairVerification' "Post-repair verification has $verifyFailCount failure(s)."
                }
            }
            $state = Read-R3State $paths
            if ($state) {
                Set-R3Property $state 'LastVerification' ([pscustomobject]@{ Summary = "FAIL=$verifyFailCount"; ReportPath = $report.JsonPath; CheckedAt = (Get-Date).ToString('o') })
                Save-R3State $paths $state
            }
            $repairSuccess = ($verifyFailCount -eq 0)
            $exitCode = if ($repairSuccess) { 0 } else { 2 }
            $repairLevel = if (-not $repairSuccess) { 'FAIL' } elseif ($restart) { 'WARN' } else { 'PASS' }
            Write-R3Progress 100 $repairLevel $(if (-not $repairSuccess) { "修复已执行，但静态验收仍有 $verifyFailCount 个 FAIL。" } elseif ($restart) { '修复完成；重启后自动复核。' } else { '修复与静态复核完成。' })
            $result = [ordered]@{ action = $Action; success = $repairSuccess; exitCode = $exitCode; dataRoot = $paths.DataRoot; restartRequired = $restart; reportPath = $report.TextPath; checks = @($verifyChecks); preview = @(Get-R3Preview 'Repair' $paths); apiKeyIncluded = $false }
        }
        'Verify' {
            Write-R3Progress 10 'INFO' '正在核对已安装组件；不会读取或显示 API Key。'
            $checks = Get-R3VerificationChecks $paths
            $report = Write-R3AcceptanceReport $paths 'verify' $checks
            $failCount = @($checks | Where-Object status -eq 'FAIL').Count
            $warnCount = @($checks | Where-Object { $_.status -in @('WARN', 'MANUAL') }).Count
            $exitCode = if ($failCount -gt 0) { 2 } elseif ($warnCount -gt 0) { 1 } else { 0 }
            $verificationOwnership = Get-PilotDataRootOwnership -DataRoot $paths.DataRoot -ExpectedUserSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            if ($verificationOwnership.Trusted) {
                $state = Read-R3State $paths
                if ($state) {
                    Set-R3Property $state 'LastVerification' ([pscustomobject]@{ Summary = "FAIL=$failCount; WARN_OR_MANUAL=$warnCount"; ReportPath = $report.JsonPath; CheckedAt = (Get-Date).ToString('o') })
                    Save-R3State $paths $state
                }
            }
            Write-R3Progress 100 $(if ($failCount -gt 0) { 'FAIL' } elseif ($warnCount -gt 0) { 'WARN' } else { 'PASS' }) "验证完成：FAIL=$failCount，WARN/MANUAL=$warnCount。"
            $result = [ordered]@{ action = $Action; success = ($failCount -eq 0); exitCode = $exitCode; dataRoot = $paths.DataRoot; reportPath = $report.TextPath; checks = @($checks); preview = @(Get-R3Preview 'Verify' $paths); apiKeyIncluded = $false }
        }
        'Resume' {
            Assert-R3ExpectedUser
            $resumeOwnership = Get-PilotDataRootOwnership -DataRoot $paths.DataRoot -ExpectedUserSid $ExpectedUserSid
            if (-not $resumeOwnership.Trusted) {
                throw "Automatic resume refused an untrusted DataRoot: $($resumeOwnership.Status)."
            }
            Write-R3Progress 10 'INFO' 'Windows 登录后续装复核已启动。'
            Update-R3StateStatus $paths 'Resuming' 'PostRestartVerification'
            $checks = Get-R3VerificationChecks $paths
            $report = Write-R3AcceptanceReport $paths 'resume' $checks
            $failCount = @($checks | Where-Object status -eq 'FAIL').Count
            if ($failCount -eq 0) {
                Complete-R3Resume $paths
                Update-R3StateStatus $paths 'Installed' 'PostRestartCompleted'
                try {
                    Start-R3ClaudeDesktop
                    Write-R3Progress 95 'INFO' 'Claude Desktop 已启动，供继续完成真实 Cowork/Office 人工任务。'
                }
                catch {
                    Write-R3Progress 95 'WARN' '静态复核通过，但未能自动启动 Claude Desktop；可从开始菜单手动打开。'
                }
                $exitCode = 0
                Write-R3Progress 100 'PASS' '重启续装与静态复核完成；请继续执行报告中的真实 Cowork/Office 人工任务。'
            }
            else {
                Update-R3StateStatus $paths 'Failed' 'PostRestartVerification' "Post-restart verification has $failCount failure(s)."
                $exitCode = 2
                Write-R3Progress 100 'FAIL' "重启后仍有 $failCount 个 FAIL，请保留报告并运行修复/补齐组件。"
            }
            $result = [ordered]@{ action = $Action; success = ($failCount -eq 0); exitCode = $exitCode; dataRoot = $paths.DataRoot; reportPath = $report.TextPath; checks = @($checks); apiKeyIncluded = $false }
        }
        'Uninstall' {
            Assert-R3ExpectedUser
            if (-not (Test-R3Administrator)) { throw 'Uninstall must run in the elevated process started by the graphical launcher.' }
            [void](Repair-R3PointerIfSafe $paths)
            $script:MutationStarted = $true
            Write-R3Progress 10 'WARN' '正在执行已确认的卸载范围。'
            $arguments = @('-ExpectedUserSid', $ExpectedUserSid, '-DataRoot', $paths.DataRoot, '-NonInteractive', '-UninstallMode', $UninstallMode, '-Confirmation', 'UNINSTALL')
            if ($RemoveGit) { $arguments += '-RemoveGitRequested' }
            if ($DisableVmp) { $arguments += '-DisableVmpRequested' }
            $child = Invoke-R3ChildPowerShell -ScriptPath (Join-Path $PSScriptRoot 'Uninstall-Pilot.ps1') -Arguments $arguments -Percent 55
            $documents = [Environment]::GetFolderPath('MyDocuments')
            $reportRoot = Join-Path $documents 'ClaudePilotR3-Reports'
            New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
            $reportPath = Join-Path $reportRoot ("uninstall-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $reportLines = @(
                'Claude Pilot R3.5 卸载报告',
                "完成时间：$((Get-Date).ToString('o'))",
                "模式：$UninstallMode",
                "数据目录：$($paths.DataRoot)",
                "Git 请求卸载：$([bool]$RemoveGit)",
                "VMP 请求关闭：$([bool]$DisableVmp)",
                'API Key：未写入本报告',
                '',
                (Protect-R3Message $child.Output),
                '',
                '本地删除不等于云端 Key 撤销；设备退役后请在 DeepSeek 后台撤销该设备 Key。'
            )
            [IO.File]::WriteAllLines($reportPath, $reportLines, (New-Object Text.UTF8Encoding($false)))
            $exitCode = $child.ExitCode
            $completedWithWarnings = ($child.ExitCode -eq 3)
            $success = ($child.ExitCode -in @(0, 3))
            $uninstallChecks = @(
                if ($completedWithWarnings) {
                    New-R3Check '卸载警告' 'WARN' "卸载已完成，但存在非致命提示；请查看报告：$reportPath" $false
                }
                elseif (-not $success) {
                    New-R3Check '卸载执行' 'FAIL' "卸载子进程退出代码：$($child.ExitCode)；请查看报告：$reportPath" $true
                }
            )
            $progressLevel = if ($success) { if ($completedWithWarnings) { 'WARN' } else { 'PASS' } } else { 'FAIL' }
            $progressMessage = if ($completedWithWarnings) {
                '卸载完成但有提示；报告已保存到文档目录。'
            }
            elseif ($success) {
                '卸载完成；报告已保存到文档目录。'
            }
            else {
                '卸载存在失败项，请查看报告。'
            }
            Write-R3Progress 100 $progressLevel $progressMessage
            $result = [ordered]@{ action = $Action; success = $success; exitCode = $exitCode; dataRoot = $paths.DataRoot; reportPath = $reportPath; checks = $uninstallChecks; preview = @(Get-R3Preview 'Uninstall' $paths); apiKeyIncluded = $false }
        }
    }
}
catch {
    $message = Protect-R3Message $_.Exception.Message
    $rollback = $null
    if ($script:MutationStarted -and $Action -in @('Install', 'Repair')) {
        Write-R3Progress ([math]::Max(5, $script:ProgressPercent)) 'WARN' '操作失败，正在按部署前基线执行逆序安全回滚。'
        $rollback = Invoke-R3BestEffortRollback $paths
        if ($paths -and (Test-Path -LiteralPath $paths.StatePath -PathType Leaf)) {
            Update-R3StateStatus $paths $(if ($rollback.Complete) { 'RolledBack' } else { 'PartiallyRolledBack' }) 'Rollback' $message ([pscustomobject]@{ Rollback = $rollback })
        }
    }
    if ($ApiKeyBlobPath) {
        try {
            $ticket = Assert-R3TransientPath $ApiKeyBlobPath 'API Key ticket'
            if ([IO.Path]::GetExtension($ticket) -eq '.dpapi') { Remove-Item -LiteralPath $ticket -Force -ErrorAction SilentlyContinue }
        }
        catch {}
    }
    $exitCode = 2
    Write-R3Progress 100 'FAIL' $message
    $result = [ordered]@{
        action = $Action
        success = $false
        exitCode = $exitCode
        dataRoot = if ($paths) { $paths.DataRoot } else { $DataRoot }
        error = $message
        rollback = $rollback
        apiKeyIncluded = $false
    }
}
finally {
    if ($ApiKeyBlobPath) {
        try {
            $ticket = Assert-R3TransientPath $ApiKeyBlobPath 'API Key ticket'
            if ([IO.Path]::GetExtension($ticket) -eq '.dpapi') { Remove-Item -LiteralPath $ticket -Force -ErrorAction SilentlyContinue }
        }
        catch {}
    }
}

Write-R3Result $result
exit $exitCode
