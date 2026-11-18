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


function Get-WifiHourlyNeighborDensity($Db,[long]$Now,[object[]]$HourlyQuality) {
    if (-not $Db) {return @()}
    $rows=$Db.Query(@'
SELECT CAST(at_ms / 3600000 AS INTEGER), observed_points
FROM radio_scans
WHERE at_ms >= ? AND at_ms <= ?
ORDER BY at_ms DESC LIMIT 240
'@,@(($Now-48L*3600000),$Now))
    $groups=@{}
    foreach($row in @($rows)) {
        try {
            $points=@(ConvertFrom-Json -InputObject ([string]$row[1]) -ErrorAction Stop)
            foreach($band in @('2.4','5')) {
                $neighbors=@($points | Where-Object {$_.Band -eq $band -and -not $_.Own -and $_.Fresh -ne $false -and $_.BSSID} |
                    Group-Object BSSID)
                $key='{0}|{1}' -f $row[0],$band
                if(-not $groups.ContainsKey($key)) {
                    $groups[$key]=[pscustomobject]@{
                        hourUtc=([DateTimeOffset]::FromUnixTimeMilliseconds([long]$row[0]*3600000)).ToString('yyyy-MM-dd HH:mm')
                        band=$band;scans=0;sum=0;max=0
                    }
                }
                $group=$groups[$key]
                $group.scans++
                $group.sum+=$neighbors.Count
                $group.max=[Math]::Max($group.max,$neighbors.Count)
            }
        } catch {continue}
    }
    $result=@()
    foreach($group in $groups.Values) {
        if($group.scans -lt 2) {continue}
        $matching=@($HourlyQuality | Where-Object {$_.band -eq $group.band -and $_.hourUtc -eq $group.hourUtc -and $_.samples -ge 10})
        $quality=$(if($matching.Count){[Math]::Round([double](@($matching | Measure-Object badPercent -Average)[0].Average),1)}else{$null})
        $result += [pscustomobject]@{
            hourUtc=$group.hourUtc;band=$group.band;scans=$group.scans
            averageNeighbors=[Math]::Round($group.sum/$group.scans,1)
            maxNeighbors=$group.max;localBadPercent=$quality
            correlation='unverified'
        }
    }
    @($result | Sort-Object hourUtc -Descending | Select-Object -First 30)
}
