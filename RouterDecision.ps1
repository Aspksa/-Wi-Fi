# Passive comparison of observed links; never claims an untested channel is faster.
function Get-WifiChannelQuality([object[]] $Samples, [string] $Network, [int] $Channel, [int] $Width, [long] $Now) {
    $recent = @($Samples | Where-Object {
        $_ -and $_.Network -eq $Network -and [int] $_.Channel -eq $Channel -and
        ($Width -le 0 -or [int] $_.Width -eq $Width) -and
        $_.At -ge ($Now - 900000) -and $_.At -le $Now -and
        -not $_.Scanning -and $null -ne $_.LanLoss
    })
    $bad = 0
    $lost = 0
    $latencies = @()
    foreach ($sample in $recent) {
        if ($sample.LanLoss -eq $true) {
            $lost++
            $bad++
        } elseif ($null -ne $sample.Lan) {
            $latencies += [double] $sample.Lan
            if ([double] $sample.Lan -gt 35) { $bad++ }
        }
    }
    $p90 = $null
    if ($latencies.Count) {
        $ordered = @($latencies | Sort-Object)
        $index = [int] [Math]::Ceiling(0.9 * $ordered.Count) - 1
        $p90 = [Math]::Round($ordered[[Math]::Max(0, $index)], 1)
    }
    $qualified = $recent.Count -ge 20 -and $latencies.Count -ge 10
    [pscustomobject] @{
        channel = $Channel; width = $Width; samples = $recent.Count
        lossPercent = $(if ($recent.Count) { [Math]::Round(100.0 * $lost / $recent.Count, 1) })
        badPercent = $(if ($recent.Count) { [Math]::Round(100.0 * $bad / $recent.Count, 1) })
        p90 = $p90; comparable = [bool] $qualified
        source = 'observed-local-gateway'
    }
}

function Get-WifiChannelQualityComparison($Before, $After) {
    if (-not $Before -or -not $After -or -not $Before.comparable -or -not $After.comparable) {
        return [pscustomobject] @{ status = 'insufficient'; explanation = 'Для сравнения каналов нужны не менее 20 замеров каждого состояния без сканирования.' }
    }
    # A strict safety guard: a different location, client or time of day can change results.
    $lossDelta = [double] $After.badPercent - [double] $Before.badPercent
    $latencyDelta = [double] $After.p90 - [double] $Before.p90
    $status = 'unclear'
    if ($lossDelta -le -5 -and $latencyDelta -le 0) { $status = 'improved' }
    elseif ($lossDelta -ge 5 -and $latencyDelta -ge 0) { $status = 'worse' }
    [pscustomobject] @{
        status = $status
        before = $Before; after = $After
        explanation = ('Наблюдения: плохих проб {0}% → {1}%; p90 {2} → {3} мс. Причинность не доказана.' -f
            $Before.badPercent,$After.badPercent,$Before.p90,$After.p90)
    }
}

function Get-WifiQualityRanking($Plan, [object[]] $Samples, [string] $Network, [long] $Now) {
    $rows = @()
    if (-not $Plan -or -not $Plan.Rows) { return $rows }
    foreach ($row in @($Plan.Rows | Where-Object { $_.Candidate })) {
        $quality = Get-WifiChannelQuality $Samples $Network ([int] $row.Channel) ([int] $row.Width) $Now
        $rows += [pscustomobject] @{
            channel = [int] $row.Channel; width = [int] $row.Width
            interferenceEstimate = [double] $row.Score
            historicalRank = [double] $row.Rank
            measuredQuality = $quality
            tested = [bool] $quality.comparable
            # Only small penalties from real past measurements; never fabricate performance for untested channels.
            rank = [Math]::Round(([double] $row.Rank + $(if ($quality.comparable) {
                [Math]::Min(30.0, [double] $quality.badPercent * 0.4 + [double] $quality.p90 * 0.02)
            } else { 0 })), 2)
        }
    }
    @($rows | Sort-Object rank, interferenceEstimate, channel)
}
