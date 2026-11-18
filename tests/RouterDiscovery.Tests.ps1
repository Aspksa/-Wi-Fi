$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'RouterDiscovery.ps1')
. (Join-Path $project 'Recommendation.ps1')
function Assert($condition, [string] $message) { if (-not $condition) { throw $message } }
$router = Get-WifiRouterIdentity '<html><title>Tenda RE3L</title><p>Firmware Version: V16.03.53.04</p></html>'
Assert ($router.Model -eq 'RE3L') 'Model detection'
Assert ($router.Firmware -eq 'V16.03.53.04') 'Firmware detection'
Assert ((Get-WifiRouterAccessState 401 '') -eq 'login-required') 'HTTP 401 requires login'
Assert ((Get-WifiRouterAccessState 403 '') -eq 'login-required') 'HTTP 403 requires login'
Assert ((Get-WifiRouterAccessState 302 '') -eq 'redirect-unverified') 'No automatic redirect'
Assert ((Get-WifiRouterAccessState 200 '<form><input type="password"></form>') -eq 'login-required') 'Login page classification'
Assert ((Get-WifiRouterAccessState 200 '<html>RE3L</html>') -eq 'open-page') 'Public page classification'
$hints = Get-WifiRouterCapabilityHints '<html>Wireless channel / Channel utilization / Site Survey</html>'
Assert ($hints.scan -eq 'interface-hint' -and $hints.channel -eq 'interface-hint' -and $hints.radio -eq 'interface-hint') 'HTML hints classified'
Assert ($hints.write -eq 'not-confirmed' -and $hints.rollback -eq 'not-confirmed') 'Never infer unsafe write access'
$emptyHints = Get-WifiRouterCapabilityHints '<html>Login</html>'
Assert ($emptyHints.scan -eq 'not-confirmed') 'No scan claim on login only'

Assert (-not (Get-WifiRouterAddress ([pscustomobject] @{ Gateway = '8.8.8.8' }))) 'Reject public gateway'
Assert ((Get-WifiRouterAddress ([pscustomobject] @{ Gateway = '192.168.1.1' })) -eq '192.168.1.1') 'Accept private Wi-Fi gateway'
$now = 1000000L
$network = '5|aa|home'
$samples = @(for ($i = 0; $i -lt 25; $i++) {
    [pscustomobject] @{ At = $now - (25 - $i) * 1000; Network = $network; LanLoss = $false; WanLoss = $false;
        Lan = $(if ($i -lt 5) { 60 } else { 3 }); Wan = 30; Scanning = $false }
})
$evidence = Get-WifiLatencyEvidence $samples $network $now
Assert ($evidence.Classification -eq 'local') 'Local failures must be identified'
foreach ($entry in $samples) {
    $entry.Lan = 3
    $entry.Wan = 250
}
$evidence = Get-WifiLatencyEvidence $samples $network $now
Assert ($evidence.Classification -eq 'external') 'External-only failures must not be blamed on Wi-Fi'
Assert ((Get-WifiLatencyEvidence @($samples[0..9]) $network $now).Classification -eq 'insufficient') 'Require sufficient samples'
$gateway = Get-WifiRouterInfo ([pscustomobject] @{Gateway='192.168.1.1';Router=[pscustomobject]@{Tested=$true;Lost=0}})
Assert ($gateway.reachable -and $gateway.address -eq '192.168.1.1') 'Universal local gateway diagnostics'
Assert (-not $gateway.management) 'No web admin probing'
'Router discovery and latency evidence tests passed'
