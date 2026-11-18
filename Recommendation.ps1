function Get-ChannelReplay($Plan, [object[]] $Snapshots, [long] $Now) {
    $seen = @{}
    $wins = 0
    $count = 0
    foreach ($snapshot in ($Snapshots | Where-Object { $_.At -ge $Now - 900000 -and $_.At -le $Now } | Sort-Object At -Descending)) {
        $home = $snapshot.Points | Where-Object {
            $_.BSSID -eq $Plan.Home.BSSID -and $_.Band -eq $Plan.Home.Band -and $_.Channel -eq $Plan.Home.Channel -and
                $_.Fresh -ne $false -and $_.ObservedAt -and $snapshot.At - $_.ObservedAt -le 45000 -and
                (Get-ReportedWidth $_) -eq $Plan.Current.Width
        } | Select-Object -First 1
        if (-not $home -or $seen.ContainsKey([long] $home.ObservedAt)) { continue }
        $seen[[long] $home.ObservedAt] = $true
        $neighbors = @($snapshot.Points | Where-Object {
            $_.Band -eq $home.Band -and -not $_.Own -and $_.BSSID -ne $home.BSSID -and $_.Fresh -ne $false -and
                (-not $_.ObservedAt -or $snapshot.At - $_.ObservedAt -le 45000)
        })
        $baseline = Get-CandidateFootprint $home.Band $home.Channel $home
        $candidate = Get-CandidateFootprint $home.Band $Plan.Best.Channel $home $Plan.Best.Width
        if (-not $baseline -or -not $candidate) { continue }
        $baseScore = Get-ChannelScore $home.Channel $home.Band $neighbors $baseline
        $newScore = Get-ChannelScore $Plan.Best.Channel $home.Band $neighbors $candidate
        if ($baseScore - $newScore -ge [Math]::Max(5, 0.15 * $baseScore)) { $wins++ }
        $count++
        if ($count -ge 10) { break }
    }
    @{ Count = $count; Wins = $wins }
}

function Get-WifiRecommendation {
    param([object[]] $Points, [string] $Band, [string[]] $Connected, [datetime] $At, [string] $State,
        $Native, $History, $Database, $Previous, $Forecast)

    $storageNote = ''
    $plan = Get-ChannelPlan $Points $band $Connected
    if ($plan.Home) {
        $past = Get-PastScores $History $At $band $plan.Current.Width (Get-WifiNetworkKey $plan.Home)
        $memory = @{}
        if ($Database) {
            try {
                $memory = Get-TrialMemory $Database (Get-WifiNetworkKey $plan.Home) $plan.Home.Channel $plan.Current.Width
            } catch { $storageNote = 'Не удалось прочитать результаты прошлых смен канала.' }
        }
        if ($past.Count -or $memory.Count) { $plan = Get-ChannelPlan $Points $band $Connected $past $memory }
    }
    $bandText = $band.Replace('.', ',') + ' ГГц'
    $observation = Get-ScanObservationKey $Native $Points $band $At
    $now = ([DateTimeOffset] $At).ToUnixTimeMilliseconds()
    $frames = @($Previous.Frames | Where-Object { $_ -and $_.At -ge $now - 900000 })
    if ($Native -and $observation -and (-not $frames.Count -or $frames[-1].Key -ne $observation)) {
        $frames = @((@($frames) + @(@{ Key = $observation; At = $now; Points = $Points })) | Select-Object -Last 10)
    }
    $plan | Add-Member -NotePropertyName ReplayEligible -NotePropertyValue ([bool] ($Native -and $observation))
    $count = 0
    $confirmed = $false
    $key = "$($plan.Home.BSSID)|$($plan.Home.Channel)/$($plan.Current.Width)|$($plan.Best.Channel)/$($plan.Best.Width)"
    $choice = if ($plan.Best.Width) {
        "$($plan.Best.Channel) / $($plan.Best.Width) МГц"
    } else { "$($plan.Best.Channel)" }
    if ($Native -and -not $observation) {
        $message = 'Ожидание свежего снимка эфира.'
    } elseif (-not $plan.Home) {
        $message = 'Укажи SSID, чтобы определить свой канал.'
    } elseif ($State -eq 'external') {
        $message = "Канал $($plan.Home.Channel). Проблема видна только до внешнего адреса."
    } elseif ($plan.Improves) {
        $count = 1
        if ($previous -and $previous.Key -eq $key) {
            $count = $previous.Samples
            if ($previous.Observation -ne $observation) { $count++ }
        }
        $replay = @{ Count = 0; Wins = 0 }
        if ($Native -and $count -ge 3) {
            $saved = @()
            if ($Database) {
                try { $saved = @(Get-RecentChannelScans $Database $now) }
                catch { $storageNote = 'Не удалось перепроверить совет по снимкам из SQLite.' }
            }
            $replay = Get-ChannelReplay $plan (@($frames) + $saved) $now
        }
        $confirmed = $count -ge 3 -and $replay.Count -ge 3 -and $replay.Wins -gt $replay.Count / 2
        if ($confirmed) {
            $current = $plan.Current
            $message = if ($plan.TrialSupport) {
                "Канал $choice · помогло в $($plan.TrialSupport.Wins) прошлых сравнениях."
            } else {
                "Канал $choice · оценка помех $($current.Score) → $($plan.Best.Score)."
            }
            if (-not $Previous.Confirmed -and $Previous.Observation -ne $observation) { Add-MonitorEvent $History $At "$bandText · совет: $message" }
        } elseif (-not $Native) {
            $message = "Кандидат $choice · возраст данных netsh неизвестен."
        } elseif ($count -ge 3) {
            $message = "Кандидат $choice · история подтверждает $($replay.Wins) из $($replay.Count) снимков."
        } else {
            $message = "Кандидат $choice · подтверждение $count из 3."
        }
    } elseif ($Forecast -and $Forecast.Band -eq $band -and
            $Forecast.Network -eq (Get-WifiNetworkKey $plan.Home) -and
            (Get-UnixMilliseconds) - $Forecast.At -lt 60000) {
        $message = $Forecast.Text
    } else {
        $message = "Канал $($plan.Home.Channel). Выигрыш от смены пока не виден."
    }
    [pscustomobject] @{
        Plan = $plan
        Text = $message
        Streak = @{ Key = $key; Samples = $count; Observation = $observation; Confirmed = $confirmed; Frames = $frames }
        StorageNote = $storageNote
    }
}
