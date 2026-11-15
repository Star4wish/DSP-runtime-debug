<#
    verify-mcp-malformed.ps1 -- checks that a broken/hijacked bridge port degrades safely.

    The gapped case this covers: runtime.json survives a game crash, the port is later
    recycled by an unrelated process, and the "bridge" starts answering with an HTML error
    page. Without validation the model would receive that page as game data. DspClient now
    parses the body and raises a readable game_unavailable error instead.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-mcp-malformed.ps1
#>

param(
    [string]$ServerDll = '',
    [string]$Stub      = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dspenv.ps1')

$repoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($ServerDll)) {
    $ServerDll = Join-Path $repoRoot 'DspMcpBridge\bin\Release\net10.0\DspMcpBridge.dll'
}
if ([string]::IsNullOrWhiteSpace($Stub)) {
    $Stub = Join-Path $PSScriptRoot 'stub-runtime-malformed.json'
}

if (-not (Test-Path $ServerDll)) { throw "build the server first: $ServerDll not found" }
if (-not (Test-Path $Stub)) { throw "stub not found: $Stub" }

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName               = $DspDotnet
$psi.Arguments              = '"' + $ServerDll + '"'
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.WorkingDirectory       = Split-Path $ServerDll
$psi.Environment['DSP_BRIDGE_STUB'] = $Stub

$proc = [System.Diagnostics.Process]::Start($psi)
$proc.BeginErrorReadLine()

$script:reqId = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Send-Mcp {
    param([string]$Method, $Params, [switch]$Notification)
    $msg = [ordered]@{ jsonrpc = '2.0' }
    if (-not $Notification) { $script:reqId++; $msg.id = $script:reqId }
    $msg.method = $Method
    if ($null -ne $Params) { $msg.params = $Params }
    $proc.StandardInput.WriteLine(($msg | ConvertTo-Json -Depth 12 -Compress))
    $proc.StandardInput.Flush()
    if ($Notification) { return $null }

    $myId = $script:reqId
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $out = $proc.StandardOutput.ReadLine()
        if ($null -eq $out) { throw "stdout closed awaiting $Method" }
        if ($out.Trim().Length -eq 0) { continue }
        try { $obj = $out | ConvertFrom-Json } catch { continue }
        if (($obj.PSObject.Properties.Name -contains 'id') -and ($obj.id -eq $myId)) { return $obj }
    }
    throw "timeout awaiting $Method"
}

function Assert-That {
    param([string]$What, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host ("  PASS  " + $What) -ForegroundColor Green; return }
    $suffix = ''
    if ($Detail) { $suffix = " -- " + $Detail }
    Write-Host ("  FAIL  " + $What + $suffix) -ForegroundColor Red
    $script:Failures.Add($What)
}

function Get-ToolText {
    param($Response)
    if (($null -eq $Response) -or ($null -eq $Response.result) -or ($null -eq $Response.result.content)) { return '' }
    if ($Response.result.content.Count -eq 0) { return '' }
    return [string]$Response.result.content[0].text
}

Write-Host "=== DspMcpBridge malformed-upstream checks ===" -ForegroundColor Cyan

Send-Mcp -Method 'initialize' -Params @{
    protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'verify-malformed'; version = '1.0' }
} | Out-Null
Send-Mcp -Method 'notifications/initialized' -Params @{} -Notification | Out-Null

# Healthy ops must keep working while one op is broken.
$health = Send-Mcp -Method 'tools/call' -Params @{ name = 'dsp_health'; arguments = @{} }
Assert-That 'healthy op still succeeds' ($health.result.isError -ne $true)

# The broken op must be reported as a readable tool error.
$cat = Send-Mcp -Method 'tools/call' -Params @{ name = 'dsp_get_catalog'; arguments = @{} }
Assert-That 'truncated payload is reported as a tool error' ($cat.result.isError -eq $true)
Assert-That 'no protocol-level error leaked out' ($null -eq $cat.error)
$catText = Get-ToolText $cat
Assert-That 'error is classified as game_unavailable' ($catText -match 'game_unavailable') $catText
Assert-That 'error mentions the JSON problem' (($catText -match 'JSON') -or ($catText -match 'runtime\.json')) $catText
Assert-That 'raw garbage is not handed to the model' (-not ($catText -match 'items\\":612')) $catText

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED checks:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host ("  - " + $_) -ForegroundColor Red }
    Write-Host "SOME CHECKS FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
exit 0
