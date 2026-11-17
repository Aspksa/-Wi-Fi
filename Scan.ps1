function ConvertFrom-WifiScan {
    param([string] $Text)

    $ssid = ''
    $point = $null
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*SSID\s+\d+\s*:\s?(.*)$') {
            if ($point -and $point.Channel -and $null -ne $point.Signal) { $point }
            $point = $null
            $ssid = $Matches[1]
        } elseif ($line -match '^\s*BSSID\s+\d+\s*:\s*((?:[0-9a-f]{2}:){5}[0-9a-f]{2})\s*$') {
            if ($point -and $point.Channel -and $null -ne $point.Signal) { $point }
            $point = [pscustomobject] @{
                SSID = $ssid
                BSSID = $Matches[1].ToLowerInvariant()
                Band = ''
                Channel = 0
                Signal = $null
            }
        } elseif ($point -and $line -match '^\s*(?:Signal|Сигнал|Уровень сигнала)\s*:\s*(\d{1,3})\s*%') {
            $point.Signal = [Math]::Min(100, [int] $Matches[1])
        } elseif ($point -and $line -match '^\s*(?:Channel|Канал)\s*:\s*(\d{1,3})\s*$') {
            $point.Channel = [int] $Matches[1]
        } elseif ($point -and $line -match '^\s*(?:Band|Диапазон|Полоса)\s*:\s*(2[.,]4|5|6)\s*(?:GHz|ГГц)\b') {
            $point.Band = $Matches[1].Replace(',', '.')
        }
    }
    if ($point -and $point.Channel -and $null -ne $point.Signal) { $point }
}

function Get-WifiPoints {
    param([string] $Networks, [string[]] $Connected, [string] $HomeName)

    $parsed = @(ConvertFrom-WifiScan $Networks)
    if ($Networks -match '(?m)^\s*BSSID\s+\d+\s*:' -and -not $parsed.Count) {
        throw 'Windows вернула список сетей в неподдерживаемом формате.'
    }

    $parsed | ForEach-Object {
        if (-not $_.Band) {
            if ($_.Channel -le 14) { $_.Band = '2.4' }
            elseif ($_.Channel -ge 32 -and $_.Channel -le 177) { $_.Band = '5' }
        }
        $_ | Add-Member -NotePropertyName Own -NotePropertyValue (
            $_.BSSID -in $Connected -or ($HomeName -cne '' -and $_.SSID -ceq $HomeName)
        ) -PassThru
    } | Where-Object { $_.Band -in @('2.4', '5') } |
        Group-Object -Property BSSID, Band, Channel |
        ForEach-Object { $_.Group | Sort-Object Signal -Descending | Select-Object -First 1 }
}

function Get-ConnectedAddresses {
    param([string] $Interfaces)
    $pattern = '(?im)^\s*(?:AP\s+)?BSSID(?:\s+(?:AP|точки доступа))?\s*:\s*((?:[0-9a-f]{2}:){5}[0-9a-f]{2})\s*$'
    foreach ($match in [regex]::Matches($Interfaces, $pattern)) {
        $match.Groups[1].Value.ToLowerInvariant()
    }
}

function Get-5GHzBlockStart([int] $Channel) {
    foreach ($start in @(36, 52, 100, 116, 132, 149, 165)) {
        if ($Channel -ge $start -and $Channel -le ($start + 12)) { return $start }
    }
}

function ConvertFrom-NativeScan($Result, [string] $HomeName) {
    $points = foreach ($point in $Result.Points) {
        $observedAt = $point.SeenAt
        $fresh = if ($null -ne $observedAt) { $Result.FinishedAt - $observedAt -le 45000 }
                 else { $Result.Completed }
        [pscustomobject] @{
            SSID = $point.Name; BSSID = $point.Address; Band = $point.Band; Channel = $point.Channel
            Signal = $point.Signal; Rssi = $point.Rssi; Frequency = $point.Frequency; RadioWidth = $point.Width
            ObservedAt = $observedAt; Fresh = $fresh
            Own = $point.Address -eq $Result.Connected -or ($HomeName -cne '' -and $point.Name -ceq $HomeName)
        }
    }
    $points | Group-Object -Property BSSID, Band | ForEach-Object {
        $_.Group | Sort-Object -Property @{ Expression = 'ObservedAt'; Descending = $true },
            @{ Expression = 'Signal'; Descending = $true } | Select-Object -First 1
    }
}

function Get-SignalFootprint([string] $Band, [int] $Channel, $Point) {
    if ($Point.RadioWidth -and $Point.Channel -eq $Channel) {
        $width = $Point.RadioWidth.Width
        $center = $Point.RadioWidth.Center
        return [pscustomobject] @{
            Primary = $Point.Frequency; Left = $center - $width / 2; Right = $center + $width / 2
            Width = $width; Secondary = $Point.RadioWidth.SecondaryCenter; Measured = $true
        }
    }
    if ($Band -eq '2.4') {
        $primary = if ($Channel -eq 14) { 2484 } else { 2407 + $Channel * 5 }
        return [pscustomobject] @{ Primary = $primary; Left = $primary - 10; Right = $primary + 10; Width = 20 }
    }
    $primary = 5000 + $Channel * 5
    $block = Get-5GHzBlockStart $Channel
    if ($null -ne $block) {
        $left = 5000 + $block * 5 - 10
        return [pscustomobject] @{ Primary = $primary; Left = $left; Right = $left + 80; Width = 80 }
    }
    [pscustomobject] @{ Primary = $primary; Left = $primary - 10; Right = $primary + 10; Width = 20 }
}

function Get-CandidateFootprint([string] $Band, [int] $Channel, $HomePoint) {
    $footprint = Get-SignalFootprint $Band $Channel $HomePoint
    if ($footprint.Measured -or -not $HomePoint.RadioWidth) { return $footprint }
    $width = $HomePoint.RadioWidth.Width
    $center = $footprint.Primary
    $secondary = $HomePoint.RadioWidth.SecondaryCenter
    if ($Band -eq '2.4') {
        $center += $HomePoint.RadioWidth.Center - $HomePoint.Frequency
        $secondaryFrequency = 2 * $center - $footprint.Primary
        if ($width -eq 40 -and ($secondaryFrequency -lt 2412 -or $secondaryFrequency -gt 2472)) { return }
    } elseif ($width -gt 20) {
        $start = Get-5GHzBlockStart $Channel
        if (-not $start) { return }
        if ($width -eq 40) { $center = 5000 + 5 * ($start + 2 + 8 * [Math]::Floor(($Channel - $start) / 8)) }
        if ($width -eq 80) { $center = 5000 + 5 * ($start + 6) }
        if ($width -eq 160) {
            foreach ($wideStart in @(36, 100, 149)) {
                if ($Channel -ge $wideStart -and $Channel -le $wideStart + 28) {
                    $center = 5000 + 5 * ($wideStart + 14)
                    break
                }
            }
            if ($center -eq $footprint.Primary) { return }
        }
        if ($secondary -and [Math]::Abs($secondary - $center) -le $width) { return }
    }
    [pscustomobject] @{
        Primary = $footprint.Primary; Left = $center - $width / 2; Right = $center + $width / 2
        Width = $width; Secondary = $secondary; Measured = $true
    }
}

function Get-SignalSegments($Footprint) {
    [pscustomobject] @{ Left = $Footprint.Left; Right = $Footprint.Right }
    if ($Footprint.Secondary) {
        $halfWidth = $Footprint.Width / 2
        [pscustomobject] @{ Left = $Footprint.Secondary - $halfWidth; Right = $Footprint.Secondary + $halfWidth }
    }
}

function Get-SignalOverlap($First, $Second) {
    foreach ($a in (Get-SignalSegments $First)) {
        foreach ($b in (Get-SignalSegments $Second)) {
            $left = [Math]::Max([int] $a.Left, [int] $b.Left)
            $right = [Math]::Min([int] $a.Right, [int] $b.Right)
            if ($right -gt $left) { [pscustomobject] @{ Left = $left; Right = $right } }
        }
    }
}

function Get-ChannelScore {
    param([int] $Channel, [string] $Band, [object[]] $Neighbors, $Candidate)

    if (-not $Candidate) { $Candidate = Get-SignalFootprint $Band $Channel }
    $score = 0.0
    foreach ($point in $Neighbors) {
        $distance = [Math]::Abs($point.Channel - $Channel)
        if ($Candidate.Measured -or $point.RadioWidth) {
            $neighborFootprint = Get-SignalFootprint $Band $point.Channel $point
            $intersection = 0.0
            foreach ($section in (Get-SignalOverlap $Candidate $neighborFootprint)) {
                $intersection += $section.Right - $section.Left
            }
            $width = $Candidate.Width
            if ($Candidate.Secondary) { $width *= 2 }
            $overlap = $intersection / $width
        } elseif ($Band -eq '2.4') {
            $overlap = [Math]::Max(0.0, 1 - $distance / 5.0)
        } else {
            # The scan does not report channel width. Reserve the surrounding 80 MHz block.
            $block = Get-5GHzBlockStart $Channel
            $neighborBlock = Get-5GHzBlockStart $point.Channel
            $overlap = [int] ($distance -eq 0 -or ($block -and $block -eq $neighborBlock))
        }
        $score += [Math]::Pow($point.Signal / 100.0, 2) * $overlap * 100
    }
    [Math]::Round($score)
}

function Get-ChannelPlan {
    param([object[]] $Points, [string] $Band, [string[]] $Connected, [hashtable] $PastScores = @{}, [hashtable] $TrialMemory = @{})

    $visible = @($Points | Where-Object { $_.Band -eq $Band -and $_.Fresh -ne $false })
    $neighbors = @($visible | Where-Object { -not $_.Own })
    $homePoint = $visible | Where-Object Own | Sort-Object -Property @(
        @{ Expression = { $_.BSSID -in $Connected }; Descending = $true }
        @{ Expression = { $_.Signal }; Descending = $true }
    ) | Select-Object -First 1

    $candidates = if ($Band -eq '2.4') { @(1, 6, 11) } else { @(36, 40, 44, 48, 149, 153, 157, 161) }
    $observed = @($visible | ForEach-Object { $_.Channel })
    $channels = @($candidates) + $observed | Sort-Object -Unique
    $rows = foreach ($channel in $channels) {
        $footprint = Get-CandidateFootprint $Band $channel $homePoint
        $score = Get-ChannelScore $channel $Band $neighbors $footprint
        $past = $PastScores[[int] $channel]
        $result = $TrialMemory[[int] $channel]
        $trialAdjustment = 0
        if ($result -and $result.Count -ge 2) {
            $trialAdjustment = [Math]::Max(-15, [Math]::Min(15, 5 * ($result.Losses - $result.Wins)))
        }
        [pscustomobject] @{
            Channel = $channel
            Count = @($neighbors | Where-Object Channel -eq $channel).Count
            Score = $score
            Rank = $score + [Math]::Min(15.0, [double] $past * 0.15) + $trialAdjustment
            Candidate = $null -ne $footprint -and $channel -in $candidates
            Current = $null -ne $homePoint -and $channel -eq $homePoint.Channel
        }
    }

    $best = $rows | Where-Object Candidate | Sort-Object -Property Rank, Score, Channel | Select-Object -First 1
    $current = $rows | Where-Object Current | Select-Object -First 1
    $trialSupport = $TrialMemory[[int] $best.Channel]
    $proven = $trialSupport -and $trialSupport.Wins -ge 2 -and $trialSupport.Wins -ge $trialSupport.Losses + 2
    $improves = $null -ne $best -and $null -ne $current -and $best.Channel -ne $current.Channel -and (
        ($current.Score -gt 0 -and $best.Score -le $current.Score * 0.7) -or
        ($proven -and $best.Score -le $current.Score)
    )
    [pscustomobject] @{
        Home = $homePoint
        Rows = $rows
        Best = $best
        Improves = $improves
        TrialSupport = if ($proven) { $trialSupport }
        VisibleCount = $visible.Count
    }
}

function Get-ScanObservationKey($Native, [object[]] $Points, [string] $Band, [datetime] $At) {
    if (-not $Native) { return $At.Ticks }
    $visible = @($Points | Where-Object { $_.Band -eq $Band -and $_.Fresh })
    if (-not $visible.Count) { return }
    $stamped = $visible | Where-Object { $null -ne $_.ObservedAt } |
        Sort-Object ObservedAt -Descending | Select-Object -First 1
    if ($stamped) { return $stamped.ObservedAt }
    if ($Native.Completed) { $Native.FinishedAt }
}

function Format-WifiSignal($Point) {
    if ($null -ne $Point.Rssi) { "$($Point.Rssi) дБм" }
    else { "$($Point.Signal)%" }
}

function Format-WifiPointTip($Point, [string] $Name) {
    $footprint = Get-SignalFootprint $Point.Band $Point.Channel $Point
    $width = if ($footprint.Secondary) { "$($footprint.Width)+$($footprint.Width)" } else { $footprint.Width }
    $widthLabel = if ($footprint.Measured) { 'заявленная полоса' } else { 'оценка полосы' }
    $frequency = if ($Point.Frequency) { " · $($Point.Frequency) МГц" } else { '' }
    $stale = if ($Point.Fresh -eq $false) { ' · предыдущий снимок' } else { '' }
    "$Name · канал $($Point.Channel)$frequency · $(Format-WifiSignal $Point) · $widthLabel $width МГц$stale"
}
