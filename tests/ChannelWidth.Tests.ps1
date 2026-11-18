$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'Scan.ps1')
. (Join-Path $project 'Monitor.ps1')
. (Join-Path $project 'Intelligence.ps1')
. (Join-Path $project 'Database.ps1')

function Assert($Value, [string] $Message) {
    if (-not $Value) { throw $Message }
}

function New-Point([int] $Channel, [int] $Width, [int] $Center, [bool] $Owned) {
    [pscustomobject] @{
        Channel = $Channel; Band = '5'; Frequency = 5000 + 5 * $Channel
        BSSID = $(if ($Owned) { '00:00:00:00:00:01' } else { '00:00:00:00:00:02' })
        Own = $Owned; Fresh = $true; Signal = 94; SSID = 'Тест'
        RadioWidth = $(if ($Width) { @{ Width = $Width; Center = $Center } })
    }
}

$router = New-Point 40 160 5250 $true
$dfsNeighbor = New-Point 56 80 5290 $false
$plan = Get-ChannelPlan @($router, $dfsNeighbor) '5' @()
Assert ($plan.Improves -and $plan.Best.Channel -eq 40 -and $plan.Best.Width -eq 80) 'Narrowing may keep the current primary channel'
Assert ($plan.Current.Width -eq 160 -and $plan.Current.Score -gt 0 -and $plan.Best.Score -eq 0) 'Compare the occupied spectrum at both widths'
Assert ($null -eq (Get-CandidateFootprint '5' 149 $router 160)) 'Upper group is not assumed to offer 160 MHz'
Assert (-not (Get-ChannelPlan @($router) '5' @()).Improves) 'A clear channel does not need narrowing'

$router80 = New-Point 40 80 5210 $true
$lowNeighbor = New-Point 44 80 5210 $false
$plan80 = Get-ChannelPlan @($router80, $lowNeighbor) '5' @()
Assert ($plan80.Improves -and $plan80.Best.Channel -eq 149 -and $plan80.Best.Width -eq 80) 'A cleaner candidate at the existing width takes precedence'
$unknown = New-Point 40 0 0 $true
Assert ($null -eq (Get-ChannelPlan @($unknown, $lowNeighbor) '5' @()).Best.Width) 'Unknown width keeps channel-only recommendations'

$history = New-MonitorHistory
$at = [datetime] '2026-11-17T19:30:00'
Update-HeatHistory $history @{'5'=$plan} ($at.AddDays(-1))
Update-HeatHistory $history @{'5'=$plan80} ($at.AddDays(-1))
$history160 = Get-PastScores $history $at '5' 160
$history80 = Get-PastScores $history $at '5' 80
Assert ($history160[40] -eq $plan.Current.Score -and $history80[40] -eq $plan80.Current.Score) 'Same-hour estimates are kept apart by width'

$engine = New-WifiIntelligence
$start = 3000000L
$network = Get-WifiNetworkKey $router
$firstRadio = Get-WifiRadioContext @($router) @($router.BSSID) $null ($start + 59000)
Update-WifiRadio $engine $firstRadio $firstRadio.At
function New-Sample([long] $When, [int] $Width, [int] $Latency) {
    [pscustomobject] @{ At=$When; Network=$network; Channel=40; Width=$Width; Signal=80; Upload=60; Overlap='clear'
        Lan=$Latency; LanLoss=$false; Wan=$null; WanLoss=$null }
}
for ($i = 0; $i -lt 60; $i++) {
    $latency = if ($i % 3 -eq 0) { 75 } else { 8 }
    $null = Add-WifiSample $engine (New-Sample ($start + 1000 * $i) 160 $latency) $null
}
$transition = $start + 60000
$secondRadio = Get-WifiRadioContext @($router80) @($router80.BSSID) $firstRadio $transition
Update-WifiRadio $engine $secondRadio $transition
Assert ($engine.Trial.OldWidth -eq 160 -and $engine.Trial.NewWidth -eq 80 -and $engine.Trial.Old -eq $engine.Trial.New) 'A width-only transition starts a measured trial'
for ($i = 15; $i -le 105; $i++) {
    $null = Add-WifiSample $engine (New-Sample ($transition + 1000 * $i) 80 7) $null
}
Assert ($engine.PendingTrials.Count -eq 1 -and $engine.PendingTrials[0].Improved -eq 1) 'Width-only trial completes from matching samples'
Assert ((Get-SampleContext (New-Sample $start 160 10)) -ne (Get-SampleContext (New-Sample $start 80 10))) 'Forecasts do not mix widths'

if ([Environment]::OSVersion.Platform -eq 'Unix') {
    $source = Get-Content -LiteralPath (Join-Path $project 'WifiSqlite.cs') -Raw
    Add-Type -TypeDefinition ($source.Replace('"winsqlite3.dll"', '"libsqlite3.so.0"'))
} else {
    Add-Type -Path (Join-Path $project 'WifiSqlite.cs')
}

$folder = Join-Path ([IO.Path]::GetTempPath()) ('wifi-width-' + [guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($folder)
try {
    $path = Join-Path $folder 'wifi.sqlite'
    $db = [WiFi.Sqlite]::new($path)
    [void] $db.Query(@'
CREATE TABLE channel_trials (
    id TEXT PRIMARY KEY, at_ms INTEGER NOT NULL, network TEXT NOT NULL, old_channel INTEGER,
    new_channel INTEGER, improved INTEGER, before_bad INTEGER, after_bad INTEGER, pairs INTEGER,
    before_p90 REAL, after_p90 REAL, description TEXT
)
'@, @())
    [void] $db.Query('INSERT INTO channel_trials VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
        @('legacy', $start, $network, 40, 48, 1, 7, 2, 30, 40, 9, 'Старая запись'))
    [void] $db.Query('PRAGMA user_version=1', @())
    $db.Dispose()
    $db = Open-WifiDatabase $path
    Assert ($db.Query('PRAGMA user_version', @())[0][0] -eq 2) 'Schema v1 is migrated to v2'
    Assert ((Get-TrialMemory $db $network 40)[48].Wins -eq 1) 'Legacy trial remains available'
    Save-Intelligence $db $engine
    $matched = Get-TrialMemory $db $network 40 160
    Assert ($matched.Count -eq 1 -and $matched['40/80'].Wins -eq 1) 'Read results for the matching pair only'
    Assert ((Get-TrialMemory $db $network 40 80).Count -eq 0) 'Reverse-width evidence is not inferred'
    Assert ($db.Query('SELECT COUNT(*) FROM samples WHERE width_mhz=80', @())[0][0] -gt 0) 'Measurements persist with channel width'
    $db.Dispose()
    $db = Open-WifiDatabase $path
    Assert ((Get-TrialMemory $db $network 40 160)['40/80'].Wins -eq 1) 'Reopening preserves pair data'
} finally {
    if ($db) { $db.Dispose() }
    Remove-Item -LiteralPath $folder -Recurse -ErrorAction SilentlyContinue
}
'Passed 16 channel-width and migration checks'
