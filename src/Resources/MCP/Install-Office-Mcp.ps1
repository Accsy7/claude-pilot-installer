[CmdletBinding()]
param(
    [string]$ClaudeConfigPath = "$env:LOCALAPPDATA\Claude-3p\claude_desktop_config.json",
    [string]$InstallRoot = 'D:\ClaudeDesktop\MCP\Office',
    [string]$AllowedRoot = 'D:\ClaudeDesktop\Cowork',
    [string]$BackupRoot = 'D:\ClaudeDesktop\Backups\OfficeMcp'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function Get-RegisteredApplicationPath {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutableName,
        [Parameter(Mandatory = $true)][string]$OfficeLeaf
    )

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExecutableName",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$ExecutableName",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExecutableName"
    )
    foreach ($registryPath in $registryPaths) {
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

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($root in $roots) {
        foreach ($relative in @(
            "Microsoft Office\root\Office16\$OfficeLeaf",
            "Microsoft Office\Office16\$OfficeLeaf",
            "Microsoft Office\root\Office15\$OfficeLeaf",
            "Microsoft Office\Office15\$OfficeLeaf"
        )) {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [IO.Path]::GetFullPath($candidate)
            }
        }
    }
    $localCandidate = Join-Path $env:LOCALAPPDATA "Microsoft\Office\root\Office16\$OfficeLeaf"
    if (Test-Path -LiteralPath $localCandidate -PathType Leaf) {
        return [IO.Path]::GetFullPath($localCandidate)
    }
    return $null
}

function Test-R3OwnedEntry {
    param($Entry, [string]$ServerTarget, [string]$Mode)
    if ($null -eq $Entry) { return $false }
    $argsProperty = $Entry.PSObject.Properties['args']
    if ($null -eq $argsProperty) { return $false }
    $joined = @($argsProperty.Value) -join ' '
    return ($joined.IndexOf($ServerTarget, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $joined -match ("(?i)-Mode\s+{0}(\s|$)" -f [regex]::Escape($Mode)))
}

function Remove-R3OwnedEntry {
    param($Servers, [string[]]$Names, [string]$ServerTarget, [string]$Mode)
    foreach ($name in $Names) {
        $property = $Servers.PSObject.Properties[$name]
        if ($null -ne $property -and (Test-R3OwnedEntry $property.Value $ServerTarget $Mode)) {
            $Servers.PSObject.Properties.Remove($name)
        }
    }
}

function Set-R3OfficeServer {
    param(
        [Parameter(Mandatory = $true)]$Servers,
        [Parameter(Mandatory = $true)][string]$PreferredName,
        [Parameter(Mandatory = $true)][string]$FallbackName,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][bool]$Detected,
        [Parameter(Mandatory = $true)][string]$ServerTarget,
        [Parameter(Mandatory = $true)][string]$AllowedRoot
    )

    $candidateNames = @($PreferredName, $FallbackName)
    if (-not $Detected) {
        Remove-R3OwnedEntry -Servers $Servers -Names $candidateNames -ServerTarget $ServerTarget -Mode $Mode
        return [pscustomobject]@{ Detected = $false; Configured = $false; ServerName = ''; Detail = 'Office application not detected; no MCP was registered.' }
    }

    $selectedName = $null
    foreach ($name in $candidateNames) {
        $property = $Servers.PSObject.Properties[$name]
        if ($null -eq $property -or (Test-R3OwnedEntry $property.Value $ServerTarget $Mode)) {
            $selectedName = $name
            break
        }
    }
    if (-not $selectedName) {
        throw "Both MCP names '$PreferredName' and '$FallbackName' are owned by other configurations. No existing entry was overwritten."
    }

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $entry = [pscustomobject]@{
        command = $powerShellPath
        args = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $ServerTarget, '-Mode', $Mode, '-AllowedRoot', $AllowedRoot
        )
        env = [pscustomobject]@{ CLAUDE_PILOT_R3_MCP = '1' }
    }
    Add-Member -InputObject $Servers -MemberType NoteProperty -Name $selectedName -Value $entry -Force
    return [pscustomobject]@{ Detected = $true; Configured = $true; ServerName = $selectedName; Detail = "Registered as $selectedName." }
}

$serverSource = Join-Path $PSScriptRoot 'Office-McpServer.ps1'
if (-not (Test-Path -LiteralPath $serverSource -PathType Leaf)) {
    throw "MCP server script not found: $serverSource"
}
if (-not (Test-Path -LiteralPath $ClaudeConfigPath -PathType Leaf)) {
    throw "Claude Desktop configuration not found: $ClaudeConfigPath"
}

$wordPath = Get-RegisteredApplicationPath -ExecutableName 'WINWORD.EXE' -OfficeLeaf 'WINWORD.EXE'
$excelPath = Get-RegisteredApplicationPath -ExecutableName 'EXCEL.EXE' -OfficeLeaf 'EXCEL.EXE'
$powerPointPath = Get-RegisteredApplicationPath -ExecutableName 'POWERPNT.EXE' -OfficeLeaf 'POWERPNT.EXE'

New-Item -ItemType Directory -Path $AllowedRoot -Force | Out-Null
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = Join-Path $BackupRoot "claude_desktop_config-$timestamp.json.dpapi"
$backupPlain = $null
$backupEncrypted = $null
try {
    $backupPlain = [IO.File]::ReadAllBytes($ClaudeConfigPath)
    $backupEncrypted = [Security.Cryptography.ProtectedData]::Protect(
        $backupPlain,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [IO.File]::WriteAllBytes($backupPath, $backupEncrypted)
}
finally {
    if ($backupPlain) { [Array]::Clear($backupPlain, 0, $backupPlain.Length) }
    if ($backupEncrypted) { [Array]::Clear($backupEncrypted, 0, $backupEncrypted.Length) }
}

$serverTarget = Join-Path $InstallRoot 'Office-McpServer.ps1'
if ($wordPath -or $excelPath) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item -LiteralPath $serverSource -Destination $serverTarget -Force
}

$config = Get-Content -LiteralPath $ClaudeConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $config.PSObject.Properties['mcpServers'] -or $null -eq $config.mcpServers) {
    Add-Member -InputObject $config -MemberType NoteProperty -Name 'mcpServers' -Value ([pscustomobject]@{}) -Force
}

$wordResult = Set-R3OfficeServer -Servers $config.mcpServers -PreferredName 'word' -FallbackName 'claude_pilot_word' -Mode 'Word' -Detected ([bool]$wordPath) -ServerTarget $serverTarget -AllowedRoot $AllowedRoot
$excelResult = Set-R3OfficeServer -Servers $config.mcpServers -PreferredName 'excel' -FallbackName 'claude_pilot_excel' -Mode 'Excel' -Detected ([bool]$excelPath) -ServerTarget $serverTarget -AllowedRoot $AllowedRoot

$tempPath = "$ClaudeConfigPath.r3-$([guid]::NewGuid().ToString('N')).tmp"
try {
    $json = $config | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    [void](Get-Content -LiteralPath $tempPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    Move-Item -LiteralPath $tempPath -Destination $ClaudeConfigPath -Force
}
finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    Installed = [bool]($wordResult.Configured -or $excelResult.Configured)
    ConfigPath = $ClaudeConfigPath
    RuntimePath = if ($wordPath -or $excelPath) { $serverTarget } else { '' }
    AllowedRoot = $AllowedRoot
    BackupPath = $backupPath
    Word = [pscustomobject]@{ Detected = [bool]$wordPath; Path = [string]$wordPath; Configured = [bool]$wordResult.Configured; ServerName = [string]$wordResult.ServerName; Detail = [string]$wordResult.Detail }
    Excel = [pscustomobject]@{ Detected = [bool]$excelPath; Path = [string]$excelPath; Configured = [bool]$excelResult.Configured; ServerName = [string]$excelResult.ServerName; Detail = [string]$excelResult.Detail }
    PowerPoint = [pscustomobject]@{ Detected = [bool]$powerPointPath; Path = [string]$powerPointPath; McpConfigured = $false; Detail = 'Detection only; R3 does not provide a PowerPoint MCP.' }
    RestartClaudeRequired = $true
    ContainsDeepSeekKey = $false
} | ConvertTo-Json -Depth 8 -Compress
