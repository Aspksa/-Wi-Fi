$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'RouterV22.ps1')
function Assert([bool] $Condition,[string] $Message) { if(-not $Condition) { throw $Message } }
$now=1500000L
$plan=[pscustomobject]@{ Home=[pscustomobject]@{Channel=6};Improves=$true }
$latency=[pscustomobject]@{Samples=30;Classification='local'}
$guard=Get-WifiRecommendationGuard $plan $latency $null 'Windows WLAN' ($now-5000) $now $true
Assert ($guard.eligible -and -not $guard.automatedChangeAllowed) 'Evidence supports manual trial only'
Assert (-not (Get-WifiRecommendationGuard $plan $latency $null 'router-export' ($now-5000) $now $true).eligible) 'Manual export never confirms recommendation'
Assert (-not (Get-WifiRecommendationGuard $plan $latency $null 'Windows WLAN' ($now-46000) $now $true).eligible) 'Stale scan cannot confirm'
Assert (-not (Get-WifiRecommendationGuard $plan $latency $null 'Windows WLAN' ($now-5000) $now $false).eligible) 'Independent scans needed'
Assert (-not (Get-WifiRecommendationGuard $plan ([pscustomobject]@{Samples=30;Classification='external'}) $null 'Windows WLAN' ($now-5000) $now $true).eligible) 'External-only incident guard'
Assert (-not (Get-WifiRecommendationGuard $plan $latency ([pscustomobject]@{status='improving'}) 'Windows WLAN' ($now-5000) $now $true).eligible) 'Do not switch if signal improving'
Assert (-not (Get-WifiRecommendationGuard $plan ([pscustomobject]@{Samples=1;Classification='local'}) $null 'Windows WLAN' ($now-5000) $now $true).eligible) 'Single bad probe guard'
$policy=Get-WifiSafeWritePolicy
Assert (-not $policy.enabled -and -not $policy.rollbackSupported -and $policy.lastKnownGoodRequired) 'Universal channel writes disabled'
$patterns=@(Get-WifiRepeatedHourlyIssues @(
    [pscustomobject]@{band='2.4';channel=6;hourUtc='2026-11-17 22:00';samples=30;badPercent=25}
    [pscustomobject]@{band='2.4';channel=6;hourUtc='2026-11-18 22:00';samples=35;badPercent=22}
    [pscustomobject]@{band='2.4';channel=6;hourUtc='2026-11-18 23:00';samples=35;badPercent=30}
))
Assert ($patterns.Count -eq 1 -and $patterns[0].days -eq 2) 'Repeated issue across distinct days'
Assert ((Get-WifiRepeatedHourlyIssues @([pscustomobject]@{band='2.4';channel=6;hourUtc='2026-11-18 22:00';samples=3;badPercent=100})).Count -eq 0) 'Insufficient repeated sample pattern'
$source=Get-WifiObservedSource 'Windows WLAN' $null $now
Assert ($source.kind -eq 'measured' -and $source.airtime -eq 'not-measured') 'AP observation is not busy airtime'
$import=Get-WifiObservedSource 'router-export' ([pscustomobject]@{capturedAt=$now-1000}) $now
Assert ($import.kind -eq 'unverified-import') 'Manual router import never verified'
Assert ((Get-WifiObservedSource 'router-export' ([pscustomobject]@{capturedAt=$now-90000}) $now).kind -eq 'unavailable') 'Stale router import excluded'
'Wi-Fi v2.2 universal safety and evidence tests passed'
