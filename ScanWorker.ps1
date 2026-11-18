param([string] $DiagnosticsScript, [string] $NativeSource, [bool] $ActiveScan, [bool] $DiagnosticsOnly = $false)
$ErrorActionPreference = 'Stop'
. $DiagnosticsScript

function Invoke-Netsh([string] $Arguments) {
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'netsh.exe'
    $process.StartInfo.Arguments = $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $codePage = [Globalization.CultureInfo]::InstalledUICulture.TextInfo.OEMCodePage
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::GetEncoding($codePage)
    try {
        [void] $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(7000)) {
            $process.Kill()
            throw 'Сканирование Wi-Fi не ответило вовремя.'
        }
        [pscustomobject] @{
            Code = $process.ExitCode
            Text = $stdout.GetAwaiter().GetResult()
            ErrorText = $stderr.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Get-DiagnosticsOnlyResult {
    $diagnostics = try { Get-WifiDiagnostics } catch { $null }
    [pscustomobject] @{ ScanBlocked = $true; Diagnostics = $diagnostics }
}

if ($DiagnosticsOnly) { return (Get-DiagnosticsOnlyResult) }

$nativeDenied = $false
$radio = try {
    if (-not ('WiFi.NativeScanner' -as [type])) { Add-Type -Path $NativeSource -ErrorAction Stop }
    $wait = if ($ActiveScan) { 4000 } else { 0 }
    [WiFi.NativeScanner]::Scan($wait)
} catch {
    $errorCause = $_.Exception.GetBaseException()
    $nativeDenied = $errorCause -is [ComponentModel.Win32Exception] -and $errorCause.NativeErrorCode -eq 5
    $null
}
if ($radio) {
    $diagnostics = try { Get-WifiDiagnostics } catch { $null }
    return [pscustomobject] @{ Native = $radio; Diagnostics = $diagnostics }
}

$networks = Invoke-Netsh 'wlan show networks mode=bssid'
$output = $networks.Text + ' ' + $networks.ErrorText
$permissionMessage = $output -match '(?i)location|местоположени|расположени|access (?:is )?denied|отказано в доступе|elevation|повышени.+прав'
$hasScanRows = $networks.Text -match '(?m)^\s*SSID\s+\d+\s*:'
if (($permissionMessage -or $nativeDenied) -and ($networks.Code -ne 0 -or -not $hasScanRows)) {
    return (Get-DiagnosticsOnlyResult)
}
if ($output -match '(?i)(?:not running|не запущена|не запущен|no wireless interface|беспроводн\w+ интерфейс\w+ отсутств|нет беспроводн|не найдено беспроводн)') {
    throw 'Адаптер Wi-Fi недоступен. Проверь, включены ли адаптер и служба WLAN.'
}
if ($networks.Code -ne 0) {
    throw "Windows не завершила сканирование (код $($networks.Code))."
}
$interfaces = Invoke-Netsh 'wlan show interfaces'
$diagnostics = try { Get-WifiDiagnostics } catch { $null }
[pscustomobject] @{ Networks = $networks.Text; Interfaces = $interfaces.Text; Diagnostics = $diagnostics }
