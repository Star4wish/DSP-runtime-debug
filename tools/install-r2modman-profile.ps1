<#
    install-r2modman-profile.ps1 -- install the DspBridge plugin (and the IcarusII automation
    settings) into an r2modman profile, so a "Start modded" launch keeps the HTTP bridge.

    WHY THIS EXISTS
      r2modman deploys the profile into the game directory on every "Start modded" launch
      (linkProfileFiles). A DspBridge.dll that only lives in <game>\BepInEx\plugins is removed
      by that deploy, so the bridge silently disappears on the next modded launch. The profile
      is the source of truth for modded launches: put the plugin there.

    WHAT IT DOES
      1. verifies the profile's loader generation (Doorstop 3.4.0 / BepInEx 5.4.17) matches the
         payload the plugin was built against;
      2. copies game-side-patch\BepInEx\plugins\DspBridge\DspBridge.dll into
         <profile>\BepInEx\plugins\DspBridge\ (backup-first);
      3. ensures <profile>\BepInEx\config\icarus-ii.cfg has, for unattended debugging:
           [General] DebugToolConsole = true    (enables !tool / !tools direct tool calls)
           [Agent]   PermissionLevel  = takeover (auto-approves every write, no confirm popup)
      4. also mirrors the same plugin + settings into the game directory (unless -NoGameDirCopy),
         so launching DSPGAME.exe / Steam without r2modman keeps working too.

    The IcarusII changes are SAFETY-RELEVANT: takeover means the in-game AI and the !tool console
    never ask before writing. Only use this with test saves.

    ASCII only (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-r2modman-profile.ps1
        ... -WhatIfOnly
        ... -Profile OrbitalRing
        ... -NoGameDirCopy
#>

param(
    [string]$Profile = 'Default',
    [string]$ProfilesRoot = '',
    [string]$GameDir = '',
    [switch]$WhatIfOnly,
    [switch]$NoGameDirCopy
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$payloadPlugin = Join-Path $repo 'game-side-patch\BepInEx\plugins\DspBridge\DspBridge.dll'
$payloadLoader = Join-Path $repo 'game-side-patch\winhttp.dll'

function Fail($msg) { Write-Host ("  FAIL  " + $msg) -ForegroundColor Red; exit 1 }
function Ok($msg)   { Write-Host ("  OK    " + $msg) }
function Warn($msg) { Write-Host ("  WARN  " + $msg) -ForegroundColor Yellow }
function Info($msg) { Write-Host $msg }

if (-not (Test-Path $payloadPlugin)) { Fail ("payload plugin not found: " + $payloadPlugin + " (build it with tools\build-and-deploy.ps1)") }

# ---------------------------------------------------------------- locate profile / game dir
if ([string]::IsNullOrWhiteSpace($ProfilesRoot)) {
    $ProfilesRoot = Join-Path $env:APPDATA 'r2modmanPlus-local\DysonSphereProgram\profiles'
}
$profileDir = Join-Path $ProfilesRoot $Profile
if (-not (Test-Path $profileDir)) { Fail ("r2modman profile not found: " + $profileDir) }

if ([string]::IsNullOrWhiteSpace($GameDir)) {
    if ($env:DSP_GAME_DIR) { $GameDir = $env:DSP_GAME_DIR }
    else {
        foreach ($c in @(
            'C:\Games\Steam\steamapps\common\Dyson Sphere Program',
            'C:\Program Files (x86)\Steam\steamapps\common\Dyson Sphere Program',
            'C:\Program Files\Steam\steamapps\common\Dyson Sphere Program',
            'D:\Steam\steamapps\common\Dyson Sphere Program',
            'D:\SteamLibrary\steamapps\common\Dyson Sphere Program',
            'E:\SteamLibrary\steamapps\common\Dyson Sphere Program')) {
            if (Test-Path (Join-Path $c 'DSPGAME.exe')) { $GameDir = $c; break }
        }
    }
}
$haveGameDir = ($GameDir -and (Test-Path (Join-Path $GameDir 'DSPGAME.exe')))

Info "=== install DspBridge into an r2modman profile ==="
Info ("  profile : " + $profileDir)
Info ("  plugin  : " + $payloadPlugin + "  (" + (Get-Item $payloadPlugin).Length + " B)")
Info ("  game    : " + $(if ($haveGameDir) { $GameDir } else { '<not found; profile only>' }))
Info ""

if ($haveGameDir -and (Get-Process -Name 'DSPGAME' -ErrorAction SilentlyContinue)) {
    Fail "DSPGAME.exe is running. Close the game first: a mapped DLL cannot be replaced."
}

# ---------------------------------------------------------------- verify loader generation
$profileCore = Join-Path $profileDir 'BepInEx\core\BepInEx.dll'
if (Test-Path $profileCore) {
    $ver = (Get-Item $profileCore).VersionInfo.FileVersion
    if ($ver -like '5.4.17*') { Ok ("profile BepInEx core " + $ver) }
    else { Warn ("profile BepInEx core is " + $ver + "; the payload plugin is built against 5.4.17") }
}
$profileWinhttp = Join-Path $profileDir 'winhttp.dll'
if (Test-Path $profileWinhttp) {
    $len = (Get-Item $profileWinhttp).Length
    if ($len -eq 25088) { Ok "profile loader is Doorstop 3.4.0 (winhttp.dll 25088 B)" }
    else { Warn ("profile winhttp.dll is " + $len + " B, expected 25088 (Doorstop 3.4.0)") }
}

# ---------------------------------------------------------------- backup
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $profileDir ("_backup_dspbridge_" + $stamp)
$touched = @()

$targets = @(@{ Root = $profileDir; Name = 'profile' })
if ($haveGameDir -and -not $NoGameDirCopy) { $targets += @{ Root = $GameDir; Name = 'game' } }

if (-not $WhatIfOnly) {
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($t in $targets) {
        $existing = Join-Path $t.Root 'BepInEx\plugins\DspBridge'
        if (Test-Path $existing) {
            $dest = Join-Path $backup ($t.Name + '\plugins\DspBridge')
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-Item (Join-Path $existing '*') $dest -Recurse -Force
            $touched += ($t.Name + ':plugins\DspBridge')
        }
        $cfg = Join-Path $t.Root 'BepInEx\config\icarus-ii.cfg'
        if (Test-Path $cfg) {
            $dest2 = Join-Path $backup ($t.Name + '\config')
            New-Item -ItemType Directory -Force -Path $dest2 | Out-Null
            Copy-Item $cfg $dest2 -Force
            $touched += ($t.Name + ':config\icarus-ii.cfg')
        }
    }
    Ok ("backup: " + $backup + "  (" + $touched.Count + " item(s))")
}

# ---------------------------------------------------------------- copy plugin
foreach ($t in $targets) {
    $dstDir = Join-Path $t.Root 'BepInEx\plugins\DspBridge'
    if ($WhatIfOnly) { Ok ("would copy DspBridge.dll -> " + $t.Name); continue }
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    Copy-Item $payloadPlugin (Join-Path $dstDir 'DspBridge.dll') -Force
    $files = @(Get-ChildItem $dstDir -File)
    if ($files.Count -ne 1) { Warn ($t.Name + ": plugin folder has extra files (BepInEx loads dlls at any depth)") }
    Ok ("copied DspBridge.dll -> " + $t.Name + " (" + ($files[0].Length) + " B)")
}

# ---------------------------------------------------------------- IcarusII unattended settings
function Set-CfgKey {
    param([string]$Path, [string]$Section, [string]$Key, [string]$Value)
    $lines = @()
    if (Test-Path $Path) { $lines = @(Get-Content $Path -Encoding UTF8) }
    $out = New-Object System.Collections.Generic.List[string]
    $inSection = $false
    $sectionFound = $false
    $keyDone = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            if ($inSection -and -not $keyDone) { $out.Add($Key + ' = ' + $Value); $keyDone = $true }
            $inSection = ($matches[1].Trim() -eq $Section)
            if ($inSection) { $sectionFound = $true }
            $out.Add($line)
            continue
        }
        if ($inSection -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $out.Add($Key + ' = ' + $Value)
            $keyDone = $true
            continue
        }
        $out.Add($line)
    }
    if ($inSection -and -not $keyDone) { $out.Add($Key + ' = ' + $Value); $keyDone = $true }
    if (-not $sectionFound) {
        $out.Add('')
        $out.Add('[' + $Section + ']')
        $out.Add($Key + ' = ' + $Value)
    }
    $text = ($out -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

foreach ($t in $targets) {
    $cfgPath = Join-Path $t.Root 'BepInEx\config\icarus-ii.cfg'
    if ($WhatIfOnly) { Ok ("would set DebugToolConsole=true + PermissionLevel=takeover -> " + $t.Name); continue }
    New-Item -ItemType Directory -Force -Path (Split-Path $cfgPath -Parent) | Out-Null
    if (-not (Test-Path $cfgPath) -and $haveGameDir) {
        $template = Join-Path $GameDir 'BepInEx\config\icarus-ii.cfg'
        if (Test-Path $template) { Copy-Item $template $cfgPath -Force }
    }
    Set-CfgKey -Path $cfgPath -Section 'General' -Key 'DebugToolConsole' -Value 'true'
    Set-CfgKey -Path $cfgPath -Section 'Agent' -Key 'PermissionLevel' -Value 'takeover'
    Ok ("icarus-ii.cfg: DebugToolConsole=true, PermissionLevel=takeover -> " + $t.Name)
}

Write-Host ""
if ($WhatIfOnly) {
    Write-Host "DRY RUN COMPLETE (nothing was copied)" -ForegroundColor Green
    exit 0
}
Write-Host "PROFILE INSTALL COMPLETE" -ForegroundColor Green
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1. start the game (r2modman 'Start modded' or DSPGAME.exe directly)" -ForegroundColor Yellow
Write-Host "  2. check BepInEx\LogOutput.log for the [DspBridge] listener line on http://127.0.0.1:17890/" -ForegroundColor Yellow
Write-Host "  3. check for: [sidecar] READY   (IcarusII sidecar on 8765)" -ForegroundColor Yellow
exit 0
