# The scanner reports evidence, never invents unavailable networks.
function Get-WifiNeighborSummary([object[]]$Points,[string]$Source,[long]$ScanAt,[long]$Now,[bool]$Blocked) {
    $fresh = @($Points | Where-Object {
        $_ -and $_.Fresh -ne $false -and $_.Band -in @('2.4','5') -and
        $_.Channel -gt 0 -and $_.BSSID
    })
    $unique = @($fresh | Group-Object -Property BSSID,Band | ForEach-Object {
        $_.Group | Sort-Object Signal -Descending | Select-Object -First 1
    })
    $neighbors = @($unique | Where-Object { -not $_.Own })
    $bands = foreach($band in @('2.4','5')) {
        $subset = @($neighbors | Where-Object { $_.Band -eq $band })
        $channels = @($subset | Group-Object Channel | ForEach-Object {
            [pscustomobject]@{
                channel=[int]$_.Group[0].Channel
                networks=$_.Count
                strongestSignal=[int](@($_.Group | Measure-Object Signal -Maximum)[0].Maximum)
            }
        } | Sort-Object channel)
        [pscustomobject]@{band=$band;neighbors=$subset.Count;channels=@($channels)}
    }
    $age = if($ScanAt -gt 0 -and $ScanAt -le $Now) { $Now-$ScanAt } else { $null }
    $status = if($Blocked -and -not $fresh.Count) {'blocked'}
              elseif(-not $Source -or $null -eq $age) {'unavailable'}
              elseif($Source -eq 'router-export') {'unverified-import'}
              elseif($age -gt 45000) {'stale'}
              elseif($Source -eq 'netsh') {'unverified-age'}
              elseif($Source -eq 'Windows WLAN' -and $fresh.Count) {'observed'}
              elseif($fresh.Count) {'unverified'}
              else {'empty'}
    $explanation = switch($status) {
        'observed' {'Найдены соседние точки доступа Windows WLAN. Это не измерение загрузки канала.'}
        'unverified-age' {'Сети получены через netsh. Давность радиоизмерений не подтверждена.'}
        'unverified-import' {'Сети из необязательного импорта. Достоверность источника не подтверждена.'}
        'stale' {'Последний снимок устарел. Каналы нельзя оценивать как свежие.'}
        'blocked' {'Windows ограничила сканирование. Соседние сети не выдумываются.'}
        'empty' {'Сканирование выполнено, подходящие сети 2,4/5 ГГц не обнаружены.'}
        default {'Свежих сведений о соседних Wi-Fi-сетях нет.'}
    }
    [pscustomobject]@{
        status=$status;explanation=$explanation;source=$Source;scanAt=$ScanAt;ageMs=$age
        accessPoints=$unique.Count;neighborCount=$neighbors.Count
        bands=@($bands);hardwareAirtimeMeasured=$false
    }
}
