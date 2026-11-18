# Pure helpers for adaptive scans, permission guidance and spectral evidence.
function Get-WifiScanInterval([bool]$Blocked,[bool]$Issue,[bool]$Incident,[bool]$Stable,[int]$FailureCount) {
    if ($Blocked) { return 120000 }
    if ($Issue) { return [Math]::Min(120000,30000*[Math]::Pow(2,[Math]::Min(2,[Math]::Max(0,$FailureCount)))) }
    if ($Incident) { return 20000 }
    if ($Stable) { return 60000 }
    return 30000
}
function Get-WifiPermissionGuidance([bool]$Blocked,[string]$Issue) {
    if (-not $Blocked) {
        return [pscustomobject]@{status='not-blocked';reason='Нет подтверждённого запрета сканирования.';steps=@()}
    }
    [pscustomobject]@{
        status='scan-restricted'
        reason='Сканирование ограничено Windows. По одному сообщению нельзя точно определить системный переключатель.'
        steps=@(
            'Windows: Параметры → Конфиденциальность и безопасность → Расположение (в Windows 10: Конфиденциальность → Расположение).',
            'Включи службы определения местоположения и доступ для классических приложений, если эти параметры доступны.',
            'Проверь, что Wi-Fi включён, драйвер адаптера установлен и служба WLAN AutoConfig работает.',
            'Вернись в Wi-Fi и нажми обновление. Изменять настройки безопасности автоматически программа не будет.'
        )
    }
}
function Get-WifiAdapterSummary($Adapter) {
    if (-not $Adapter) {
        return [pscustomobject]@{status='unknown';name='';description='';speedMbps=$null;bands='unknown';driver='not-verified'}
    }
    [pscustomobject]@{
        status='detected'
        name=[string]$Adapter.Name
        description=[string]$Adapter.Description
        speedMbps=$(if([long]$Adapter.Speed -gt 0){[Math]::Round([double]$Adapter.Speed / 1000000,0)})
        bands='not-verified'
        driver='not-verified'
    }
}
function Get-WifiScanConfidence([string]$Source,[bool]$Completed,[long]$ScanAt,[long]$Now,[int]$FreshPoints) {
    $age=$Now-$ScanAt
    if ($ScanAt -le 0 -or $age -lt 0 -or $age -gt 45000) { return 'stale-or-missing' }
    if ($Source -eq 'Windows WLAN' -and $Completed -and $FreshPoints -gt 0) { return 'observed' }
    if ($Source -eq 'Windows WLAN') { return 'cached-or-incomplete' }
    if ($Source -eq 'netsh') { return 'unverified-cache' }
    return 'unverified'
}
function Get-WifiInterferenceEvidence([object[]]$Points,[string]$Band) {
    $valid=@($Points | Where-Object {$_ -and $_.Band -eq $Band -and $_.Fresh -ne $false -and -not $_.Own})
    $rows=@()
    foreach($point in $valid) {
        $strength=[Math]::Min(100.0,[Math]::Max(0.0,[double]$point.Signal))
        $width=$(if($point.RadioWidth -and $point.RadioWidth.Width){[int]$point.RadioWidth.Width}else{0})
        $rows += [pscustomobject]@{
            channel=[int]$point.Channel
            signal=$strength
            widthMhz=$width
            widthConfirmed=[bool]($width -gt 0)
            # The channel score already factors overlap geometry; this is evidence, not measured airtime.
            estimatedImpact=[Math]::Round($strength*$strength/100.0,1)
        }
    }
    [pscustomobject]@{
        band=$Band; neighborCount=$rows.Count
        strongest=@($rows | Sort-Object estimatedImpact -Descending | Select-Object -First 5)
        method='RSSI/signal and channel geometry estimate; not measured spectrum utilization'
    }
}
function Get-WifiRecommendationConfidence($Guard,[string]$ScanConfidence,[int]$IndependentSurveys) {
    $ok=[bool]($Guard -and $Guard.eligible -and $ScanConfidence -eq 'observed' -and $IndependentSurveys -ge 3)
    [pscustomobject]@{
        eligible=$ok
        confidence=$(if($ok){'medium'}else{'low'})
        reason=$(if($ok){'Можно рассмотреть ручное испытание; результат не гарантирован.'}else{'Недостаточно независимых свежих измерений для испытания канала.'})
        automaticChange=$false
    }
}
