function Get-WebPointId($Point) {
    if ($Point) { "$($Point.BSSID)/$($Point.Band)" }
}

function ConvertTo-WebPoint($Point, $Tracked) {
    $shape = Get-SignalFootprint $Point.Band $Point.Channel $Point
    [pscustomobject] @{
        id = Get-WebPointId $Point
        name = if ($Point.SSID) { $Point.SSID } else { 'Скрытая сеть' }
        band = $Point.Band
        channel = $Point.Channel
        signal = $Point.Signal
        rssi = $Point.Rssi
        observedAt = $Point.ObservedAt
        signalText = Format-WifiSignal $Point
        frequency = $shape.Primary
        segments = @(Get-SignalSegments $shape)
        width = $(if ($shape.Secondary) { "$($shape.Width)+$($shape.Width)" } else { [string] $shape.Width })
        measured = [bool] $shape.Measured
        own = [bool] $Point.Own
        stale = $Point.Fresh -eq $false
        tracked = $Tracked -and $Tracked.BSSID -eq $Point.BSSID -and $Tracked.Band -eq $Point.Band
    }
}

function Get-WebHeat($History, [datetime] $At, [string] $Band) {
    $lookup = @{}
    foreach ($entry in $History.Hours) {
        if ($entry.Band -eq $Band) { $lookup[$entry.Key] = $entry }
    }
    for ($i = 23; $i -ge 0; $i--) {
        $hour = $At.AddHours(-$i)
        $key = $hour.ToString('yyyy-MM-dd HH')
        $value = $lookup[$key]
        [pscustomobject] @{
            hour = $hour.ToString('HH:mm')
            score = if ($value.OwnCount -gt 0) { [Math]::Round($value.OwnSum / $value.OwnCount) }
        }
    }
}

function Get-WebHealth($Session, [long] $Now) {
    $adapter = if ($Session.Issue) { 'unverified' }
               elseif ($Session.Source) { 'ready' }
               else { 'pending' }
    $scan = if ($Session.Issue) { 'failed' }
            elseif ($Session.Worker -and $Session.ScanStartedAt -and $Now - $Session.ScanStartedAt -gt 25000) { 'slow' }
            elseif (-not $Session.ScanAt) { 'pending' }
            elseif ($Now - $Session.ScanAt -gt 45000) { 'stale' }
            elseif (-not $Session.Points.Count) { 'empty' }
            elseif ($Session.Source -eq 'netsh') { 'unverified' }
            elseif ($Session.Points | Where-Object {
                $_.Fresh -ne $false -and ($null -eq $_.ObservedAt -or $Now - $_.ObservedAt -le 45000)
            } | Select-Object -First 1) { 'fresh' }
            else { 'stale' }
    $storage = if (-not $Session.Database) { 'unavailable' }
               elseif ($Session.Storage) { 'degraded' }
               else { 'ready' }
    [pscustomobject] @{ adapter = $adapter; scan = $scan; storage = $storage }
}

function Get-WebState($Session, [long] $Now, [datetime] $At) {
    $bands = foreach ($band in @('2.4', '5')) {
        $plan = $Session.Plans[$band]
        $suggestion = $Session.Advice[$band]
        $preview = if ($plan.Improves -and $plan.Home -and $plan.Best.Width) {
            $footprint = Get-CandidateFootprint $band $plan.Best.Channel $plan.Home $plan.Best.Width
            if ($footprint) {
                [pscustomobject] @{
                    channel = $plan.Best.Channel; width = $plan.Best.Width; frequency = $footprint.Primary
                    segments = @(Get-SignalSegments $footprint)
                    confirmed = [bool] ($Session.Streak -and $Session.Streak[$band].Samples -ge 3)
                    fromScore = $plan.Current.Score; toScore = $plan.Best.Score
                }
            }
        }
        [pscustomobject] @{
            key = $band; ownId = Get-WebPointId $plan.Home
            channel = $plan.Home.Channel
            width = $plan.Current.Width
            preview = $preview
            advice = if ($suggestion) { $suggestion } else { 'Ожидание первого замера.' }
            heat = @(Get-WebHeat $Session.History $At $band)
        }
    }
    [pscustomobject] @{
        now = $Now; scanAt = $Session.ScanAt; scanning = [bool] $Session.Worker
        source = $Session.Source; issue = $Session.Issue; storage = $Session.Storage
        health = Get-WebHealth $Session $Now
        home = $Session.HomeName
        tracked = Get-WebPointId $Session.History.Tracked
        trackedName = $Session.History.Tracked.SSID
        bands = @($bands)
        diagnostics = $Session.Diagnostics
        link = $Session.Link
        points = @(foreach ($point in $Session.Points) { ConvertTo-WebPoint $point $Session.History.Tracked })
        latency = @($Session.Latency | Where-Object { $Now - $_.at -le 60000 })
        events = @($Session.History.Events | Select-Object -First 100)
        episodes = @($Session.Episodes)
    }
}

function Set-WebTrackedPoint($Session, [string] $Value, [datetime] $At) {
    if (-not $Value) {
        $previous = $Session.History.Tracked
        if (-not $previous) { return }
        Add-MonitorEvent $Session.History $At "Наблюдение завершено · $($previous.SSID)."
        $Session.History.Tracked = $null
        return
    }
    $point = $Session.Points | Where-Object {
        -not $_.Own -and $_.Fresh -ne $false -and (Get-WebPointId $_) -ceq $Value
    } | Select-Object -First 1
    if (-not $point -or (Get-WebPointId $Session.History.Tracked) -ceq $Value) { return }
    $name = if ($point.SSID) { $point.SSID } else { 'Скрытая сеть' }
    $Session.History.Tracked = [pscustomobject] @{
        SSID = $name; BSSID = $point.BSSID; Band = $point.Band; Channel = $point.Channel; Overlap = $null
    }
    Add-MonitorEvent $Session.History $At "Наблюдение · $name, канал $($point.Channel)."
    Update-TrackedPoint $Session.History $Session.Points $Session.Plans $At
}

function Get-SpectrumFrame([long] $At, [object[]] $Points) {
    $fresh = @($Points | Where-Object { $_.Fresh -ne $false })
    if (-not $fresh.Count) { return }
    $timestamps = @(foreach ($band in @('2.4', '5')) {
        $recent = $fresh | Where-Object { $_.Band -eq $band -and $_.ObservedAt } |
            Sort-Object ObservedAt -Descending | Select-Object -First 1
        if ($recent) { "$band/$($recent.ObservedAt)" }
    })
    [pscustomobject] @{
        at = $At
        key = if ($timestamps.Count) { $timestamps -join '|' } else { "scan/$At" }
        points = @(foreach ($point in $fresh) { ConvertTo-WebPoint $point $null })
    }
}

function Update-SpectrumFrames([object[]] $Frames, $Frame) {
    if (-not $Frame -or ($Frames.Count -and $Frames[-1].key -eq $Frame.key)) { return $Frames }
    @($Frames + $Frame | Select-Object -Last 16)
}

function Read-WebSpectrum($Database, [long] $Now) {
    $rows = $Database.Query(@'
SELECT at_ms, observed_points FROM radio_scans
WHERE at_ms >= ? AND at_ms <= ?
ORDER BY at_ms DESC LIMIT 80
'@, @(($Now - 3600000L), $Now))
    $frames = @()
    for ($index = $rows.Count - 1; $index -ge 0; $index--) {
        $row = $rows[$index]
        try {
            $points = @($row[1] | ConvertFrom-Json)
            $frames = @(Update-SpectrumFrames $frames (Get-SpectrumFrame $row[0] $points))
        } catch {
            # A malformed saved snapshot must not stop the live map.
            continue
        }
    }
    $frames
}

function Get-WebEpisode($Entry) {
    $band = ([string] $Entry.Network -split '\|', 2)[0]
    $route = if ($Entry.Cause -in @('external', 'upload')) { 'external' }
             elseif ($Entry.Cause -in @('local', 'local-overlap')) { 'router' }
             else { 'uncertain' }
    [pscustomobject] @{
        id = $Entry.Id; at = $Entry.At; ended = $Entry.Ended; band = $band
        route = $route; message = $Entry.Message
    }
}

function Read-WebEpisodes($Database, [long] $Now) {
    $rows = $Database.Query(@'
SELECT id, at_ms, ended_ms, network, cause, description
FROM incidents WHERE at_ms >= ? AND at_ms <= ?
ORDER BY at_ms DESC LIMIT 8
'@, @(($Now - 3600000L), $Now))
    foreach ($row in $rows) {
        Get-WebEpisode @{ Id = $row[0]; At = $row[1]; Ended = $row[2]; Network = $row[3]; Cause = $row[4]; Message = $row[5] }
    }
}
