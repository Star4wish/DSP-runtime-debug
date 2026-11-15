<#
    install-game-side.ps1 -- install everything that lives INSIDE the game folder.

    Run this on the target machine after tools\setup-machine.ps1 has located the game.

    Baseline (this project targets the Thunderstore/r2modman environment):

      winhttp.dll                 <- Doorstop 3.4.0 injector        (25088 bytes)
      doorstop_config.ini         <- Doorstop 3 format ([UnityDoorstop] + targetAssembly)
      changelog.txt               <- BepInEx changelog (harmless, keeps the root tidy)
      BepInEx\core\*              <- BepInEx 5.4.17 preloader and core libraries
      BepInEx\plugins\DspBridge\  <- the bridge plugin (built against BepInEx 5.4.17)

    Doorstop 4 + BepInEx 5.4.23.5 also boots the game, but the mods published for this game
    are built against BepInEx 5.4.17 and the player-facing mod manager ships Doorstop 3.4.0,
    so 3.4.0 + 5.4.17 is the supported baseline. Do not mix the generations: a Doorstop 4
    injector pointed at a 5.4.17 preloader (or the reverse) silently fails to boot BepInEx.

    This script also REMOVES a stale .doorstop_version from the game folder: it is a Doorstop 4
    marker and a left-over copy makes people believe a Doorstop 4 install is in place.

    Usage (elevated shell if the game is under Program Files):
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-game-side.ps1
        ... -GameDir "D:\SteamLibrary\steamapps\common\Dyson Sphere Program"
        ... -WhatIfOnly          # report what would change, copy nothing
#>

param(
    [string]$GameDir = '',
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dspenv.ps1')

$payload = Join-Path (Split-Path $PSScriptRoot -Parent) 'game-side-patch'
if (-not (Test-Path $payload)) { throw "payload folder not found: $payload" }

function Fail($msg) { Write-Host ("  FAIL  " + $msg) -ForegroundColor Red; exit 1 }
function Ok($msg)   { Write-Host ("  OK    " + $msg) }
function Warn($msg) { Write-Host ("  WARN  " + $msg) -ForegroundColor Yellow }

Write-Host "=== install game-side files ===" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($GameDir)) { $GameDir = Resolve-DspGameDir }
if ([string]::IsNullOrWhiteSpace($GameDir)) { Fail "game directory not found; pass -GameDir or set `$env:DSP_GAME_DIR" }
if (-not (Test-Path (Join-Path $GameDir 'DSPGAME.exe'))) { Fail "no DSPGAME.exe under $GameDir" }

Write-Host ("  game: " + $GameDir)
Write-Host ("  from: " + $payload)
Write-Host ""

if (Get-Process -Name 'DSPGAME' -ErrorAction SilentlyContinue) {
    Fail "DSPGAME.exe is running. Close the game first: a loaded DLL cannot be replaced."
}

# ---------------------------------------------------------------- backup
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $GameDir ("_backup_dsp_bridge_" + $stamp)

if (-not $WhatIfOnly) {
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    $backedUp = 0
    foreach ($rel in @('winhttp.dll', 'doorstop_config.ini', '.doorstop_version', 'changelog.txt')) {
        $src = Join-Path $GameDir $rel
        if (Test-Path $src) { Copy-Item $src (Join-Path $backup $rel) -Force; $backedUp++ }
    }
    $existingCore = Join-Path $GameDir 'BepInEx\core'
    if (Test-Path $existingCore) {
        Copy-Item $existingCore (Join-Path $backup 'core') -Recurse -Force
        $backedUp++
    }
    $existingPlugin = Join-Path $GameDir 'BepInEx\plugins\DspBridge'
    if (Test-Path $existingPlugin) {
        $dest = Join-Path $backup 'plugins\DspBridge'
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item (Join-Path $existingPlugin '*') $dest -Recurse -Force
        $backedUp++
    }
    Ok ("backup: " + $backup + "  (" + $backedUp + " item(s))")
}

# ---------------------------------------------------------------- copy root files
$rootFiles = @('winhttp.dll', 'doorstop_config.ini', 'changelog.txt')
foreach ($f in $rootFiles) {
    $src = Join-Path $payload $f
    if (-not (Test-Path $src)) { Warn ("payload missing " + $f + " (skipped)"); continue }
    $dst = Join-Path $GameDir $f
    if ($WhatIfOnly) { Ok ("would copy " + $f) ; continue }
    Copy-Item $src $dst -Force
    Ok ("copied " + $f)
}

# ---------------------------------------------------------------- stale Doorstop 4 marker
$staleVersion = Join-Path $GameDir '.doorstop_version'
if (Test-Path $staleVersion) {
    if ($WhatIfOnly) { Ok "would DELETE stale .doorstop_version (Doorstop 4 marker)" }
    else { Remove-Item $staleVersion -Force; Ok "removed stale .doorstop_version (Doorstop 4 marker)" }
}

# ---------------------------------------------------------------- copy BepInEx tree
$srcCore = Join-Path $payload 'BepInEx\core'
$dstCore = Join-Path $GameDir 'BepInEx\core'
if (Test-Path $srcCore) {
    if ($WhatIfOnly) { Ok "would copy BepInEx\core (preloader + core libraries)" }
    else {
        New-Item -ItemType Directory -Force -Path $dstCore | Out-Null
        Copy-Item (Join-Path $srcCore '*') $dstCore -Recurse -Force
        Ok ("copied BepInEx\core  (" + (Get-ChildItem $dstCore -File).Count + " files)")
    }
}
else { Warn "payload missing BepInEx\core (skipped)" }

# ---------------------------------------------------------------- plugin
$srcPlugin = Join-Path $payload 'BepInEx\plugins\DspBridge'
$dstPlugin = Join-Path $GameDir 'BepInEx\plugins\DspBridge'
if (Test-Path $srcPlugin) {
    if ($WhatIfOnly) { Ok "would copy BepInEx\plugins\DspBridge\DspBridge.dll" }
    else {
        New-Item -ItemType Directory -Force -Path $dstPlugin | Out-Null
        Copy-Item (Join-Path $srcPlugin '*') $dstPlugin -Recurse -Force
        $files = @(Get-ChildItem $dstPlugin -File)
        Ok ("copied plugin: " + (($files | ForEach-Object { $_.Name }) -join ', '))
        if ($files.Count -ne 1 -or $files[0].Name -ne 'DspBridge.dll') {
            Warn "the plugin folder holds files other than DspBridge.dll; BepInEx loads dlls at ANY depth, so third-party dependencies there collide with other mods"
        }
    }
}
else { Warn "payload missing the plugin (skipped)" }

# ---------------------------------------------------------------- verify
Write-Host ""
Write-Host "=== verification ===" -ForegroundColor Cyan
$checks = @(
    @{ Path = 'winhttp.dll';                         Note = 'Doorstop 3.4.0 injector' },
    @{ Path = 'doorstop_config.ini';                 Note = 'Doorstop 3 config' },
    @{ Path = 'BepInEx\core\BepInEx.Preloader.dll';  Note = 'Doorstop target' },
    @{ Path = 'BepInEx\core\BepInEx.dll';            Note = 'BepInEx core' },
    @{ Path = 'BepInEx\core\0Harmony.dll';           Note = 'HarmonyX' },
    @{ Path = 'BepInEx\plugins\DspBridge\DspBridge.dll'; Note = 'bridge plugin' }
)
foreach ($c in $checks) {
    $full = Join-Path $GameDir $c.Path
    if (Test-Path $full) { Ok ($c.Path + "   (" + $c.Note + ")") }
    else { Warn ($c.Path + "   MISSING (" + $c.Note + ")") }
}

$inipath = Join-Path $GameDir 'doorstop_config.ini'
if (Test-Path $inipath) {
    $ini = Get-Content $inipath -Raw
    if ($ini -match '\[UnityDoorstop\]') { Ok "doorstop_config.ini uses the Doorstop 3 section ([UnityDoorstop])" }
    else { Warn "doorstop_config.ini is missing the [UnityDoorstop] section: this is not the Doorstop 3 config" }
    if ($ini -match 'targetAssembly\s*=\s*BepInEx\\core\\BepInEx\.Preloader\.dll') { Ok "targetAssembly points at the preloader" }
    else { Warn "targetAssembly does not point at BepInEx\core\BepInEx.Preloader.dll" }
    if ($ini -match 'redirectOutputLog\s*=\s*true') {
        Warn "redirectOutputLog = true: Doorstop will also write output_log.txt. Harmless, but LogOutput.log is the one to read."
    }
}

$coreDll = Join-Path $GameDir 'BepInEx\core\BepInEx.dll'
if (Test-Path $coreDll) {
    $ver = (Get-Item $coreDll).VersionInfo.FileVersion
    if ($ver -like '5.4.17*') { Ok ("BepInEx core version " + $ver) }
    else { Warn ("BepInEx core version is " + $ver + ", expected 5.4.17.x") }
}

if (Test-Path (Join-Path $GameDir '.doorstop_version')) {
    Warn ".doorstop_version still present: a Doorstop 4 marker does not belong to a Doorstop 3 install"
}

Write-Host ""
if ($WhatIfOnly) {
    Write-Host "DRY RUN COMPLETE (nothing was copied)" -ForegroundColor Green
    exit 0
}

Write-Host "GAME-SIDE INSTALL COMPLETE" -ForegroundColor Green
Write-Host ""
Write-Host "Next: start the game and check for [DspBridge] in:" -ForegroundColor Yellow
Write-Host ("  " + (Join-Path $GameDir 'BepInEx\LogOutput.log')) -ForegroundColor Yellow
exit 0
