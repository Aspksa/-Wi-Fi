@echo off
setlocal DisableDelayedExpansion
pushd "%~dp0" || exit /b 1
set "wifi_entry=.\Wi-Fi.ps1"
if /i "%~1"=="web" set "wifi_entry=.\Wi-Fi-Web.ps1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%wifi_entry%"
set "wifi_result=%errorlevel%"
popd
if not "%wifi_result%"=="0" pause
exit /b %wifi_result%
