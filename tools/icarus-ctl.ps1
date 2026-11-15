<#
    icarus-ctl.ps1 -- drive the in-game IcarusII chat from outside the game, unattended.

    WHY THIS EXISTS
      The sidecar only executes GAME tools through the real game connection. An external
      WebSocket client can chat, but cannot execute game tools (tools are routed to the
      client that owns the connection). So game actions must be typed into the in-game chat.
      This script does that with synthetic input: focus the game window, open the chat with
      the configured hotkey (default R), paste text from the clipboard, press Enter, then take
      a screenshot so the result can be inspected.

    MODES
      status        show DSPBridge discovery + /health, IcarusII sidecar discovery + /health,
                    and the recent [DspBridge]/[sidecar]/[confirm] log lines
      tool          send "<!tool Name ArgsJson>" into the chat (deterministic, no LLM, needs
                    DebugToolConsole=true in icarus-ii.cfg)
      talk          send a natural-language prompt (needs a configured API key; the AI may ask
                    for confirmation unless PermissionLevel=takeover)
      shot          save a PNG of the game window (delegates to dev-loop -Mode shot)
      click         click at physical pixel coordinates (-X -Y)
      key           press a virtual key (-VK, e.g. 13=Enter, 27=Esc, 82=R)
      focus         bring the game window to the foreground

    IMPORTANT
      * Requires DebugToolConsole=true for `tool` and PermissionLevel=takeover for `talk`
        writes; both are set by tools\install-r2modman-profile.ps1.
      * The chat must be CLOSED before `tool`/`talk` (the hotkey toggles). Close it with
        -Mode key -VK 27 (Esc) first if unsure.
      * Coordinates are physical pixels (the script makes itself DPI-aware).
      * ASCII only (PS 5.1 ANSI rule).

    EXAMPLES
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode status
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode tool -Name game_get_progress -ArgsJson "{}"
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode talk -Text "summarize power supply and demand on this planet"
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode key -VK 27
#>

param(
    [ValidateSet('status', 'tool', 'talk', 'shot', 'click', 'key', 'focus')]
    [string]$Mode = 'status',
    [string]$Name = '',
    [string]$ArgsJson = '{}',
    [string]$ArgsFile = '',
    [string]$Text = '',
    [int]$WaitMs = 12000,
    [int]$X = -1,
    [int]$Y = -1,
    [int]$VK = 0,
    [int]$KeyCode = 0x52,
    [switch]$ChatAlreadyOpen,
    [switch]$NoScreenshot,
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'

$gameDir = 'C:\Games\Steam\steamapps\common\Dyson Sphere Program'
if ($env:DSP_GAME_DIR) { $gameDir = $env:DSP_GAME_DIR }
$logPath = Join-Path $gameDir 'BepInEx\LogOutput.log'
$mcpRt = Join-Path $env:LOCALAPPDATA 'DSPBridge\runtime.json'
$icarusRt = Join-Path $env:APPDATA 'icarus-ii\runtime.json'

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class IcarusWin32 {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@
[void][IcarusWin32]::SetProcessDPIAware()

function Get-GameWindow {
    $p = @(Get-Process -Name 'DSPGAME' -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending)
    if ($p.Count -eq 0) { return $null }
    $h = $p[0].MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return $null }
    return @{ Handle = $h; Pid = $p[0].Id }
}

function Focus-Game {
    $w = Get-GameWindow
    if ($null -eq $w) { Write-Host 'FAIL: game is not running' -ForegroundColor Red; return $false }
    if ([IcarusWin32]::IsIconic($w.Handle)) { [void][IcarusWin32]::ShowWindow($w.Handle, 9) }
    [void][IcarusWin32]::SetForegroundWindow($w.Handle)
    Start-Sleep -Milliseconds 400
    return $true
}

function Send-Key([int]$code, [int]$holdMs = 60) {
    [IcarusWin32]::keybd_event([byte]$code, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds $holdMs
    [IcarusWin32]::keybd_event([byte]$code, 0, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 120
}

function Send-Paste([string]$text) {
    # STA is required for the WinForms clipboard; powershell.exe -File is STA by default.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::SetText($text)
    } catch {
        Set-Clipboard -Value $text
    }
    Start-Sleep -Milliseconds 200
    [IcarusWin32]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)   # Ctrl down
    Start-Sleep -Milliseconds 40
    [IcarusWin32]::keybd_event(0x56, 0, 0, [IntPtr]::Zero)   # V down
    Start-Sleep -Milliseconds 60
    [IcarusWin32]::keybd_event(0x56, 0, 2, [IntPtr]::Zero)   # V up
    Start-Sleep -Milliseconds 40
    [IcarusWin32]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)   # Ctrl up
    Start-Sleep -Milliseconds 200
}

function Save-Shot([string]$path) {
    $w = Get-GameWindow
    if ($null -eq $w) { Write-Host 'FAIL: game is not running' -ForegroundColor Red; return $null }
    $r = New-Object 'IcarusWin32+RECT'
    [void][IcarusWin32]::GetWindowRect($w.Handle, [ref]$r)
    $bmp = New-Object Drawing.Bitmap ($r.Right - $r.Left), ($r.Bottom - $r.Top)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [IcarusWin32]::PrintWindow($w.Handle, $hdc, 2)
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("shot: " + $path + "  (PrintWindow=" + $ok + ")")
    return $path
}

function Send-Chat([string]$text, [int]$waitMs) {
    if (-not (Focus-Game)) { exit 2 }
    if (-not $ChatAlreadyOpen) {
        Send-Key $KeyCode 80          # hotkey R: open chat
        Start-Sleep -Milliseconds 700
        Send-Key 13 60                # Enter: focus the input box (AutoFocusInput=false)
        Start-Sleep -Milliseconds 250
    }
    Send-Paste $text
    Send-Key 13 60                    # Enter: send
    Start-Sleep -Milliseconds $waitMs
}

function Show-Status {
    Write-Host '=== DSPBridge ==='
    if (Test-Path $mcpRt) {
        $j = Get-Content $mcpRt -Raw -Encoding UTF8 | ConvertFrom-Json
        $alive = [bool](Get-Process -Id $j.pid -ErrorAction SilentlyContinue)
        Write-Host ("  runtime.json pid=" + $j.pid + " port=" + $j.port + " alive=" + $alive)
        if ($alive) {
            try {
                $h = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $j.port + "/health") -Headers @{ Authorization = 'Bearer ' + $j.token } -TimeoutSec 5
                Write-Host ("  /health: " + ($h | ConvertTo-Json -Compress))
            } catch { Write-Host ('  /health failed: ' + $_.Exception.Message) }
        }
    } else { Write-Host '  no runtime.json (bridge not running)' }

    Write-Host '=== IcarusII sidecar ==='
    if (Test-Path $icarusRt) {
        $s = Get-Content $icarusRt -Raw -Encoding UTF8 | ConvertFrom-Json
        $alive2 = [bool](Get-Process -Id $s.pid -ErrorAction SilentlyContinue)
        Write-Host ("  runtime.json pid=" + $s.pid + " port=" + $s.port + " version=" + $s.version + " alive=" + $alive2)
        try {
            $r = Invoke-WebRequest -Uri ("http://127.0.0.1:" + $s.port + "/health") -UseBasicParsing -TimeoutSec 5
            Write-Host ("  /health: " + $r.Content)
        } catch { Write-Host ('  /health failed: ' + $_.Exception.Message) }
    } else { Write-Host '  no runtime.json (sidecar not running)' }

    Write-Host '=== log tail ==='
    if (Test-Path $logPath) {
        Get-Content $logPath -Encoding UTF8 | Select-String -Pattern '\[DspBridge\]|\[sidecar\]|\[confirm\]|\[tool\] done|verif|permission' | Select-Object -Last 15 | ForEach-Object { '  ' + $_.Line }
    } else { Write-Host '  no LogOutput.log' }
}

switch ($Mode) {
    'status' { Show-Status }
    'focus'  { if (-not (Focus-Game)) { exit 2 }; Write-Host 'game focused' }
    'shot' {
        $path = $Out
        if (-not $path) { $path = Join-Path (Split-Path $PSScriptRoot -Parent) ('logs\icarus-shot-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.png') }
        [void](Save-Shot $path)
    }
    'click' {
        if ($X -lt 0 -or $Y -lt 0) { Write-Host 'FAIL: click needs -X -Y' -ForegroundColor Red; exit 2 }
        if (-not (Focus-Game)) { exit 2 }
        [void][IcarusWin32]::SetCursorPos($X, $Y)
        Start-Sleep -Milliseconds 120
        [IcarusWin32]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 70
        [IcarusWin32]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 300
        Write-Host ("clicked " + $X + "," + $Y)
    }
    'key' {
        $code = $VK
        if ($code -le 0) { $code = 13 }
        if (-not (Focus-Game)) { exit 2 }
        Send-Key $code
        Write-Host ("sent VK " + $code)
    }
    'tool' {
        if ([string]::IsNullOrWhiteSpace($Name)) { Write-Host 'FAIL: tool needs -Name' -ForegroundColor Red; exit 2 }
        $json = $ArgsJson
        if (-not [string]::IsNullOrWhiteSpace($ArgsFile)) {
            if (-not (Test-Path $ArgsFile)) { Write-Host ('FAIL: args file not found: ' + $ArgsFile) -ForegroundColor Red; exit 2 }
            $json = ([System.IO.File]::ReadAllText($ArgsFile, [System.Text.Encoding]::UTF8)).Trim()
        }
        $cmd = '!tool ' + $Name + ' ' + $json
        Write-Host ('sending: ' + $cmd)
        Send-Chat -text $cmd -waitMs $WaitMs
        if (-not $NoScreenshot) {
            $path = $Out
            if (-not $path) { $path = Join-Path (Split-Path $PSScriptRoot -Parent) ('logs\icarus-tool-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.png') }
            [void](Save-Shot $path)
        }
    }
    'talk' {
        if ([string]::IsNullOrWhiteSpace($Text)) { Write-Host 'FAIL: talk needs -Text' -ForegroundColor Red; exit 2 }
        Write-Host ('sending prompt: ' + $Text)
        Send-Chat -text $Text -waitMs $WaitMs
        if (-not $NoScreenshot) {
            $path = $Out
            if (-not $path) { $path = Join-Path (Split-Path $PSScriptRoot -Parent) ('logs\icarus-talk-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.png') }
            [void](Save-Shot $path)
        }
    }
}
