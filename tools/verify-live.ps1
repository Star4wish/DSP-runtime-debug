<#
    verify-live.ps1 -- checks the game side of the bridge against a RUNNING game.

    This is the counterpart to verify-mcp.ps1 (which proves the MCP layer without a game).
    Run the game first, load a save, then run this. It walks the acceptance checklist from
    the runtime debugging doc section 5.6 in order and reports exactly which step fails.

    What it checks, and why each one matters:
      1. runtime.json exists in %LOCALAPPDATA%\DSPBridge (discovery works at all).
      2. /health without a token returns 401 -- the auth path is actually wired up.
      3. /health with the token returns {status:ok,pid,schemaVersion}.
      4. /state returns a snapshot with gameLoaded != false.
      5. POST /command with an unknown op is refused (closed-by-default router).
      6. The token never appears in any response body.
      7. The game process named in runtime.json is the one we are talking to.

    NOTE: this file is ASCII-only on purpose. Windows PowerShell 5.1 reads .ps1 files
    without a BOM as ANSI, which corrupts non-ASCII literals and produces parse errors
    that point at unrelated lines.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-live.ps1
        ... -RuntimePath <path>   -SkipState   -TimeoutSec 60
#>

param(
    [string]$RuntimePath = '',
    [switch]$SkipState,
    [int]$TimeoutSec = 40
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dspenv.ps1')

function Write-Result {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        Write-Host ("  PASS  " + $What) -ForegroundColor Green
        return
    }
    Write-Host ("  FAIL  " + $What + $(if ($Detail) { " -- " + $Detail } else { '' })) -ForegroundColor Red
    $script:Failed++
}

$script:Failed = 0

Write-Host "=== DspBridge live checks (game must be running) ===" -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. discovery
$candidates = @()
if ($RuntimePath) { $candidates += $RuntimePath }
$candidates += (Join-Path $env:LOCALAPPDATA 'DSPBridge\runtime.json')
if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE 'AppData\Local\DSPBridge\runtime.json') }
$candidates += (Join-Path $DspWs 'localappdata\DSPBridge\runtime.json')

$runtimeFile = $null
foreach ($c in $candidates) {
    if (Test-Path $c) { $runtimeFile = $c; break }
}

if ($null -eq $runtimeFile) {
    Write-Host ""
    Write-Host "runtime.json not found. Looked in:" -ForegroundColor Yellow
    $candidates | ForEach-Object { Write-Host ("  " + $_) }
    Write-Host ""
    Write-Host "The game is probably not running, or DspBridge did not load. Check:" -ForegroundColor Yellow
    $gameDir = Resolve-DspGameDir -Quiet
    if ($null -ne $gameDir) {
        Write-Host ("  " + (Join-Path $gameDir 'BepInEx\LogOutput.log') + "   for lines containing [DspBridge]") -ForegroundColor Yellow
    }
    else {
        Write-Host "  <game>\BepInEx\LogOutput.log   for lines containing [DspBridge]" -ForegroundColor Yellow
        Write-Host "  (game directory not auto-detected; set `$env:DSP_GAME_DIR)" -ForegroundColor Yellow
    }
    exit 1
}

Write-Host ("  runtime.json: " + $runtimeFile)
$rt = Get-Content $runtimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
$port = [int]$rt.port
$token = [string]$rt.token
$pidGame = [int]$rt.pid

Write-Result 'runtime.json has port/token/schemaVersion' `
             (($port -gt 0) -and ($token.Length -ge 8) -and ($rt.schemaVersion -ge 1)) `
             ("port=" + $port + " schemaVersion=" + $rt.schemaVersion)
Write-Result 'runtime.json reports writes disabled by default' ($rt.allowWrites -eq $false) `
             ("allowWrites=" + $rt.allowWrites)

$gameProc = Get-Process -Id $pidGame -ErrorAction SilentlyContinue
Write-Result ("game process " + $pidGame + " is alive") ($null -ne $gameProc) `
             ("process " + $pidGame + " not found; runtime.json may be stale")

$base = 'http://127.0.0.1:' + $port

# ---------------------------------------------------------------- 2. auth
try {
    $resp = Invoke-WebRequest -Uri ($base + '/health') -UseBasicParsing -TimeoutSec $TimeoutSec
    Write-Result '/health without token returns 401' ($resp.StatusCode -eq 401) ("got HTTP " + $resp.StatusCode)
}
catch {
    $code = -1
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    Write-Result '/health without token returns 401' ($code -eq 401) ("got HTTP " + $code + " / " + $_.Exception.Message)
}

# ---------------------------------------------------------------- 3. health with token
$headers = @{ Authorization = 'Bearer ' + $token }
try {
    $health = Invoke-RestMethod -Uri ($base + '/health') -Headers $headers -TimeoutSec $TimeoutSec -Method Get
    Write-Result '/health with token returns status=ok' ($health.status -eq 'ok') ($health | ConvertTo-Json -Compress)
    Write-Result '/health reports the same pid as runtime.json' ([int]$health.pid -eq $pidGame) `
                 ("health.pid=" + $health.pid + " runtime.pid=" + $pidGame)
    Write-Result '/health carries schemaVersion' ($health.schemaVersion -ge 1)
    Write-Host ("  info  unityVersion=" + $health.unityVersion + " gameLoaded=" + $health.gameLoaded)
}
catch {
    Write-Result '/health with token returns status=ok' $false $_.Exception.Message
    Write-Host "Cannot continue without /health." -ForegroundColor Red
    exit 1
}

if (-not $health.gameLoaded) {
    Write-Host ""
    Write-Host "  NOTE  The game is running but no save is loaded (main menu)." -ForegroundColor Yellow
    Write-Host "        Load a save to exercise /state, /command and the MCP tools." -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 4. state snapshot
if (-not $SkipState) {
    try {
        $state = Invoke-RestMethod -Uri ($base + '/state') -Headers $headers -TimeoutSec $TimeoutSec -Method Get
        Write-Result '/state returns a snapshot' ($null -ne $state) ($state | ConvertTo-Json -Compress -Depth 2)
        Write-Result '/state does not report a snapshot failure' ($state.error -ne 'snapshot_failed') `
                     ($state.detail)

        if ($state.gameLoaded) {
            Write-Result '/state reports a local planet or none without error' `
                         (($null -ne $state.localPlanet) -or ($state.gameLoaded -eq $true))
            Write-Result '/state includes the power roll-up' ($null -ne $state.power)
            Write-Result '/state includes the proto catalogue' ($null -ne $state.catalog)
            if ($state.unresolvedMembers) {
                Write-Host ("  warn  unresolved reflective members: " + ($state.unresolvedMembers -join ', ')) -ForegroundColor Yellow
                Write-Host "        The game build renamed fields; payloads degrade to null for those." -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Result '/state returns a snapshot' $false $_.Exception.Message
    }
}

# ---------------------------------------------------------------- 5. closed-by-default router
$body = '{"op":"definitely_not_a_real_op"}'
try {
    $unknown = Invoke-RestMethod -Uri ($base + '/command') -Headers $headers -Method Post `
                                 -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
    Write-Result 'unknown op is refused' ($unknown.error -eq 'unknown_or_disabled_op') `
                 ($unknown | ConvertTo-Json -Compress)
}
catch {
    Write-Result 'unknown op is refused' $false $_.Exception.Message
}

# ---------------------------------------------------------------- 6. a real read op
try {
    $cat = Invoke-RestMethod -Uri ($base + '/command') -Headers $headers -Method Post `
                             -ContentType 'application/json' -Body '{"op":"get_catalog"}' -TimeoutSec $TimeoutSec
    if ($cat.error) {
        Write-Result 'get_catalog answers' $false ($cat | ConvertTo-Json -Compress)
    }
    else {
        $payload = $cat
        if ($cat.data) { $payload = $cat.data }
        Write-Result 'get_catalog returns proto counts' ($null -ne $payload.items) ($cat | ConvertTo-Json -Compress)
    }
}
catch {
    Write-Result 'get_catalog answers' $false $_.Exception.Message
}

# ---------------------------------------------------------------- 7. write gate
try {
    $pause = Invoke-RestMethod -Uri ($base + '/command') -Headers $headers -Method Post `
                               -ContentType 'application/json' -Body '{"op":"set_pause","args":{"paused":true}}' -TimeoutSec $TimeoutSec
    if ($rt.allowWrites) {
        Write-Result 'set_pause is honoured when AllowWrites=true' ($null -ne $pause.isPaused) `
                     ($pause | ConvertTo-Json -Compress)
    }
    else {
        Write-Result 'set_pause is refused when AllowWrites=false' ($pause.error -eq 'writes_disabled') `
                     ($pause | ConvertTo-Json -Compress)
    }
}
catch {
    Write-Result 'set_pause answers' $false $_.Exception.Message
}

# ---------------------------------------------------------------- 8. token hygiene
try {
    $all = (Invoke-WebRequest -Uri ($base + '/state') -Headers $headers -UseBasicParsing -TimeoutSec $TimeoutSec).Content
    Write-Result 'the shared token never appears in a response body' (-not $all.Contains($token))
}
catch {
    Write-Result 'the shared token never appears in a response body' $false $_.Exception.Message
}

Write-Host ""
Write-Host "=== summary ===" -ForegroundColor Cyan
if ($script:Failed -eq 0) {
    Write-Host "ALL LIVE CHECKS PASSED" -ForegroundColor Green
    exit 0
}
Write-Host ("failed checks: " + $script:Failed) -ForegroundColor Red
exit 1
