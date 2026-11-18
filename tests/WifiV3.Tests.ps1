$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Scan.ps1')
. (Join-Path $root 'WifiV3.ps1')
. (Join-Path $root 'PcapOffline.ps1')
Add-Type -Path (Join-Path $root 'WifiNativeScan.cs')
function Assert([bool]$Ok,[string]$Message) {if(-not $Ok){throw $Message}}
$ie=[byte[]]@(45,0,191,0,48,0,255,2,35,1,255,2,108,1,221,4,80,111,154,9)
$caps=[WiFi.NativeScanner]::DecodeCapabilities($ie)
Assert ($caps.Ht -and $caps.Vht -and $caps.He -and $caps.Eht -and $caps.Rsn -and $caps.WifiDirect) 'Beacon IE flags correctly recognized'
Assert ($caps.Generation -match 'Wi-Fi 7') 'Advertised generation is capability only'
$bad=[WiFi.NativeScanner]::DecodeCapabilities([byte[]]@(255,8,108,1))
Assert ($bad.Truncated -and -not $bad.Eht) 'Truncated IE never establishes EHT'
$empty=[WiFi.NativeScanner]::DecodeCapabilities([byte[]]@())
Assert (-not $empty.He -and -not $empty.Eht) 'Empty IEs are unverified'
$point=[pscustomobject]@{SSID='';HiddenSsid=$true; BSSID='aa:bb:cc:dd:ee:01';Band='5';Fresh=$true;RadioWidth=@{Width=80;Center=5210};Capabilities=$caps}
$summary=Get-WifiV3RadioSummary @($point) (New-WifiRoamTracker) 200000L $true
Assert ($summary.hidden -eq 1 -and $summary.he -eq 1 -and $summary.eht -eq 1 -and $summary.p2pAdvertised -eq 1) 'Hidden and HE/EHT/P2P exposed'
Assert ($summary.widthGeometry[0].width -eq 80) 'Known geometry propagated'
$tracker=New-WifiRoamTracker
Assert (Update-WifiRoamTracker $tracker 'aa:bb:cc:dd:ee:01' 'Home' 100000L $true @()) 'Initial connected BSSID'
Assert (-not (Update-WifiRoamTracker $tracker 'aa:bb:cc:dd:ee:02' 'Home' 110000L $false @())) 'Unconfirmed roam rejected'
Assert (Update-WifiRoamTracker $tracker 'aa:bb:cc:dd:ee:02' 'Home' 120000L $true @([pscustomobject]@{at=115000L;lost=$true;ms=$null})) 'Roam accepted'
Assert ($tracker.Changes.Count -eq 1 -and $tracker.Changes[0].localProblemsNearby -eq 1 -and $tracker.Changes[0].cause -eq 'unverified') 'Nearby loss not treated as causal'
Assert (-not (Update-WifiRoamTracker $tracker 'aa:bb:cc:dd:ee:03' 'Home' 120000L $true @())) 'Repeated scan cannot replay roam'
$hyp=Get-WifiV3Hypotheses $summary @{volatile=1} @()
Assert ($hyp.status -eq 'hypotheses' -and -not $hyp.automaticChanges) 'Research suggestions remain observational'
$monitor=Get-WifiV3CaptureCapabilities
Assert (-not $monitor.captureEnabled) 'Monitor mode never enabled automatically'
# Construct safe offline libpcap with a single 802.11 beacon frame, 802.11 linktype=105.
$folder=Join-Path ([IO.Path]::GetTempPath()) ('wifi-v3-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
$path=Join-Path $folder 'beacon.pcap'
try {
    $frame=[byte[]]::new(36)
    $frame[0]=0x80
    $mac=[byte[]]@(0xaa,0xbb,0xcc,0xdd,0xee,0x01)
    [Array]::Copy($mac,0,$frame,16,6)
    $payload=[byte[]]($frame + [byte[]]@(0,0) + $ie)
    $header=[byte[]]@(0xd4,0xc3,0xb2,0xa1,2,0,4,0,0,0,0,0,0,0,0,0,0xff,0xff,0,0,105,0,0,0)
    $record=[byte[]]::new(16)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$payload.Length),0,$record,8,4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$payload.Length),0,$record,12,4)
    [IO.File]::WriteAllBytes($path,[byte[]]($header+$record+$payload))
    $scan=Read-WifiPcap $path
    Assert ($scan.packetsRead -eq 1 -and $scan.networks.Count -eq 1) 'PCAP packet parsed'
    Assert ($scan.networks[0].hiddenSsid -and $scan.networks[0].eht -and $scan.networks[0].p2p) 'Offline IE evidence'
    Assert (-not $scan.containsRadioMeasurements -and $scan.networks[0].notLive) 'Offline not mislabeled live RF'
    $invalid=Join-Path $folder 'invalid.pcap'
    [IO.File]::WriteAllBytes($invalid,[byte[]]::new(24))
    $failed=$false
    try {[void](Read-WifiPcap $invalid)} catch {$failed=$true}
    Assert $failed 'Unsupported capture rejected'
} finally {
    [IO.Directory]::Delete($folder,$true)
}
'Wi-Fi v3 radio IE, roam and offline capture checks passed'
