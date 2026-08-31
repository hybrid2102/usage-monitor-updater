@echo off
REM Double-click launcher for Update-UsageMonitor.ps1.
REM
REM -ExecutionPolicy Bypass applies to THIS process only: it does not change any
REM machine or user setting, and exists so the script runs on default Windows
REM installations, where the policy is Restricted. Read the .ps1 first if you
REM downloaded this from the internet - it is plain text and does exactly what
REM the README describes.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-UsageMonitor.ps1" %*
echo.
pause
