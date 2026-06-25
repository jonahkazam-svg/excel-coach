@echo off
title Excel Coach
rem One-click launcher. On FIRST run (no API key set yet) it prompts you for your OpenAI key,
rem then always clears any stuck/old instance and starts a fresh coach. Safe to double-click anytime.
if not exist "%~dp0.env" goto :setkey
findstr /I /C:"OPENAI_API_KEY=sk-" "%~dp0.env" >nul 2>&1 && goto :launch
:setkey
echo.
echo  Welcome to Excel Coach. First, set your OpenAI API key (one time).
echo  Get one at https://platform.openai.com/api-keys
echo.
call "%~dp0tools\Set OpenAI key.bat"
echo.
:launch
echo Starting Excel Coach...
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tools\Launch-Coach.ps1"
