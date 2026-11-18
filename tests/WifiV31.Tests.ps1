$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'WifiReliabilityV31.ps1')
. (Join-Path $root 'WifiResearchV31.ps1')
. (Join-Path $root 'WifiLongMemoryV31.ps1')
. (Join-Path $root 'Database.ps1')
. (Join-Path $root 'PcapOffline.ps1')
. (Join-Path $root 'PcapngOfflineV31.ps1')
function Assert([bool]$Okay,[string]$Why){if(-not $Okay){throw $Why}}
$recovery=New-WifiRecoveryState
Assert (-not (Test-WifiRecoveryRetry $recovery $true 30000L)) 'No blocked scans before minimum cooldown'
Assert (Test-WifiRecoveryRetry $recovery $true 120001L) 'Autoretry allowed after cooldown'
$recovery.LastRetryAt=120001L
Assert (-not (Test-WifiRecoveryRetry $recovery $true 140000L)) 'No repeated active scans'
Assert ((Get-WifiFailureCategory 'location access denied' $false $false) -eq 'permissions') 'Permissions classification'
Assert ((Get-WifiFailureCategory 'adapter is off' $false $false) -eq 'adapter') 'Adapter classification'
Assert ((Get-WifiFailureCategory 'WLAN AutoConfig service not running' $false $false) -eq 'wlan-service') 'Service classification'
Assert ((Get-WifiFailureCategory '' $false $true) -eq 'timeout') 'Timeout classification'
Add-WifiRecoveryEvent $recovery 200000L 'driver error'
Assert ($recovery.Failures -eq 1 -and $recovery.Events[0].kind -eq 'driver-or-api') 'Recovery history'
Reset-WifiRecovery $recovery
Assert ($recovery.Failures -eq 0 -and $recovery.Events.Count -eq 1) 'Successful scan resets failures, not history'
Assert ((Get-WifiRecoveryDelay 99 $false) -le 120000) 'Bounded exponential backoff'
$bands=@(Get-WifiBandEvidence @([pscustomobject]@{Band='6';Fresh=$true}))
Assert ($bands.Count -eq 3 -and $bands[2].observed -eq 1 -and $bands[0].hardwareSupport -eq 'not-verified') '6 GHz observed does not imply other band support'
$memory=New-WifiResearchMemory
$p=[pscustomobject]@{BSSID='aa:bb:cc:dd:ee:01';SSID='Home';Channel=1;Band='2.4';Fresh=$true;Rssi=-48;Capabilities=@{Generation='Wi-Fi 5';Rsn=$true}}
Update-WifiResearchMemory $memory @($p) 200000L $true
$p.Channel=6
$p.Rssi=-75
Update-WifiResearchMemory $memory @($p) 220000L $true
Assert ($memory.Changes.Count -eq 1 -and $memory.Changes[0].changes -contains 'rssi-jump') 'BSSID signal and channel anomalies'
Add-WifiInvestigation $memory 230000L 'timeout' @($p) @([pscustomobject]@{at=229000L;lost=$true;ms=$null})
Add-WifiInvestigation $memory 240000L 'timeout' @($p) @()
Assert ($memory.Incidents.Count -eq 2 -and $memory.Alerts.Count -eq 1) 'Incident history and alert dedup'
Assert ((Get-WifiResearchConfidence $memory 2 'netsh' 1000L).level -eq 'low') 'Unverified scan confidence stays low'
Assert ((Get-WifiResearchConfidence $memory 3 'Windows WLAN' 1000L).level -eq 'medium') 'Independent scan evidence medium'
$folder=Join-Path ([IO.Path]::GetTempPath()) ('wifi-v31-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
$db=$null
try {
    $db=Open-WifiDatabase (Join-Path $folder 'wifi.sqlite')
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $yesterday=([long][Math]::Floor($now/86400000.0)-1)*86400000L
    for($i=1;$i -le 4;$i++){
        [void]$db.Query('INSERT INTO samples(session_id,at_ms,network,channel,lan,lan_loss) VALUES(?,?,?,?,?,?)',
            @('v31',($yesterday+$i*3600000),'5|home',36,$(if($i -eq 1){90}else{5}),0))
    }
    Update-WifiLongMemory $db $now
    $daily=@(Get-WifiHistoricalQuality $db)
    Assert ($daily.Count -ge 1 -and $daily[0].samples -eq 4 -and $daily[0].badPercent -eq 25) 'Daily aggregates from real SQLite'
    $backup=Save-WifiVerifiedBackup $db (Join-Path $folder 'backups') $now
    Assert ($backup.status -eq 'verified') 'Consistent online backup and integrity check'
    Assert (@(Get-ChildItem (Join-Path $folder 'backups') -Filter '*.sqlite').Count -eq 1) 'Backup file persisted'
    $report=Save-WifiLocalReport (Join-Path $folder 'reports') ([pscustomobject]@{label='<script>alert(1)</script>';count=1}) $now
    Assert ((Test-Path $report.json) -and (Test-Path $report.html)) 'Local HTML and JSON created'
    Assert ((Get-Content $report.html -Raw) -notmatch '<script>alert') 'HTML report escapes untrusted values'
} finally {
    if($db){$db.Dispose()}
    [IO.Directory]::Delete($folder,$true)
}
# Synthetic PCAPNG: SHB, IDB (105) and an EPB with one Beacon.
$ngDir=Join-Path ([IO.Path]::GetTempPath()) ('wifi-pcapng-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($ngDir)
$ngPath=Join-Path $ngDir 'beacon.pcapng'
try{
    $beacon=[byte[]]::new(36)
    $beacon[0]=0x80
    [Array]::Copy([byte[]]@(1,2,3,4,5,6),0,$beacon,16,6)
    $payload=[byte[]]($beacon+[byte[]]@(0,0))
    $padded=[byte[]]($payload+[byte[]]@(0,0))
    $out=[IO.File]::Create($ngPath)
    $write=[IO.BinaryWriter]::new($out)
    try {
        $write.Write([byte[]]@(0x0a,0x0d,0x0d,0x0a))
        $write.Write([uint32]28)
        $write.Write([byte[]]@(0x4d,0x3c,0x2b,0x1a,1,0,0,0,255,255,255,255,255,255,255,255))
        $write.Write([uint32]28)
        $write.Write([uint32]1);$write.Write([uint32]20)
        $write.Write([uint16]105);$write.Write([uint16]0)
        $write.Write([uint32]65535);$write.Write([uint32]20)
        $write.Write([uint32]6);$write.Write([uint32]72)
        $write.Write([uint32]0);$write.Write([uint32]0);$write.Write([uint32]0)
        $write.Write([uint32]38);$write.Write([uint32]38)
        $write.Write($padded);$write.Write([uint32]72)
    } finally {$write.Dispose()}
    $ng=Read-WifiPcapng $ngPath
    Assert ($ng.format -eq 'pcapng' -and $ng.networks.Count -eq 1 -and $ng.networks[0].hiddenSsid) 'PCAPNG synthetic beacon imported'
    $bytes=[IO.File]::ReadAllBytes($ngPath)
    $bytes[$bytes.Length-1]=0
    [IO.File]::WriteAllBytes($ngPath,$bytes)
    $invalid=$false
    try {[void](Read-WifiPcapng $ngPath)} catch {$invalid=$true}
    Assert $invalid 'Corrupt PCAPNG block length rejected'
} finally {[IO.Directory]::Delete($ngDir,$true)}
Add-Type -Path (Join-Path $root 'WifiNativeScan.cs')
$method=[WiFi.NativeScanner].GetMethod('ChannelOf',[Reflection.BindingFlags]'Static,NonPublic')
$args=[object[]]@(5955,$null)
$ch=$method.Invoke($null,$args)
Assert ($ch -eq 1 -and $args[1] -eq '6') '6 GHz channel one via native frequency'
$args=[object[]]@(5935,$null)
Assert ($method.Invoke($null,$args) -eq 2 -and $args[1] -eq '6') '6 GHz channel 2 special frequency'
$args=[object[]]@(7115,$null)
Assert ($method.Invoke($null,$args) -eq 233) '6 GHz upper edge'
$args=[object[]]@(7145,$null)
Assert ($method.Invoke($null,$args) -eq 0) 'Out-of-band entry excluded'
'Wi-Fi v3.1 resilience, radio geometry, PCAPNG and backup tests passed'
