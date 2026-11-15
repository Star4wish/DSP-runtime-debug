<#
    verify-mcp.ps1 -- end-to-end check of the MCP layer without launching the game.

    Drives DspMcpBridge over a real stdio JSON-RPC session (the same wire the LLM client
    uses) and asserts the properties that actually matter:

      1. stdout carries JSON-RPC only -- every line parses as JSON (doc 5.4.1 / 5.7 #6).
      2. tools/list exposes the read tools and the resource list exposes dsp:// URIs.
      3. tools/call returns content for a good op.
      4. a game-side business error is surfaced as a readable message, not as a protocol
         error (doc 5.6 step 6 -- the single most important degradation path).
      5. game text containing control characters is sanitized before reaching the model.
      6. L1 write tools are refused, with a reason, while the game side says AllowWrites = false.

    Two modes:
      default   : stub mode. A canned bridge payload (tools\stub-runtime.json) is served, so
                  every tool can be exercised without a game. Verifies the happy path.
      -Offline  : no bridge at all. Verifies the degradation path -- the case that decides
                  whether this environment is usable day to day, because the game will be
                  closed most of the time.

    NOTE: this file is deliberately ASCII-only. Windows PowerShell 5.1 reads .ps1 files
    without a BOM as ANSI (gb2312 on this machine), which corrupts non-ASCII literals and
    produces bewildering parse errors.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-mcp.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-mcp.ps1 -Offline
        ... -Stub tools\stub-runtime-raw.json     # malformed upstream payload variant
#>

param(
    [string]$ServerDll = '',
    [string]$Stub      = '',
    [switch]$Offline,               # simulate "no runtime.json": expect game_unavailable
    [switch]$UseCmdLauncher         # launch through tools\run-dsp-mcp.cmd, exactly as a client does
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dspenv.ps1')

# Portable paths: derived from this script's location, never hard-coded.
$repoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($ServerDll)) {
    $ServerDll = Join-Path $repoRoot 'DspMcpBridge\bin\Release\net10.0\DspMcpBridge.dll'
}
if ([string]::IsNullOrWhiteSpace($Stub)) {
    $Stub = Join-Path $PSScriptRoot 'stub-runtime.json'
}

if (-not $Offline -and -not (Test-Path $Stub)) { throw "stub file not found: $Stub" }

$launcher = Join-Path $PSScriptRoot 'run-dsp-mcp.cmd'

if (-not $UseCmdLauncher -and -not (Test-Path $ServerDll)) {
    throw "build the server first: $ServerDll not found"
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
if ($UseCmdLauncher) {
    if (-not (Test-Path $launcher)) { throw "launcher not found: $launcher" }
    # Exactly what an MCP client does: cmd.exe is the command, the .cmd is its argument.
    $psi.FileName  = $env:ComSpec
    $psi.Arguments = '/c ""' + $launcher + '""'
    $psi.WorkingDirectory = $repoRoot
}
else {
    $psi.FileName  = $DspDotnet
    # Windows PowerShell 5.1 has no ProcessStartInfo.ArgumentList, so quote the path by hand.
    $psi.Arguments = '"' + $ServerDll + '"'
    $psi.WorkingDirectory = Split-Path $ServerDll
}
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false

if ($Offline) {
    # Point discovery at things that cannot exist, so no candidate path can match.
    $psi.Environment['DSP_BRIDGE_RUNTIME'] = (Join-Path $DspWs 'tmp\does-not-exist-runtime.json')
    $psi.Environment['USERPROFILE']        = (Join-Path $DspWs 'tmp\nonexistent-profile')
    $psi.Environment['SystemDrive']        = 'Q:'
}
else {
    $psi.Environment['DSP_BRIDGE_STUB'] = $Stub
}

$proc = [System.Diagnostics.Process]::Start($psi)
$stderr = [System.Text.StringBuilder]::new()
$errHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($s, $e) if ($null -ne $e.Data) { [void]$stderr.AppendLine($e.Data) }
}
$proc.add_ErrorDataReceived($errHandler)
$proc.BeginErrorReadLine()

$script:reqId = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:StdoutLines = 0
$script:NonJsonLines = [System.Collections.Generic.List[string]]::new()

function Send-Mcp {
    param([string]$Method, $Params, [switch]$Notification)

    $msg = [ordered]@{ jsonrpc = '2.0' }
    if (-not $Notification) { $script:reqId++; $msg.id = $script:reqId }
    $msg.method = $Method
    if ($null -ne $Params) { $msg.params = $Params }

    $line = $msg | ConvertTo-Json -Depth 12 -Compress
    $proc.StandardInput.WriteLine($line)
    $proc.StandardInput.Flush()

    if ($Notification) { return $null }

    $myId = $script:reqId
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $out = $proc.StandardOutput.ReadLine()
        if ($null -eq $out) { throw "stdout closed while waiting for $Method" }
        if ($out.Trim().Length -eq 0) { continue }

        $script:StdoutLines++
        try { $obj = $out | ConvertFrom-Json } catch {
            $script:NonJsonLines.Add($out)
            continue
        }

        if (($obj.PSObject.Properties.Name -contains 'id') -and ($obj.id -eq $myId)) { return $obj }
    }
    throw "timeout waiting for $Method"
}

function Assert-That {
    param([string]$What, [bool]$Condition, [string]$Detail = '')

    if ($Condition) {
        Write-Host ("  PASS  " + $What) -ForegroundColor Green
        return
    }

    $suffix = ''
    if ($Detail) { $suffix = " -- " + $Detail }
    Write-Host ("  FAIL  " + $What + $suffix) -ForegroundColor Red
    $script:Failures.Add($What)
}

function Get-ToolText {
    param($Response)
    if ($null -eq $Response) { return '' }
    if ($null -eq $Response.result) { return '' }
    if ($null -eq $Response.result.content) { return '' }
    if ($Response.result.content.Count -eq 0) { return '' }
    return [string]$Response.result.content[0].text
}

$mode = 'STUB mode'
if ($Offline) { $mode = 'OFFLINE mode' }
Write-Host ("=== DspMcpBridge stdio verification (" + $mode + ") ===") -ForegroundColor Cyan

# ---------------------------------------------------------------- handshake
$init = Send-Mcp -Method 'initialize' -Params @{
    protocolVersion = '2025-06-18'
    capabilities    = @{}
    clientInfo      = @{ name = 'verify-mcp'; version = '1.0' }
}
Assert-That 'initialize returns a result' ($null -ne $init.result) ($init | ConvertTo-Json -Compress)
Assert-That 'server advertises tool capability' ($null -ne $init.result.capabilities.tools)
Send-Mcp -Method 'notifications/initialized' -Params @{} -Notification | Out-Null

# ---------------------------------------------------------------- tools/list
$tools = Send-Mcp -Method 'tools/list' -Params @{}
$names = @($tools.result.tools | ForEach-Object { $_.name })
Write-Host ("  tools: " + ($names -join ', '))
Assert-That 'tools/list returns tools' ($names.Count -gt 0)
$expectedTools = @('dsp_health', 'dsp_get_state', 'dsp_get_catalog', 'dsp_get_planet_power',
                   'dsp_list_planets', 'dsp_find_items', 'dsp_tail_log', 'dsp_get_audit', 'dsp_set_pause')
foreach ($expected in $expectedTools) {
    Assert-That ("tool present: " + $expected) ($names -contains $expected)
}
$pauseTool = $tools.result.tools | Where-Object { $_.name -eq 'dsp_set_pause' }
Assert-That 'dsp_set_pause is annotated readOnlyHint=false' ($pauseTool.annotations.readOnlyHint -eq $false)

# ---------------------------------------------------------------- resources/list
$res = Send-Mcp -Method 'resources/list' -Params @{}
$uris = @($res.result.resources | ForEach-Object { $_.uri })
Write-Host ("  resources: " + ($uris -join ', '))
Assert-That 'resources/list exposes dsp://health' ($uris -contains 'dsp://health')
Assert-That 'resources/list exposes dsp://state' ($uris -contains 'dsp://state')

# ---------------------------------------------------------------- happy path (stub only)
if (-not $Offline) {
    $health = Send-Mcp -Method 'tools/call' -Params @{ name = 'dsp_health'; arguments = @{} }
    Assert-That 'dsp_health is not an error' ($health.result.isError -ne $true)
    Assert-That 'dsp_health returns text content' ($health.result.content[0].type -eq 'text')

    $state = Send-Mcp -Method 'tools/call' -Params @{ name = 'dsp_get_state'; arguments = @{} }
    Assert-That 'dsp_get_state is not an error' ($state.result.isError -ne $true)

    $items = Send-Mcp -Method 'tools/call' -Params @{ name = 'dsp_find_items'; arguments = @{ fromId = 1100; limit = 5; nameContains = 'Ingot' } }
    Assert-That 'dsp_find_items is not an error' ($items.result.isError -ne $true)

    $logTail = Send-Mcp -Method 'tools/call' -Params @{ name = 'dsp_tail_log'; arguments = @{ lines = 10 } }
    Assert-That 'dsp_tail_log is not an error' ($logTail.result.isError -ne $true)

    $readHealth = Send-Mcp -Method 'resources/read' -Params @{ uri = 'dsp://health' }
    Assert-That 'resources/read dsp://health returns contents' ($null -ne $readHealth.result.contents)

    # ---- sanitization of untrusted game text ----
    $stateText = Get-ToolText $state
    $previewPath = Join-Path $DspWs 'tmp\dsp_state_probe.txt'
    $preview = $stateText
    if ($preview.Length -gt 600) { $preview = $preview.Substring(0, 600) }
    Set-Content -Path $previewPath -Value $preview -Encoding UTF8

    Assert-That 'snapshot reached the model' (($stateText -match 'Stub') -and ($stateText -match 'Planet')) $preview
    Assert-That 'control character 0x07 stripped' (-not $stateText.Contains([char]0x07))
    Assert-That 'control character 0x00 stripped' (-not $stateText.Contains([char]0x00))
    Assert-That 'injection bait survives only as inert data' ($stateText -match 'IGNORE ALL PREVIOUS INSTRUCTIONS')
    Assert-That 'payload carries the do-not-obey note' ($stateText -match 'schemaVersion')
}

# ---------------------------------------------------------------- write gate
$pause = Send-Mcp -Method 'tools/call' -Params @{ name = 'dsp_set_pause'; arguments = @{ paused = $true } }
Assert-That 'dsp_set_pause is refused as a tool error' ($pause.result.isError -eq $true)
Assert-That 'dsp_set_pause returns no protocol error' ($null -eq $pause.error)
$pauseText = Get-ToolText $pause
if ($Offline) {
    # With no bridge at all, discovery fails first, so the write is refused before the
    # game-side AllowWrites switch is even consulted. Either refusal is correct; what
    # matters is that it is readable and is not a protocol error.
    Assert-That 'OFFLINE: refusal is readable and specific' `
                (($pauseText -match 'writes_disabled') -or ($pauseText -match 'game_unavailable')) $pauseText
}
else {
    Assert-That 'STUB: refusal explains the AllowWrites switch' ($pauseText -match 'AllowWrites')
}

# ---------------------------------------------------------------- degradation (offline only)
if ($Offline) {
    foreach ($tool in @('dsp_health', 'dsp_get_state', 'dsp_get_catalog', 'dsp_find_items',
                        'dsp_tail_log', 'dsp_get_audit', 'dsp_list_planets')) {
        $r = Send-Mcp -Method 'tools/call' -Params @{ name = $tool; arguments = @{} }
        $text = Get-ToolText $r
        Assert-That ("OFFLINE: " + $tool + " is a tool error, not a protocol error") `
                    (($r.result.isError -eq $true) -and ($null -eq $r.error)) $text
        Assert-That ("OFFLINE: " + $tool + " message is actionable") `
                    ($text -match 'runtime\.json|game_unavailable') $text
    }

    $offRes = Send-Mcp -Method 'resources/read' -Params @{ uri = 'dsp://health' }
    Assert-That 'OFFLINE: resource read still returns a payload' ($null -ne $offRes.result.contents)
    Assert-That 'OFFLINE: resource payload explains the state' ([string]$offRes.result.contents[0].text -match 'game_unavailable')
}

# ---------------------------------------------------------------- protocol hygiene
$nonJson = [string]::Join(' || ', $script:NonJsonLines)
Assert-That 'stdout contained only JSON-RPC lines' ($script:NonJsonLines.Count -eq 0) $nonJson

Write-Host ""
Write-Host "=== summary ===" -ForegroundColor Cyan
Write-Host ("  stdout JSON-RPC lines : " + $script:StdoutLines)
Write-Host ("  non-JSON stdout lines : " + $script:NonJsonLines.Count)
Write-Host ("  failures              : " + $script:Failures.Count)

try { $proc.StandardInput.Close() } catch { }

# Let the server shut down on its own: closing stdin ends the stdio transport.
# Killing it mid-shutdown would leave a native exit code behind that PowerShell then
# reports for this script, which would make the "ALL CHECKS PASSED" result look like a
# failure to tools\test-all.ps1.
$exited = $proc.WaitForExit(10000)
if (-not $exited) { try { $proc.Kill($true) } catch { } }

if ($script:Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "FAILED checks:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host ("  - " + $_) -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
exit 0

# $host.SetShouldExit wins over any native exit code left behind by a child process; without
# it, a nonzero code from dotnet.exe can make this script report failure despite every check
# passing, which would break tools\test-all.ps1 as a gate.
$host.SetShouldExit(0)
exit 0
