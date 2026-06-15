@echo off
REM ===========================================================================
REM  Excel Coach launcher
REM  Installed to: %LOCALAPPDATA%\ExcelCoach\excel-coach.cmd
REM
REM  Responsibilities (in order):
REM    1. Ensure the WebView2 runtime is present; if not, run the bundled
REM       bootstrapper silently.
REM    2. On first run (no OPENAI_API_KEY in .env), run setup.ps1 -> Invoke-Setup.
REM    3. Launch the coach hidden (watch.ps1).
REM
REM  ASCII only. No external dependencies beyond Windows + PowerShell 5.1.
REM ===========================================================================

setlocal

REM --- Resolve the install directory (folder this script lives in) -----------
set "APPDIR=%~dp0"
REM Strip the trailing backslash for cleaner paths
if "%APPDIR:~-1%"=="\" set "APPDIR=%APPDIR:~0,-1%"

cd /d "%APPDIR%"

REM ===========================================================================
REM  1. WebView2 runtime check
REM     The Evergreen runtime registers its version under these registry keys.
REM     Per-machine (HKLM) on x64 lives under WOW6432Node; per-user under HKCU.
REM     If none of them have a non-empty "pv" value, install the runtime.
REM ===========================================================================
set "WV2GUID={F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
set "WV2FOUND="

for %%K in (
  "HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\%WV2GUID%"
  "HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\%WV2GUID%"
  "HKCU\SOFTWARE\Microsoft\EdgeUpdate\Clients\%WV2GUID%"
) do (
  for /f "tokens=3" %%V in ('reg query %%K /v pv 2^>nul ^| find "pv"') do (
    if not "%%V"=="" if not "%%V"=="0.0.0.0" set "WV2FOUND=1"
  )
)

if not defined WV2FOUND (
  if exist "%APPDIR%\MicrosoftEdgeWebView2RuntimeInstaller.exe" (
    echo Installing WebView2 runtime, please wait...
    "%APPDIR%\MicrosoftEdgeWebView2RuntimeInstaller.exe" /silent /install
  ) else (
    echo WARNING: WebView2 runtime not found and bootstrapper missing.
    echo The coach UI may not render. Continuing anyway...
  )
)

REM ===========================================================================
REM  2. First-run setup (bring-your-own-key)
REM     setup.ps1 exposes Test-FirstRun and Invoke-Setup. We ask Test-FirstRun;
REM     if it returns true, we run Invoke-Setup interactively so the user can
REM     enter their own OPENAI_API_KEY and pick a mic. setup.ps1 writes .env.
REM ===========================================================================
set "FIRSTRUN="
for /f "usebackticks" %%R in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%APPDIR%\tools\setup.ps1'; if (Test-FirstRun) { 'YES' } else { 'NO' }"`) do set "FIRSTRUN=%%R"

if "%FIRSTRUN%"=="YES" (
  echo First-run setup: enter your OpenAI API key.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%APPDIR%\tools\setup.ps1" -Command Invoke-Setup
  REM setup.ps1 is also runnable as: -File setup.ps1 then call Invoke-Setup.
  REM If -Command is not supported by setup.ps1, fall back to dot-source + call:
  if errorlevel 1 powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%APPDIR%\tools\setup.ps1'; Invoke-Setup"
)

REM ===========================================================================
REM  3. Launch the coach hidden
REM     -WindowStyle Hidden keeps the PowerShell host invisible; watch.ps1
REM     draws its own WebView2 strip/panel UI.
REM ===========================================================================
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APPDIR%\tools\watch.ps1"

endlocal
