# Wi-Fi v2.2: evidence and safety; no router mutations.
function Get-Re3lCaptureAssessment($Capture, [string] $ExpectedFirmware) {
    if (-not $Capture -or $Capture.status -ne 'inspection-only') {
        return [pscustomobject] @{ status='unverified'; firmwareMatched=$false; endpoints=@(); readReady=$false; writeReady=$false; rollbackReady=$false; reason='Нет подтверждённого журнала функций RE3L.' }
    }
    $endpoints = @($Capture.entries | Where-Object { $_.method -eq 'GET' -and $_.status -eq 200 -and -not $_.usable })
    # A sanitized request list does not prove JSON structure, authorization, or firmware compatibility.
    [pscustomobject] @{
        status='capture-only'; firmwareMatched=$false; endpoints=@($endpoints | Select-Object -First 25)
        readReady=$false; writeReady=$false; rollbackReady=$false
        reason='Наблюдённые GET-запросы не подтверждают структуру ответа и права чтения; требуется проверка на устройстве.'
    }
}

function Get-WifiRecommendationGuard($Plan, $LatencyEvidence, $Trend, [string] $Source,
        [long] $ScanAt, [long] $Now, [bool] $Confirmed) {
    $reasons = @()
    $canSuggest = $true
    if (-not $Plan -or -not $Plan.Home -or -not $Plan.Improves) {
        $reasons += 'Нет доказанного кандидата с выигрышем по расчёту пересечений.'
        $canSuggest = $false
    }
    if ($Source -ne 'Windows WLAN' -or $ScanAt -le 0 -or $Now - $ScanAt -gt 45000 -or $Now -lt $ScanAt) {
        $reasons += 'Нет свежего подтверждённого снимка от Windows WLAN.'
        $canSuggest = $false
    }
    if (-not $Confirmed) {
        $reasons += 'Выигрыш не подтверждён независимыми снимками эфира.'
        $canSuggest = $false
    }
    if (-not $LatencyEvidence -or $LatencyEvidence.Samples -lt 20) {
        $reasons += 'Недостаточно контрольных измерений задержки и потерь.'
        $canSuggest = $false
    } elseif ($LatencyEvidence.Classification -eq 'external') {
        $reasons += 'Проблема обнаружена только на внешнем маршруте.'
        $canSuggest = $false
    } elseif ($LatencyEvidence.Classification -ne 'local') {
        $reasons += 'Нет подтверждённого ухудшения локального соединения.'
        $canSuggest = $false
    }
    if ($Trend -and $Trend.status -eq 'improving') {
        $reasons += 'Связь уже улучшается: изменение канала преждевременно.'
        $canSuggest = $false
    }
    [pscustomobject] @{
        eligible=$canSuggest
        label=$(if ($canSuggest) { 'Кандидат для ручного испытания' } else { 'Только наблюдение' })
        reasons=@($reasons)
        automatedChangeAllowed=$false
        recommendationSource='local-measurements-and-observed-spectrum'
    }
}

function Get-WifiRepeatedHourlyIssues([object[]] $History) {
    $groups=@($History | Where-Object {
        $_ -and $_.samples -ge 10 -and $_.badPercent -ge 15 -and $_.hourUtc -and
        $_.band -in @('2.4','5')
    } | Group-Object { '{0}|{1}|{2}' -f $_.band,$_.channel,([string]$_.hourUtc).Substring(11,2) })
    $patterns=@()
    foreach($group in $groups) {
        $days=@($group.Group | ForEach-Object { ([string] $_.hourUtc).Substring(0,10) } | Sort-Object -Unique)
        if($days.Count -lt 2) { continue }
        $first=$group.Group[0]
        $patterns += [pscustomobject] @{
            band=$first.band;channel=[int]$first.channel;hourUtc=([string]$first.hourUtc).Substring(11,2)
            days=$days.Count;reason='Повторяющиеся проблемные часы по сохранённым измерениям; причина не установлена.'
        }
    }
    @($patterns | Sort-Object days -Descending | Select-Object -First 8)
}

function Get-WifiObservedSource($Source, $Telemetry, [long]$Now) {
    if ($Source -eq 'Windows WLAN') {
        return [pscustomobject] @{ kind='measured'; radioSurvey='observed-networks'; airtime='not-measured'; label='Windows WLAN: измерены точки доступа, занятость эфира не измерена' }
    }
    if ($Source -eq 'router-export' -and $Telemetry -and $Now - $Telemetry.capturedAt -ge 0 -and $Now - $Telemetry.capturedAt -le 60000) {
        return [pscustomobject] @{ kind='unverified-import'; radioSurvey='router-export'; airtime='unverified-claim'; label='Импорт панели RE3L: происхождение аппаратных счётчиков не подтверждено' }
    }
    [pscustomobject] @{ kind='unavailable'; radioSurvey='unknown'; airtime='not-measured'; label='Нет проверенного свежего сканирования радиоэфира' }
}

function Get-Re3lSafeWritePolicy($Router, $Capture) {
    # Do not implement change/rollback requests without a certified, device-tested driver.
    [pscustomobject] @{
        enabled=$false; writeSupported=$false; rollbackSupported=$false
        needsFirmwareMatch=$true; needsPhysicalVerification=$true
        userConfirmationRequired=$true; cooldownSeconds=3600
        lastKnownGoodRequired=$true; state='locked'
        reason='Запись и откат RE3L недоступны: нет подтверждённого API, прав и испытанного восстановления.'
    }
}
