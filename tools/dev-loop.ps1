<#
    dev-loop.ps1 -- hands-off launch / log-capture / live-verify harness for the DSP bridge.

    WHY THIS EXISTS
      The package ships everything EXCEPT automation of the two steps a human was expected to
      do by hand every iteration: start the game, and look at the log. This script closes that
      loop so a debugging session is one command instead of "click Steam, wait, alt-tab to the
      log, copy lines". Together with the bridge (which exposes live game state over localhost)
      it is what makes the loop seconds long instead of minutes.

    NOT ASCII-OPTIONAL: every tools\*.ps1 in this package is pure ASCII. Windows PowerShell 5.1
    reads a BOM-less .ps1 as ANSI and corrupts non-ASCII literals, producing parse errors that
    point at unrelated lines (manual pitfall 5). Keep this file ASCII-only.

    MODES
      status   (default) show game process + bridge discovery + /health + log tail
      up       launch the game (via Steam) and wait until the bridge answers /health
      down     stop the game process and archive its log
      restart  down, then up
      cycle    restart -> wait ready -> verify-live -> archive log  (the full hands-off loop)
      log      print the newest (or Nth newest) BepInEx log; -Follow to stream
      verify   run tools\verify-live.ps1 against the running game
      watch    heartbeat loop; with -AutoRestart, relaunch the game when it exits
      shot     save a PNG of the game window to <repo>\logs\shot-<stamp>.png
      click    synthetic mouse click at -X/-Y (physical screen pixels)
      key      synthetic key press: -Key escape, or -VK <virtual-key code>

    EXAMPLES
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev-loop.ps1 -Mode cycle
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev-loop.ps1 -Mode up -RequireSave
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev-loop.ps1 -Mode log -Lines 200 -Filter DspBridge
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev-loop.ps1 -Mode log -Follow -Filter 'error|Exception'
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev-loop.ps1 -Mode watch -AutoRestart -DurationSec 3600
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev-loop.ps1 -Mode shot
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev-loop.ps1 -Mode click -X 310 -Y 854
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev-loop.ps1 -Mode key -Key escape

    NOTES
      * Launching goes through Steam (`steam.exe -applaunch 1366540`), NOT DSPGAME.exe directly:
        the game is Steam-DRM protected and a direct launch is not guaranteed to work.
      * BepInEx overwrites BepInEx\LogOutput.log on every start, so each run's log is archived
        to <repo>\logs\LogOutput-<stamp>-<tag>-pid<N>.log before/after a launch. That is what
        lets you diff "the run that failed" against "the run that worked" without a human
        copying files.
      * Reading the log here is deliberately independent of the bridge: if the plugin fails to
        load, the bridge cannot answer get_log_tail, and this is the only way to see why.
      * shot / click / key are the GUI fallback, not the main road. They need a visible, actually
        rendering game window; a synthetic click goes wherever the cursor is, so nothing verifies
        that you hit the intended control. Use the bridge for state and this script for the log;
        reach for pixels only for what only the rendered window can show - layout, native dialogs,
        and the case where BepInEx did not load at all.
      * These modes make the process DPI-aware on purpose. On a scaled desktop a non-DPI-aware
        process sees virtual coordinates (2560x1600 at 200% looks like 1280x800) and its clicks
        land in the wrong place; that mismatch is the usual cause of "I can see it but cannot
        click it". Coordinates here are always PHYSICAL pixels, the same ones the PNG uses.
      * Synthetic input takes the real mouse and keyboard for the duration. Do not run these while
        a human is using the machine.
#>

param(
    [ValidateSet('status', 'up', 'down', 'restart', 'cycle', 'log', 'verify', 'watch', 'shot', 'click', 'key')]
    [string]$Mode = 'status',

    [string]$GameDir = '',
    [int]$SteamAppId = 1366540,

    [int]$Lines = 80,
    [int]$Back = 0,
    [string]$Filter = '',
    [switch]$Follow,

    [int]$TimeoutSec = 300,
    [int]$GraceSec = 90,
    [switch]$RequireSave,

    [switch]$NoArchive,
    [switch]$AutoRestart,
    [int]$IntervalSec = 10,
    [int]$DurationSec = 0,

    [ValidateSet('keep', 'on', 'off')]
    [string]$Writes = 'keep',

    # ---- GUI fallback (shot / click / key) ----
    # X/Y are PHYSICAL screen pixels (the same coordinates as the saved PNG).
    [int]$X = -1,
    [int]$Y = -1,
    [ValidateSet('left', 'right', 'double')]
    [string]$Button = 'left',
    [string]$Key = '',
    [int]$VK = 0,
    [int]$Repeat = 1,
    [switch]$Foreground,
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'

# Capture the REAL profile path before dspenv.ps1 redirects LOCALAPPDATA into tools\.
$realLocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)

. (Join-Path $PSScriptRoot 'dspenv.ps1')

$repoRoot = Split-Path $PSScriptRoot -Parent
$logArchiveDir = Join-Path $repoRoot 'logs'

function Info($m) { Write-Host $m }
function Good($m) { Write-Host ("  OK    " + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ("  WARN  " + $m) -ForegroundColor Yellow }
function Bad($m) { Write-Host ("  FAIL  " + $m) -ForegroundColor Red }
function Head($m) { Write-Host ""; Write-Host ("=== " + $m + " ===") -ForegroundColor Cyan }

# ------------------------------------------------------------------ game directory
if ([string]::IsNullOrWhiteSpace($GameDir)) { $GameDir = Resolve-DspGameDir -Quiet }
if ([string]::IsNullOrWhiteSpace($GameDir) -or -not (Test-Path (Join-Path $GameDir 'DSPGAME.exe'))) {
    Bad ("game directory not found; pass -GameDir or run tools\setup-machine.ps1. Tried: " + $GameDir)
    exit 2
}
$gameLogPath = Join-Path $GameDir 'BepInEx\LogOutput.log'
$bridgeCfgPath = Join-Path $GameDir 'BepInEx\config\org.yourname.dspbridge.cfg'

# ------------------------------------------------------------------ bridge discovery
function Get-RuntimeCandidates {
    $c = @()
    if ($env:DSP_BRIDGE_RUNTIME) { $c += $env:DSP_BRIDGE_RUNTIME }
    if ($realLocalAppData) { $c += (Join-Path $realLocalAppData 'DSPBridge\runtime.json') }
    if ($env:USERPROFILE) { $c += (Join-Path $env:USERPROFILE 'AppData\Local\DSPBridge\runtime.json') }
    $c += (Join-Path $DspWs 'localappdata\DSPBridge\runtime.json')
    @($c | Where-Object { $_ } | Select-Object -Unique)
}

function Get-RuntimeInfo {
    foreach ($path in (Get-RuntimeCandidates)) {
        if (-not (Test-Path $path)) { continue }
        try {
            $rt = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $rt.port) { continue }
            Add-Member -InputObject $rt -NotePropertyName __path -NotePropertyValue $path -Force
            return $rt
        }
        catch { }
    }
    return $null
}

function Test-GameProcess {
    param([int]$ProcessId = 0)
    if ($ProcessId -gt 0) {
        return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
    }
    return [bool](Get-Process -Name 'DSPGAME' -ErrorAction SilentlyContinue)
}

function Invoke-Bridge {
    param([string]$Url, [hashtable]$Headers, [string]$Method = 'Get', [string]$Body = '')
    if ($Method -eq 'Post') {
        return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Post -ContentType 'application/json' -Body $Body -TimeoutSec 40
    }
    return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -TimeoutSec 40
}

function Get-BridgeHealth {
    param($RuntimeInfo)
    if ($null -eq $RuntimeInfo) { return $null }
    $base = 'http://127.0.0.1:' + [int]$RuntimeInfo.port
    $headers = @{ Authorization = 'Bearer ' + [string]$RuntimeInfo.token }
    try { return Invoke-Bridge -Url ($base + '/health') -Headers $headers -Method Get }
    catch { return $null }
}

# ------------------------------------------------------------------ log helpers
function Get-LogFiles {
    $files = @()
    if (Test-Path $logArchiveDir) {
        $files += @(Get-ChildItem $logArchiveDir -Filter 'LogOutput-*.log' -File -ErrorAction SilentlyContinue)
    }
    if (Test-Path $gameLogPath) { $files += @(Get-Item $gameLogPath) }
    @($files | Sort-Object LastWriteTime -Descending)
}

function Archive-Log {
    param([string]$Tag = 'run', [int]$GameProcessId = 0)
    if ($NoArchive) { return $null }
    if (-not (Test-Path $gameLogPath)) { return $null }
    if ((Get-Item $gameLogPath).Length -le 0) { return $null }
    if (-not (Test-Path $logArchiveDir)) { New-Item -ItemType Directory -Force -Path $logArchiveDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $pidTag = ''
    if ($GameProcessId -gt 0) { $pidTag = '-pid' + $GameProcessId }
    $dst = Join-Path $logArchiveDir ("LogOutput-" + $stamp + "-" + $Tag + $pidTag + ".log")
    Copy-Item $gameLogPath $dst -Force
    return $dst
}

function Show-Log {
    param([int]$WantLines = 80, [string]$Pattern = '', [int]$Index = 0, [bool]$Stream = $false)

    $files = Get-LogFiles
    if ($files.Count -eq 0) {
        Warn "no BepInEx log found yet (game never ran with BepInEx installed?)"
        Warn ("expected: " + $gameLogPath)
        return
    }
    if ($Index -ge $files.Count) { $Index = $files.Count - 1 }
    $file = $files[$Index]

    Info ("  log   : " + $file.FullName + "   (" + $file.Length + " bytes, written " + $file.LastWriteTime + ")")

    if ($Stream) {
        Info "  streaming (Ctrl+C to stop)..."
        Get-Content -Path $file.FullName -Wait -Tail $WantLines -Encoding UTF8 | ForEach-Object {
            if ($Pattern -eq '' -or $_ -match $Pattern) { Write-Host $_ }
        }
        return
    }

    $tail = @(Get-Content -Path $file.FullName -Tail $WantLines -Encoding UTF8)
    if ($Pattern -ne '') { $tail = @($tail | Where-Object { $_ -match $Pattern }) }
    if ($tail.Count -eq 0) { Warn "no matching lines (pattern: '$Pattern') in the last $WantLines lines"; return }
    $tail | ForEach-Object { Write-Host $_ }
    Info ("  (" + $tail.Count + " line(s) shown)")
}

function Show-StartupDiagnosis {
    if (-not (Test-Path $gameLogPath)) {
        Warn ("no log at " + $gameLogPath + " -- BepInEx/Doorstop probably did not load at all")
        Warn "check: BepInEx\core\BepInEx.Preloader.dll, .doorstop_version, and that doorstop_config.ini is the Doorstop 4 format"
        return
    }
    $all = @(Get-Content -Path $gameLogPath -Encoding UTF8)
    if (-not ($all | Where-Object { $_ -match '\[DspBridge\]' })) {
        Warn "no [DspBridge] line in the log: the plugin did not load"
        $all | Select-Object -Last 20 | ForEach-Object { Write-Host ("    " + $_) }
        return
    }
    $bad = @($all | Where-Object { $_ -match 'MissingMethodException|MissingFieldException|MissingMemberException|Exception|Error' })
    if ($bad.Count -gt 0) {
        Warn ("exceptions/missing members in the log (" + $bad.Count + " line(s)); last few:")
        $bad | Select-Object -Last 10 | ForEach-Object { Write-Host ("    " + $_) }
    }
    else { Good "no MissingMethod/Field or Exception lines in the log" }
}

# ------------------------------------------------------------------ game process control
function Get-SteamExe {
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        if (-not (Test-Path $key)) { continue }
        $p = Get-ItemProperty $key -ErrorAction SilentlyContinue
        $candidates = @()
        if ($p.SteamExe) { $candidates += ($p.SteamExe -replace '/', '\') }
        if ($p.SteamPath) { $candidates += (Join-Path ($p.SteamPath -replace '/', '\') 'steam.exe') }
        if ($p.InstallPath) { $candidates += (Join-Path $p.InstallPath 'steam.exe') }
        foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    }
    return $null
}

function Start-Game {
    if (Test-GameProcess) { Good ("game already running (pid " + (@(Get-Process -Name 'DSPGAME')[0].Id) + ")"); return $true }

    $steam = Get-SteamExe
    if ($steam) {
        Info ("  launch: " + $steam + " -applaunch " + $SteamAppId)
        Start-Process -FilePath $steam -ArgumentList '-applaunch', ([string]$SteamAppId) | Out-Null
        return $true
    }
    Warn "Steam not found in the registry; falling back to a direct DSPGAME.exe launch (may fail DRM checks)"
    Start-Process -FilePath (Join-Path $GameDir 'DSPGAME.exe') -WorkingDirectory $GameDir | Out-Null
    return $true
}

function Stop-Game {
    $procs = @(Get-Process -Name 'DSPGAME' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Good "game is not running"; return $true }
    foreach ($p in $procs) {
        Info ("  stopping pid " + $p.Id + " ...")
        try { $p.CloseMainWindow() | Out-Null } catch { }
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and (Test-GameProcess)) { Start-Sleep -Milliseconds 500 }
    if (Test-GameProcess) {
        Warn "game did not exit on its own after 30s; forcing"
        Get-Process -Name 'DSPGAME' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    if (Test-GameProcess) { Bad "could not stop DSPGAME"; return $false }
    Good "game stopped"
    return $true
}

function Wait-Bridge {
    param([int]$WaitSeconds = 300, [bool]$NeedSave = $false, [int]$GraceSec = 90)

    $start = Get-Date
    $deadline = $start.AddSeconds($WaitSeconds)
    $sawProcess = $false
    $nextProgress = 0

    while ((Get-Date) -lt $deadline) {
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $alive = Test-GameProcess
        if ($alive) { $sawProcess = $true }
        elseif ($sawProcess) {
            Bad ("the game process exited after " + $elapsed + "s (crash, or it was closed)")
            Show-StartupDiagnosis
            return $false
        }
        elseif ($elapsed -ge $GraceSec) {
            Bad ("DSPGAME.exe never appeared within " + $GraceSec + "s")
            Warn "Steam may have shown a dialog (update / first run / cloud conflict) or refused the launch"
            return $false
        }

        if ($alive) {
            $rt = Get-RuntimeInfo
            if ($null -ne $rt -and (Test-GameProcess -ProcessId ([int]$rt.pid))) {
                $health = Get-BridgeHealth -RuntimeInfo $rt
                if ($null -ne $health -and $health.status -eq 'ok') {
                    if (-not $NeedSave -or $health.gameLoaded) {
                        Good ("ready after " + $elapsed + "s: port " + $rt.port + " pid " + $rt.pid + " gameLoaded=" + $health.gameLoaded + " unity=" + $health.unityVersion)
                        return $true
                    }
                    if ($elapsed -ge $nextProgress) {
                        Info ("  bridge is up but no save is loaded yet (" + $elapsed + "s); load a save in the game, or run without -RequireSave")
                        $nextProgress = $elapsed + 15
                    }
                }
                elseif ($elapsed -ge $nextProgress) {
                    Info ("  runtime.json found (port " + $rt.port + "), waiting for /health to answer (" + $elapsed + "s)")
                    $nextProgress = $elapsed + 10
                }
            }
            elseif ($elapsed -ge $nextProgress) {
                Info ("  game is up (pid " + (@(Get-Process -Name 'DSPGAME')[0].Id) + "), waiting for the bridge's first frame (" + $elapsed + "s)")
                $nextProgress = $elapsed + 10
            }
        }
        elseif ($elapsed -ge $nextProgress) {
            Info ("  waiting for DSPGAME.exe to appear (" + $elapsed + "s)")
            $nextProgress = $elapsed + 5
        }

        Start-Sleep -Seconds 2
    }

    Bad ("the bridge did not become ready within " + $WaitSeconds + "s")
    Show-StartupDiagnosis
    Info "  last 30 log lines:"
    Show-Log -WantLines 30
    return $false
}

# ------------------------------------------------------------------ window capture / input injection
# The bridge is the primary road for state; these helpers are the GUI fallback for the few things
# only the rendered window can show (layout, native dialogs, and "the plugin did not load at all").
# They use the same Win32 primitives any GUI automation plugin would: PrintWindow/BitBlt to read
# pixels and mouse_event/keybd_event to act. No third-party tool or injection is involved, so this
# keeps working even when BepInEx did not load.
function Initialize-DspWin32 {
    if ('DspWin32' -as [type]) { return }
    $cs = @'
using System;
using System.Runtime.InteropServices;
public class DspWin32 {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
}
'@
    Add-Type -TypeDefinition $cs -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    # Physical pixels from here on. Without this, a 2560x1600 @200% desktop looks like 1280x800 to
    # this process, every coordinate is scaled, and a click lands somewhere else - the classic
    # "I can see the control but cannot click it" failure.
    [void][DspWin32]::SetProcessDPIAware()
}

function Get-GameWindow {
    param([switch]$Activate)
    $procs = @(Get-Process -Name 'DSPGAME' -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending)
    if ($procs.Count -eq 0) { return $null }
    $proc = $procs[0]
    $hwnd = $proc.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    if ($Activate) {
        if ([DspWin32]::IsIconic($hwnd)) { [void][DspWin32]::ShowWindow($hwnd, 9) }   # SW_RESTORE
        [void][DspWin32]::SetForegroundWindow($hwnd)
        Start-Sleep -Milliseconds 400
    }
    $r = New-Object 'DspWin32+RECT'
    [void][DspWin32]::GetWindowRect($hwnd, [ref]$r)
    [pscustomobject]@{
        Hwnd    = $hwnd
        Pid     = $proc.Id
        Left    = $r.Left
        Top     = $r.Top
        Width   = ($r.Right - $r.Left)
        Height  = ($r.Bottom - $r.Top)
        Visible = [DspWin32]::IsWindowVisible($hwnd)
        Iconic  = [DspWin32]::IsIconic($hwnd)
    }
}

function Measure-NonBlack {
    param($Bitmap)
    $nonBlack = 0
    $total = 0
    for ($y = 0; $y -lt $Bitmap.Height; $y += 16) {
        for ($x = 0; $x -lt $Bitmap.Width; $x += 16) {
            $c = $Bitmap.GetPixel($x, $y)
            $total++
            if (($c.R + $c.G + $c.B) -gt 24) { $nonBlack++ }
        }
    }
    if ($total -eq 0) { return 0.0 }
    return ($nonBlack / [double]$total)
}

function Save-GameShot {
    param([string]$Path, [switch]$Foreground)
    $w = Get-GameWindow -Activate:$Foreground
    if ($null -eq $w) { Warn 'the game is not running (no DSPGAME main window to capture)'; return $null }
    if ($w.Width -le 0 -or $w.Height -le 0) {
        Warn ('the game window has no usable size (' + $w.Width + 'x' + $w.Height + '); is it minimised?')
        return $null
    }

    $bmp = New-Object Drawing.Bitmap $w.Width, $w.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [DspWin32]::PrintWindow($w.Hwnd, $hdc, 2)     # 2 = PW_RENDERFULLCONTENT, needed for DirectX
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    $method = 'PrintWindow'
    $ratio = Measure-NonBlack -Bitmap $bmp

    if ($ratio -lt 0.02) {
        # PrintWindow cannot always read a DirectX swap chain; capture what is on the screen instead.
        if (-not $Foreground) { Warn 'PrintWindow returned a black frame; falling back to a desktop capture (the window has to be visible)' }
        $g2 = [Drawing.Graphics]::FromImage($bmp)
        $g2.CopyFromScreen($w.Left, $w.Top, 0, 0, (New-Object Drawing.Size $w.Width, $w.Height))
        $g2.Dispose()
        $method = 'desktop-BitBlt'
        $ratio = Measure-NonBlack -Bitmap $bmp
    }

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    [pscustomobject]@{
        Path          = $Path
        Width         = $w.Width
        Height        = $w.Height
        Method        = $method
        NonBlackRatio = $ratio
        PrintWindowOk = $ok
        Pid           = $w.Pid
    }
}

function Invoke-GameClick {
    param([int]$X, [int]$Y, [string]$Button = 'left')
    $w = Get-GameWindow -Activate
    if ($null -eq $w) { Warn 'the game is not running'; return $false }
    # A synthetic click goes wherever the cursor is, so the cursor IS the target: there is no widget
    # lookup and nothing checks what was hit. That is why a -Mode shot first is the workflow.
    [void][DspWin32]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 150
    switch ($Button) {
        'left' {
            [DspWin32]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)    # LEFTDOWN
            Start-Sleep -Milliseconds 70
            [DspWin32]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)    # LEFTUP
        }
        'right' {
            [DspWin32]::mouse_event(0x0008, 0, 0, 0, [IntPtr]::Zero)    # RIGHTDOWN
            Start-Sleep -Milliseconds 70
            [DspWin32]::mouse_event(0x0010, 0, 0, 0, [IntPtr]::Zero)    # RIGHTUP
        }
        'double' {
            [DspWin32]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 50
            [DspWin32]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 90
            [DspWin32]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 50
            [DspWin32]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        }
    }
    Start-Sleep -Milliseconds 300
    return $true
}

function Resolve-VirtualKey {
    param([string]$Name, [int]$Code)
    if ($Code -gt 0) { return $Code }
    if ([string]::IsNullOrWhiteSpace($Name)) { return -1 }
    $map = @{
        'escape' = 27; 'esc' = 27; 'enter' = 13; 'return' = 13; 'tab' = 9; 'space' = 32;
        'backspace' = 8; 'delete' = 46; 'insert' = 45; 'home' = 36; 'end' = 35;
        'pageup' = 33; 'pagedown' = 34; 'up' = 38; 'down' = 40; 'left' = 37; 'right' = 39;
        'shift' = 16; 'ctrl' = 17; 'control' = 17; 'alt' = 18;
        'f1' = 112; 'f2' = 113; 'f3' = 114; 'f4' = 115; 'f5' = 116; 'f6' = 117;
        'f7' = 118; 'f8' = 119; 'f9' = 120; 'f10' = 121; 'f11' = 122; 'f12' = 123
    }
    $key = $Name.Trim().ToLowerInvariant()
    if ($map.ContainsKey($key)) { return [int]$map[$key] }
    if ($key -match '^0x([0-9a-f]{1,2})$') { return [Convert]::ToInt32($Matches[1], 16) }
    if ($key -match '^\d{1,3}$') { return [int]$key }
    return -1
}

function Invoke-GameKey {
    param([int]$Code, [int]$Repeat = 1, [int]$HoldMs = 60)
    $w = Get-GameWindow -Activate
    if ($null -eq $w) { Warn 'the game is not running'; return $false }
    $times = 1
    if ($Repeat -gt 1) { $times = $Repeat }
    for ($i = 0; $i -lt $times; $i++) {
        [DspWin32]::keybd_event([byte]$Code, 0, 0, [IntPtr]::Zero)          # key down
        Start-Sleep -Milliseconds $HoldMs
        [DspWin32]::keybd_event([byte]$Code, 0, 2, [IntPtr]::Zero)          # key up
        Start-Sleep -Milliseconds 120
    }
    return $true
}

function Invoke-Shot {
    Head "screenshot the game window"
    $path = $Out
    if ([string]::IsNullOrWhiteSpace($path)) {
        if (-not (Test-Path $logArchiveDir)) { New-Item -ItemType Directory -Force -Path $logArchiveDir | Out-Null }
        $path = Join-Path $logArchiveDir ('shot-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.png')
    }
    $s = Save-GameShot -Path $path -Foreground:$Foreground
    if ($null -eq $s) { exit 2 }
    Good ("saved   : " + $s.Path)
    Info ("          " + $s.Width + "x" + $s.Height + " via " + $s.Method + ", non-black " + ('{0:P1}' -f $s.NonBlackRatio) + ", pid " + $s.Pid)
    if ($s.NonBlackRatio -lt 0.02) { Warn 'the frame is almost entirely black: the window may be minimised or not rendering (retry with -Foreground)' }
}

function Invoke-Click {
    Head "synthetic mouse click"
    if ($X -lt 0 -or $Y -lt 0) {
        Bad 'click needs -X and -Y (physical screen pixels; take a -Mode shot first to pick them)'
        exit 2
    }
    if (-not (Invoke-GameClick -X $X -Y $Y -Button $Button)) { exit 2 }
    Good ("clicked " + $Button + " at " + $X + "," + $Y + " (physical pixels; the cursor stays there)")
    Info '  check the result with: -Mode shot'
}

function Invoke-Keystroke {
    Head "synthetic key press"
    $code = Resolve-VirtualKey -Name $Key -Code $VK
    if ($code -le 0) {
        Bad 'key needs -Key <name> (escape, enter, tab, space, f1..f12, up/down/left/right, 0x1B) or -VK <code>'
        exit 2
    }
    if (-not (Invoke-GameKey -Code $code -Repeat $Repeat)) { exit 2 }
    $times = 1
    if ($Repeat -gt 1) { $times = $Repeat }
    Good ("sent virtual key " + $code + " x" + $times)
}

# ------------------------------------------------------------------ modes
function Show-Status {
    Head "DSP runtime bridge status"
    Info ("  repo  : " + $repoRoot)
    Info ("  game  : " + $GameDir)

    $procs = @(Get-Process -Name 'DSPGAME' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Warn "DSPGAME.exe is not running" }
    else {
        foreach ($p in $procs) {
            Info ("  game  : pid " + $p.Id + ", started " + $p.StartTime + ", uptime " + [int]((Get-Date) - $p.StartTime).TotalSeconds + "s")
        }
    }

    $rt = Get-RuntimeInfo
    if ($null -eq $rt) {
        Warn "no runtime.json found (the in-game bridge has not started)"
        foreach ($c in (Get-RuntimeCandidates)) { Info ("        looked in: " + $c) }
    }
    else {
        Good ("runtime.json: " + $rt.__path)
        Info ("        port=" + $rt.port + " pid=" + $rt.pid + " schemaVersion=" + $rt.schemaVersion + " allowWrites=" + $rt.allowWrites + " startedAt=" + $rt.startedAt)
        if (Test-GameProcess -ProcessId ([int]$rt.pid)) { Good ("process " + $rt.pid + " is alive") }
        else { Warn ("process " + $rt.pid + " is NOT alive: stale runtime.json (the game probably exited)") }

        $health = Get-BridgeHealth -RuntimeInfo $rt
        if ($null -eq $health) { Bad ("/health did not answer (port " + $rt.port + ")") }
        else {
            Good ("/health -> status=" + $health.status + " gameLoaded=" + $health.gameLoaded + " unityVersion=" + $health.unityVersion + " snapshotTick=" + $health.snapshotTick)
            if (-not $health.gameLoaded) { Warn "no save is loaded (main menu): /state will be mostly empty - load a save to debug" }
        }
    }

    $cfgExists = Test-Path $bridgeCfgPath
    Info ("  cfg   : " + $bridgeCfgPath + "   (" + $(if ($cfgExists) { "present" } else { "not written yet - the game has never run with the plugin" }) + ")")

    Head "log"
    $files = Get-LogFiles
    if ($files.Count -eq 0) { Warn ("no log yet at " + $gameLogPath) }
    else {
        Info ("  archives: " + @(Get-ChildItem $logArchiveDir -Filter 'LogOutput-*.log' -File -ErrorAction SilentlyContinue).Count + " file(s) under " + $logArchiveDir)
        Show-StartupDiagnosis
        Info ""
        Info "  last $Lines line(s) of the newest log:"
        Show-Log -WantLines $Lines -Pattern $Filter -Index $Back
    }
}

function Invoke-Verify {
    Head "live verification (tools\verify-live.ps1)"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-live.ps1') 2>&1 | Out-String
    Write-Host $out
    if ($out -match 'ALL LIVE CHECKS PASSED') { Good "live verification passed"; return $true }
    Bad "live verification did not pass (see the output above; exit code $LASTEXITCODE)"
    return $false
}

function Invoke-Up {
    param([bool]$NeedSave = $false)
    Head "bring up the debug environment"
    if (Test-Path $gameLogPath) {
        $a = Archive-Log -Tag 'previous'
        if ($a) { Info ("  archived previous log: " + $a) }
    }
    if (-not (Start-Game)) { return $false }
    $ok = Wait-Bridge -WaitSeconds $TimeoutSec -NeedSave $NeedSave -GraceSec $GraceSec
    $rt = Get-RuntimeInfo
    $gamePid = 0
    if ($null -ne $rt) { $gamePid = [int]$rt.pid }
    elseif (Test-GameProcess) { $gamePid = @(Get-Process -Name 'DSPGAME')[0].Id }
    $a = Archive-Log -Tag $(if ($ok) { 'ready' } else { 'failed' }) -GameProcessId $gamePid
    if ($a) { Info ("  archived this run's log: " + $a) }
    if ($ok) {
        Info ""
        Info "  the game stays running; use the MCP tools or -Mode verify / -Mode log from here."
    }
    return $ok
}

function Set-WritesMode {
    param([string]$Setting)
    if ($Setting -eq 'keep') { return }
    if (-not (Test-Path $bridgeCfgPath)) {
        Warn "-Writes ignored: the bridge config does not exist yet (start the game once)"
        return
    }
    $want = 'false'
    if ($Setting -eq 'on') { $want = 'true' }
    $text = Get-Content $bridgeCfgPath -Raw -Encoding UTF8
    $new = $text -replace '(?m)^(\s*AllowWrites\s*=\s*)(true|false)', ('${1}' + $want)
    if ($new -eq $text) { Warn ("AllowWrites was already " + $want + " (or the key was not found)") ; return }
    Set-Content -Path $bridgeCfgPath -Value $new -Encoding UTF8 -NoNewline
    Good ("set [Bridge] AllowWrites = " + $want + " (takes effect the next time the game starts)")
}

# ------------------------------------------------------------------ dispatch
switch ($Mode) {
    'status' { Show-Status }
    'log' {
        Head "BepInEx log"
        Show-Log -WantLines $Lines -Pattern $Filter -Index $Back -Stream ([bool]$Follow)
    }
    'up' {
        Set-WritesMode -Setting $Writes
        Show-Status
        if (-not (Invoke-Up -NeedSave ([bool]$RequireSave))) { exit 1 }
    }
    'down' {
        Head "stop the game"
        $rt = Get-RuntimeInfo
        $gamePid = 0
        if ($null -ne $rt) { $gamePid = [int]$rt.pid }
        if (-not (Stop-Game)) { exit 1 }
        $a = Archive-Log -Tag 'final' -GameProcessId $gamePid
        if ($a) { Info ("  archived final log: " + $a) }
    }
    'restart' {
        Set-WritesMode -Setting $Writes
        & $PSCommandPath -Mode down -GameDir $GameDir -NoArchive:$NoArchive
        if (-not (Invoke-Up -NeedSave ([bool]$RequireSave))) { exit 1 }
    }
    'cycle' {
        Set-WritesMode -Setting $Writes
        & $PSCommandPath -Mode down -GameDir $GameDir -NoArchive:$NoArchive
        if (-not (Invoke-Up -NeedSave ([bool]$RequireSave))) { exit 1 }
        if (-not (Invoke-Verify)) { exit 1 }
        Head "log tail after verification"
        Show-Log -WantLines $Lines -Pattern $Filter -Index $Back
    }
    'verify' { if (-not (Invoke-Verify)) { exit 1 } }
    'shot' { Initialize-DspWin32; Invoke-Shot }
    'click' { Initialize-DspWin32; Invoke-Click }
    'key' { Initialize-DspWin32; Invoke-Keystroke }
    'watch' {
        Set-WritesMode -Setting $Writes
        Head "watchdog (Ctrl+C to stop)"
        $stopAt = $null
        if ($DurationSec -gt 0) { $stopAt = (Get-Date).AddSeconds($DurationSec) }
        while ($true) {
            $stamp = Get-Date -Format 'HH:mm:ss'
            $rt = Get-RuntimeInfo
            $alive = Test-GameProcess
            if ($alive -and $null -ne $rt -and (Test-GameProcess -ProcessId ([int]$rt.pid))) {
                $health = Get-BridgeHealth -RuntimeInfo $rt
                if ($null -ne $health) {
                    Info ("[" + $stamp + "] pid " + $rt.pid + " port " + $rt.port + " status=" + $health.status + " gameLoaded=" + $health.gameLoaded + " tick=" + $health.snapshotTick)
                }
                else { Warn ("[" + $stamp + "] pid " + $rt.pid + " alive but /health is not answering") }
            }
            elseif ($alive) { Warn ("[" + $stamp + "] DSPGAME is running but the bridge has not started yet") }
            else {
                Warn ("[" + $stamp + "] the game is not running")
                if ($AutoRestart) {
                    Info ("[" + $stamp + "] -AutoRestart: bringing it back up")
                    Invoke-Up -NeedSave ([bool]$RequireSave) | Out-Null
                }
            }
            if ($null -ne $stopAt -and (Get-Date) -ge $stopAt) { Info ("[" + $stamp + "] duration reached; stopping the watchdog (the game keeps running)"); break }
            Start-Sleep -Seconds $IntervalSec
        }
    }
}
