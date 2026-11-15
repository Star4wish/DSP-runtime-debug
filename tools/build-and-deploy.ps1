<#
    build-and-deploy.ps1 -- build a plugin project, then copy the dll into the game's
    BepInEx\plugins\<name> directory.

    Portable: all paths are derived from this script's location. The game directory is
    auto-detected (common Steam paths) or taken from $env:DSP_GAME_DIR.

    Usage (from an *elevated* shell when the game is under Program Files):
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-and-deploy.ps1
        ... -Project <path to csproj> -SkipBuild
        ... -DeployDir "D:\somewhere\BepInEx\plugins\DspBridge"

    Why a script instead of msbuild -p:DeployDir: MSBuild inherits the caller's token and
    cannot write under Program Files when run unelevated. This script detects that, builds
    first (always works, output goes to the repo), then reports clearly if the copy needs
    an elevated shell.
#>

param(
    [string]$Project = '',
    [string]$Configuration = 'Release',
    [string]$DeployDir = '',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dspenv.ps1')

if ([string]::IsNullOrWhiteSpace($Project)) {
    $Project = Join-Path (Split-Path $PSScriptRoot -Parent) 'DspBridge\DspBridge.csproj'
}

$pluginName = [System.IO.Path]::GetFileNameWithoutExtension($Project)

# The MCP server is a net10.0 console app that must NOT be copied into the game folder
# (BepInEx would try to load it). Only net472 in-game plugins get deployed.
$targetFramework = ''
try {
    [xml]$projectXml = Get-Content $Project -Raw
    $targetFramework = [string]$projectXml.Project.PropertyGroup.TargetFramework
}
catch { }

$isGamePlugin = ($targetFramework -like 'net4*')

if (-not $isGamePlugin -and [string]::IsNullOrWhiteSpace($DeployDir)) {
    Write-Host ("target framework is '" + $targetFramework + "': this is not an in-game plugin, " +
                "so nothing is copied into the game folder.") -ForegroundColor DarkGray
    $DeployDir = 'SKIP'
}

if ($DeployDir -ne 'SKIP' -and [string]::IsNullOrWhiteSpace($DeployDir)) {
    $gameDir = Resolve-DspGameDir
    if ($null -eq $gameDir) {
        throw "Cannot locate the game directory, so -DeployDir was not derived. " +
              'Set $env:DSP_GAME_DIR or pass -DeployDir explicitly.'
    }
    $DeployDir = Join-Path $gameDir "BepInEx\plugins\$pluginName"; $DeployDerived = $true
}

if (-not $SkipBuild) {
    Write-Host "=== building $Project ($Configuration) ===" -ForegroundColor Cyan
    & $DspDotnet build $Project -c $Configuration -v minimal
    if ($LASTEXITCODE -ne 0) { throw "build failed with exit code $LASTEXITCODE" }
}

# Artifact layout depends on the project: net472 plugins land in bin\<cfg>\<name>.dll, while
# SDK-style netX.Y projects also nest a target-framework folder (bin\<cfg>\net10.0\<name>.dll).
# Check the flat path first, then fall back to a recursive search under bin\<cfg>.
$binRoot = Join-Path (Split-Path $Project) "bin\$Configuration"
$artifact = Join-Path $binRoot "$pluginName.dll"
if (-not (Test-Path $artifact)) {
    $found = @(Get-ChildItem $binRoot -Filter "$pluginName.dll" -Recurse -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
    if ($found.Count -gt 0) { $artifact = $found[0].FullName }
}
if (-not (Test-Path $artifact)) { throw "artifact not found under $binRoot (expected $pluginName.dll)" }

if ($DeployDir -eq 'SKIP') {
    Write-Host ("built: " + $artifact) -ForegroundColor Green
    exit 0
}

Write-Host "=== deploying to $DeployDir ===" -ForegroundColor Cyan
try {
    New-Item -ItemType Directory -Force -Path $DeployDir | Out-Null
    Copy-Item $artifact $DeployDir -Force
}
catch [System.UnauthorizedAccessException] {
    throw "Access denied writing to '$DeployDir'. The game is under Program Files: " +
          "re-run this script from an elevated PowerShell, or copy $artifact there manually."
}
catch [System.IO.IOException] {
    throw "Could not write '$DeployDir' ($($_.Exception.Message)). " +
          "If the game is running, close it -- a loaded DLL is locked."
}

$deployed = @(Get-ChildItem $DeployDir -File)
Write-Host ("deployed: " + (($deployed | ForEach-Object { "$($_.Name) ($($_.Length) bytes)" }) -join ', ')) -ForegroundColor Green

if ($deployed.Count -ne 1 -or $deployed[0].Name -ne "$pluginName.dll") {
    Write-Warning ("$DeployDir contains files other than $pluginName.dll. BepInEx loads dlls at " +
                   "ANY depth under plugins, so third-party dependencies here collide with other mods.")
}

Write-Host ""
if ($DeployDerived) {
    Write-Host "Next: start the game and look for '[DspBridge]' and the listen line in:" -ForegroundColor Yellow
    $gameRoot = Split-Path (Split-Path (Split-Path $DeployDir -Parent) -Parent) -Parent
    Write-Host ("  " + (Join-Path $gameRoot 'LogOutput.log')) -ForegroundColor Yellow
}
