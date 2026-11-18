$ErrorActionPreference = 'Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'RouterInsights.ps1')
function Assert([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
$now=500000L
$network='2.4|test'
$samples=@()
for($i=0;$i -lt 25;$i++){
    $samples+= [pscustomobject]@{ At=($now-119000+$i*2000);Network=$network;Scanning=$false;LanLoss=$false;Lan=5 }
    $samples+= [pscustomobject]@{ At=($now-59000+$i*2000);Network=$network;Scanning=$false;LanLoss=$false;Lan=$(if($i -lt 10){70}else{5}) }
}
$trend=Get-WifiTrendSignal $samples $network $now
Assert ($trend.status -eq 'worsening') 'Sustained increase in local failures detected'
$reverse=@(foreach($s in $samples){
    $copy=$s.PSObject.Copy()
    $copy.Lan= $(if($s.At -lt ($now-60000)){70}else{5})
    $copy
})
Assert ((Get-WifiTrendSignal $reverse $network $now).status -eq 'improving') 'Improving tendency'
Assert ((Get-WifiTrendSignal @($samples[0..5]) $network $now).status -eq 'insufficient') 'Do not predict without enough probes'
$folder=Join-Path ([IO.Path]::GetTempPath()) ('wifi-v21-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
try {
    $path=Join-Path $folder 'capture.json'
    $valid=[pscustomobject]@{routerAddress='192.168.0.1';model='RE3L';requests=@(
        [pscustomobject]@{method='GET';path='/api/status';status=200}
        [pscustomobject]@{method='POST';path='/api/set-channel';status=200}
        [pscustomobject]@{method='GET';path='/api/token';status=200}
        [pscustomobject]@{method='GET';path='https://example.com/a';status=200}
        [pscustomobject]@{method='GET';path='/api/wifi';status=401}
    )}
    [IO.File]::WriteAllText($path,($valid | ConvertTo-Json -Depth 6),[Text.Encoding]::UTF8)
    $result=Get-RouterApiCaptureSummary $path '192.168.0.1'
    Assert ($result.status -eq 'inspection-only' -and $result.readEndpoints -eq 1) 'Only harmless same-gateway GET paths listed'
    Assert (-not $result.entries[0].usable) 'Captured path never classified as usable API'
    Assert ((Get-RouterApiCaptureSummary $path '192.168.0.2').status -eq 'mismatch') 'Reject wrong gateway capture'
} finally { [IO.Directory]::Delete($folder,$true) }
$db=[pscustomobject]@{
    Rows = @( ,@('2.4|test',6,20,100,30,3,1,8.5))
    TrialRows = @( ,@(400000L,1,6,1,30,10,2))
}
$db | Add-Member ScriptMethod Query { param($sql,$params)
    if($sql -match 'channel_trials') { return ,$this.TrialRows }
    return ,$this.Rows
}
$history=@(Get-WifiHourlyEfficiency $db $now)
Assert ($history.Count -eq 1 -and $history[0].channel -eq 6 -and $history[0].badPercent -eq 10) 'SQLite hourly aggregates'
$trials=@(Get-WifiRecentTrials $db $now)
Assert ($trials.Count -eq 1 -and $trials[0].outcome -eq 'improved') 'Previous manual changes exposed'
. (Join-Path $root 'Database.ps1')
$folderSql=Join-Path ([IO.Path]::GetTempPath()) ('wifi-v21-sqlite-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folderSql)
$realDb=$null
try {
    $realDb=Open-WifiDatabase (Join-Path $folderSql 'insights.sqlite')
    $current=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $bucket=[long][Math]::Floor($current / 3600000.0)*3600000L - 3600000L
    foreach($i in @(1,2,3)) {
        [void]$realDb.Query('INSERT INTO samples(session_id,at_ms,network,channel,width_mhz,lan,lan_loss) VALUES(?,?,?,?,?,?,?)',
            @('v21-test',($bucket+$i*1000),'2.4|test',6,20,$(if($i -eq 1){50}else{5}),0))
    }
    [void]$realDb.Query('INSERT INTO channel_trials(id,at_ms,network,old_channel,new_channel,improved,before_bad,after_bad,pairs) VALUES(?,?,?,?,?,?,?,?,?)',
        @('v21-trial',($current-300000L),'2.4|test',1,6,1,10,2,30))
    $realHourly=@(Get-WifiHourlyEfficiency $realDb $current)
    Assert ($realHourly.Count -ge 1 -and $realHourly[0].samples -eq 3 -and $realHourly[0].badPercent -eq 33.3) 'Real SQLite hourly aggregation'
    $realTrials=@(Get-WifiRecentTrials $realDb $current)
    Assert ($realTrials.Count -eq 1 -and $realTrials[0].outcome -eq 'improved') 'Real SQLite trial history'
} finally {
    if($realDb){$realDb.Dispose()}
    [IO.Directory]::Delete($folderSql,$true)
}
'Router v2.1 insights checks passed'
