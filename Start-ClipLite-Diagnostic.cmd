@echo off
setlocal
cd /d "%~dp0"
echo ClipLite diagnostic startup - no policy changes
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Get-ExecutionPolicy -List; $ExecutionContext.SessionState.LanguageMode"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -File "%~dp0ClipLite.ps1"
echo Review messages above. Contact your administrator if blocked.
pause
endlocal
