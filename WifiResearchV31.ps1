# Evidence-first local investigations; never treats an SSID match as proof of an attack.
function New-WifiResearchMemory {
    @{ByBssid=@{};Changes=@();Incidents=@();Alerts=@();LastNoticeAt=0L}
}
function Update-WifiResearchMemory($Memory,[object[]]$Points,[long]$At,[bool]$Verified) {
    if(-not $Memory -or -not $Verified -or $At -le 0){return}
    foreach($point in @($Points | Where-Object {
        $_.Fresh -ne $false -and $_.BSSID -match '^(?i:[0-9a-f]{2}:){5}(?i:[0-9a-f]{2})$'
    } | Select-Object -First 500)){
        $key=([string]$point.BSSID).ToLowerInvariant()
        $gen=$(if($point.Capabilities){[string]$point.Capabilities.Generation}else{'unverified'})
        $secure=$(if($point.Capabilities){[bool]$point.Capabilities.Rsn}else{$null})
        $prev=$Memory.ByBssid[$key]
        $signature=[pscustomobject]@{
            ssid=[string]$point.SSID;channel=[int]$point.Channel
            band=[string]$point.Band;generation=$gen;rsn=$secure
            rssi=$point.Rssi;at=$At
        }
        if($prev -and $At -gt [long]$prev.at){
            $changes=@()
            if($prev.generation -ne $gen -and $prev.generation -ne 'unverified' -and $gen -ne 'unverified'){$changes+='advertised-generation'}
            if($null -ne $secure -and $null -ne $prev.rsn -and $prev.rsn -ne $secure){$changes+='advertised-rsn'}
            if($prev.channel -ne $point.Channel){$changes+='channel'}
            if($null -ne $point.Rssi -and $null -ne $prev.rssi -and [Math]::Abs([int]$point.Rssi-[int]$prev.rssi) -gt 18){$changes+='rssi-jump'}
            if($changes.Count){
                $Memory.Changes=@([pscustomobject]@{
                    at=$At;bssid=$key;ssid=[string]$point.SSID
                    changes=@($changes);classification='unverified-configuration-or-radio-change'
                })+@($Memory.Changes | Select-Object -First 31)
            }
        }
        if(-not $prev -or $At -gt [long]$prev.at){$Memory.ByBssid[$key]=$signature}
    }
    if($Memory.ByBssid.Count -gt 500){
        foreach($key in @($Memory.ByBssid.Keys | Sort-Object {$Memory.ByBssid[$_].at} |
            Select-Object -First ($Memory.ByBssid.Count-500))){$Memory.ByBssid.Remove($key)}
    }
}
function Add-WifiInvestigation($Memory,[long]$Now,[string]$Category,
    [object[]]$Points,[object[]]$Latency) {
    if(-not $Memory){return}
    $recent=@($Latency | Where-Object {$Now-[long]$_.at -ge 0 -and $Now-[long]$_.at -le 60000})
    $record=[pscustomobject]@{
        at=$Now;category=$Category
        visibleNeighbors=@($Points | Where-Object {$_.Fresh -ne $false -and -not $_.Own}).Count
        localLoss=@($recent | Where-Object {$_.lost}).Count
        slowProbes=@($recent | Where-Object {$null -ne $_.ms -and $_.ms -gt 35}).Count
        source='local-window';cause='unverified'
    }
    $Memory.Incidents=@($record)+@($Memory.Incidents | Select-Object -First 31)
    if($Now -ge [long]$Memory.LastNoticeAt -and
        ($Memory.LastNoticeAt -eq 0 -or $Now-[long]$Memory.LastNoticeAt -ge 300000)){
        $Memory.Alerts=@([pscustomobject]@{at=$Now;kind=$Category;level='notice'})+
            @($Memory.Alerts | Select-Object -First 15)
        $Memory.LastNoticeAt=$Now
    }
}
function Get-WifiResearchConfidence($Memory,[int]$IndependentScans,[string]$Source,[long]$AgeMs){
    $level='low'
    if($Source -eq 'Windows WLAN' -and $IndependentScans -ge 3 -and $AgeMs -ge 0 -and $AgeMs -le 45000){
        $level='medium'
    }
    [pscustomobject]@{
        level=$level;independentScans=$IndependentScans;source=$Source
        reason='Количество сканов не доказывает источник помех; требуется сопоставление локальных проб.'
        incidents=@($(if($Memory){$Memory.Incidents}) | Select-Object -First 8)
        anomalies=@($(if($Memory){$Memory.Changes}) | Select-Object -First 8)
        alerts=@($(if($Memory){$Memory.Alerts}) | Select-Object -First 6)
    }
}
function Save-WifiLocalReport([string]$Directory,$Data,[long]$Now){
    [void][IO.Directory]::CreateDirectory($Directory)
    $name='wifi-diagnostics-'+$Now
    $json=Join-Path $Directory ($name+'.json')
    $html=Join-Path $Directory ($name+'.html')
    $summary=ConvertTo-Json -InputObject $Data -Depth 7 -Compress
    [IO.File]::WriteAllText($json,$summary,[Text.UTF8Encoding]::new($false))
    $encoded=[Net.WebUtility]::HtmlEncode(($summary | ConvertFrom-Json | ConvertTo-Json -Depth 7))
    $document='<!doctype html><html lang="ru"><meta charset="utf-8"><title>Wi-Fi диагностика</title><style>body{background:#080a09;color:#e6d4ac;font:15px system-ui;margin:32px}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style><h1>Локальный отчёт Wi-Fi</h1><p>Диагностические данные. Причинная связь не установлена.</p><pre>'+$encoded+'</pre></html>'
    [IO.File]::WriteAllText($html,$document,[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{json=$json;html=$html;at=$Now}
}


# Different BSSIDs sharing an SSID can be ordinary roaming or multi-band deployment.
function Get-WifiSsidVariations([object[]]$Points) {
    $groups=@($Points | Where-Object {
        $_ -and $_.Fresh -ne $false -and $_.SSID -and $_.BSSID -and -not $_.Own
    } | Group-Object SSID)
    $results=@()
    foreach($group in $groups) {
        $unique=@($group.Group | Group-Object BSSID | ForEach-Object {$_.Group | Select-Object -First 1})
        if($unique.Count -lt 2){continue}
        $rsn=@($unique | Where-Object {$_.Capabilities} | ForEach-Object {[bool]$_.Capabilities.Rsn} | Select-Object -Unique)
        $gen=@($unique | Where-Object {$_.Capabilities -and $_.Capabilities.Generation -ne 'unverified'} |
            ForEach-Object {$_.Capabilities.Generation} | Select-Object -Unique)
        if($rsn.Count -lt 2 -and $gen.Count -lt 2){continue}
        $results += [pscustomobject]@{
            ssid=[string]$group.Name;accessPoints=$unique.Count
            reportedSecurityModes=$rsn.Count;reportedGenerations=$gen.Count
            classification='configuration-variation-not-proof-of-impostor'
        }
    }
    @($results | Select-Object -First 8)
}
