# Optional read-only router telemetry adapter. No undocumented API requests or mutations.
# An authenticated RE3L export can be placed in %LOCALAPPDATA%\Wi Fi\router-telemetry.json.
# The program never treats manually supplied or calculated values as measured airtime.
function Get-ValidatedRouterTelemetry($Data, [string] $ExpectedAddress, [long] $Now) {
    if (-not $Data -or -not $ExpectedAddress -or [string] $Data.routerAddress -ne $ExpectedAddress) { return $null }
    if ([string] $Data.model -cne 'RE3L') { return $null }
    $captured = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string] $Data.capturedAt, [ref] $captured)) { return $null }
    $age = $Now - $captured.ToUnixTimeMilliseconds()
    if ($age -lt 0 -or $age -gt 60000) { return $null }
    $points = @()
    foreach ($entry in @($Data.networks)) {
        if (-not $entry) { continue }
        $band = [string] $entry.band
        $channel = 0
        $rssi = 0
        if (-not [int]::TryParse([string] $entry.channel, [ref] $channel)) { continue }
        if (-not [int]::TryParse([string] $entry.rssi, [ref] $rssi)) { continue }
        if (($band -eq '2.4' -and ($channel -lt 1 -or $channel -gt 13)) -or
            ($band -eq '5' -and ($channel -lt 36 -or $channel -gt 165)) -or
            ($band -notin @('2.4','5')) -or $rssi -gt -1 -or $rssi -lt -110) { continue }
        if ([string] $entry.bssid -notmatch '^(?i:[0-9a-f]{2}:){5}(?i:[0-9a-f]{2})$') { continue }
        $width = 0
        if (-not [int]::TryParse([string] $entry.widthMhz, [ref] $width)) { $width = 0 }
        if ($width -notin @(0,20,40,80,160)) { $width = 0 }
        $signal = [int] [Math]::Min(100, [Math]::Max(0, 2 * ($rssi + 100)))
        $frequency = if ($band -eq '2.4') { 2407 + 5 * $channel } else { 5000 + 5 * $channel }
        $points += [pscustomobject] @{
            SSID = [string] $entry.ssid; BSSID = ([string] $entry.bssid).ToLowerInvariant()
            Band = $band; Channel = $channel; Rssi = $rssi; Signal = $signal
            Frequency = $frequency; RadioWidth = $null
            ObservedAt = $captured.ToUnixTimeMilliseconds(); Fresh = $true
            Source = 'router-export'; Own = [bool] $entry.own
        }
        if ($points.Count -ge 200) { break }
    }
    $airtime = @()
    foreach ($entry in @($Data.airtime)) {
        if (-not $entry -or [string] $entry.source -ne 'radio-airtime-counter') { continue }
        $busy = 0.0
        $ch = 0
        if (-not [double]::TryParse(([string] $entry.busyPercent).Replace(',', '.'), [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref] $busy)) { continue }
        if (-not [int]::TryParse([string] $entry.channel, [ref] $ch)) { continue }
        if ($busy -lt 0 -or $busy -gt 100 -or [string] $entry.band -notin @('2.4','5')) { continue }
        $airtime += [pscustomobject] @{ band = [string] $entry.band; channel = $ch; busyPercent = [Math]::Round($busy,1); source = 'router-export/unverified-counter' }
    }
    [pscustomobject] @{
        address = $ExpectedAddress; model = 'RE3L'; firmware = [string] $Data.firmware
        capturedAt = $captured.ToUnixTimeMilliseconds(); points = @($points); airtime = @($airtime)
        source = 'router-export'; trustedLive = $false
    }
}

function Read-RouterTelemetry([string] $Path, [string] $ExpectedAddress, [long] $Now) {
    if (-not $ExpectedAddress -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -gt 262144) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $data = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        Get-ValidatedRouterTelemetry $data $ExpectedAddress $Now
    } catch { return $null }
}

function Get-WifiRecommendationEvidence($Plan, $Latency, $RouterTelemetry) {
    $reasons = @()
    $confidence = 'low'
    if ($Plan -and $Plan.Improves -and $Plan.Home -and $Plan.Best) {
        $reasons += ('Расчёт пересечений: {0} → {1}' -f $Plan.Current.Score, $Plan.Best.Score)
        if ($Plan.Current.Width -and $Plan.Best.Width) {
            $reasons += ('Ширина: {0} → {1} МГц' -f $Plan.Current.Width, $Plan.Best.Width)
        }
        if ($Plan.TrialSupport -and $Plan.TrialSupport.Wins -gt $Plan.TrialSupport.Losses) {
            $reasons += 'Положительная история прежних испытаний'
        }
    }
    if ($Latency -and $Latency.Samples -ge 20) {
        if ($Latency.Classification -eq 'local') {
            $reasons += ('Проблемы до шлюза: {0} из {1}' -f $Latency.LocalBad, $Latency.Samples)
            $confidence = 'medium'
        } elseif ($Latency.Classification -eq 'external') {
            $reasons += 'Сбои только во внешнем маршруте: смена канала не обоснована'
        } else { $reasons += 'Стабильная или неясная локальная связь' }
    } else { $reasons += 'Для оценки реальных задержек недостаточно проб' }
    if ($RouterTelemetry -and @($RouterTelemetry.airtime).Count) {
        $reasons += 'Показатели эфирного времени получены из импорта; их достоверность не проверена'
    } else { $reasons += 'Измеренная загрузка эфира недоступна (пересечения являются оценкой)' }
    [pscustomobject] @{ reasons = @($reasons); confidence = $confidence; measuredAirtime = $false }
}

# Safety policy: hardware changes require an independently tested, reversible driver.
# This build has no verified RE3L driver, so it never changes a channel automatically.
function Get-RouterAutomationPolicy($Router, $Telemetry) {
    [pscustomobject] @{
        enabled = $false
        writeSupported = $false
        rollbackSupported = $false
        reason = 'Автопереключение и откат отключены: API записи, проверка канала и восстановление RE3L не подтверждены.'
        cooldownSeconds = 3600
        requiresVerifiedDriver = $true
        requiresConfirmedFreshMeasurements = $true
    }
}
