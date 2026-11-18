$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'RouterDecision.ps1')
function Assert([bool] $Check, [string] $Description) { if (-not $Check) { throw $Description } }
$now = 1000000L
$network = '2.4|lab'
$observed = @()
for ($i = 0; $i -lt 30; $i++) {
    $observed += [pscustomobject] @{
        At = $now - (30000 - $i * 1000); Network = $network; Channel = 1; Width = 20
        Lan = $(if ($i -lt 8) { 50 } else { 5 }); LanLoss = $false; Scanning = $false
    }
    $observed += [pscustomobject] @{
        At = $now - (30000 - $i * 1000); Network = $network; Channel = 6; Width = 20
        Lan = 4; LanLoss = $false; Scanning = $false
    }
}
$before = Get-WifiChannelQuality $observed $network 1 20 $now
$after = Get-WifiChannelQuality $observed $network 6 20 $now
Assert ($before.comparable -and $after.comparable) 'Enough clean measurements'
Assert ($before.badPercent -gt $after.badPercent) 'Bad probes are recorded'
Assert ((Get-WifiChannelQualityComparison $before $after).status -eq 'improved') 'Real improvement'
Assert ((Get-WifiChannelQualityComparison $after $before).status -eq 'worse') 'Regression classification'
Assert ((Get-WifiChannelQualityComparison $null $after).status -eq 'insufficient') 'No unfounded comparison'
Assert (-not (Get-WifiChannelQuality $observed $network 11 20 $now).comparable) 'Untested channel cannot count as tested'
$plan = [pscustomobject] @{ Rows = @(
    [pscustomobject] @{ Channel=1; Width=20; Score=10.0; Rank=11.0; Candidate=$true }
    [pscustomobject] @{ Channel=6; Width=20; Score=12.0; Rank=12.0; Candidate=$true }
    [pscustomobject] @{ Channel=11; Width=20; Score=9.0; Rank=9.0; Candidate=$true }
) }
$rank = @(Get-WifiQualityRanking $plan $observed $network $now)
Assert ($rank.Count -eq 3) 'Ranking includes all candidates'
Assert (@($rank | Where-Object { $_.channel -eq 11 -and -not $_.tested }).Count -eq 1) 'Untested marked clearly'
Assert (@($rank | Where-Object { $_.channel -eq 1 -and $_.measuredQuality.badPercent -gt 0 }).Count -eq 1) 'Measured loss reflected in ranking'
'Router channel quality checks passed'
