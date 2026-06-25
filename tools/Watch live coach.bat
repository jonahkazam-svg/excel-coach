@echo off
rem Routed through the robust launcher so it always clears a stuck instance and starts fresh.
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Launch-Coach.ps1"
