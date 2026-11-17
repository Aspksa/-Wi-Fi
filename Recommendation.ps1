function Get-WifiRecommendation {
    param([object[]] $Points, [string] $Band, [string[]] $Connected, [datetime] $At, [string] $State,
        $Native, $History, $Database, $Previous, $Forecast)

    $storageNote = ''
    $plan = Get-ChannelPlan $Points $band $Connected
    if ($plan.Home) {
        $past = Get-PastScores $History $At $band $plan.Current.Width
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
    $count = 0
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
        if ($count -ge 3) {
            $current = $plan.Current
            $message = if ($plan.TrialSupport) {
                "Канал $choice · помогло в $($plan.TrialSupport.Wins) прошлых сравнениях."
            } else {
                "Канал $choice · оценка помех $($current.Score) → $($plan.Best.Score)."
            }
            if ($count -eq 3 -and $previous.Samples -lt 3) { Add-MonitorEvent $History $At "$bandText · совет: $message" }
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
        Streak = @{ Key = $key; Samples = $count; Observation = $observation }
        StorageNote = $storageNote
    }
}
