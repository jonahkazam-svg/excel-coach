@echo off
REM Double-click to transcribe your most recent recording.
REM Or drag a recording file onto this .bat to transcribe that specific file.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0transcribe.ps1" -Audio "%~1"
echo.
pause
