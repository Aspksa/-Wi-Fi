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

function Get-ChannelScore {
    param([int] $Channel, [string] $Band, [object[]] $Neighbors)

    $score = 0.0
    foreach ($point in $Neighbors) {
        $distance = [Math]::Abs($point.Channel - $Channel)
        if ($Band -eq '2.4') {
            $overlap = [Math]::Max(0.0, 1 - $distance / 5.0)
        } else {
            # The scan does not report channel width. Reserve the surrounding 80 MHz block.
            $overlap = 0
            foreach ($start in @(36, 52, 100, 116, 132, 149, 165)) {
                if ($Channel -ge $start -and $Channel -le ($start + 12) -and
                    $point.Channel -ge $start -and $point.Channel -le ($start + 12)) {
                    $overlap = 1
                    break
                }
            }
            if ($distance -eq 0) { $overlap = 1 }
        }
        $score += [Math]::Pow($point.Signal / 100.0, 2) * $overlap * 100
    }
    [Math]::Round($score)
}

function Get-ChannelPlan {
    param([object[]] $Points, [string] $Band, [string[]] $Connected, [hashtable] $PastScores = @{})

    $visible = @($Points | Where-Object Band -eq $Band)
    $neighbors = @($visible | Where-Object { -not $_.Own })
    $homePoint = $visible | Where-Object Own | Sort-Object -Property @(
        @{ Expression = { $_.BSSID -in $Connected }; Descending = $true }
        @{ Expression = { $_.Signal }; Descending = $true }
    ) | Select-Object -First 1

    $candidates = if ($Band -eq '2.4') { @(1, 6, 11) } else { @(36, 40, 44, 48, 149, 153, 157, 161) }
    $observed = @($visible | ForEach-Object { $_.Channel })
    $channels = @($candidates) + $observed | Sort-Object -Unique
    $rows = foreach ($channel in $channels) {
        $score = Get-ChannelScore $channel $Band $neighbors
        $past = $PastScores[[int] $channel]
        [pscustomobject] @{
            Channel = $channel
            Count = @($neighbors | Where-Object Channel -eq $channel).Count
            Score = $score
            Rank = $score + [Math]::Min(15.0, [double] $past * 0.15)
            Candidate = $channel -in $candidates
            Current = $null -ne $homePoint -and $channel -eq $homePoint.Channel
        }
    }

    $best = $rows | Where-Object Candidate | Sort-Object -Property Rank, Score, Channel | Select-Object -First 1
    $current = $rows | Where-Object Current | Select-Object -First 1
    $improves = $null -ne $current -and $current.Score -gt 0 -and
        $best.Score -le $current.Score * 0.7
    [pscustomobject] @{
        Home = $homePoint
        Rows = $rows
        Best = $best
        Improves = $improves
        VisibleCount = $visible.Count
    }
}
