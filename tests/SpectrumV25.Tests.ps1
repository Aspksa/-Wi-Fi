$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'SpectrumV25.ps1')
function Assert([bool]$Ok,[string]$Why){if(-not $Ok){throw $Why}}
Assert ((Get-WifiScanInterval $true $false $false $false 0) -ge 90000) 'Blocked scanner backoff'
Assert ((Get-WifiScanInterval $false $false $true $false 0) -lt 30000) 'Incident adaptive scan'
Assert ((Get-WifiScanInterval $false $false $false $true 0) -eq 60000) 'Stable scan slower'
Assert ((Get-WifiScanInterval $false $true $false $false 4) -le 120000) 'Bound failure backoff'
$g=Get-WifiPermissionGuidance $true ''
Assert ($g.status -eq 'scan-restricted' -and $g.steps.Count -ge 3) 'Windows location and WLAN guidance'
Assert ((Get-WifiPermissionGuidance $false '').steps.Count -eq 0) 'No false permission warnings'
Assert ((Get-WifiAdapterSummary $null).status -eq 'unknown') 'Unknown adapter explicitly'
Assert ((Get-WifiScanConfidence 'Windows WLAN' $true 100000L 100100L 1) -eq 'observed') 'Complete native scan'
Assert ((Get-WifiScanConfidence 'Windows WLAN' $false 100000L 100100L 1) -eq 'cached-or-incomplete') 'Incomplete scan marked'
Assert ((Get-WifiScanConfidence 'netsh' $false 100000L 100100L 1) -eq 'unverified-cache') 'Netsh cannot confirm freshness'
Assert ((Get-WifiScanConfidence 'Windows WLAN' $true 100000L 150001L 1) -eq 'stale-or-missing') 'Old scan rejected'
$pts=@(
 [pscustomobject]@{Band='2.4';Channel=1;Signal=85;RadioWidth=@{Width=20};Fresh=$true;Own=$false}
 [pscustomobject]@{Band='2.4';Channel=6;Signal=50;Fresh=$true;Own=$false}
 [pscustomobject]@{Band='2.4';Channel=11;Signal=95;Fresh=$false;Own=$false}
)
$impact=Get-WifiInterferenceEvidence $pts '2.4'
Assert ($impact.neighborCount -eq 2 -and $impact.strongest[0].channel -eq 1) 'Signal ranked without stale neighbors'
Assert ($impact.strongest[0].widthConfirmed -and -not $impact.strongest[1].widthConfirmed) 'Unknown channel width explicit'
$guard=[pscustomobject]@{eligible=$true}
Assert (-not (Get-WifiRecommendationConfidence $guard 'observed' 2).eligible) 'Two surveys insufficient'
Assert (-not (Get-WifiRecommendationConfidence $guard 'unverified-cache' 5).eligible) 'Cached result blocks advice'
Assert ((Get-WifiRecommendationConfidence $guard 'observed' 3).eligible) 'Three surveys and guard permit manual trial'
Assert (-not (Get-WifiRecommendationConfidence $guard 'observed' 5).automaticChange) 'Router remains unchanged'
# Query mock: no database service required for shape and grouping logic.
$db=[pscustomobject]@{}
$db | Add-Member -MemberType ScriptMethod -Name Query -Value {
  param($sql,$args)
  @(
   @(360L, '[{"Band":"2.4","BSSID":"aa:aa:aa:aa:aa:01","Own":false,"Fresh":true}]')
   @(360L, '[{"Band":"2.4","BSSID":"aa:aa:aa:aa:aa:02","Own":false,"Fresh":true},{"Band":"2.4","BSSID":"aa:aa:aa:aa:aa:03","Own":false,"Fresh":true}]')
  )
}
$rows=@(Get-WifiHourlyNeighborDensity $db 1500000000L @())
Assert ($rows.Count -eq 1 -and $rows[0].band -eq '2.4') 'Two scans grouped by hour'
Assert ($rows[0].averageNeighbors -eq 1.5 -and $null -eq $rows[0].localBadPercent) 'Density and honest lack of local samples'
'Wi-Fi v2.5 spectrum guards passed'
