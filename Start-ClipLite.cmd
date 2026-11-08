@echo off
setlocal
cd /d "%~dp0"
rem Respect existing execution policy; never change user settings.
start "ClipLite" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -WindowStyle Hidden -File "%~dp0ClipLite.ps1"
endlocal
