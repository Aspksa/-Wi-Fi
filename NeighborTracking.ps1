# Temporal Wi-Fi survey, no privileged operations, no speculative networks.
# Only completed Windows WLAN scans are accepted as independent observations.
function New-WifiNeighborTracker {
    @{
        Seen = @{}
        LastSurveyAt = 0L
        CompletedSurveys = 0
        Changes = @()
    }
}

function Update-WifiNeighborTracker($Tracker, [object[]] $Points, [long] $ScanAt,
        [string] $Source, [bool] $Completed) {
    if (-not $Tracker -or $Source -ne 'Windows WLAN' -or -not $Completed -or
            $ScanAt -le 0 -or $ScanAt -le [long]$Tracker.LastSurveyAt) { return $false }
    $Tracker.LastSurveyAt = $ScanAt
    $Tracker.CompletedSurveys = [int]$Tracker.CompletedSurveys + 1
    $current=@{}
    foreach ($point in $Points) {
        if (-not $point -or $point.Own -or $point.Fresh -eq $false -or
                $point.Band -notin @('2.4','5') -or [int]$point.Channel -le 0 -or
                [string]$point.BSSID -notmatch '^(?i:[0-9a-f]{2}:){5}(?i:[0-9a-f]{2})$') { continue }
        if ($point.ObservedAt -and ($point.ObservedAt -gt $ScanAt -or
                $ScanAt - [long]$point.ObservedAt -gt 45000)) { continue }
        $key=([string]$point.BSSID).ToLowerInvariant()+'|'+[string]$point.Band
        if (-not $current.ContainsKey($key) -or [int]$point.Signal -gt [int]$current[$key].Signal) {
            $current[$key]=$point
        }
    }
    foreach ($key in @($current.Keys | Sort-Object)) {
        $point=$current[$key]
        $previous=$Tracker.Seen[$key]
        if ($previous) {
            if ([int]$previous.Channel -ne [int]$point.Channel) {
                $Tracker.Changes=@([pscustomobject]@{
                    at=$ScanAt;type='channel-shift';band=[string]$point.Band
                    from=[int]$previous.Channel;to=[int]$point.Channel
                    name=[string]$point.SSID
                })+@($Tracker.Changes | Select-Object -First 19)
            }
            $signalDelta=[Math]::Abs([int]$previous.Signal - [int]$point.Signal)
            if ($signalDelta -ge 25) {
                $Tracker.Changes=@([pscustomobject]@{
                    at=$ScanAt;type='signal-jump';band=[string]$point.Band
                    from=[int]$previous.Signal;to=[int]$point.Signal;name=[string]$point.SSID
                })+@($Tracker.Changes | Select-Object -First 19)
                $previous.SignalJumps++
            }
            if ([int]$previous.Channel -ne [int]$point.Channel) { $previous.ChannelChanges++ }
            $previous.SignalTotal += [int]$point.Signal
            $previous.Channel=[int]$point.Channel
            $previous.Signal=[int]$point.Signal
            $previous.LastSeen=$ScanAt
            $previous.Sightings++
            $previous.Misses=0
            $previous.Present=$true
            $previous.Name=[string]$point.SSID
        } else {
            $Tracker.Seen[$key]=[pscustomobject]@{
                Key=$key;Name=[string]$point.SSID;Band=[string]$point.Band
                Channel=[int]$point.Channel;Signal=[int]$point.Signal
                FirstSeen=$ScanAt;LastSeen=$ScanAt;Sightings=1;Misses=0;Present=$true
                SignalTotal=[int]$point.Signal;SignalJumps=0;ChannelChanges=0
            }
            $Tracker.Changes=@([pscustomobject]@{
                at=$ScanAt;type='new-observation';band=[string]$point.Band
                from=$null;to=[int]$point.Channel;name=[string]$point.SSID
            })+@($Tracker.Changes | Select-Object -First 19)
        }
    }
    foreach ($key in @($Tracker.Seen.Keys)) {
        if ($current.ContainsKey($key)) { continue }
        $previous=$Tracker.Seen[$key]
        if ($previous.Present) {
            $previous.Misses++
            if ($previous.Misses -ge 2) {
                $previous.Present=$false
                $Tracker.Changes=@([pscustomobject]@{
                    at=$ScanAt;type='not-observed';band=$previous.Band
                    from=$previous.Channel;to=$null;name=$previous.Name
                })+@($Tracker.Changes | Select-Object -First 19)
            }
        }
        if ($ScanAt - [long]$previous.LastSeen -gt 3600000) { $Tracker.Seen.Remove($key) }
    }
    # Bound memory even under excessive beacon identifiers; drop oldest inactive sightings first.
    if ($Tracker.Seen.Count -gt 500) {
        $old=@($Tracker.Seen.Values | Sort-Object LastSeen | Select-Object -First ($Tracker.Seen.Count-500))
        foreach ($entry in $old) { $Tracker.Seen.Remove($entry.Key) }
    }
    return $true
}

function Get-WifiNeighborEvolution($Tracker,[long]$Now) {
    $empty=[pscustomobject]@{
        completeSurveys=0;stable=0;new=0;tentative=0;notObserved=0
        status='waiting';changes=@();explanation='Нужны несколько завершённых сканирований Windows WLAN.'
    }
    if (-not $Tracker -or $Tracker.CompletedSurveys -le 0) { return $empty }
    $recent=@($Tracker.Seen.Values | Where-Object { $Now - $_.LastSeen -ge 0 -and $Now - $_.LastSeen -le 120000 })
    $stable=@($recent | Where-Object { $_.Present -and $_.Sightings -ge 3 }).Count
    $new=@($recent | Where-Object { $_.Present -and $_.Sightings -eq 1 }).Count
    $tentative=@($recent | Where-Object { $_.Present -and $_.Sightings -eq 2 }).Count
    $missing=@($recent | Where-Object { -not $_.Present }).Count
    [pscustomobject]@{
        completeSurveys=[int]$Tracker.CompletedSurveys
        stable=$stable;new=$new;tentative=$tentative;notObserved=$missing
        status='observed'
        volatile=@($recent | Where-Object {$_.SignalJumps -ge 2 -or $_.ChannelChanges -ge 2}).Count
        strongest=@($recent | Where-Object {$_.Present -and $_.Sightings -ge 2} |
            Sort-Object Signal -Descending | Select-Object -First 6 |
            ForEach-Object {[pscustomobject]@{
                name=$_.Name; band=$_.Band;channel=$_.Channel
                signal=$_.Signal;meanSignal=[Math]::Round($_.SignalTotal/$_.Sightings,1)
                sightings=$_.Sightings;channelChanges=$_.ChannelChanges;signalJumps=$_.SignalJumps
            }})
        changes=@($Tracker.Changes | Where-Object {$Now - $_.at -ge 0 -and $Now - $_.at -le 3600000} | Select-Object -First 8)
        explanation='Устойчивые точки замечены в 3+ завершённых сканированиях. Отсутствие в двух снимках не доказывает отключение сети.'
    }
}
