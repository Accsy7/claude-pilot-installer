[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DataRoot,
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$SessionLogPath,
    [Parameter(Mandatory = $true)][string]$ExpectedUserSid
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$script:HashCache = @{}
$script:StagingRoot = ''

function Write-DiagnosticProgress {
    param([int]$Percent, [string]$Message)
    Write-Output ("PROGRESS|{0}|{1}" -f ([math]::Max(0, [math]::Min(100, $Percent))), $Message)
}

function Get-ObjectProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Protect-DiagnosticText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
    $safe = [string]$Text
    $profile = [Environment]::GetFolderPath('UserProfile')
    if ($profile) {
        $safe = [Text.RegularExpressions.Regex]::Replace(
            $safe,
            [Text.RegularExpressions.Regex]::Escape($profile),
            '%USERPROFILE%',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    $identityName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($identityName) {
        $safe = [Text.RegularExpressions.Regex]::Replace(
            $safe,
            [Text.RegularExpressions.Regex]::Escape($identityName),
            '<CURRENT_USER>',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    if ($env:COMPUTERNAME) {
        $safe = [Text.RegularExpressions.Regex]::Replace(
            $safe,
            [Text.RegularExpressions.Regex]::Escape($env:COMPUTERNAME),
            '<COMPUTER>',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    $safe = [Text.RegularExpressions.Regex]::Replace($safe, 'S-\d-\d+(?:-\d+){2,}', '<USER-SID>')
    $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)sk-[A-Za-z0-9_-]{12,}', '[REDACTED-KEY]')
    $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)Bearer\s+[A-Za-z0-9._~+/=-]{12,}', 'Bearer [REDACTED]')
    $safe = [Text.RegularExpressions.Regex]::Replace(
        $safe,
        '(?i)((?:x-api-key|api[_-]?key|authorization|access[_-]?token|refresh[_-]?token)\s*["'']?\s*[:=]\s*["'']?)[^\s"'',;}{]{8,}',
        '$1[REDACTED]'
    )
    return $safe
}

function Write-Utf8Json {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 15
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

function Write-Utf8Lines {
    param([string]$Path, [object[]]$Lines)
    $safeLines = @($Lines | ForEach-Object { Protect-DiagnosticText ([string]$_) })
    [IO.File]::WriteAllLines($Path, $safeLines, (New-Object Text.UTF8Encoding($false)))
}

function ConvertTo-FullPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Resolve-ContainedPath {
    param([string]$Root, [string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "Rooted manifest path is not allowed: $RelativePath" }
    $rootFull = ConvertTo-FullPath $Root
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes the package root: $RelativePath"
    }
    return $full
}

function Get-CachedSha256 {
    param([string]$Path)
    $key = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
    if (-not $script:HashCache.ContainsKey($key)) {
        $script:HashCache[$key] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return [string]$script:HashCache[$key]
}

function Get-DiskSummary {
    param([string]$DriveLetter)
    try {
        $device = $DriveLetter.TrimEnd('\').TrimEnd(':') + ':'
        $escaped = $device.Replace("'", "''")
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$escaped'" -ErrorAction Stop
        if (-not $disk) { return [ordered]@{ drive = $device; available = $false } }
        return [ordered]@{
            drive = $device
            available = $true
            driveType = [int]$disk.DriveType
            fileSystem = [string]$disk.FileSystem
            sizeGiB = [math]::Round(([double]$disk.Size / 1GB), 1)
            freeGiB = [math]::Round(([double]$disk.FreeSpace / 1GB), 1)
        }
    }
    catch {
        return [ordered]@{ drive = $DriveLetter; available = $false; error = Protect-DiagnosticText $_.Exception.Message }
    }
}

function Get-ProgramPath {
    param([string]$Executable)
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$Executable",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$Executable"
    )
    foreach ($key in $keys) {
        try {
            $value = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)'
            if ($value -and (Test-Path -LiteralPath $value -PathType Leaf)) { return [string]$value }
        }
        catch {}
    }
    return ''
}

function Get-ProgramSummary {
    param([string]$Name, [string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{ name = $Name; detected = $false }
    }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        name = $Name
        detected = $true
        version = [string]$item.VersionInfo.FileVersion
        path = Protect-DiagnosticText $item.FullName
    }
}

function Get-GitSummary {
    $candidates = New-Object Collections.Generic.List[string]
    foreach ($key in @('HKLM:\Software\GitForWindows', 'HKCU:\Software\GitForWindows')) {
        try {
            $root = [string](Get-ItemProperty -LiteralPath $key -ErrorAction Stop).InstallPath
            if ($root) { $candidates.Add((Join-Path $root 'cmd\git.exe')) }
        }
        catch {}
    }
    $candidates.Add((Join-Path $env:ProgramFiles 'Git\cmd\git.exe'))
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $item = Get-Item -LiteralPath $candidate
            return [ordered]@{
                detected = $true
                version = [string]$item.VersionInfo.ProductVersion
                path = Protect-DiagnosticText $item.FullName
            }
        }
    }
    return [ordered]@{ detected = $false }
}

function Get-SignatureSummary {
    param([string]$Name, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{ name = $Name; present = $false }
    }
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        return [ordered]@{
            name = $Name
            present = $true
            status = [string]$signature.Status
            signerSubject = Protect-DiagnosticText ([string]$signature.SignerCertificate.Subject)
            path = Protect-DiagnosticText $Path
        }
    }
    catch {
        return [ordered]@{
            name = $Name
            present = $true
            status = 'ReadError'
            error = Protect-DiagnosticText $_.Exception.Message
        }
    }
}

function Get-SafeDeploymentState {
    param([string]$ResolvedDataRoot)
    $statePath = Join-Path $ResolvedDataRoot 'State\deployment-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [ordered]@{ present = $false }
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $storage = Get-ObjectProperty $state 'Storage'
        $git = Get-ObjectProperty $state 'Git'
        $vmp = Get-ObjectProperty $state 'VirtualMachinePlatform'
        $claude = Get-ObjectProperty $state 'Claude'
        $transaction = Get-ObjectProperty $state 'Transaction'
        $resume = Get-ObjectProperty $state 'Resume'
        $lastVerification = Get-ObjectProperty $state 'LastVerification'
        return [ordered]@{
            present = $true
            schemaVersion = Get-ObjectProperty $state 'SchemaVersion'
            product = Protect-DiagnosticText ([string](Get-ObjectProperty $state 'Product' ''))
            packageVersion = Protect-DiagnosticText ([string](Get-ObjectProperty $state 'PackageVersion' ''))
            status = Protect-DiagnosticText ([string](Get-ObjectProperty $state 'Status' ''))
            phase = Protect-DiagnosticText ([string](Get-ObjectProperty $state 'Phase' ''))
            updatedAt = Get-ObjectProperty $state 'UpdatedAt'
            dataRoot = Protect-DiagnosticText ([string](Get-ObjectProperty $storage 'DataRoot' $ResolvedDataRoot))
            claude = [ordered]@{
                presentBefore = [bool](Get-ObjectProperty $claude 'PresentBefore' $false)
                installedByPilot = [bool](Get-ObjectProperty $claude 'InstalledByPilot' $false)
                versionAfter = Protect-DiagnosticText ([string](Get-ObjectProperty $claude 'VersionAfter' ''))
            }
            git = [ordered]@{
                presentBefore = [bool](Get-ObjectProperty $git 'PresentBefore' $false)
                installedByPilot = [bool](Get-ObjectProperty $git 'InstalledByPilot' $false)
                changedByPilot = [bool](Get-ObjectProperty $git 'ChangedByPilot' $false)
                versionAfter = Protect-DiagnosticText ([string](Get-ObjectProperty $git 'VersionAfter' ''))
            }
            virtualMachinePlatform = [ordered]@{
                stateBefore = Protect-DiagnosticText ([string](Get-ObjectProperty $vmp 'StateBefore' ''))
                enabledByPilot = [bool](Get-ObjectProperty $vmp 'EnabledByPilot' $false)
                stateAfter = Protect-DiagnosticText ([string](Get-ObjectProperty $vmp 'StateAfter' ''))
            }
            transaction = [ordered]@{
                failureCode = Protect-DiagnosticText ([string](Get-ObjectProperty $transaction 'FailureCode' ''))
                sanitizedFailure = Protect-DiagnosticText ([string](Get-ObjectProperty $transaction 'SanitizedFailure' ''))
            }
            resume = [ordered]@{
                required = [bool](Get-ObjectProperty $resume 'Required' $false)
                completedAt = Get-ObjectProperty $resume 'CompletedAt'
            }
            lastVerification = [ordered]@{
                summary = Protect-DiagnosticText ([string](Get-ObjectProperty $lastVerification 'Summary' ''))
                checkedAt = Get-ObjectProperty $lastVerification 'CheckedAt'
            }
        }
    }
    catch {
        return [ordered]@{
            present = $true
            readable = $false
            error = Protect-DiagnosticText $_.Exception.Message
        }
    }
}

function Assert-GeneratedContentSafe {
    param([string]$Root)
    $forbidden = '(?i)sk-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._~+/=-]{12,}'
    foreach ($file in Get-ChildItem -LiteralPath $Root -File) {
        $text = [IO.File]::ReadAllText($file.FullName)
        if ($text -match $forbidden) {
            throw "Generated diagnostic content failed its secret safety scan: $($file.Name)"
        }
    }
}

try {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (-not [string]::Equals($currentSid, $ExpectedUserSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Diagnostic export must continue under the same Windows user.'
    }

    $resolvedDataRoot = ConvertTo-FullPath $DataRoot
    $resolvedPackageRoot = ConvertTo-FullPath $PackageRoot
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.Path]::GetExtension($resolvedOutput) -ne '.zip') { throw 'Diagnostic output must use the .zip extension.' }
    $outputParent = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw 'Diagnostic output parent directory does not exist.' }
    if (-not (Test-Path -LiteralPath $resolvedPackageRoot -PathType Container)) { throw 'Package root does not exist.' }

    $tempBase = ConvertTo-FullPath (Join-Path ([IO.Path]::GetTempPath()) 'ClaudePilotR3')
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
    $script:StagingRoot = Join-Path $tempBase ('Diagnostics-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:StagingRoot | Out-Null

    Write-DiagnosticProgress 5 '正在收集白名单环境信息。'
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $dataDrive = [IO.Path]::GetPathRoot($resolvedDataRoot)
    $vmpState = try { [string](Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop).State } catch { 'Unavailable' }

    $environment = [ordered]@{
        schemaVersion = 1
        product = 'Claude Pilot R3.5'
        generatedAt = (Get-Date).ToString('o')
        userIdentityIncluded = $false
        userContextMatched = $true
        windows = [ordered]@{
            caption = Protect-DiagnosticText ([string]$os.Caption)
            version = [string]$os.Version
            build = [string]$os.BuildNumber
            architecture = [string]$os.OSArchitecture
            processIs64Bit = [Environment]::Is64BitProcess
            osIs64Bit = [Environment]::Is64BitOperatingSystem
            powershell = [string]$PSVersionTable.PSVersion
            administrator = [bool]$admin
        }
        hardware = [ordered]@{
            manufacturer = Protect-DiagnosticText ([string]$computer.Manufacturer)
            model = Protect-DiagnosticText ([string]$computer.Model)
            biosManufacturer = Protect-DiagnosticText ([string]$bios.Manufacturer)
            virtualizationFirmwareEnabled = [bool]$processor.VirtualizationFirmwareEnabled
            hypervisorPresent = [bool]$computer.HypervisorPresent
            virtualMachinePlatform = $vmpState
        }
        storage = @(
            Get-DiskSummary 'C:'
            if ($dataDrive -and $dataDrive.TrimEnd('\') -ne 'C:') { Get-DiskSummary $dataDrive }
        )
        dataRoot = Protect-DiagnosticText $resolvedDataRoot
    }
    Write-Utf8Json (Join-Path $script:StagingRoot 'environment.json') $environment

    Write-DiagnosticProgress 18 '正在读取组件和部署状态摘要。'
    $claudePackage = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    $claude3p = Join-Path $env:LOCALAPPDATA 'Claude-3p'
    $claude3pPhysical = $false
    if (Test-Path -LiteralPath $claude3p -PathType Container) {
        $claude3pPhysical = -not [bool]((Get-Item -LiteralPath $claude3p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
    }
    $coworkService = Get-Service -Name 'CoworkVMService' -ErrorAction SilentlyContinue
    $runOnce = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue
    $runOnceRegistered = $null -ne ($runOnce.PSObject.Properties | Where-Object Name -eq 'ClaudePilotR3Resume' | Select-Object -First 1)
    $components = [ordered]@{
        schemaVersion = 1
        claudeDesktop = [ordered]@{
            detected = [bool]$claudePackage
            version = if ($claudePackage) { [string]$claudePackage.Version } else { '' }
            installLocation = if ($claudePackage) { Protect-DiagnosticText ([string]$claudePackage.InstallLocation) } else { '' }
        }
        git = Get-GitSummary
        office = @(
            Get-ProgramSummary 'Microsoft Word' (Get-ProgramPath 'WINWORD.EXE')
            Get-ProgramSummary 'Microsoft Excel' (Get-ProgramPath 'EXCEL.EXE')
            Get-ProgramSummary 'Microsoft PowerPoint' (Get-ProgramPath 'POWERPNT.EXE')
        )
        cowork = [ordered]@{
            serviceDetected = [bool]$coworkService
            serviceStatus = if ($coworkService) { [string]$coworkService.Status } else { '' }
            serviceStartType = if ($coworkService) { [string]$coworkService.StartType } else { '' }
            claude3pExists = Test-Path -LiteralPath $claude3p -PathType Container
            claude3pPhysicalDirectory = $claude3pPhysical
        }
        resume = [ordered]@{
            runOnceRegistered = [bool]$runOnceRegistered
        }
        deploymentState = Get-SafeDeploymentState $resolvedDataRoot
    }
    Write-Utf8Json (Join-Path $script:StagingRoot 'component-status.json') $components

    Write-DiagnosticProgress 30 '正在校验离线资源 manifest 与 SHA-256。'
    $resources = Join-Path $resolvedPackageRoot '资源目录'
    $manifestPath = Join-Path $resources 'manifest.json'
    $sumPath = Join-Path $resources 'SHA256SUMS'
    $manifestFailures = New-Object Collections.Generic.List[string]
    $sumFailures = New-Object Collections.Generic.List[string]
    $manifestCount = 0
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifestEntries = @($manifest.files)
        $manifestCount = $manifestEntries.Count
        $index = 0
        foreach ($entry in $manifestEntries) {
            $index++
            $relative = [string]$entry.path
            try {
                $path = Resolve-ContainedPath $resources $relative
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $manifestFailures.Add("missing: $relative")
                }
                elseif ((Get-Item -LiteralPath $path).Length -ne [int64]$entry.size) {
                    $manifestFailures.Add("size: $relative")
                }
                elseif ((Get-CachedSha256 $path) -ne ([string]$entry.sha256).ToUpperInvariant()) {
                    $manifestFailures.Add("hash: $relative")
                }
            }
            catch { $manifestFailures.Add("unsafe: $relative") }
            if ($manifestCount -gt 0 -and ($index % 10 -eq 0)) {
                Write-DiagnosticProgress (30 + [int](25 * $index / $manifestCount)) "正在校验 manifest：$index/$manifestCount"
            }
        }
    }
    else {
        $manifestFailures.Add('manifest.json missing')
    }

    $sumCount = 0
    if (Test-Path -LiteralPath $sumPath -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $sumPath -Encoding UTF8) {
            if ($line -notmatch '^([A-Fa-f0-9]{64})\s{2}(.+)$') {
                $sumFailures.Add('malformed SHA256SUMS line')
                continue
            }
            $sumCount++
            $expected = $matches[1].ToUpperInvariant()
            $relative = $matches[2]
            try {
                $path = Resolve-ContainedPath $resolvedPackageRoot $relative
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $sumFailures.Add("missing: $relative") }
                elseif ((Get-CachedSha256 $path) -ne $expected) { $sumFailures.Add("hash: $relative") }
            }
            catch { $sumFailures.Add("unsafe: $relative") }
        }
    }
    else {
        $sumFailures.Add('SHA256SUMS missing')
    }

    Write-DiagnosticProgress 72 '正在核对厂商签名。'
    $integrity = [ordered]@{
        schemaVersion = 1
        packageRoot = Protect-DiagnosticText $resolvedPackageRoot
        manifest = [ordered]@{
            present = Test-Path -LiteralPath $manifestPath -PathType Leaf
            entries = $manifestCount
            passed = ($manifestFailures.Count -eq 0)
            failures = @($manifestFailures | ForEach-Object { Protect-DiagnosticText $_ })
        }
        sha256Sums = [ordered]@{
            present = Test-Path -LiteralPath $sumPath -PathType Leaf
            entries = $sumCount
            passed = ($sumFailures.Count -eq 0)
            failures = @($sumFailures | ForEach-Object { Protect-DiagnosticText $_ })
        }
        signatures = @(
            Get-SignatureSummary 'Claude Desktop MSIX' (Join-Path $resources 'Claude\Claude-Desktop-x64.msix')
            Get-SignatureSummary 'Git for Windows' (Join-Path $resources 'Git\Git-2.55.0.3-64-bit.exe')
            Get-SignatureSummary 'Cowork Host Code' (Join-Path $resources 'Cowork\claude-code\2.1.209\claude.exe')
            Get-SignatureSummary 'Claude Pilot Setup' (Join-Path $resolvedPackageRoot 'ClaudePilotSetup.exe')
        )
    }
    Write-Utf8Json (Join-Path $script:StagingRoot 'integrity-check.json') $integrity

    Write-DiagnosticProgress 82 '正在生成脱敏日志摘要。'
    $sessionLines = @()
    if (Test-Path -LiteralPath $SessionLogPath -PathType Leaf) {
        $sessionLines = @(Get-Content -LiteralPath $SessionLogPath -Encoding UTF8 | Select-Object -Last 200)
    }
    $logLines = New-Object Collections.Generic.List[string]
    $logLines.Add('Claude Pilot R3.5 sanitized diagnostic log')
    $logLines.Add('Source: current graphical session progress only; Office documents, Cowork work files and Claude authentication configuration were not read.')
    $logLines.Add('')
    foreach ($line in $sessionLines) { $logLines.Add((Protect-DiagnosticText ([string]$line))) }
    Write-Utf8Lines (Join-Path $script:StagingRoot 'sanitized-log.txt') $logLines.ToArray()

    $summary = @(
        'Claude Pilot R3.5 脱敏诊断摘要',
        "生成时间：$((Get-Date).ToString('o'))",
        "Windows：$([string]$os.Caption) | Build $([string]$os.BuildNumber) | $([string]$os.OSArchitecture)",
        "管理员：$admin",
        "VirtualMachinePlatform：$vmpState",
        "Claude Desktop：$(if ($claudePackage) { [string]$claudePackage.Version } else { '未检测到' })",
        "CoworkVMService：$(if ($coworkService) { [string]$coworkService.Status } else { '未检测到' })",
        "manifest：$(if ($manifestFailures.Count -eq 0) { 'PASS' } else { 'FAIL' })，$manifestCount 项",
        "SHA256SUMS：$(if ($sumFailures.Count -eq 0) { 'PASS' } else { 'FAIL' })，$sumCount 项",
        '',
        '本诊断包未读取或收集：DeepSeek API Key、认证字段、Office 文档内容、Cowork 工作文件、用户名、当前用户 SID 和设备名。',
        '本诊断包不会自动上传或发送。'
    )
    Write-Utf8Lines (Join-Path $script:StagingRoot 'summary.txt') $summary

    Assert-GeneratedContentSafe $script:StagingRoot
    Write-DiagnosticProgress 92 '正在压缩诊断文件。'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $resolvedOutput -PathType Leaf) { Remove-Item -LiteralPath $resolvedOutput -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $script:StagingRoot,
        $resolvedOutput,
        [IO.Compression.CompressionLevel]::Optimal,
        $false
    )
    Write-DiagnosticProgress 100 '脱敏诊断包已生成。'
    Write-Output $resolvedOutput
    exit 0
}
catch {
    Write-Error (Protect-DiagnosticText $_.Exception.Message)
    exit 2
}
finally {
    if ($script:StagingRoot -and (Test-Path -LiteralPath $script:StagingRoot -PathType Container)) {
        try {
            $tempBase = ConvertTo-FullPath (Join-Path ([IO.Path]::GetTempPath()) 'ClaudePilotR3')
            $stageFull = ConvertTo-FullPath $script:StagingRoot
            if ($stageFull.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $stageFull -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }
}
