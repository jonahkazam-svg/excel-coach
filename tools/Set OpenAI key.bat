@echo off
title Set OpenAI key
echo.
echo  Paste your OpenAI API key below, then press Enter.
echo  (Right-click in this window to paste.)
echo.
set /p "KEY=  Key: "
if "%KEY%"=="" ( echo. & echo  Nothing entered - not saved. & echo. & pause & exit /b )
> "%~dp0..\.env" echo OPENAI_API_KEY=%KEY%
echo.
echo  Saved. Close this window and tell Claude "go".
echo.
pause
