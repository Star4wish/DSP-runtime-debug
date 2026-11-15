<#
    smoke-test-package.ps1 -- prove that the portable ZIP works on a "clean" machine.

    Extracts the ZIP into a throwaway directory whose path is DIFFERENT from the original
    workspace, then runs the same first-run sequence the README tells a human to run:

        setup-machine.ps1   (path fixups + build)
        test-all.ps1        (offline suites)

    This is what catches packaging mistakes: a forgotten file, a hard-coded absolute path,
    a NuGet package missing from the cache, or a script that only worked because the original
    workspace happened to exist.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\smoke-test-package.ps1
        ... -Zip <path> -WorkDir <dir> -Keep
#>

param(
    [string]$Zip = '',
    [string]$WorkDir = '',
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

function Say($m) { Write-Host ("  " + $m) }
function Head($m) { Write-Host ""; Write-Host ("=== " + $m + " ===") -ForegroundColor Cyan }

$repoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($Zip)) {
    $candidate = Get-ChildItem (Join-Path $repoRoot 'dist') -Filter 'DSP-MPD-runtime-debug-*.zip' -File |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $candidate) { throw "no package found in dist\; run tools\pack-portable.ps1 first" }
    $Zip = $candidate.FullName
}
if (-not (Test-Path $Zip)) { throw "zip not found: $Zip" }

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = Join-Path $env:TEMP ('dsp-pkg-smoke-' + (Get-Date -Format 'HHmmss'))
}

Head 'extracting'
Say ("zip     : " + $Zip + "   (" + [math]::Round((Get-Item $Zip).Length / 1MB, 1) + " MB)")
Say ("workdir : " + $WorkDir)

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
# ExtractToDirectory has no overwrite overload in this framework; the dir is empty anyway.
[System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $WorkDir)

$roots = @(Get-ChildItem $WorkDir -Directory)
Say ("extracted top-level folders: " + (($roots | ForEach-Object { $_.Name }) -join ', '))
if ($roots.Count -ne 1) { throw "expected exactly one top-level folder inside the zip, found $($roots.Count)" }

$extracted = $roots[0].FullName
Say ("package root: " + $extracted)

if ($extracted.TrimEnd('\') -eq $repoRoot.TrimEnd('\')) {
    throw "refusing to smoke-test: the extracted path equals the original workspace, which would prove nothing"
}

$script:Failures = @()

function Step($name, [scriptblock]$body) {
    Head $name
    & $body
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        Say ("exit code " + $LASTEXITCODE + " (informational; the marker below is what decides)")
    }
    $global:LASTEXITCODE = 0
}

function Check($what, [bool]$ok, $detail = '') {
    if ($ok) { Write-Host ("  PASS  " + $what) -ForegroundColor Green; return }
    Write-Host ("  FAIL  " + $what + $(if ($detail) { " -- " + $detail } else { '' })) -ForegroundColor Red
    $script:Failures += $what
}

# ---------------------------------------------------------------- structural checks
Head 'structural checks (no build required)'

$required = @(
    'README.md',
    'DspBridge\DspBridge.csproj',
    'DspBridge\BridgePlugin.cs',
    'DspMcpBridge\DspMcpBridge.csproj',
    'DspMcpBridge\bin\Release\net10.0\DspMcpBridge.dll',
    'game-side-patch\winhttp.dll',
    'game-side-patch\doorstop_config.ini',
    'game-side-patch\.doorstop_version',
    'game-side-patch\BepInEx\core\BepInEx.Preloader.dll',
    'game-side-patch\BepInEx\plugins\DspBridge\DspBridge.dll',
    'tools\dspenv.ps1',
    'tools\setup-machine.ps1',
    'tools\install-game-side.ps1',
    'tools\build-and-deploy.ps1',
    'tools\test-all.ps1',
    'tools\verify-live.ps1',
    'tools\verify-mcp.ps1',
    'tools\verify-mcp-malformed.ps1',
    'tools\run-dsp-mcp.cmd',
    'tools\refs\Assembly-CSharp.dll',
    'tools\bepinex-lib\BepInEx.dll',
    'tools\dotnet-sdk\dotnet.exe',
    'tools\nuget-packages\modelcontextprotocol\2.2.0',
    'tools\nuget-packages\microsoft.netframework.referenceassemblies.net472'
)
foreach ($rel in $required) {
    $full = Join-Path $extracted $rel
    Check ("present: " + $rel) (Test-Path $full)
}

# The Chinese-named design documents must have survived the trip. Matched by wildcard so
# this script itself stays ASCII-only (PowerShell 5.1 reads BOM-less .ps1 as ANSI).
$mdCount = @(Get-ChildItem $extracted -Filter '*.md' -File).Count
Check 'markdown documents present (README plus the design docs)' ($mdCount -ge 3) ("found " + $mdCount)
$xlsxCount = @(Get-ChildItem $extracted -Filter '*.xlsx' -File).Count
Check 'reference spreadsheets present' ($xlsxCount -ge 1) ("found " + $xlsxCount)

# The plugin folder must contain nothing but the plugin.
$pluginDir = Join-Path $extracted 'game-side-patch\BepInEx\plugins\DspBridge'
if (Test-Path $pluginDir) {
    $files = @(Get-ChildItem $pluginDir -File)
    Check 'plugin folder holds exactly DspBridge.dll' (($files.Count -eq 1) -and ($files[0].Name -eq 'DspBridge.dll')) `
          (($files | ForEach-Object { $_.Name }) -join ', ')
}

# No script may still carry the original machine's absolute path.
$offenders = @()
$scriptFiles = Get-ChildItem (Join-Path $extracted 'tools') -File -Recurse |
               Where-Object { $_.Extension -in @('.ps1', '.cmd') }
foreach ($f in $scriptFiles) {
    if ((Get-Content $f.FullName -Raw) -match 'C:\\XCM\\DSP MPD') { $offenders += $f.Name }
}
Check 'no tools script hard-codes the old workspace path' ($offenders.Count -eq 0) ($offenders -join ', ')

# ---------------------------------------------------------------- first-run sequence
Step 'setup-machine.ps1 (as a human would run it)' {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extracted 'tools\setup-machine.ps1') -SkipTests
}
Check 'setup-machine.ps1 generated machine.config.ps1' (Test-Path (Join-Path $extracted 'tools\machine.config.ps1'))
Check 'setup-machine.ps1 generated MCP-REGISTRATION.txt' (Test-Path (Join-Path $extracted 'MCP-REGISTRATION.txt'))
Check 'setup-machine.ps1 rewrote .mcp.json' (Test-Path (Join-Path $extracted '.mcp.json'))

$mcpJson = Join-Path $extracted '.mcp.json'
if (Test-Path $mcpJson) {
    $text = Get-Content $mcpJson -Raw
    $expectedLauncher = (Join-Path $extracted 'tools\run-dsp-mcp.cmd').Replace('\', '\\')
    Check '.mcp.json points at the extracted launcher' ($text.Contains($expectedLauncher)) $text
    Check '.mcp.json no longer contains the original workspace path' (-not ($text -match 'C:\\\\XCM')) $text
}

Step 'test-all.ps1 (offline suites only)' {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extracted 'tools\test-all.ps1') 2>&1 | Out-String
    Write-Host $out
    $global:SmokeOut = $out
}
Check 'all offline suites passed in the extracted copy' ($global:SmokeOut -match 'ALL SUITES PASSED')

# ---------------------------------------------------------------- deploy dry run
Step 'install-game-side.ps1 -WhatIfOnly (no game needed)' {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extracted 'tools\install-game-side.ps1') -WhatIfOnly 2>&1 | Out-String
    Write-Host $out
    $global:DryOut = $out
}
$gameFound = Test-Path 'C:\Program Files (x86)\Steam\steamapps\common\Dyson Sphere Program\DSPGAME.exe'
if ($gameFound) {
    Check 'dry run located the game and listed the payload' ($global:DryOut -match 'DRY RUN COMPLETE')
}
else {
    Say 'game not installed on this machine: dry run is expected to report that'
}

# ---------------------------------------------------------------- result
Head 'result'
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED checks:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host ("  - " + $_) -ForegroundColor Red }
    Write-Host "PACKAGE SMOKE TEST FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "PACKAGE SMOKE TEST PASSED" -ForegroundColor Green
Write-Host ("  a fresh extraction at " + $extracted)
Write-Host "  can be set up, built and verified with no reference to the original workspace." -ForegroundColor Green

if (-not $Keep) {
    Write-Host ""
    Write-Host ("removing " + $WorkDir)
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host ("kept: " + $WorkDir) -ForegroundColor Yellow
}
exit 0
