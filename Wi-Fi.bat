@echo off
setlocal DisableDelayedExpansion
pushd "%~dp0" || exit /b 1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File ".\Wi-Fi.ps1"
set "wifi_result=%errorlevel%"
popd
if not "%wifi_result%"=="0" pause
exit /b %wifi_result%
