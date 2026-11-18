$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'RouterTelemetry.ps1')
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$captured = [DateTimeOffset]::FromUnixTimeMilliseconds($now - 1000).ToString('o')
$data = [pscustomobject] @{
    routerAddress = '192.168.0.1'; model = 'RE3L'; firmware = 'V16.03.60.62'; capturedAt = $captured
    networks = @(
        [pscustomobject] @{ ssid = 'Home'; bssid = 'aa:bb:cc:dd:ee:01'; band = '2.4'; channel = 6; rssi = -48; widthMhz = 20; own = $true }
        [pscustomobject] @{ ssid = 'Invalid'; bssid = 'not-mac'; band = '2.4'; channel = 7; rssi = -53; widthMhz = 40; own = $false }
    )
    airtime = @([pscustomobject] @{ band = '2.4'; channel = 6; busyPercent = 32; source = 'radio-airtime-counter' })
}
$parsed = Get-ValidatedRouterTelemetry $data '192.168.0.1' $now
Assert ($null -ne $parsed) 'Valid fresh router export'
Assert (@($parsed.points).Count -eq 1) 'Malformed BSSID excluded'
Assert ($parsed.points[0].Own -eq $true) 'Home network marked'
Assert (@($parsed.airtime).Count -eq 1) 'Counters accepted as unverified claims'
Assert ($parsed.airtime[0].source -eq 'router-export/unverified-counter') 'Counter not misrepresented as measured'
Assert (-not $parsed.trustedLive) 'Manual import cannot become verified live scan'
Assert ($null -eq (Get-ValidatedRouterTelemetry $data '192.168.1.1' $now)) 'Reject wrong gateway'
$data.model = 'AC10'
Assert ($null -eq (Get-ValidatedRouterTelemetry $data '192.168.0.1' $now)) 'Reject different model'
$data.model = 'RE3L'
$data.capturedAt = [DateTimeOffset]::FromUnixTimeMilliseconds($now - 70000).ToString('o')
Assert ($null -eq (Get-ValidatedRouterTelemetry $data '192.168.0.1' $now)) 'Reject stale file'
$policy = Get-RouterAutomationPolicy $null $null
Assert (-not $policy.enabled -and -not $policy.writeSupported -and -not $policy.rollbackSupported) 'Never write without verified rollback driver'
'Router telemetry and safety checks passed'
