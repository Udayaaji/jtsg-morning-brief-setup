@echo off
echo Starting today's Morning Brief in the background. It takes 10 to 30 minutes.
echo A notification appears when it is ready, or when it could not be produced.
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0jtsg_launcher.ps1"
timeout /t 5 >nul
