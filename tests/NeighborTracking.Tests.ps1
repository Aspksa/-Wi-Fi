$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'NeighborTracking.ps1')
function Assert([bool]$Result,[string]$Description){if(-not $Result){throw $Description}}
function Point([int]$Channel,[long]$Observed) {
    [pscustomobject]@{
        SSID='Сосед'; BSSID='aa:bb:cc:dd:ee:01';Band='2.4';Channel=$Channel
        Signal=75;ObservedAt=$Observed;Fresh=$true;Own=$false
    }
}
$tracker=New-WifiNeighborTracker
Assert (-not (Update-WifiNeighborTracker $tracker @((Point 1 100000L)) 100000L 'netsh' $true)) 'netsh is not a complete independent survey'
Assert (-not (Update-WifiNeighborTracker $tracker @((Point 1 100000L)) 100000L 'Windows WLAN' $false)) 'Passive cache is not a new survey'
Assert ((Get-WifiNeighborEvolution $tracker 100000L).status -eq 'waiting') 'No observations before active scan'
Assert (Update-WifiNeighborTracker $tracker @((Point 1 100000L)) 100000L 'Windows WLAN' $true) 'First scan accepted'
Assert (-not (Update-WifiNeighborTracker $tracker @((Point 1 100000L)) 100000L 'Windows WLAN' $true)) 'Duplicate timestamp discarded'
Assert ((Get-WifiNeighborEvolution $tracker 100000L).new -eq 1) 'Single sighting not stable'
Assert (Update-WifiNeighborTracker $tracker @((Point 1 130000L)) 130000L 'Windows WLAN' $true) 'Second scan accepted'
Assert ((Get-WifiNeighborEvolution $tracker 130000L).tentative -eq 1) 'Two sightings still tentative'
Assert (Update-WifiNeighborTracker $tracker @((Point 6 160000L)) 160000L 'Windows WLAN' $true) 'Third scan accepted'
$result=Get-WifiNeighborEvolution $tracker 160000L
Assert ($result.stable -eq 1) 'Three sightings establish stability'
Assert (@($result.changes | Where-Object {$_.type -eq 'channel-shift' -and $_.from -eq 1 -and $_.to -eq 6}).Count -eq 1) 'Observed channel change'
Assert (Update-WifiNeighborTracker $tracker @() 190000L 'Windows WLAN' $true) 'First missing scan processed'
Assert ((Get-WifiNeighborEvolution $tracker 190000L).notObserved -eq 0) 'One missing scan not counted as disappearance'
Assert (Update-WifiNeighborTracker $tracker @() 220000L 'Windows WLAN' $true) 'Second missing scan processed'
Assert ((Get-WifiNeighborEvolution $tracker 220000L).notObserved -eq 1) 'Two missing scans classified cautiously'
$other=New-WifiNeighborTracker
Assert (Update-WifiNeighborTracker $other @((Point 1 1L)) 500000L 'Windows WLAN' $true) 'Stale point not crash'
Assert ((Get-WifiNeighborEvolution $other 500000L).new -eq 0) 'Old point excluded'
Assert (Update-WifiNeighborTracker $other @([pscustomobject]@{SSID='invalid';BSSID='abc';Band='2.4';Channel=6;Signal=90;Fresh=$true;Own=$false}) 530000L 'Windows WLAN' $true) 'Invalid entries handled'
Assert ((Get-WifiNeighborEvolution $other 530000L).new -eq 0) 'Bad BSSID excluded'
$reset=New-WifiNeighborTracker
Assert ($reset.CompletedSurveys -eq 0) 'A route change can reset the tracker'
'Neighbor temporal intelligence checks passed'
