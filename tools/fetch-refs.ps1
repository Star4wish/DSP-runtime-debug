<#
    fetch-refs.ps1 -- populate the local build references this repo deliberately does not ship.

    WHAT IT DOES
      Copies, from YOUR OWN installation:
        <game>\DSPGAME_Data\Managed\*.dll   ->  tools\refs\        (game/Unity assemblies)
        <bepinex>\core\*.dll                ->  tools\bepinex-lib\  (BepInEx runtime assemblies)

    WHY THIS SCRIPT EXISTS
      The repo excludes both folders on purpose: refs\ holds the game's own assemblies
      (Assembly-CSharp.dll and friends) and redistributing game code is not allowed;
      BepInEx is a third-party project, so users get it from its own distribution.
      Both are needed only to COMPILE, never at runtime -- the deployed plugin links
      against the BepInEx that ships with the game.

    USAGE
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\fetch-refs.ps1
        ... -GameDir "D:\SteamLibrary\steamapps\common\Dyson Sphere Program"
        ... -BepInExDir "<game>\BepInEx"       # or a r2modman profile's BepInEx folder
        ... -WhatIfOnly                        # report, copy nothing
        ... -Force                             # overwrite existing refs

    ASCII only: Windows PowerShell 5.1 parses a BOM-less .ps1 as ANSI.
#>

param(
    [string]$GameDir = '',
    [string]$BepInExDir = '',
    [string]$OutRoot = '',
    [switch]$Force,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host $m }
function Ok($m)   { Write-Host ("  OK    " + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ("  WARN  " + $m) -ForegroundColor Yellow }
function Fail($m) { Write-Host ("  FAIL  " + $m) -ForegroundColor Red; exit 1 }

if ([string]::IsNullOrWhiteSpace($OutRoot)) { $OutRoot = Split-Path $PSScriptRoot -Parent }
$refsOut = Join-Path $OutRoot 'tools\refs'
$libOut = Join-Path $OutRoot 'tools\bepinex-lib'

Write-Host "=== fetch build references ===" -ForegroundColor Cyan

# ---------------------------------------------------------------- locate the game
if ([string]::IsNullOrWhiteSpace($GameDir)) {
    if ($env:DSP_GAME_DIR) { $GameDir = $env:DSP_GAME_DIR }
    else {
        foreach ($c in @(
            'C:\Program Files (x86)\Steam\steamapps\common\Dyson Sphere Program',
            'C:\Program Files\Steam\steamapps\common\Dyson Sphere Program',
            'C:\Games\Steam\steamapps\common\Dyson Sphere Program',
            'D:\Steam\steamapps\common\Dyson Sphere Program',
            'D:\SteamLibrary\steamapps\common\Dyson Sphere Program',
            'E:\SteamLibrary\steamapps\common\Dyson Sphere Program')) {
            if (Test-Path (Join-Path $c 'DSPGAME.exe')) { $GameDir = $c; break }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($GameDir) -or -not (Test-Path (Join-Path $GameDir 'DSPGAME.exe'))) {
    Fail "game directory not found; pass -GameDir or set `$env:DSP_GAME_DIR"
}
Info ("  game : " + $GameDir)

$managed = Join-Path $GameDir 'DSPGAME_Data\Managed'
if (-not (Test-Path (Join-Path $managed 'Assembly-CSharp.dll'))) {
    Fail ("Assembly-CSharp.dll not found under " + $managed)
}

# ---------------------------------------------------------------- locate BepInEx core
if ([string]::IsNullOrWhiteSpace($BepInExDir)) {
    $candidates = @((Join-Path $GameDir 'BepInEx'))
    $profiles = Join-Path $env:APPDATA 'r2modmanPlus-local\DysonSphereProgram\profiles'
    if (Test-Path $profiles) {
        foreach ($p in Get-ChildItem $profiles -Directory -ErrorAction SilentlyContinue) {
            $candidates += (Join-Path $p.FullName 'BepInEx')
        }
    }
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'core\BepInEx.dll')) { $BepInExDir = $c; break }
    }
}
if ([string]::IsNullOrWhiteSpace($BepInExDir) -or -not (Test-Path (Join-Path $BepInExDir 'core\BepInEx.dll'))) {
    Fail "BepInEx core not found; install BepInEx 5.4.x or pass -BepInExDir <...\BepInEx>"
}
Info ("  bepinex: " + $BepInExDir)

$coreSrc = Join-Path $BepInExDir 'core'
$ver = (Get-Item (Join-Path $coreSrc 'BepInEx.dll')).VersionInfo.FileVersion
if ($ver -like '5.4.17*') { Ok ("BepInEx core " + $ver + " (matches the community/R2 baseline)") }
else { Warn ("BepInEx core is " + $ver + "; the community baseline is 5.4.17.x -- the plugin still builds, but verify in-game") }

# ---------------------------------------------------------------- copy
function Copy-Assemblies {
    param([string]$Src, [string]$Dst, [string]$Label)
    $files = @(Get-ChildItem $Src -Filter *.dll -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Warn ("no dlls in " + $Src); return }

    if ($WhatIfOnly) { Ok ("would copy " + $files.Count + " dll(s) -> " + $Label); return }

    if ((Test-Path $Dst) -and -not $Force) {
        $existing = @(Get-ChildItem $Dst -Filter *.dll -File -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            Warn ($Label + " already has " + $existing.Count + " dll(s); use -Force to refresh")
            return
        }
    }
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    foreach ($f in $files) { Copy-Item $f.FullName (Join-Path $Dst $f.Name) -Force }
    $total = (@(Get-ChildItem $Dst -Filter *.dll -File) | Measure-Object Length -Sum).Sum
    Ok ("copied " + $files.Count + " dll(s) -> " + $Label + "  (" + [math]::Round($total/1MB,1) + " MB)")
}

Copy-Assemblies -Src $managed -Dst $refsOut -Label 'tools\refs'
Copy-Assemblies -Src $coreSrc -Dst $libOut  -Label 'tools\bepinex-lib'

Write-Host ""
if ($WhatIfOnly) {
    Write-Host "DRY RUN COMPLETE (nothing was copied)" -ForegroundColor Green
    exit 0
}
Write-Host "REFERENCES READY" -ForegroundColor Green
Write-Host "Next: powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup-machine.ps1" -ForegroundColor Yellow
exit 0
