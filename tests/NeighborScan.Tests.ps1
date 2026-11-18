$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'NeighborScan.ps1')
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$now=1000000L
$points=@(
    [pscustomobject]@{SSID='Home';BSSID='aa:bb:cc:dd:ee:01';Band='2.4';Channel=6;Signal=78;Fresh=$true;Own=$true}
    [pscustomobject]@{SSID='Cafe';BSSID='aa:bb:cc:dd:ee:02';Band='2.4';Channel=1;Signal=60;Fresh=$true;Own=$false}
    [pscustomobject]@{SSID='Cafe';BSSID='aa:bb:cc:dd:ee:02';Band='2.4';Channel=1;Signal=50;Fresh=$true;Own=$false}
    [pscustomobject]@{SSID='Other';BSSID='aa:bb:cc:dd:ee:03';Band='5';Channel=40;Signal=90;Fresh=$true;Own=$false}
    [pscustomobject]@{SSID='Old';BSSID='aa:bb:cc:dd:ee:04';Band='5';Channel=44;Signal=90;Fresh=$false;Own=$false}
)
$summary=Get-WifiNeighborSummary $points 'Windows WLAN' ($now-1000) $now $false
Assert ($summary.status -eq 'observed') 'Native observations marked'
Assert ($summary.neighborCount -eq 2 -and $summary.accessPoints -eq 3) 'Dedup BSSID and exclude own and stale'
Assert ($summary.bands[0].channels[0].channel -eq 1 -and $summary.bands[1].channels[0].channel -eq 40) 'Band/channel distribution'
Assert (-not $summary.hardwareAirtimeMeasured) 'AP count never equates airtime'
Assert ((Get-WifiNeighborSummary $points 'netsh' ($now-1000) $now $false).status -eq 'unverified-age') 'netsh cache age unknown'
Assert ((Get-WifiNeighborSummary $points 'router-export' ($now-1000) $now $false).status -eq 'unverified-import') 'Unverified import remains distinct'
Assert ((Get-WifiNeighborSummary $points 'Windows WLAN' ($now-50000) $now $false).status -eq 'stale') 'Stale scan not trusted'
Assert ((Get-WifiNeighborSummary @() '' 0 $now $true).status -eq 'blocked') 'Windows restriction explicit'
Assert ((Get-WifiNeighborSummary @() 'Windows WLAN' ($now-1000) $now $false).status -eq 'empty') 'Empty scan explicit'
'Neighbor Wi-Fi scanning summary checks passed'
