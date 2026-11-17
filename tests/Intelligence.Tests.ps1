$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'Scan.ps1')
. (Join-Path $project 'Visuals.ps1')
. (Join-Path $project 'Monitor.ps1')
. (Join-Path $project 'Intelligence.ps1')
. (Join-Path $project 'Database.ps1')
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Sample([long] $when, [int] $channel = 6, $lan = 5, $wan = $null, $upload = 20, [string] $overlap = 'clear') {
    [pscustomobject] @{ At=$when; Network='2.4|aa|Дом'; Channel=$channel; Signal=75; Upload=$upload; Overlap=$overlap
        Lan=$lan; LanLoss=$false; Wan=$wan; WanLoss=$false }
}
$t = 1000000L
$e = New-WifiIntelligence
$local = @(Sample $t 6 60 $null 20 'changed'; Sample ($t+350) 6 70 $null 20 'changed')
Assert ((Get-EpisodeConclusion $local).Cause -eq 'local-overlap') 'Local episode and overlap correlation'
$external = @(Sample $t 6 5 252 2100; Sample ($t+3000) 6 4 244 2900)
Assert ((Get-EpisodeConclusion $external).Cause -eq 'upload') 'WAN lag with local upload is classified separately'
Assert ((Get-EpisodeConclusion @(Sample $t 6 5 252)).Cause -eq 'uncertain') 'One bad sample remains uncertain'
Add-WifiSample $e $local[0] $null
Add-WifiSample $e $local[1] $null
Assert ($e.BurstUntil -eq $t+10000) 'First high-latency sample starts brief burst'
$episode = @(Add-WifiSample $e (Sample ($t+9000)) $null)
Assert ($episode.Count -eq 1 -and $episode[0].Cause -eq 'local-overlap' -and $e.PendingIncidents.Count -eq 1) 'Incident closes and buffers evidence'
$before = @(for ($i=0; $i -lt 37; $i++) { Sample ($t + $i * 1000) 6 $(if ($i -lt 14) { 52 } else { 4 }) })
$after = @(for ($i=0; $i -lt 37; $i++) { Sample ($t + 140000 + $i * 1000) 11 4 })
$trial = Get-ChannelTrialResult @{ Network='2.4|aa|Дом'; Old=6; New=11; Before=$before } $after ($t+200000)
Assert ($trial.Improved -eq 1 -and $trial.BeforeBad -eq 14 -and $trial.AfterBad -eq 0 -and $trial.Pairs -eq 37) 'Measured channel trial captures real gains'
Assert ($trial.BeforeP90 -eq 52 -and $trial.AfterP90 -eq 4) 'Tail latency is calculated'
$after | ForEach-Object { $_.Upload=2000 }
$unmatched = Get-ChannelTrialResult @{ Network='2.4|aa|Дом'; Old=6; New=11; Before=$before } $after ($t+200000)
Assert ($null -eq $unmatched.Improved -and $unmatched.Pairs -eq 0) 'Different load is not compared'
$after | ForEach-Object { $_.Upload=20; $_.Signal=48 }
$unmatched = Get-ChannelTrialResult @{ Network='2.4|aa|Дом'; Old=6; New=11; Before=$before } $after ($t+200000)
Assert ($null -eq $unmatched.Improved -and $unmatched.Pairs -eq 0) 'Different signal is not compared'
Assert ((Test-ForecastConfidence @{Count=10;Bad=8;Predicted=5;Correct=4})) 'Consistent pattern allows forecast'
Assert (-not (Test-ForecastConfidence @{Count=10;Bad=8;Predicted=5;Correct=1})) 'Repeated false forecasts reduce confidence'
$radio0 = [pscustomobject] @{SSID='Дом'; BSSID='aa'; Band='2.4'; Channel=6; Signal=75; Own=$true}
$neighbor = [pscustomobject] @{SSID='Сосед'; BSSID='bb'; Band='2.4'; Channel=11; Signal=95; Own=$false}
$previous = Get-WifiRadioContext @($radio0,$neighbor) @('aa') $null $t
$neighbor.Channel = 6
$current = Get-WifiRadioContext @($radio0,$neighbor) @('aa') $previous ($t+30000)
Assert ($current.Signature -eq 'bb/6' -and $current.ChangedAt -eq $t+30000) 'Radio changes are observed per BSSID and band'
Assert ((Get-UploadRate @{At=$t;Bytes=0} 125000 ($t+1000)) -eq 1000) 'Upload converts bytes to kilobits per second'
Assert ($null -eq (Get-UploadRate @{At=$t;Bytes=2000} 0 ($t+1000))) 'Counter resets invalidate load'
$plan = Get-ChannelPlan @($radio0) '2.4' @('aa') @{} @{11=[pscustomobject] @{Count=3;Wins=3;Losses=0}}
Assert ($plan.Improves -and $plan.Best.Channel -eq 11 -and $plan.TrialSupport.Wins -eq 3) 'Proven improvement can distinguish equally quiet channels'

$replay = New-WifiIntelligence
$network = $trial.Network
$start = 2000000L
$beforeRadio = [pscustomobject] @{ Network=$network; Channel=6; At=$start+59000 }
Update-WifiRadio $replay $beforeRadio $start
for ($i = 0; $i -lt 60; $i++) {
    $latency = if ($i % 3 -eq 0) { 70 } else { 4 }
    $null = Add-WifiSample $replay (Sample ($start + $i * 1000) 6 $latency) $null
}
$switchAt = $start + 60000
Update-WifiRadio $replay ([pscustomobject] @{ Network=$network; Channel=11; At=$switchAt }) $switchAt
Assert ($replay.Trial.Old -eq 6 -and $replay.Trial.New -eq 11) 'A change on the same radio starts a comparison'
for ($i = 15; $i -le 106; $i++) {
    $null = Add-WifiSample $replay (Sample ($switchAt + $i * 1000) 11 4) $null
}
Assert ($replay.PendingTrials.Count -eq 1 -and $replay.PendingTrials[0].Improved -eq 1) 'Engine finishes an observed channel comparison'

$forecastEngine = New-WifiIntelligence
$forecastEvidence = { param($network, $context) @{ Count=12; Bad=10; Predicted=4; Correct=4 } }
$forecast = @(Add-WifiSample $forecastEngine (Sample $start) $forecastEvidence)
Assert ($forecast.Count -eq 1 -and $forecast[0].Forecast) 'A strong historical pattern can warn before a bad sample'
for ($i = 1; $i -le 61; $i++) {
    $null = Add-WifiSample $forecastEngine (Sample ($start + $i * 1000)) $forecastEvidence
}
Assert ($forecastEngine.PendingChecks.Count -eq 1 -and $forecastEngine.PendingChecks[0].Predicted -and
    -not $forecastEngine.PendingChecks[0].Actual) 'False forecasts are recorded for calibration'

if ([Environment]::OSVersion.Platform -eq 'Unix') {
    $source = Get-Content -LiteralPath (Join-Path $project 'WifiSqlite.cs') -Raw
    Add-Type -TypeDefinition ($source.Replace('"winsqlite3.dll"', '"libsqlite3.so.0"'))
}
$folder = Join-Path ([IO.Path]::GetTempPath()) ('wifi-sql-' + [guid]::NewGuid().ToString('N'))
$dbPath = Join-Path $folder 'Тест SQLite.sqlite'
try {
    $db = Open-WifiDatabase $dbPath
    $legacy = Join-Path $folder 'history.json'
    $record = New-MonitorHistory
    Add-MonitorEvent $record (Get-Date) 'Существующее событие'
    Save-MonitorHistory $record $legacy
    Assert ((Get-DatabaseHistory $db $legacy).Events[0].Message -eq 'Существующее событие') 'Legacy JSON migrates'
    Set-DatabaseSetting $db "key'withquote" 'Привет'
    Assert ((Get-DatabaseSetting $db "key'withquote") -eq 'Привет') 'Parameter binding handles UTF8 and quotes'
    $e.PendingTrials.Add($trial)
    $e.PendingScans.Add([pscustomobject] @{ At=$t; Network=$trial.Network; Points=@($radio0, $neighbor) })
    $e.PendingChecks.Add([pscustomobject] @{Id='forecast';At=$t;Network=$trial.Network;Context='6|quiet|clear';Predicted=$true;Actual=$true})
    Save-Intelligence $db $e
    Assert ($e.PendingSamples.Count -eq 0 -and $e.PendingIncidents.Count -eq 0) 'Commit clears pending records'
    Assert ($db.Query('SELECT count(*) FROM samples',@())[0][0] -eq 3) 'SQLite contains measurements'
    Assert ($null -eq $db.Query('SELECT wan FROM samples ORDER BY at_ms LIMIT 1',@())[0][0]) 'Missing measurement stays SQL NULL'
    Assert ($db.Query('SELECT cause FROM incidents',@())[0][0] -eq 'local-overlap') 'SQLite contains incident'
    $observed = $db.Query('SELECT observed_points FROM radio_scans',@())[0][0] | ConvertFrom-Json
    Assert ($observed.Count -eq 2 -and $observed[1].SSID -eq 'Сосед') 'Spectrum snapshots are stored with their original observations'
    Assert ((Get-TrialMemory $db $trial.Network 6)[11].Wins -eq 1) 'SQLite trial memory loads evidence'
    Assert ((Get-ForecastEvidence $db $trial.Network '6|quiet|clear').Correct -eq 1) 'SQLite forecast evaluation persists'
    $db.Dispose()
    $db = Open-WifiDatabase $dbPath
    Assert ((Get-DatabaseHistory $db 'missing').Events[0].Message -eq 'Существующее событие') 'Restarts read migrated data from SQLite'
    Remove-ExpiredMeasurements $db ($t + 3L * 86400000)
    Assert ($db.Query('SELECT count(*) FROM samples',@())[0][0] -eq 0) 'Measurements expire'
    Assert ($db.Query('SELECT count(*) FROM radio_scans',@())[0][0] -eq 0) 'Snapshot retention is bounded'
    Assert ($db.Query('SELECT count(*) FROM incidents',@())[0][0] -eq 1) 'Incident retention differs from samples'
} finally {
    if ($db) { $db.Dispose() }
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse }
}
'Passed 31 intelligence and SQLite checks'
