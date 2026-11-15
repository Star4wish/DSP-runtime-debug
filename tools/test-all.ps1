<#
    test-all.ps1 -- run every automated check for the runtime debugging environment.

    The suites, in increasing order of "needs the game" (1-2 run offline, 3-4 need the game):

      1. tools\bridge-core-test   -- the bridge plugin's pure logic (JSON parser, closed
                                    op table, write gate, token redaction, reflective
                                    fallbacks). No game, no Unity. 60 checks.
      2. tools\verify-mcp.ps1     -- the whole MCP layer over real stdio JSON-RPC, in stub
                                    mode AND in offline (game absent) mode, plus the cmd
                                    launcher path an LLM client actually uses.
      3. tools\verify-live.ps1    -- the game side against a RUNNING game. Skipped
                                    automatically when the game is not up.
      4. tools\verify-mcp-live.ps1 -- the MCP server itself reaching that running game
                                     (MCP -> cmd launcher -> DspMcpBridge -> HTTP -> in-game bridge).
                                     Also skipped automatically when the game is not up.

    Pass/fail is decided by the "ALL ... PASSED" marker in each child's output rather than
    by its process exit code: this machine's PowerShell reports a stray nonzero code for
    some child processes even when the run is clean (see docs\RUNBOOK note), so trusting
    the exit code alone would produce false failures. Reproduced 2026-10-17: a script whose
    only statement is "exit 0" returns 0, but the same script plus a .NET child process with
    redirected stdio returns 2.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-all.ps1
        ... -RequireLive           # fail if the game is not running
#>

param(
    [switch]$RequireLive,
    [switch]$SkipCore,
    [switch]$SkipMcp,
    [switch]$SkipLive
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'dspenv.ps1')

$script:SuiteFailures = 0
$script:SuitePassed = 0
function Invoke-Suite {
    param([string]$Name, [string]$PassMarker, [scriptblock]$Body)

    Write-Host ""
    Write-Host ("########## " + $Name + " ##########") -ForegroundColor Cyan

    $global:LASTEXITCODE = 0
    $output = & $Body 2>&1 | Out-String
    $global:LASTEXITCODE = 0

    # Echo the child output so a failure can be diagnosed from this run alone.
    Write-Host $output

    $passed = $output -match [regex]::Escape($PassMarker)
    if ($passed) {
        Write-Host ("[ok] " + $Name) -ForegroundColor Green
        $script:SuitePassed++
        return
    }

    Write-Host ("[FAILED] " + $Name + " (expected output marker: " + $PassMarker + ")") -ForegroundColor Red
    $script:SuiteFailures++
}

if (-not $SkipCore) {
    Invoke-Suite 'bridge core logic (no game)' 'ALL CORE CHECKS PASSED' {
        & $DspDotnet run --project (Join-Path $PSScriptRoot 'bridge-core-test\BridgeCoreTest.csproj') -c Release -v quiet
    }
}

if (-not $SkipMcp) {
    Invoke-Suite 'MCP layer: stub mode (canned bridge payload)' 'ALL CHECKS PASSED' {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-mcp.ps1')
    }

    Invoke-Suite 'MCP layer: offline mode (game absent)' 'ALL CHECKS PASSED' {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-mcp.ps1') -Offline
    }

    Invoke-Suite 'MCP layer: launched exactly as an MCP client does' 'ALL CHECKS PASSED' {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-mcp.ps1') -UseCmdLauncher
    }

    Invoke-Suite 'MCP layer: malformed upstream payloads' 'ALL CHECKS PASSED' {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-mcp-malformed.ps1')
    }
}

# ---------------------------------------------------------------- live suite
# The game writes runtime.json under the REAL user profile, but dspenv.ps1 has already
# redirected $env:LOCALAPPDATA into tools\ for the portable toolchain. Ask Windows for the
# real profile folder (the same way verify-live.ps1 and DspClient.cs do) instead of trusting
# the environment variable, otherwise -RequireLive reports "game not running" while the game
# is running and answering on 127.0.0.1.
$runtimeCandidates = @()
if ($env:DSP_BRIDGE_RUNTIME) { $runtimeCandidates += $env:DSP_BRIDGE_RUNTIME }
$runtimeCandidates += (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'DSPBridge\runtime.json')
if ($env:USERPROFILE) { $runtimeCandidates += (Join-Path $env:USERPROFILE 'AppData\Local\DSPBridge\runtime.json') }
$runtimeCandidates += (Join-Path $DspWs 'localappdata\DSPBridge\runtime.json')
$runtimeCandidates = @($runtimeCandidates | Where-Object { $_ } | Select-Object -Unique)

$runtimeFound = $false
foreach ($c in $runtimeCandidates) {
    if (Test-Path $c) { $runtimeFound = $true; break }
}

if ($SkipLive) {
    Write-Host ""
    Write-Host "[skipped] live bridge checks (-SkipLive)." -ForegroundColor Yellow
}
elseif ($runtimeFound) {
    Invoke-Suite 'game side: live bridge (running game)' 'ALL LIVE CHECKS PASSED' {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-live.ps1')
    }
    Invoke-Suite 'MCP layer: live game (MCP server -> running game)' 'ALL LIVE MCP CHECKS PASSED' {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-mcp-live.ps1')
    }
}
elseif ($RequireLive) {
    Write-Host ""
    Write-Host "[FAILED] -RequireLive was given but no runtime.json exists (game not running)." -ForegroundColor Red
    Write-Host "         looked in:" -ForegroundColor Red
    $runtimeCandidates | ForEach-Object { Write-Host ("           " + $_) -ForegroundColor Red }
    Write-Host "         start the game with tools\dev-loop.ps1 -Mode up, then re-run." -ForegroundColor Red
    $script:SuiteFailures++
}
else {
    Write-Host ""
    Write-Host "[skipped] live bridge checks: no runtime.json, so the game is not running." -ForegroundColor Yellow
    Write-Host "          Start the game, load a save, then re-run to cover the game side." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==================== summary ====================" -ForegroundColor Cyan
Write-Host ("  suites passed : " + $script:SuitePassed)
Write-Host ("  suites failed : " + $script:SuiteFailures)

if ($script:SuiteFailures -eq 0) {
    Write-Host "ALL SUITES PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "SOME SUITES FAILED" -ForegroundColor Red
exit 1
