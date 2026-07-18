Set-StrictMode -Version 2.0

function ConvertTo-PilotFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw '工作目录不能为空。'
    }
    if ($candidate.StartsWith('\\') -or $candidate.StartsWith('//')) {
        throw '工作目录必须位于本机固定磁盘，不能使用网络共享路径。'
    }
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        throw "工作目录路径不完整：$candidate"
    }

    $full = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
    $volumeRoot = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    if ($full.Equals($volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "不能直接使用整个磁盘作为工作目录，请选择磁盘内的一个文件夹：$full"
    }
    if ($full -notmatch '^[A-Za-z]:\\') {
        throw "工作目录必须使用普通的本机盘符路径：$full"
    }
    return $full
}

function Test-PilotSamePath {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )
    $a = (ConvertTo-PilotFullPath $First).TrimEnd('\')
    $b = (ConvertTo-PilotFullPath $Second).TrimEnd('\')
    return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PilotPathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if ($fullPath.Equals($fullParent, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $fullPath.StartsWith($fullParent + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-PilotPointerPath {
    return Join-Path $env:LOCALAPPDATA 'ClaudePilotR3\deployment-pointer.json'
}

function Get-PilotMarkerPath {
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    return Join-Path (ConvertTo-PilotFullPath $DataRoot) '.claude-pilot-r3-managed.json'
}

function Read-PilotJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON file: $Path. $($_.Exception.Message)"
    }
}

function Get-PilotPropertyValue {
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

function Resolve-PilotDeploymentPaths {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [string]$RequestedDataRoot = '',
        [string]$SettingsPath = '',
        [ValidateSet('Install', 'Uninstall')][string]$Mode = 'Install'
    )

    $pointerPath = Get-PilotPointerPath
    $pointer = Read-PilotJsonFile $pointerPath
    $pointerRoot = ''
    if ($pointer -and (Get-PilotPropertyValue $pointer 'DataRoot' '')) {
        $pointerRoot = ConvertTo-PilotFullPath ([string]$pointer.DataRoot)
    }

    $requestedRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($RequestedDataRoot)) {
        $requestedRoot = ConvertTo-PilotFullPath $RequestedDataRoot
    }
    if ($requestedRoot -and $pointerRoot -and -not (Test-PilotSamePath $requestedRoot $pointerRoot)) {
        throw "本机已有部署使用工作目录 $pointerRoot。请继续使用原目录，或先完成安全卸载。"
    }

    $resolvedSettingsPath = $SettingsPath
    if ([string]::IsNullOrWhiteSpace($resolvedSettingsPath)) {
        $resolvedSettingsPath = Join-Path $BundleRoot 'deployment-settings.json'
    }
    elseif (-not [IO.Path]::IsPathRooted($resolvedSettingsPath)) {
        $resolvedSettingsPath = Join-Path $BundleRoot $resolvedSettingsPath
    }
    $resolvedSettingsPath = [IO.Path]::GetFullPath($resolvedSettingsPath)

    $settingsRoot = ''
    if ($Mode -eq 'Install' -and (Test-Path -LiteralPath $resolvedSettingsPath -PathType Leaf)) {
        $settings = Read-PilotJsonFile $resolvedSettingsPath
        $configured = [string](Get-PilotPropertyValue $settings 'DataRoot' '')
        if (-not [string]::IsNullOrWhiteSpace($configured)) {
            $settingsRoot = ConvertTo-PilotFullPath $configured
        }
    }

    if ($requestedRoot) {
        $dataRoot = $requestedRoot
        $source = 'CommandLine'
    }
    elseif ($pointerRoot) {
        $dataRoot = $pointerRoot
        $source = 'InstalledPointer'
    }
    elseif ($Mode -eq 'Install' -and $settingsRoot) {
        $dataRoot = $settingsRoot
        $source = 'SettingsFile'
    }
    else {
        $dataRoot = 'D:\ClaudeDesktop'
        $source = 'LegacyDefault'
    }

    $dataRoot = ConvertTo-PilotFullPath $dataRoot
    return [pscustomobject]@{
        DataRoot = $dataRoot
        CoworkRoot = Join-Path $dataRoot 'Cowork'
        RuntimeRoot = Join-Path $dataRoot 'Runtime'
        # Kept for repairing/uninstalling early bundles that placed Claude-3p behind a junction.
        ClaudeUserDataTarget = Join-Path $dataRoot 'Runtime\Claude-3p'
        LegacyClaudeUserDataTarget = Join-Path $dataRoot 'Runtime\Claude-3p'
        StatePath = Join-Path $dataRoot 'State\deployment-state.json'
        MarkerPath = Get-PilotMarkerPath $dataRoot
        PointerPath = $pointerPath
        SettingsPath = $resolvedSettingsPath
        ResolutionSource = $source
    }
}

function Get-PilotDataRootOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [string]$ExpectedUserSid = ''
    )

    $root = ConvertTo-PilotFullPath $DataRoot
    $statePath = Join-Path $root 'State\deployment-state.json'
    $markerPath = Get-PilotMarkerPath $root
    $pointerPath = Get-PilotPointerPath
    $state = Read-PilotJsonFile $statePath
    $marker = Read-PilotJsonFile $markerPath
    $pointer = Read-PilotJsonFile $pointerPath

    # Read-only compatibility with the R2 ownership triple. This permits a
    # verified in-place R2 -> R3 repair without rewriting or deleting R2 files.
    $legacyStatePath = Join-Path $root 'deployment-state.json'
    $legacyMarkerPath = Join-Path $root '.claude-pilot-managed.json'
    $legacyPointerPath = Join-Path $env:LOCALAPPDATA 'ClaudePilot\deployment-pointer.json'
    $legacyState = Read-PilotJsonFile $legacyStatePath
    $legacyMarker = Read-PilotJsonFile $legacyMarkerPath
    $legacyPointer = Read-PilotJsonFile $legacyPointerPath

    $stateStorage = Get-PilotPropertyValue $state 'Storage'
    $stateRoot = [string](Get-PilotPropertyValue $stateStorage 'CompanyRoot' '')
    if (-not $stateRoot) {
        $stateRoot = [string](Get-PilotPropertyValue $stateStorage 'DataRoot' '')
    }
    $stateSid = [string](Get-PilotPropertyValue $state 'WindowsUserSid' '')
    $stateId = [string](Get-PilotPropertyValue $state 'DeploymentId' '')
    $markerRoot = [string](Get-PilotPropertyValue $marker 'DataRoot' '')
    $markerSid = [string](Get-PilotPropertyValue $marker 'WindowsUserSid' '')
    $markerId = [string](Get-PilotPropertyValue $marker 'DeploymentId' '')
    $pointerRoot = [string](Get-PilotPropertyValue $pointer 'DataRoot' '')
    $pointerSid = [string](Get-PilotPropertyValue $pointer 'WindowsUserSid' '')
    $pointerId = [string](Get-PilotPropertyValue $pointer 'DeploymentId' '')
    $markerStatus = [string](Get-PilotPropertyValue $marker 'Status' '')
    $pointerStatus = [string](Get-PilotPropertyValue $pointer 'Status' '')
    $markerManagedBy = [string](Get-PilotPropertyValue $marker 'ManagedBy' '')
    $pointerManagedBy = [string](Get-PilotPropertyValue $pointer 'ManagedBy' '')

    $stateRootMatches = $false
    $markerRootMatches = $false
    $pointerRootMatches = $false
    try { if ($stateRoot) { $stateRootMatches = Test-PilotSamePath $stateRoot $root } } catch {}
    try { if ($markerRoot) { $markerRootMatches = Test-PilotSamePath $markerRoot $root } } catch {}
    try { if ($pointerRoot) { $pointerRootMatches = Test-PilotSamePath $pointerRoot $root } } catch {}
    $sidMatches = (-not $ExpectedUserSid) -or (
        (($stateSid -eq $ExpectedUserSid) -or (-not $state)) -and
        (($markerSid -eq $ExpectedUserSid) -or (-not $marker)) -and
        (($pointerSid -eq $ExpectedUserSid) -or (-not $pointer))
    )

    $fullyManaged = (
        $state -and $marker -and $pointer -and
        $stateRootMatches -and $markerRootMatches -and $pointerRootMatches -and
        $stateId -and $stateId -eq $markerId -and $stateId -eq $pointerId -and
        $sidMatches -and $markerStatus -eq 'Installed' -and $pointerStatus -eq 'Installed' -and
        $markerManagedBy -eq 'ClaudePilotR3' -and $pointerManagedBy -eq 'ClaudePilotR3'
    )
    $legacyStorage = Get-PilotPropertyValue $legacyState 'Storage'
    $legacyStateRoot = [string](Get-PilotPropertyValue $legacyStorage 'DataRoot' '')
    if (-not $legacyStateRoot) { $legacyStateRoot = [string](Get-PilotPropertyValue $legacyStorage 'CompanyRoot' '') }
    $legacyStateSid = [string](Get-PilotPropertyValue $legacyState 'WindowsUserSid' '')
    $legacyStateId = [string](Get-PilotPropertyValue $legacyState 'DeploymentId' '')
    $legacyMarkerRoot = [string](Get-PilotPropertyValue $legacyMarker 'DataRoot' '')
    $legacyMarkerSid = [string](Get-PilotPropertyValue $legacyMarker 'WindowsUserSid' '')
    $legacyMarkerId = [string](Get-PilotPropertyValue $legacyMarker 'DeploymentId' '')
    $legacyMarkerManagedBy = [string](Get-PilotPropertyValue $legacyMarker 'ManagedBy' '')
    $legacyMarkerStatus = [string](Get-PilotPropertyValue $legacyMarker 'Status' '')
    $legacyPointerRoot = [string](Get-PilotPropertyValue $legacyPointer 'DataRoot' '')
    $legacyPointerSid = [string](Get-PilotPropertyValue $legacyPointer 'WindowsUserSid' '')
    $legacyPointerId = [string](Get-PilotPropertyValue $legacyPointer 'DeploymentId' '')
    $legacyPointerManagedBy = [string](Get-PilotPropertyValue $legacyPointer 'ManagedBy' '')
    $legacyPointerStatus = [string](Get-PilotPropertyValue $legacyPointer 'Status' '')
    $legacyRootsMatch = $false
    try {
        $legacyRootsMatch = (
            $legacyStateRoot -and $legacyMarkerRoot -and $legacyPointerRoot -and
            (Test-PilotSamePath $legacyStateRoot $root) -and
            (Test-PilotSamePath $legacyMarkerRoot $root) -and
            (Test-PilotSamePath $legacyPointerRoot $root)
        )
    }
    catch {}
    $legacySidMatches = (-not $ExpectedUserSid) -or (
        $legacyStateSid -eq $ExpectedUserSid -and
        $legacyMarkerSid -eq $ExpectedUserSid -and
        $legacyPointerSid -eq $ExpectedUserSid
    )
    $legacyManaged = (
        -not $state -and $legacyState -and $legacyMarker -and $legacyPointer -and
        $legacyRootsMatch -and $legacySidMatches -and
        $legacyStateId -and $legacyStateId -eq $legacyMarkerId -and $legacyStateId -eq $legacyPointerId -and
        $legacyMarkerStatus -eq 'Installed' -and $legacyPointerStatus -eq 'Installed' -and
        $legacyMarkerManagedBy -eq 'ClaudePilotDeployment' -and
        $legacyPointerManagedBy -eq 'ClaudePilotDeployment'
    )
    $pointerBackedPreservedWork = (
        $marker -and $pointer -and $markerRootMatches -and $pointerRootMatches -and $sidMatches -and
        $markerId -and $markerId -eq $pointerId -and
        $markerStatus -eq 'WorkPreserved' -and $pointerStatus -eq 'WorkPreserved' -and
        $markerManagedBy -eq 'ClaudePilotR3' -and $pointerManagedBy -eq 'ClaudePilotR3'
    )

    # A preserve-data uninstall intentionally removes the deployment state but
    # leaves Cowork and its ownership marker. If the per-user pointer is later
    # missing (for example after an interrupted GUI/UAC close), recover only
    # from a tightly constrained marker-only layout. A present-but-mismatched
    # pointer never falls back to this path.
    $markerOnlyPreservedWork = $false
    $markerPreservedPath = [string](Get-PilotPropertyValue $marker 'PreservedPath' '')
    $markerSchemaVersion = [int](Get-PilotPropertyValue $marker 'SchemaVersion' 0)
    if (
        $marker -and -not $pointer -and -not $state -and
        $markerRootMatches -and $markerId -and $markerSid -and
        ((-not $ExpectedUserSid) -or $markerSid -eq $ExpectedUserSid) -and
        $markerStatus -eq 'WorkPreserved' -and
        $markerManagedBy -eq 'ClaudePilotR3' -and
        $markerSchemaVersion -eq 2 -and
        (Test-Path -LiteralPath $root -PathType Container)
    ) {
        try {
            $expectedPreservedPath = Join-Path $root 'Cowork'
            $preservedPathMatches = $markerPreservedPath -and (Test-PilotSamePath $markerPreservedPath $expectedPreservedPath)
            $unexpectedItems = @(
                Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop |
                    Where-Object { $_.Name -notin @('Cowork', '.claude-pilot-r3-managed.json') }
            )
            $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
            $coworkItem = Get-Item -LiteralPath $expectedPreservedPath -Force -ErrorAction Stop
            $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction Stop
            $physicalLayout = (
                $coworkItem.PSIsContainer -and -not $markerItem.PSIsContainer -and
                (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -and
                (($coworkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -and
                (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
            )
            $markerOnlyPreservedWork = [bool]($preservedPathMatches -and $unexpectedItems.Count -eq 0 -and $physicalLayout)
        }
        catch {
            $markerOnlyPreservedWork = $false
        }
    }
    $preservedWork = [bool]($pointerBackedPreservedWork -or $markerOnlyPreservedWork)

    $status = if ($fullyManaged) { 'Managed' } elseif ($legacyManaged) { 'LegacyManaged' } elseif ($preservedWork) { 'WorkPreserved' } elseif (-not (Test-Path -LiteralPath $root)) { 'Fresh' } elseif ((Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | Select-Object -First 1) -eq $null) { 'Empty' } else { 'Untrusted' }
    return [pscustomobject]@{
        Trusted = [bool]($fullyManaged -or $legacyManaged -or $preservedWork)
        Status = $status
        State = if ($state) { $state } else { $legacyState }
        Marker = $marker
        Pointer = $pointer
        TrustSource = if ($fullyManaged) { 'StateMarkerPointer' } elseif ($legacyManaged) { 'LegacyTriple' } elseif ($pointerBackedPreservedWork) { 'PreservedMarkerPointer' } elseif ($markerOnlyPreservedWork) { 'PreservedMarkerOnly' } else { 'None' }
        DataRoot = $root
        StatePath = $statePath
        MarkerPath = $markerPath
        PointerPath = $pointerPath
    }
}

function Repair-PilotDeploymentPointer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedUserSid
    )

    $root = ConvertTo-PilotFullPath $DataRoot
    $statePath = Join-Path $root 'State\deployment-state.json'
    $markerPath = Get-PilotMarkerPath $root
    $pointerPath = Get-PilotPointerPath

    if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
        return [pscustomobject]@{ Repaired = $false; Status = 'Present'; PointerPath = $pointerPath }
    }
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return [pscustomobject]@{ Repaired = $false; Status = 'InsufficientEvidence'; PointerPath = $pointerPath }
    }

    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    $stateItem = Get-Item -LiteralPath $statePath -Force -ErrorAction Stop
    $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction Stop
    foreach ($item in @($rootItem, $stateItem, $markerItem)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ Repaired = $false; Status = 'ReparsePointRejected'; PointerPath = $pointerPath }
        }
    }

    $state = Read-PilotJsonFile $statePath
    $marker = Read-PilotJsonFile $markerPath
    $storage = Get-PilotPropertyValue $state 'Storage'
    $stateRoot = [string](Get-PilotPropertyValue $storage 'CompanyRoot' '')
    if (-not $stateRoot) { $stateRoot = [string](Get-PilotPropertyValue $storage 'DataRoot' '') }
    $stateId = [string](Get-PilotPropertyValue $state 'DeploymentId' '')
    $stateSid = [string](Get-PilotPropertyValue $state 'WindowsUserSid' '')
    $markerRoot = [string](Get-PilotPropertyValue $marker 'DataRoot' '')
    $markerId = [string](Get-PilotPropertyValue $marker 'DeploymentId' '')
    $markerSid = [string](Get-PilotPropertyValue $marker 'WindowsUserSid' '')
    $markerStatus = [string](Get-PilotPropertyValue $marker 'Status' '')
    $markerManagedBy = [string](Get-PilotPropertyValue $marker 'ManagedBy' '')

    $evidenceMatches = (
        $stateRoot -and $markerRoot -and
        (Test-PilotSamePath $stateRoot $root) -and
        (Test-PilotSamePath $markerRoot $root) -and
        $stateId -and $stateId -eq $markerId -and
        $stateSid -and $stateSid -eq $ExpectedUserSid -and
        $markerSid -eq $ExpectedUserSid -and
        $markerStatus -eq 'Installed' -and
        $markerManagedBy -eq 'ClaudePilotR3'
    )
    if (-not $evidenceMatches) {
        return [pscustomobject]@{ Repaired = $false; Status = 'EvidenceMismatch'; PointerPath = $pointerPath }
    }

    if ($PSCmdlet.ShouldProcess($pointerPath, 'Rebuild Claude Pilot deployment pointer from matching state and marker')) {
        $now = (Get-Date).ToString('o')
        $createdAt = [string](Get-PilotPropertyValue $marker 'CreatedAt' '')
        if (-not $createdAt) { $createdAt = $now }
        $pointer = [ordered]@{
            SchemaVersion = 2
            ManagedBy = 'ClaudePilotR3'
            PackageVersion = 'R3.5-20260718'
            Status = 'Installed'
            DeploymentId = $stateId
            WindowsUserSid = $ExpectedUserSid
            DataRoot = $root
            StatePath = [IO.Path]::GetFullPath($statePath)
            CreatedAt = $createdAt
            UpdatedAt = $now
            RecoveredAt = $now
            RecoverySource = 'MatchingStateAndMarker'
        }
        Write-PilotJsonAtomic -Path $pointerPath -Value $pointer
        return [pscustomobject]@{ Repaired = $true; Status = 'Recovered'; PointerPath = $pointerPath }
    }
    return [pscustomobject]@{ Repaired = $false; Status = 'WhatIf'; PointerPath = $pointerPath }
}

function Assert-PilotDataRootSafety {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [int64]$MinimumFreeBytes = 20GB,
        [switch]$AllowExistingManaged,
        [string]$ExpectedUserSid = ''
    )

    $root = ConvertTo-PilotFullPath $DataRoot
    $bundle = [IO.Path]::GetFullPath($BundleRoot).TrimEnd('\')
    if ((Test-PilotPathWithin $root $bundle) -or (Test-PilotPathWithin $bundle $root)) {
        throw "工作目录不能放在安装包里面，安装包也不能放在工作目录里面。请选择另一个文件夹：$root"
    }

    foreach ($forbidden in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:TEMP)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$forbidden)) {
            $fullForbidden = [IO.Path]::GetFullPath([string]$forbidden).TrimEnd('\')
            if ($root.Equals($fullForbidden, [StringComparison]::OrdinalIgnoreCase) -or
                (Test-PilotPathWithin $fullForbidden $root) -or
                (Test-PilotPathWithin $root $fullForbidden)) {
                throw "这个工作目录范围过大，可能包含 Windows 或个人文件。请新建一个专用文件夹：$root"
            }
        }
    }

    $deviceId = [IO.Path]::GetPathRoot($root).TrimEnd('\')
    $escaped = $deviceId.Replace("'", "''")
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$escaped'" -ErrorAction SilentlyContinue
    if (-not $disk) {
        throw "无法读取工作目录所在磁盘：$deviceId"
    }
    if ([int]$disk.DriveType -ne 3) {
        throw "工作目录必须位于本机固定磁盘：$deviceId"
    }
    if ([string]$disk.FileSystem -ne 'NTFS') {
        throw "工作目录所在磁盘必须是 NTFS 格式；当前 $deviceId 为 $($disk.FileSystem)。"
    }
    if ([int64]$disk.FreeSpace -lt $MinimumFreeBytes) {
        throw ('工作目录所在磁盘空间不足：至少需要 {0:N0} GB，当前可用 {1:N1} GB。' -f ($MinimumFreeBytes / 1GB), ([int64]$disk.FreeSpace / 1GB))
    }

    if (Test-Path -LiteralPath $root) {
        $item = Get-Item -LiteralPath $root -Force
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "工作目录必须是普通文件夹，不能是文件、快捷链接或目录联接：$root"
        }
        $hasContent = $null -ne (Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop | Select-Object -First 1)
        if ($hasContent) {
            $ownership = Get-PilotDataRootOwnership -DataRoot $root -ExpectedUserSid $ExpectedUserSid
            if (-not $AllowExistingManaged -or -not $ownership.Trusted) {
                throw "这个工作目录里已有其他文件，无法安全使用：$root。请新建一个空文件夹，或选择本程序以前使用的目录。"
            }
        }
    }

    return [pscustomobject]@{
        DataRoot = $root
        DeviceId = [string]$disk.DeviceID
        DriveType = [int]$disk.DriveType
        FileSystem = [string]$disk.FileSystem
        FreeBytes = [int64]$disk.FreeSpace
    }
}

function Write-PilotJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ('.pilot-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Write-PilotDeploymentMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$DeploymentId,
        [Parameter(Mandatory = $true)][string]$WindowsUserSid
    )
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "Cannot write deployment metadata before the state file exists: $StatePath"
    }
    $root = ConvertTo-PilotFullPath $DataRoot
    $markerPath = Get-PilotMarkerPath $root
    $pointerPath = Get-PilotPointerPath
    $now = (Get-Date).ToString('o')
    $oldMarker = Read-PilotJsonFile $markerPath
    $createdAt = [string](Get-PilotPropertyValue $oldMarker 'CreatedAt' '')
    if (-not $createdAt) { $createdAt = $now }
    $common = [ordered]@{
        SchemaVersion = 2
        ManagedBy = 'ClaudePilotR3'
        PackageVersion = 'R3.5-20260718'
        Status = 'Installed'
        DeploymentId = $DeploymentId
        WindowsUserSid = $WindowsUserSid
        DataRoot = $root
        StatePath = [IO.Path]::GetFullPath($StatePath)
        CreatedAt = $createdAt
        UpdatedAt = $now
    }
    Write-PilotJsonAtomic -Path $markerPath -Value $common
    Write-PilotJsonAtomic -Path $pointerPath -Value $common
}

function Write-PilotPreservedWorkMarker {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$DeploymentId,
        [Parameter(Mandatory = $true)][string]$WindowsUserSid
    )
    $root = ConvertTo-PilotFullPath $DataRoot
    $markerPath = Get-PilotMarkerPath $root
    $now = (Get-Date).ToString('o')
    $marker = [ordered]@{
        SchemaVersion = 2
        ManagedBy = 'ClaudePilotR3'
        PackageVersion = 'R3.5-20260718'
        Status = 'WorkPreserved'
        DeploymentId = $DeploymentId
        WindowsUserSid = $WindowsUserSid
        DataRoot = $root
        PreservedPath = Join-Path $root 'Cowork'
        UpdatedAt = $now
    }
    Write-PilotJsonAtomic -Path $markerPath -Value $marker
    Write-PilotJsonAtomic -Path (Get-PilotPointerPath) -Value $marker
}

function Remove-PilotDeploymentPointer {
    $pointerPath = Get-PilotPointerPath
    Remove-Item -LiteralPath $pointerPath -Force -ErrorAction SilentlyContinue
    $parent = Split-Path -Parent $pointerPath
    if (Test-Path -LiteralPath $parent -PathType Container) {
        $remaining = Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $remaining) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        }
    }
}
