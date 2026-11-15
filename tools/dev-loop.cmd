@echo off
rem =====================================================================================
rem  dev-loop.cmd -- double-clickable / client-callable wrapper for tools\dev-loop.ps1.
rem
rem  The package's scripts must be called with -ExecutionPolicy Bypass because this
rem  machine's PowerShell may refuse to run unsigned scripts. This wrapper does that so
rem  the hands-off loop is one word: "dev-loop up" / "dev-loop cycle" / "dev-loop log".
rem
rem  Usage:
rem    dev-loop.cmd status
rem    dev-loop.cmd up
rem    dev-loop.cmd cycle
rem    dev-loop.cmd log -Lines 200 -Filter DspBridge
rem    (no argument == status)
rem =====================================================================================
setlocal
set "HERE=%~dp0"
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%dev-loop.ps1" -Mode status
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%dev-loop.ps1" -Mode %*
)
exit /b %ERRORLEVEL%
