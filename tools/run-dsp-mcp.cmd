@echo off
rem =====================================================================================
rem  run-dsp-mcp.cmd -- launch the DSP MCP server over stdio.
rem
rem  This is what an MCP client should point at (NOT "dotnet run --project"): dotnet run
rem  needs MSBuild, NuGet restore and a writable package cache at launch time. Running the
rem  prebuilt dll keeps startup fast and independent of the user profile.
rem
rem  PORTABLE: %~dp0 is this script's own folder, so the whole tree can be moved anywhere.
rem
rem  Two supported layouts:
rem    * portable: tools\dotnet-sdk\dotnet.exe exists (offline bundle) -> its env is redirected
rem      into the tree so a read-only user profile does not matter;
rem    * system:   no portable SDK -> a dotnet found on PATH is used as-is.
rem
rem  STDOUT IS THE JSON-RPC CHANNEL. Nothing in this script may echo to stdout;
rem  every diagnostic goes to stderr via 1>&2.
rem =====================================================================================
setlocal

set "ROOT=%~dp0"
set "DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1"
set "DOTNET_NOLOGO=1"
set "DOTNET_CLI_TELEMETRY_OPTOUT=1"

set "DOTNET_EXE="
if exist "%ROOT%dotnet-sdk\dotnet.exe" (
  set "DOTNET_EXE=%ROOT%dotnet-sdk\dotnet.exe"
  set "DOTNET_ROOT=%ROOT%dotnet-sdk"
  set "DOTNET_CLI_HOME=%ROOT%dotnet-home"
  set "NUGET_PACKAGES=%ROOT%nuget-packages"
  set "TMP=%ROOT%tmp"
  set "TEMP=%ROOT%tmp"
  set "APPDATA=%ROOT%appdata"
  set "LOCALAPPDATA=%ROOT%localappdata"
)

if not defined DOTNET_EXE (
  for /f "delims=" %%D in ('where dotnet 2^>nul') do (
    if not defined DOTNET_EXE set "DOTNET_EXE=%%D"
  )
)

if not defined DOTNET_EXE (
  echo [run-dsp-mcp] dotnet not found: extract the portable SDK into tools\dotnet-sdk, or install the .NET SDK and make sure dotnet is on PATH 1>&2
  exit /b 1
)

set "DLL=%ROOT%..\DspMcpBridge\bin\Release\net10.0\DspMcpBridge.dll"
if not exist "%DLL%" set "DLL=%ROOT%..\DspMcpBridge\bin\Release\DspMcpBridge.dll"
if not exist "%DLL%" (
  echo [run-dsp-mcp] DspMcpBridge.dll not found under %ROOT%..\DspMcpBridge\bin\Release 1>&2
  echo [run-dsp-mcp] Build it first, from the repo root: 1>&2
  echo [run-dsp-mcp]   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-and-deploy.ps1 -Project DspMcpBridge\DspMcpBridge.csproj 1>&2
  exit /b 1
)

"%DOTNET_EXE%" "%DLL%" %*
exit /b %ERRORLEVEL%
