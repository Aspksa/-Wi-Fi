# Read-only discovery. Never logs in, changes router settings, or scans arbitrary addresses.
function Get-WifiRouterAddress($Diagnostics) {
    if (-not $Diagnostics -or -not $Diagnostics.Gateway) { return $null }
    $address = $Diagnostics.Gateway
    if ($address -isnot [Net.IPAddress]) {
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse([string] $address, [ref] $parsed)) { return $null }
        $address = $parsed
    }
    if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $bytes = $address.GetAddressBytes()
    $private = ($bytes[0] -eq 10) -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    if (-not $private) { return $null }
    return $address.ToString()
}

function Get-WifiRouterIdentity([string] $Html) {
    $model = ''
    $firmware = ''
    if ($Html -match '(?i)\b(?:RE3L|TE3L|RE6L\s*Pro|TE6L\s*Pro)\b') {
        $model = $Matches[0].ToUpperInvariant()
    }
    if ($Html -match '(?i)(?:firmware(?:\s+version)?|версия\s+прошивки)\s*[:=]?\s*(?:<[^>]*>\s*)?(V?\d{1,3}\.\d{1,3}\.\d{1,3}(?:\.\d{1,4})?(?:_[A-Za-z0-9-]+)?)') {
        $firmware = $Matches[1]
    }
    [pscustomobject] @{ Model = $model; Firmware = $firmware }
}

function Get-WifiRouterCapabilityHints([string] $Html) {
    # Informational only. Strings in HTML do not prove functional API support.
    $scanHint = [bool] ($Html -match '(?i)(?:site survey|wireless survey|neighbor(?:ing)? (?:ap|network)|wifi scan|scan wifi|扫描|周边网络)')
    $channelHint = [bool] ($Html -match '(?i)(?:channel width|wireless channel|wifi channel|信道|канал)')
    $radioHint = [bool] ($Html -match '(?i)(?:channel utilization|airtime|radio statistics|channel busy|信道利用率)')
    [pscustomobject] @{
        scan = $(if ($scanHint) { 'interface-hint' } else { 'not-confirmed' })
        channel = $(if ($channelHint) { 'interface-hint' } else { 'not-confirmed' })
        radio = $(if ($radioHint) { 'interface-hint' } else { 'not-confirmed' })
        write = 'not-confirmed'
        rollback = 'not-confirmed'
    }
}

function Get-WifiRouterAccessState([int] $Code, [string] $Page) {
    if ($Code -eq 401 -or $Code -eq 403) { return 'login-required' }
    if ($Code -in @(301,302,303,307,308)) { return 'redirect-unverified' }
    if ($Code -ne 200) { return 'unverified' }
    if ($Page -match '(?i)<(?:input|form)[^>]*(?:password|login|signin|auth|logon)') {
        return 'login-required'
    }
    'open-page'
}

# Universal gateway monitoring. No firmware identification, login or API probing.
function Get-WifiRouterInfo($Diagnostics) {
    $address = Get-WifiRouterAddress $Diagnostics
    $reachable = $false
    if ($Diagnostics -and $Diagnostics.Router) {
        $probe = $Diagnostics.Router
        $reachable = [bool] ($probe.Tested -and $probe.Lost -lt 3)
    }
    [pscustomobject] @{
        address=[string] $address
        status=$(if (-not $address) {'no-wifi-gateway'} elseif ($reachable) {'reachable'} else {'unknown'})
        reachable=$reachable
        management=$false
        explanation=$(if (-not $address) {'Шлюз Wi-Fi не определён.'} elseif ($reachable) {'Локальный шлюз отвечает на контрольные запросы.'} else {'Доступность шлюза ещё не подтверждена.'})
    }
}
