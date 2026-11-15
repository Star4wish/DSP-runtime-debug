<#
    verify-mcp-live.ps1 -- proves the MCP SERVER ITSELF reaches the RUNNING game.

    Why this file exists: the package's other MCP suites run in STUB / OFFLINE mode on
    purpose (so they work without a game), and verify-live.ps1 talks HTTP to the bridge
    directly. Neither covers the one link that only exists in real use:

        MCP client -> tools\run-dsp-mcp.cmd -> DspMcpBridge.dll -> HTTP -> DspBridge.dll (in game)

    That link matters because run-dsp-mcp.cmd redirects LOCALAPPDATA into tools\ (portable
    toolchain), while the game writes %LOCALAPPDATA%\DSPBridge\runtime.json to the REAL user
    profile. The MCP server has to find it through its own candidate list; a stub test cannot
    catch it if that list breaks. This script runs the real launcher, with the redirected
    environment inherited, and asserts it still finds the live game.

    What it checks:
      1. runtime.json exists (real profile first) and its pid is alive.
      2. The MCP server handshakes over stdio (initialize) and lists its tools.
      3. dsp_health returns the SAME pid as runtime.json -- i.e. it really reached this game.
      4. dsp_tail_log returns live BepInEx log lines (MCP -> bridge -> game log).
      5. The shared token never appears in what the model would see.
      6. stdout carries JSON-RPC only (no log pollution).

    ASCII only: Windows PowerShell 5.1 parses a BOM-less .ps1 as ANSI (package pitfall 5).
    The launch/read mechanism is copied from verify-mcp.ps1 (ProcessStartInfo + synchronous
    line reads), NOT Start-Process with file redirects: that variant produced an empty stdout
    file here even though the server answered correctly.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-mcp-live.ps1
#>

param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dspenv.ps1')

$repoRoot = Split-Path $PSScriptRoot -Parent
$script:Failed = 0

function Write-Result {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("  PASS  " + $What) -ForegroundColor Green; return }
    Write-Host ("  FAIL  " + $What + $(if ($Detail) { " -- " + $Detail } else { '' })) -ForegroundColor Red
    $script:Failed++
}

Write-Host "=== DspMcpBridge live checks (MCP server must reach the running game) ===" -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. find the game
$candidates = @()
if ($env:DSP_BRIDGE_RUNTIME) { $candidates += $env:DSP_BRIDGE_RUNTIME }
$candidates += (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'DSPBridge\runtime.json')
if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE 'AppData\Local\DSPBridge\runtime.json') }
$candidates += (Join-Path $DspWs 'localappdata\DSPBridge\runtime.json')
$candidates = @($candidates | Where-Object { $_ } | Select-Object -Unique)

$runtimeFile = $null
foreach ($c in $candidates) {
    if (Test-Path $c) { $runtimeFile = $c; break }
}
if ($null -eq $runtimeFile) {
    Write-Host "  runtime.json not found. Start the game first: tools\dev-loop.ps1 -Mode up" -ForegroundColor Yellow
    $candidates | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor Yellow }
    exit 1
}

$rt = Get-Content $runtimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
$gamePid = [int]$rt.pid
$token = [string]$rt.token
Write-Host ("  runtime.json: " + $runtimeFile + "  (port " + $rt.port + ", pid " + $gamePid + ")")
Write-Result "the game process named in runtime.json is alive" ([bool](Get-Process -Id $gamePid -ErrorAction SilentlyContinue))

$launcher = Join-Path $PSScriptRoot 'run-dsp-mcp.cmd'
Write-Result "the MCP launcher exists" (Test-Path $launcher) $launcher

# ---------------------------------------------------------------- 2. drive the server over stdio
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $env:ComSpec
# Exactly what an MCP client does: cmd.exe is the command, the .cmd file is its argument.
$psi.Arguments = '/c ""' + $launcher + '""'
$psi.WorkingDirectory = $repoRoot
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false

$proc = [System.Diagnostics.Process]::Start($psi)
$stderr = [System.Text.StringBuilder]::new()
$errHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($s, $e) if ($null -ne $e.Data) { [void]$stderr.AppendLine($e.Data) }
}
$proc.add_ErrorDataReceived($errHandler)
$proc.BeginErrorReadLine()

$script:reqId = 0
$script:stdoutLines = 0
$script:nonJson = 0

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
        if ($null -eq $out) { throw ("stdout closed while waiting for " + $Method) }
        if ($out.Trim().Length -eq 0) { continue }
        $script:stdoutLines++
        $obj = $null
        try { $obj = $out | ConvertFrom-Json } catch { $script:nonJson++; continue }
        if ($obj.id -eq $myId) { return $obj }
    }
    throw ("timed out waiting for " + $Method)
}

function Get-Text {
    param($Message)
    if ($null -eq $Message -or $null -eq $Message.result -or $null -eq $Message.result.content) { return '' }
    return ((@($Message.result.content) | ForEach-Object { $_.text }) -join '')
}

$init = $null; $tools = $null; $health = $null; $tail = $null; $driverError = $null
try {
    $init = Send-Mcp -Method 'initialize' -Params ([ordered]@{
        protocolVersion = '2025-11-25'; capabilities = @{}
        clientInfo = @{ name = 'verify-mcp-live'; version = '1.0' }
    })
    Send-Mcp -Method 'notifications/initialized' -Params ([ordered]@{}) -Notification
    $tools  = Send-Mcp -Method 'tools/list'   -Params ([ordered]@{})
    $health = Send-Mcp -Method 'tools/call'   -Params ([ordered]@{ name = 'dsp_health'; arguments = @{} })
    $tail   = Send-Mcp -Method 'tools/call'   -Params ([ordered]@{ name = 'dsp_tail_log'; arguments = @{ lines = 20 } })
}
catch { $driverError = $_.Exception.Message }

try { $proc.StandardInput.Close() } catch { }
$exited = $proc.WaitForExit(15000)
if (-not $exited) { try { $proc.Kill() } catch { } }

Write-Result "the MCP server shut down after stdin closed" ([bool]$exited) ("driver error: " + $driverError)
Write-Result "the stdio conversation completed" ($null -eq $driverError) $driverError
Write-Result "stdout carried JSON-RPC only" ($script:nonJson -eq 0) ($script:nonJson.ToString() + " non-JSON line(s) of " + $script:stdoutLines)

$toolNames = @()
if ($null -ne $tools -and $null -ne $tools.result -and $null -ne $tools.result.tools) {
    $toolNames = @($tools.result.tools | ForEach-Object { $_.name })
}
Write-Result "initialize returned a result" ($null -ne $init -and $null -ne $init.result)
Write-Result "tools/list exposes dsp_health" ($toolNames -contains 'dsp_health') ("tools: " + ($toolNames -join ', '))

# ---- dsp_health must report THIS game's pid: that is what proves the live link
$healthText = Get-Text $health
$healthIsError = ($null -ne $health -and $null -ne $health.result -and $health.result.isError -eq $true)
Write-Result "dsp_health is not a tool error" (-not $healthIsError) $healthText
Write-Result ("dsp_health reports pid " + $gamePid + " (proves MCP -> live game)") ($healthText -like ('*"pid":' + $gamePid + '*')) $healthText

# ---- the log tail must contain real BepInEx log content from THIS game.
# Do NOT assert on one plugin's name: the tail holds whatever was logged last, and once
# other mods (or their debug probes) are installed, [DspBridge] lines are no longer the
# newest ones. Assert on shape instead: log-level prefix + the op's own JSON fields.
$tailText = Get-Text $tail
$tailOk = ($tailText.Length -gt 0) -and ($tailText -match '\[(Info|Message|Debug|Warning|Error)') -and ($tailText -match '"path"')
Write-Result "dsp_tail_log returned live BepInEx log lines" $tailOk ("length " + $tailText.Length)

# ---- token hygiene across everything the model would see
$allText = $healthText + $tailText
Write-Result "the shared token never reaches the model" ($token.Length -gt 0 -and -not $allText.Contains($token))

Write-Host ""
Write-Host ("  info  server stderr lines: " + ($stderr.ToString() -split "`n").Count + " (expected: diagnostics go to stderr)") -ForegroundColor DarkGray
$discovery = @($stderr.ToString() -split "`n" | Where-Object { $_ -match 'runtime\.json|DSPBridge\\DSPBridge' })
if ($discovery.Count -gt 0) {
    Write-Host ("  info  server discovery: " + $discovery[-1].Trim()) -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=== summary ===" -ForegroundColor Cyan
if ($script:Failed -eq 0) {
    Write-Host "ALL LIVE MCP CHECKS PASSED" -ForegroundColor Green
    exit 0
}
Write-Host ("failed checks: " + $script:Failed) -ForegroundColor Red
exit 1
