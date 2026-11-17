function Get-UnixMilliseconds {
    [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function New-WifiIntelligence {
    @{
        Session = [Guid]::NewGuid().ToString('N')
        Samples = [Collections.Generic.List[object]]::new()
        PendingSamples = [Collections.Generic.List[object]]::new()
        PendingScans = [Collections.Generic.List[object]]::new()
        PendingIncidents = [Collections.Generic.List[object]]::new()
        PendingTrials = [Collections.Generic.List[object]]::new()
        PendingChecks = [Collections.Generic.List[object]]::new()
        Incident = $null
        Trial = $null
        Check = $null
        Radio = $null
        BurstUntil = 0L
        LastProbeAt = 0L
        LastForecastAt = 0L
    }
}

function Get-SampleMetric($Sample, [string] $Metric, [double] $Limit) {
    $lost = $Sample.($Metric + 'Loss')
    $value = $Sample.$Metric
    if ($lost -eq $true) { return 'bad' }
    if ($null -eq $value) { return 'unknown' }
    if ($value -gt $Limit) { return 'bad' }
    'ok'
}

function Get-SampleIssue($Sample) {
    $lan = Get-SampleMetric $Sample 'Lan' 35
    $wan = Get-SampleMetric $Sample 'Wan' 180
    $lan -eq 'bad' -or $wan -eq 'bad'
}

function Get-EpisodeConclusion([object[]] $Samples) {
    $local = 0; $external = 0
    $upload = 0; $radio = 0; $paired = 0
    foreach ($sample in $Samples) {
        $lan = Get-SampleMetric $sample 'Lan' 35
        $wan = Get-SampleMetric $sample 'Wan' 180
        if ($lan -eq 'bad') {
            $local++
            if ($sample.Overlap -eq 'changed') { $radio++ }
        }
        if ($lan -eq 'ok' -and $wan -eq 'bad') {
            $external++
            if ($null -ne $sample.Upload) {
                $paired++
                if ($sample.Upload -ge 1000) { $upload++ }
            }
        }
    }
    if ($local -ge 2 -and $local -gt $external) {
        if ($radio -ge 2) {
            return @{ Cause = 'local-overlap'; Text = 'Сбои до роутера совпали со сменой пересечения каналов. Канал стоит проверить сравнением.' }
        }
        return @{ Cause = 'local'; Text = 'Сбои заметны уже до роутера. Проверяй локальную связь и эфир.' }
    }
    if ($external -ge 2) {
        if ($paired -ge 2 -and $upload / $paired -ge 0.65) {
            return @{ Cause = 'upload'; Text = 'До роутера связь стабильна. Внешние сбои совпали с исходящей загрузкой.' }
        }
        return @{ Cause = 'external'; Text = 'До роутера отклик сохранён, сбои видны дальше по маршруту.' }
    }
    @{ Cause = 'uncertain'; Text = 'Короткий скачок отклика. Замеров для определения участка пока мало.' }
}

function Complete-WifiEpisode($Engine) {
    $incident = $Engine.Incident
    if (-not $incident) { return }
    $evidence = @($Engine.Samples | Where-Object { $_.Network -eq $incident.Network -and $_.At -ge $incident.At })
    $outcome = Get-EpisodeConclusion $evidence
    $entry = [pscustomobject] @{
        Id = [Guid]::NewGuid().ToString('N'); At = $incident.At; Ended = $incident.LastBad
        Network = $incident.Network; Cause = $outcome.Cause; Message = $outcome.Text
    }
    $Engine.PendingIncidents.Add($entry)
    $Engine.Incident = $null
    $entry
}

function Get-ChannelTrialResult($Trial, [object[]] $After, [long] $Now) {
    $used = [Collections.Generic.HashSet[long]]::new()
    $beforeLag = 0; $afterLag = 0
    $beforeTimes = [Collections.Generic.List[double]]::new()
    $afterTimes = [Collections.Generic.List[double]]::new()
    $previousAt = 0L
    foreach ($next in $After) {
        if ($next.At - $previousAt -lt 850 -or $null -eq $next.Signal -or $null -eq $next.Upload) { continue }
        $nextMetric = Get-SampleMetric $next 'Lan' 35
        if ($nextMetric -eq 'unknown') { continue }
        $isUpload = $next.Upload -ge 1000
        $match = $Trial.Before | Where-Object {
            -not $used.Contains([long] $_.At) -and $null -ne $_.Signal -and $null -ne $_.Upload -and
                [Math]::Abs($_.Signal - $next.Signal) -le 15 -and ($_.Upload -ge 1000) -eq $isUpload -and
                (Get-SampleMetric $_ 'Lan' 35) -ne 'unknown'
        } | Select-Object -First 1
        if (-not $match) { continue }
        $previousAt = $next.At
        [void] $used.Add([long] $match.At)
        if ((Get-SampleMetric $match 'Lan' 35) -eq 'bad') { $beforeLag++ }
        if ($nextMetric -eq 'bad') { $afterLag++ }
        if ($null -ne $match.Lan) { $beforeTimes.Add([double] $match.Lan) }
        if ($null -ne $next.Lan) { $afterTimes.Add([double] $next.Lan) }
    }
    $pairs = $used.Count
    $beforeP90 = Get-LatencyPercentile $beforeTimes
    $afterP90 = Get-LatencyPercentile $afterTimes
    $improved = $null
    $message = "Каналы $($Trial.Old) → $($Trial.New): мало сопоставимых замеров."
    if ($pairs -ge 25) {
        $improved = 0
        $delta = $beforeLag - $afterLag
        if ([Math]::Abs($delta) -ge 3 -and [Math]::Abs($delta) / $pairs -ge 0.10) {
            $improved = [Math]::Sign($delta)
        }
        $message = "Каналы $($Trial.Old) → $($Trial.New): скачки или потери $beforeLag → $afterLag из $pairs пар."
    }
    [pscustomobject] @{
        Id = [Guid]::NewGuid().ToString('N'); At = $Now; Network = $Trial.Network; Old = $Trial.Old; New = $Trial.New
        Improved = $improved; BeforeBad = $beforeLag; AfterBad = $afterLag; Pairs = $pairs
        BeforeP90 = $beforeP90; AfterP90 = $afterP90; Message = $message
    }
}

function Get-LatencyPercentile([object[]] $Values) {
    if ($Values.Count) {
        $sorted = @($Values | Sort-Object)
        $sorted[[int] [Math]::Ceiling($sorted.Count * 0.90) - 1]
    }
}

function Update-WifiRadio($Engine, $Radio, [long] $Now) {
    $old = $Engine.Radio
    if ($old -and $Radio) {
        if ($old.Network -ne $Radio.Network) {
            $Engine.Trial = $null
        } elseif ($old.Channel -ne $Radio.Channel -and $old.At -ge $Now - 120000) {
            $last = 0L
            $before = @(foreach ($entry in $Engine.Samples) {
                if ($entry.Network -eq $Radio.Network -and $entry.Channel -eq $old.Channel -and
                        $entry.At -le $old.At -and $entry.At -ge $old.At - 90000 -and $entry.At - $last -ge 950) {
                    $last = $entry.At
                    $entry
                }
            })
            $Engine.Trial = @{
                Network = $Radio.Network; Old = $old.Channel; New = $Radio.Channel; At = $Now; Before = $before
            }
        }
    }
    if ($Radio) { $Engine.Radio = $Radio }
}

function Get-SampleContext($Sample) {
    if (-not $Sample.Network -or $null -eq $Sample.Upload -or -not $Sample.Channel -or -not $Sample.Overlap) { return }
    $traffic = if ($Sample.Upload -ge 1000) { 'upload' } else { 'quiet' }
    $radio = if ($Sample.Overlap -in @('strong', 'changed')) { 'strong' } else { 'clear' }
    "$($Sample.Channel)|$traffic|$radio"
}

function Test-ForecastConfidence($Evidence) {
    if (-not $Evidence -or $Evidence.Count -lt 8 -or $Evidence.Bad -lt 4) { return $false }
    if ($Evidence.Predicted -ge 4 -and $Evidence.Correct / $Evidence.Predicted -lt 0.60) { return $false }
    ($Evidence.Bad + 1.0) / ($Evidence.Count + 2.0) -ge 0.65
}

function Add-WifiSample($Engine, $Sample, [scriptblock] $ReadEvidence) {
    $now = [long] $Sample.At
    if ($now -le $Engine.LastProbeAt) { return }
    $Engine.LastProbeAt = $now
    $Engine.Samples.Add($Sample)
    if ($Engine.PendingSamples.Count -lt 1000) { $Engine.PendingSamples.Add($Sample) }
    while ($Engine.Samples.Count -and $Engine.Samples[0].At -lt $now - 240000) { $Engine.Samples.RemoveAt(0) }
    $bad = Get-SampleIssue $Sample
    if ($Engine.Incident -and $Sample.Network -ne $Engine.Incident.Network) { Complete-WifiEpisode $Engine }
    if (-not $Sample.Network) { $Engine.Check = $null; return }
    if ($bad -and -not $Engine.Incident) {
        $Engine.Incident = @{ At = $now; LastBad = $now; Network = $Sample.Network }
        $Engine.BurstUntil = [Math]::Max([long] $Engine.BurstUntil, [long] ($now + 10000))
    }
    if ($Engine.Incident) {
        if ($bad) { $Engine.Incident.LastBad = $now }
        if ($now - $Engine.Incident.LastBad -ge 8000 -or $now - $Engine.Incident.At -ge 45000) {
            Complete-WifiEpisode $Engine
        }
    }

    $trial = $Engine.Trial
    if ($trial -and $now -ge $trial.At + 105000) {
        $after = @($Engine.Samples | Where-Object {
            $_.Network -eq $trial.Network -and $_.Channel -eq $trial.New -and
                $_.At -ge $trial.At + 15000 -and $_.At -le $trial.At + 105000
        })
        $result = Get-ChannelTrialResult $trial $after $now
        $Engine.PendingTrials.Add($result)
        $Engine.Trial = $null
        $result
    }

    $context = Get-SampleContext $Sample
    $check = $Engine.Check
    if ($check -and ($check.Context -ne $context -or $check.Network -ne $Sample.Network)) {
        $Engine.Check = $null
        $check = $null
    }
    if ($check -and $now - $check.At -ge 60000) {
        if ($check.Count -ge 30) {
            $Engine.PendingChecks.Add([pscustomobject] @{
                Id = [Guid]::NewGuid().ToString('N'); At = $check.At; Network = $check.Network
                Context = $check.Context; Predicted = $check.Predicted; Actual = $check.Bad -ge 2
            })
        }
        $Engine.Check = $null
    }
    if (-not $Engine.Check -and $context) {
        $evidence = if ($ReadEvidence -and -not $bad -and $now - $Engine.LastForecastAt -ge 60000) {
            & $ReadEvidence $Sample.Network $context
        }
        $predicted = Test-ForecastConfidence $evidence
        $Engine.Check = @{ At = $now; Network = $Sample.Network; Context = $context; Count = 0; Bad = 0; Predicted = $predicted }
        if ($predicted) {
            $Engine.LastForecastAt = $now
            $Engine.BurstUntil = [Math]::Max([long] $Engine.BurstUntil, [long] ($now + 10000))
            [pscustomobject] @{ Message = "Похожие условия раньше приводили к скачкам ($($evidence.Bad) из $($evidence.Count) интервалов). Усиливаю замеры."; Forecast = $true }
        }
    }
    $check = $Engine.Check
    if ($check -and (Get-SampleMetric $Sample 'Lan' 35) -ne 'unknown') {
        $check.Count++
        if ($bad) { $check.Bad++ }
    }
}

function Get-WifiNetworkKey($Point) {
    if ($Point) { "$($Point.Band)|$($Point.BSSID)|$($Point.SSID)" }
}

function Get-WifiRadioContext([object[]] $Points, [string[]] $Connected, $Previous, [long] $Now) {
    if ($Connected.Count -ne 1) { return }
    $ownPoint = $Points | Where-Object { $_.BSSID -eq $Connected[0] -and $_.Fresh -ne $false } | Select-Object -First 1
    if (-not $ownPoint) { return }
    $network = Get-WifiNetworkKey $ownPoint
    $footprint = Get-SignalFootprint $ownPoint.Band $ownPoint.Channel $ownPoint
    $neighbors = foreach ($point in $Points) {
        if (-not $point.Own -and $point.Fresh -ne $false -and $point.Band -eq $ownPoint.Band -and $point.Signal -ge 65 -and
                (Get-SignalOverlap $footprint (Get-SignalFootprint $point.Band $point.Channel $point))) {
            "$($point.BSSID)/$($point.Channel)"
        }
    }
    $signature = @($neighbors | Sort-Object -Unique) -join ','
    $changedAt = 0L
    if ($signature -and $Previous -and $Previous.Network -eq $network -and
            $Previous.Channel -eq $ownPoint.Channel -and $Now - $Previous.At -le 50000) {
        if ($Previous.Signature -ne $signature) { $changedAt = $Now }
        else { $changedAt = $Previous.ChangedAt }
    }
    [pscustomobject] @{
        At = $Now; Network = $network; Band = $ownPoint.Band; Signal = $ownPoint.Signal; Channel = $ownPoint.Channel
        Signature = $signature; ChangedAt = $changedAt; ObservedAt = $ownPoint.ObservedAt
    }
}

function Get-UploadRate($Previous, [long] $Bytes, [long] $Now) {
    if ($Previous -and $Now -gt $Previous.At -and $Now - $Previous.At -le 8000 -and $Bytes -ge $Previous.Bytes) {
        [Math]::Round(($Bytes - $Previous.Bytes) * 8.0 / ($Now - $Previous.At), 1)
    }
}
