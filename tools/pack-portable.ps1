<#
    pack-portable.ps1 -- build the portable ZIP of the whole runtime debugging environment.

    Produces  <repo>\dist\DSP-MPD-runtime-debug-<yyyyMMdd>.zip

    The package is meant to be extracted on another PC and work offline:
      * sources + prebuilt binaries for both projects
      * the portable .NET SDK (no installer, no admin, no writable user profile needed)
      * the local NuGet cache so `dotnet build` needs no network
      * the game reference assemblies (tools\refs) and BepInEx libs for offline compilation
      * the game-side payload (Doorstop 4 + BepInEx core + the bridge plugin)
      * docs, templates and every script

    Skipped on purpose: per-user caches (dotnet-home, appdata, localappdata, tmp), build
    intermediaries (obj), and other sessions' scratch folders.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\pack-portable.ps1
        ... -NoSdk          # smaller (~65 MB): rely on the target machine's own .NET SDK
        ... -StageOnly      # leave the staged tree in dist\ for inspection, no ZIP
#>

param(
    [switch]$NoSdk,
    [switch]$StageOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dspenv.ps1')

$repoRoot = Split-Path $PSScriptRoot -Parent
$packageName = 'DSP-MPD-runtime-debug'
$stageRoot = Join-Path $repoRoot 'dist\_stage'
$stage = Join-Path $stageRoot $packageName
$distDir = Join-Path $repoRoot 'dist'

if (Test-Path $stageRoot) {
    if (-not $Force) { Write-Host "removing previous stage tree..." -ForegroundColor DarkGray }
    Remove-Item $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null

function Say($msg) { Write-Host ("  " + $msg) }
function Section($msg) { Write-Host ""; Write-Host ("=== " + $msg + " ===") -ForegroundColor Cyan }

function Copy-Tree {
    param(
        [string]$From,
        [string]$To,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeNames = @()
    )

    if (-not (Test-Path $From)) { Say ("SKIP (missing): " + $From); return }

    New-Item -ItemType Directory -Force -Path $To | Out-Null

    # Walk iteratively so directory exclusions actually prune the traversal (and so deep
    # trees cannot blow the recursion limit).
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($From)

    while ($pending.Count -gt 0) {
        $dir = $pending.Dequeue()

        foreach ($sub in Get-ChildItem $dir -Directory -Force) {
            if ($ExcludeDirs -contains $sub.Name) { continue }
            $pending.Enqueue($sub.FullName)
        }

        foreach ($file in Get-ChildItem $dir -File -Force) {
            if ($ExcludeNames -contains $file.Name) { continue }
            $rel = $file.FullName.Substring($From.Length).TrimStart('\')
            $dest = Join-Path $To $rel
            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Copy-Item $file.FullName $dest -Force
        }
    }
}

# ---------------------------------------------------------------------------------------
Section 'README and documents'

Copy-Item (Join-Path $repoRoot 'PACKAGE-README.md') (Join-Path $stage 'README.md') -Force
Say 'README.md  (package entry point)'

Copy-Tree (Join-Path $repoRoot 'docs') (Join-Path $stage 'docs')

$docExcludes = @('v3', 'obj', 'bin')
Copy-Tree (Join-Path $repoRoot 'assets') (Join-Path $stage 'assets') -ExcludeDirs $docExcludes

# All markdown/xlsx at the repo root are design docs or reference data: copy them generically
# rather than listing names, so this script stays ASCII-only (PowerShell 5.1 reads BOM-less
# .ps1 files as ANSI, which corrupts non-ASCII literals).
foreach ($doc in Get-ChildItem $repoRoot -File | Where-Object { $_.Extension -in @('.md', '.xlsx') }) {
    if ($doc.Name -eq 'PACKAGE-README.md') { continue }   # copied as README.md already
    Copy-Item $doc.FullName (Join-Path $stage $doc.Name) -Force
    Say ($doc.Extension.TrimStart('.') + ': ' + $doc.Name)
}

# ---------------------------------------------------------------------------------------
Section 'Projects (source + prebuilt binaries)'

# DspMcpBridge: keep net10.0 output only; everything else is restore/compile noise.
Copy-Tree (Join-Path $repoRoot 'DspBridge') (Join-Path $stage 'DspBridge') -ExcludeDirs @('obj')

$mcpSrc = Join-Path $repoRoot 'DspMcpBridge'
Copy-Tree $mcpSrc (Join-Path $stage 'DspMcpBridge') -ExcludeDirs @('obj')
$mcpBin = Join-Path $stage 'DspMcpBridge\bin\Release'
if (Test-Path $mcpBin) {
    Get-ChildItem $mcpBin -Directory | Where-Object { $_.Name -ne 'net10.0' } | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force
    }
}

Copy-Tree (Join-Path $repoRoot 'templates') (Join-Path $stage 'templates') -ExcludeDirs @('obj')
Say 'templates\ (MyDspMod scaffolding)'

foreach ($helper in @('deepseek_text_20261006_8ff29d.txt', '.mcp.json')) {
    $src = Join-Path $repoRoot $helper
    if (Test-Path $src) { Copy-Item $src (Join-Path $stage $helper) -Force }
}

# ---------------------------------------------------------------------------------------
Section 'Game-side payload (what must be copied into the game folder)'

$gameDir = Resolve-DspGameDir -Quiet
if ($null -eq $gameDir) {
    Write-Host "  WARNING: game directory not found, so the game-side payload cannot be staged." -ForegroundColor Yellow
    Write-Host "           Copy it manually from <game> before packing, or re-run with -GameDir set." -ForegroundColor Yellow
}
else {
    $patch = Join-Path $stage 'game-side-patch'
    New-Item -ItemType Directory -Force -Path $patch | Out-Null

    foreach ($f in @('winhttp.dll', 'doorstop_config.ini', '.doorstop_version', 'changelog.txt')) {
        $src = Join-Path $gameDir $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $patch $f) -Force; Say ("game-side: " + $f) }
        else { Write-Host ("  WARNING: missing in the game folder: " + $f) -ForegroundColor Yellow }
    }

    $coreSrc = Join-Path $gameDir 'BepInEx\core'
    if (Test-Path $coreSrc) {
        Copy-Tree $coreSrc (Join-Path $patch 'BepInEx\core')
        Say ("game-side: BepInEx\core (" + (Get-ChildItem (Join-Path $patch 'BepInEx\core') -File).Count + " files)")
    }
    else { Write-Host "  WARNING: BepInEx\core not found in the game folder" -ForegroundColor Yellow }

    $pluginSrc = Join-Path $repoRoot 'DspBridge\bin\Release\DspBridge.dll'
    if (Test-Path $pluginSrc) {
        $pluginDst = Join-Path $patch 'BepInEx\plugins\DspBridge'
        New-Item -ItemType Directory -Force -Path $pluginDst | Out-Null
        Copy-Item $pluginSrc $pluginDst -Force
        Say 'game-side: BepInEx\plugins\DspBridge\DspBridge.dll'
    }
    else { Write-Host "  WARNING: DspBridge.dll has not been built yet; run build-and-deploy.ps1 first" -ForegroundColor Yellow }

    Copy-Item (Join-Path $repoRoot 'tools\install-game-side.ps1') (Join-Path $patch 'install-game-side.ps1') -Force
}

# ---------------------------------------------------------------------------------------
Section 'Toolchain and offline build inputs'

Copy-Tree (Join-Path $repoRoot 'tools\refs') (Join-Path $stage 'tools\refs')
Say ("tools\refs (" + (Get-ChildItem (Join-Path $stage 'tools\refs') -File).Count + " assemblies)")

Copy-Tree (Join-Path $repoRoot 'tools\bepinex-lib') (Join-Path $stage 'tools\bepinex-lib')
Say 'tools\bepinex-lib'

Copy-Tree (Join-Path $repoRoot 'tools\metaprobe') (Join-Path $stage 'tools\metaprobe') -ExcludeDirs @('obj', 'bin')
Copy-Tree (Join-Path $repoRoot 'tools\bridge-core-test') (Join-Path $stage 'tools\bridge-core-test') -ExcludeDirs @('obj', 'bin')

# Every script, stub and helper the package needs.
foreach ($f in Get-ChildItem (Join-Path $repoRoot 'tools') -File) {
    if ($f.Name -eq 'machine.config.ps1') { continue }   # machine-specific, must be regenerated
    Copy-Item $f.FullName (Join-Path $stage ('tools\' + $f.Name)) -Force
}
foreach ($sub in @('stub-runtime.json', 'stub-runtime-malformed.json', 'stub-runtime-raw.json')) {
    $src = Join-Path $repoRoot ('tools\' + $sub)
    if (Test-Path $src) { Copy-Item $src (Join-Path $stage ('tools\' + $sub)) -Force }
}
Say 'tools\*.ps1 / *.cmd / stubs'

# The already-extracted SDK makes these two installers redundant (~490 MB of duplicates).
$downloadExcludes = @('dotnet-sdk-10.0.401-win-x64.exe', 'dotnet-sdk-10.0.401-win-x64.zip')
Copy-Tree (Join-Path $repoRoot 'tools\downloads') (Join-Path $stage 'tools\downloads') -ExcludeNames $downloadExcludes
Say 'tools\downloads (original installers/packages; the redundant dotnet installer + SDK zip are excluded because tools\dotnet-sdk already holds the same SDK extracted)'

Copy-Tree (Join-Path $repoRoot 'tools\pylibs') (Join-Path $stage 'tools\pylibs')
if (Test-Path (Join-Path $repoRoot 'tools\dump_protos.py')) {
    foreach ($py in Get-ChildItem (Join-Path $repoRoot 'tools') -Filter '*.py' -File) {
        Copy-Item $py.FullName (Join-Path $stage ('tools\' + $py.Name)) -Force
    }
    Say 'tools\*.py (asset/proto inspection helpers)'
}

# Offline NuGet cache. Without it the target machine needs internet for the first build.
$cacheSrc = Join-Path $repoRoot 'tools\nuget-packages'
if ($NoSdk) { Say 'SKIPPING the NuGet cache (-NoSdk)' }
elseif (Test-Path $cacheSrc) {
    Copy-Tree $cacheSrc (Join-Path $stage 'tools\nuget-packages')
    Say 'tools\nuget-packages (offline restore)'
}
else { Write-Host "  WARNING: tools\nuget-packages missing; builds will need internet" -ForegroundColor Yellow }

# Portable .NET SDK: the single biggest item, and the reason the package needs no setup.
$sdkSrc = Join-Path $repoRoot 'tools\dotnet-sdk'
if ($NoSdk) {
    Say 'SKIPPING the portable SDK (-NoSdk): the target machine must provide .NET 10'
}
elseif (Test-Path $sdkSrc) {
    Copy-Tree $sdkSrc (Join-Path $stage 'tools\dotnet-sdk')
    Say 'tools\dotnet-sdk (portable SDK, extract-and-run)'
}
else { Write-Host "  WARNING: tools\dotnet-sdk missing" -ForegroundColor Yellow }

# Writable scratch directories, so the first run does not have to create them.
foreach ($d in @('dotnet-home', 'tmp', 'appdata', 'localappdata')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage ('tools\' + $d)) | Out-Null
}

# ---------------------------------------------------------------------------------------
Section 'Staging summary'

$stageFiles = Get-ChildItem $stage -Recurse -File -Force
$stageBytes = ($stageFiles | Measure-Object Length -Sum).Sum
Write-Host ("  files : " + $stageFiles.Count)
Write-Host ("  size  : " + [math]::Round($stageBytes / 1MB, 1) + " MB (uncompressed)")

# Sanity: the package must not carry the old machine's absolute path in scripts.
Section 'Portability check (old absolute paths in scripts)'
$offenders = @()
$scriptFiles = Get-ChildItem (Join-Path $stage 'tools') -File -Recurse |
               Where-Object { $_.Extension -in @('.ps1', '.cmd') }
foreach ($f in $scriptFiles) {
    $text = Get-Content $f.FullName -Raw
    if ($text -match 'C:\\XCM\\DSP MPD') { $offenders += $f.FullName.Substring($stage.Length + 1) }
}
Write-Host ("  scripts inspected: " + $scriptFiles.Count)
if ($offenders.Count -eq 0) { Write-Host "  OK: no hard-coded workspace paths in tools\ scripts" -ForegroundColor Green }
else {
    Write-Host "  PROBLEM: these scripts still hard-code the old path:" -ForegroundColor Red
    $offenders | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor Red }
}

if ($StageOnly) {
    Write-Host ""
    Write-Host ("staged at: " + $stage) -ForegroundColor Green
    Write-Host "inspect it, then re-run without -StageOnly to produce the ZIP"
    exit 0
}

# ---------------------------------------------------------------------------------------
Section 'Creating the ZIP'

$stamp = Get-Date -Format 'yyyyMMdd'
$suffix = ''
if ($NoSdk) { $suffix = '-no-sdk' }
$zipPath = Join-Path $distDir ($packageName + $suffix + '-' + $stamp + '.zip')

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
# Optimal compression: the SDK is thousands of small text/binary files and compresses well.
# includeBaseDirectory = $true so extracting produces a single well-named folder, which is
# what the README and the smoke test assume.
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stageRoot, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)

$zipItem = Get-Item $zipPath
Write-Host ("  " + $zipItem.FullName)
Write-Host ("  " + [math]::Round($zipItem.Length / 1MB, 1) + " MB")

# Verify the archive actually opens and holds the entry point.
# The archive root is the package folder ($packageName), because
# includeBaseDirectory = $true -- extracting yields exactly one folder to cd into.
$p = $packageName + '/'
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entries = $zip.Entries.Count
    $hasReadme = ($zip.Entries | Where-Object { $_.FullName -eq ($p + 'README.md') }).Count -eq 1
    $hasSdk = ($zip.Entries | Where-Object { $_.FullName -eq ($p + 'tools/dotnet-sdk/dotnet.exe') }).Count -eq 1
    $hasPlugin = ($zip.Entries | Where-Object { $_.FullName -eq ($p + 'game-side-patch/BepInEx/plugins/DspBridge/DspBridge.dll') }).Count -eq 1
    $hasMcp = ($zip.Entries | Where-Object { $_.FullName -eq ($p + 'DspMcpBridge/bin/Release/net10.0/DspMcpBridge.dll') }).Count -eq 1
    $hasEnv = ($zip.Entries | Where-Object { $_.FullName -eq ($p + 'tools/dspenv.ps1') }).Count -eq 1
    $hasInstall = ($zip.Entries | Where-Object { $_.FullName -eq ($p + 'tools/install-game-side.ps1') }).Count -eq 1
    $hasCache = ($zip.Entries | Where-Object { $_.FullName -like ($p + 'tools/nuget-packages/modelcontextprotocol/*') }).Count -gt 0
}
finally { $zip.Dispose() }

Write-Host ("  entries: " + $entries)
Write-Host ("  README.md              : " + $hasReadme)
Write-Host ("  tools\dspenv.ps1       : " + $hasEnv)
Write-Host ("  tools\install-game-side: " + $hasInstall)
Write-Host ("  portable SDK           : " + $hasSdk)
Write-Host ("  offline NuGet cache    : " + $hasCache)
Write-Host ("  prebuilt MCP server    : " + $hasMcp)
Write-Host ("  prebuilt bridge dll    : " + $hasPlugin)

$missing = @()
if (-not $hasReadme) { $missing += 'README.md' }
if (-not $hasEnv) { $missing += 'tools/dspenv.ps1' }
if (-not $hasInstall) { $missing += 'tools/install-game-side.ps1' }
if (-not $hasSdk) { $missing += 'tools/dotnet-sdk/dotnet.exe' }
if (-not $hasCache) { $missing += 'tools/nuget-packages' }
if (-not $hasMcp) { $missing += 'DspMcpBridge.dll' }
if (-not $hasPlugin) { $missing += 'DspBridge.dll' }
if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host ("PACKAGE INCOMPLETE, missing: " + ($missing -join ', ')) -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "PACKAGE READY" -ForegroundColor Green
Write-Host ("  " + $zipPath)
Write-Host ""
Write-Host "On the other machine: extract, then run" -ForegroundColor Yellow
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup-machine.ps1"
exit 0
