param(
    [string]$ServerPath = (Join-Path $PSScriptRoot 'Office-McpServer.ps1'),
    [string]$AllowedRoot = 'D:\ClaudeDesktop\Cowork'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-McpSmokeTest {
    param([Parameter(Mandatory = $true)][ValidateSet('Word', 'Excel')][string]$Mode)

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ServerPath`" -Mode $Mode -AllowedRoot `"$AllowedRoot`""
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start the $Mode MCP server."
    }

    try {
        $initialize = @{
            jsonrpc = '2.0'
            id = 1
            method = 'initialize'
            params = @{
                protocolVersion = '2024-11-05'
                capabilities = @{}
                clientInfo = @{ name = 'local-smoke-test'; version = '1.0.0' }
            }
        } | ConvertTo-Json -Depth 10 -Compress
        $process.StandardInput.WriteLine($initialize)
        $process.StandardInput.Flush()
        $initializeResponse = $process.StandardOutput.ReadLine() | ConvertFrom-Json
        if ($initializeResponse.result.serverInfo.name -notmatch $Mode.ToLowerInvariant()) {
            throw "Unexpected $Mode serverInfo response."
        }

        $notification = @{ jsonrpc = '2.0'; method = 'notifications/initialized'; params = @{} } | ConvertTo-Json -Compress
        $process.StandardInput.WriteLine($notification)
        $process.StandardInput.Flush()

        $listRequest = @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} } | ConvertTo-Json -Compress
        $process.StandardInput.WriteLine($listRequest)
        $process.StandardInput.Flush()
        $listResponse = $process.StandardOutput.ReadLine() | ConvertFrom-Json
        $toolCount = @($listResponse.result.tools).Count
        if ($toolCount -lt 5) {
            throw "$Mode returned only $toolCount tools."
        }

        $statusTool = $Mode.ToLowerInvariant() + '_status'
        $statusRequest = @{
            jsonrpc = '2.0'
            id = 3
            method = 'tools/call'
            params = @{ name = $statusTool; arguments = @{} }
        } | ConvertTo-Json -Depth 10 -Compress
        $process.StandardInput.WriteLine($statusRequest)
        $process.StandardInput.Flush()
        $statusResponse = $process.StandardOutput.ReadLine() | ConvertFrom-Json
        if ($null -eq $statusResponse.result.content) {
            throw "$Mode status tool returned no MCP content."
        }

        return [pscustomobject]@{
            Mode = $Mode
            Initialize = 'PASS'
            ToolList = 'PASS'
            ToolCount = $toolCount
            StatusCall = 'PASS'
            ChangedOfficeFiles = $false
        }
    }
    finally {
        try { $process.StandardInput.Close() } catch {}
        if (-not $process.HasExited) {
            $process.Kill()
        }
        $process.Dispose()
    }
}

$results = @(
    Invoke-McpSmokeTest -Mode Word
    Invoke-McpSmokeTest -Mode Excel
)
$results | Format-Table -AutoSize
