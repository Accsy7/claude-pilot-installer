[CmdletBinding()]
param(
    [string]$ClaudeConfigPath = "$env:LOCALAPPDATA\Claude-3p\claude_desktop_config.json",
    [string]$InstallRoot = 'D:\ClaudeDesktop\MCP\Office',
    [string]$BackupRoot = 'D:\ClaudeDesktop\Backups\OfficeMcp',
    [switch]$RemoveRuntime
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

if (-not (Test-Path -LiteralPath $ClaudeConfigPath -PathType Leaf)) {
    [pscustomobject]@{ Removed = $false; Detail = 'Claude configuration does not exist.' } | ConvertTo-Json -Compress
    return
}

New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = Join-Path $BackupRoot "before-office-mcp-remove-$timestamp.json.dpapi"
$backupPlain = $null
$backupEncrypted = $null
try {
    $backupPlain = [IO.File]::ReadAllBytes($ClaudeConfigPath)
    $backupEncrypted = [Security.Cryptography.ProtectedData]::Protect($backupPlain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($backupPath, $backupEncrypted)
}
finally {
    if ($backupPlain) { [Array]::Clear($backupPlain, 0, $backupPlain.Length) }
    if ($backupEncrypted) { [Array]::Clear($backupEncrypted, 0, $backupEncrypted.Length) }
}

$serverTarget = Join-Path $InstallRoot 'Office-McpServer.ps1'
$config = Get-Content -LiteralPath $ClaudeConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$removedNames = New-Object System.Collections.Generic.List[string]
if ($null -ne $config.PSObject.Properties['mcpServers'] -and $null -ne $config.mcpServers) {
    foreach ($name in @('word', 'claude_pilot_word', 'excel', 'claude_pilot_excel')) {
        $property = $config.mcpServers.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value.PSObject.Properties['args']) { continue }
        $joined = @($property.Value.args) -join ' '
        if ($joined.IndexOf($serverTarget, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $config.mcpServers.PSObject.Properties.Remove($name)
            $removedNames.Add($name)
        }
    }
}

$json = $config | ConvertTo-Json -Depth 30
$tempPath = "$ClaudeConfigPath.r3-remove-$([guid]::NewGuid().ToString('N')).tmp"
try {
    [IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    [void](Get-Content -LiteralPath $tempPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    Move-Item -LiteralPath $tempPath -Destination $ClaudeConfigPath -Force
}
finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}

if ($RemoveRuntime -and (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    $resolved = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if (-not $resolved.EndsWith('\MCP\Office', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected MCP runtime path: $resolved"
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to recurse through a reparse point: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

[pscustomobject]@{
    Removed = ($removedNames.Count -gt 0)
    RemovedNames = $removedNames.ToArray()
    ConfigPath = $ClaudeConfigPath
    BackupPath = $backupPath
    RestartRequired = $true
} | ConvertTo-Json -Depth 5 -Compress
