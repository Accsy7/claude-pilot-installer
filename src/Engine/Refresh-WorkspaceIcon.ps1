[CmdletBinding()]
param(
    [string]$DataRoot = '',
    [string]$SettingsPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resourcesRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bundleRoot = $resourcesRoot
. (Join-Path $PSScriptRoot 'Deployment-Paths.ps1')
$paths = Resolve-PilotDeploymentPaths -BundleRoot $bundleRoot -RequestedDataRoot $DataRoot -SettingsPath $SettingsPath -Mode Install

$iconSource = Join-Path $resourcesRoot '配置\Assets\claude.ico'
if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) {
    throw "Claude icon asset was not found: $iconSource"
}
if (-not (Test-Path -LiteralPath $paths.DataRoot -PathType Container)) {
    throw "DataRoot does not exist yet: $($paths.DataRoot)"
}

$iconTarget = Join-Path $paths.DataRoot 'claude.ico'
$desktopIni = Join-Path $paths.DataRoot 'desktop.ini'
$shortcutPath = Join-Path $paths.DataRoot 'Claude Desktop.lnk'

foreach ($path in @($desktopIni, $iconTarget)) {
    if (Test-Path -LiteralPath $path) {
        & attrib.exe -h -s -r $path 2>$null
    }
}
& attrib.exe -r $paths.DataRoot 2>$null
Copy-Item -LiteralPath $iconSource -Destination $iconTarget -Force
$desktopIniContent = "[.ShellClassInfo]`r`nIconResource=$iconTarget,0`r`n"
[IO.File]::WriteAllText($desktopIni, $desktopIniContent, (New-Object Text.UTF8Encoding($false)))

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:WINDIR 'explorer.exe'
$shortcut.Arguments = 'shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude'
$shortcut.WorkingDirectory = $paths.DataRoot
$shortcut.IconLocation = "$iconTarget,0"
$shortcut.Description = 'Launch Claude Desktop'
$shortcut.Save()

& attrib.exe +h $iconTarget 2>$null
& attrib.exe +h +s $desktopIni 2>$null
& attrib.exe +r $paths.DataRoot 2>$null
$iconRefresh = Join-Path $env:WINDIR 'System32\ie4uinit.exe'
if (Test-Path -LiteralPath $iconRefresh -PathType Leaf) {
    Start-Process -FilePath $iconRefresh -ArgumentList '-show' -WindowStyle Hidden -Wait
}

Write-Host "Folder icon refreshed: $($paths.DataRoot)" -ForegroundColor Green
Write-Host "High-resolution launcher shortcut: $shortcutPath" -ForegroundColor Green
