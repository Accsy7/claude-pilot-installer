[CmdletBinding()]
param(
    [switch]$Clean,
    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot 'src\ClaudePilotSetup\ClaudePilotSetup.csproj'
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $artifactsRoot 'public\win-x64'
}

$resolvedRepositoryRoot = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\')
$resolvedArtifactsRoot = [IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\')
$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if (-not $resolvedOutputDirectory.StartsWith($resolvedArtifactsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Public build output must stay below the repository artifacts directory: $resolvedOutputDirectory"
}

if ($Clean -and (Test-Path -LiteralPath $resolvedOutputDirectory)) {
    Remove-Item -LiteralPath $resolvedOutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null

$localDotnet = Join-Path $repositoryRoot '_tools\dotnet\dotnet.exe'
$dotnet = if (Test-Path -LiteralPath $localDotnet -PathType Leaf) {
    $localDotnet
}
else {
    (Get-Command dotnet.exe -ErrorAction Stop).Source
}
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$localNugetPackages = Join-Path $repositoryRoot '_tools\nuget-packages'
if (Test-Path -LiteralPath $localNugetPackages -PathType Container) {
    $env:NUGET_PACKAGES = $localNugetPackages
}
$localDotnetHome = Join-Path $repositoryRoot '_tools\dotnet-home'
$env:DOTNET_CLI_HOME = if (Test-Path -LiteralPath $localDotnetHome -PathType Container) {
    $localDotnetHome
}
else {
    Join-Path $artifactsRoot '.dotnet-home'
}

& $dotnet restore $projectPath --locked-mode --runtime win-x64
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed with exit code $LASTEXITCODE."
}

& $dotnet publish $projectPath `
    --no-restore `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    --output $resolvedOutputDirectory
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$executable = Join-Path $resolvedOutputDirectory 'ClaudePilotSetup.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Published executable is missing: $executable"
}

$hash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToUpperInvariant()
$hashLine = "$hash  ClaudePilotSetup.exe`r`n"
[IO.File]::WriteAllText(
    (Join-Path $resolvedOutputDirectory 'SHA256SUMS.txt'),
    $hashLine,
    (New-Object Text.UTF8Encoding($false))
)

$file = Get-Item -LiteralPath $executable
$version = $file.VersionInfo.FileVersion
$sdkVersion = (& $dotnet --version | Select-Object -First 1).Trim()
$metadata = [ordered]@{
    schemaVersion = 1
    product = 'Claude Pilot Installer Core'
    version = $version
    runtime = 'win-x64'
    dotnetSdk = $sdkVersion
    file = $file.Name
    bytes = [int64]$file.Length
    sha256 = $hash
    sourceBoundary = 'Self-developed installer core only; third-party offline resources excluded.'
}
[IO.File]::WriteAllText(
    (Join-Path $resolvedOutputDirectory 'BUILD-INFO.json'),
    ($metadata | ConvertTo-Json -Depth 4),
    (New-Object Text.UTF8Encoding($false))
)

[pscustomobject]@{
    Executable = $executable
    Sha256 = $hash
    Bytes = [int64]$file.Length
    BuildInfo = Join-Path $resolvedOutputDirectory 'BUILD-INFO.json'
} | ConvertTo-Json -Depth 4
