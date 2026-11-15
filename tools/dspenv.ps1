<#
    dspenv.ps1 -- dot-source this to get the portable workspace-local .NET environment.

        . "$PSScriptRoot\dspenv.ps1"
        & $DspDotnet build ...

    PORTABLE BY DESIGN: every path is derived from this file's own location, so the whole
    tree can be copied to another machine, drive letter or folder depth and still work.

    Why the redirection is needed at all: the user profile may not be writable (dotnet,
    NuGet and MSBuild all want C:\Users\<user>\...), and the official SDK installer cannot
    run on a machine with UAC disabled (0x8007139F). So the SDK is the portable zip under
    tools\dotnet-sdk and every writable location is redirected into the workspace.

    Environment overrides (all optional):
        DSP_TOOLS_DIR   where the toolchain lives           (default: <this file's folder>)
        DSP_GAME_DIR    the Dyson Sphere Program folder     (default: Steam default path)
#>

$script:DspWs = if ($env:DSP_TOOLS_DIR) { $env:DSP_TOOLS_DIR } else { $PSScriptRoot }

# Machine-specific settings written by tools\setup-machine.ps1 (the detected game path).
# Loaded before the defaults below; an explicit $env:DSP_GAME_DIR still wins.
$script:DspMachineConfig = Join-Path $DspWs 'machine.config.ps1'
if (Test-Path $script:DspMachineConfig) { . $script:DspMachineConfig }

if ($env:DSP_GAME_DIR) {
    $script:DspGameDir = $env:DSP_GAME_DIR
}
elseif ($env:DSP_GAME_DIR_DEFAULT) {
    $script:DspGameDir = $env:DSP_GAME_DIR_DEFAULT
}
else {
    $script:DspGameDir = 'C:\Program Files (x86)\Steam\steamapps\common\Dyson Sphere Program'
}

# Common Steam locations, tried in order when the default path does not exist.
$script:DspGameDirCandidates = @(
    $script:DspGameDir,
    'C:\Program Files (x86)\Steam\steamapps\common\Dyson Sphere Program',
    'C:\Program Files\Steam\steamapps\common\Dyson Sphere Program',
    'D:\Steam\steamapps\common\Dyson Sphere Program',
    'D:\SteamLibrary\steamapps\common\Dyson Sphere Program',
    'E:\SteamLibrary\steamapps\common\Dyson Sphere Program',
    'C:\Games\Steam\steamapps\common\Dyson Sphere Program'
)

# ---------------------------------------------------------------- dotnet
# Two supported layouts:
#   1) portable: tools\dotnet-sdk\dotnet.exe (the offline bundle). Every writable location is
#      redirected into the workspace because the user profile may be read-only there.
#   2) system:   a dotnet on PATH. The normal user profile is used and nothing is redirected,
#      so a plain "install the .NET SDK" machine works without the portable bundle.
$script:DspPortableDotnet = Join-Path $DspWs 'dotnet-sdk\dotnet.exe'
$script:DspPortable = Test-Path $script:DspPortableDotnet

if ($script:DspPortable) {
    $script:DspDotnet = $script:DspPortableDotnet
    $env:DOTNET_ROOT                       = Join-Path $DspWs 'dotnet-sdk'
    $env:DOTNET_CLI_HOME                   = Join-Path $DspWs 'dotnet-home'
    $env:NUGET_PACKAGES                    = Join-Path $DspWs 'nuget-packages'
    $env:TMP                               = Join-Path $DspWs 'tmp'
    $env:TEMP                              = Join-Path $DspWs 'tmp'
    $env:APPDATA                           = Join-Path $DspWs 'appdata'
    $env:LOCALAPPDATA                      = Join-Path $DspWs 'localappdata'
    foreach ($p in @($env:DOTNET_CLI_HOME, $env:NUGET_PACKAGES, $env:TMP, $env:APPDATA, $env:LOCALAPPDATA)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    }
}
else {
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) { $script:DspDotnet = $cmd.Source } else { $script:DspDotnet = $null }
}

$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE    = '1'
$env:DOTNET_NOLOGO                        = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT          = '1'

<#
    Resolve the game directory. Returns $null when it cannot be found, and the caller
    decides whether that is fatal (building the plugin needs it, running the MCP layer
    does not).
#>
function Resolve-DspGameDir {
    param([switch]$Quiet)

    foreach ($candidate in $script:DspGameDirCandidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path (Join-Path $candidate 'DSPGAME.exe')) {
            if (-not $Quiet) { Write-Host ("game directory: " + $candidate) -ForegroundColor DarkGray }
            return $candidate
        }
    }

    if (-not $Quiet) {
        Write-Host "game directory not found. Looked in:" -ForegroundColor Yellow
        $script:DspGameDirCandidates | ForEach-Object { Write-Host ("  " + $_) }
        Write-Host "Set it explicitly, e.g.:" -ForegroundColor Yellow
        Write-Host '  $env:DSP_GAME_DIR = "D:\SteamLibrary\steamapps\common\Dyson Sphere Program"' -ForegroundColor Yellow
    }
    return $null
}

if (-not $script:DspDotnet -or -not (Test-Path $script:DspDotnet)) {
    throw ("dotnet not found. Either extract the portable SDK into tools\dotnet-sdk " +
           "(offline bundle), or install the .NET SDK and make sure 'dotnet' is on PATH.")
}
