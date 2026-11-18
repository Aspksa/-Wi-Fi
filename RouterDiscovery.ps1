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

function Get-WifiRouterInfo($Diagnostics) {
    $address = Get-WifiRouterAddress $Diagnostics
    $result = [ordered] @{
        address = [string] $address
        status = 'no-wifi-gateway'
        model = ''
        firmware = ''
        management = $false
        authentication = 'unknown'
        scheme = ''
        httpStatus = 0
        spectrum = 'unverified'
        capabilities = Get-WifiRouterCapabilityHints ''
        explanation = 'Шлюз Wi-Fi не определён.'
    }
    if (-not $address) { return [pscustomobject] $result }
    $result.status = 'unreachable'
    $result.explanation = 'Локальная панель роутера не ответила по HTTP или HTTPS.'
    # Only the currently selected private IPv4 Wi-Fi gateway, only GET /.
    # Never follow redirects or accept a different certificate authority silently.
    foreach ($scheme in @('http','https')) {
        $response = $null
        try {
            $request = [Net.HttpWebRequest] [Net.WebRequest]::Create(('{0}://{1}/' -f $scheme,$address))
            $request.Method = 'GET'
            $request.Timeout = 1200
            $request.ReadWriteTimeout = 1200
            $request.AllowAutoRedirect = $false
            $request.Proxy = $null
            $request.UserAgent = 'Wi-Fi local read-only discovery'
            try {
                $response = $request.GetResponse()
            } catch [Net.WebException] {
                if ($_.Exception.Response) { $response = $_.Exception.Response }
                else { continue }
            }
            if (-not $response) { continue }
            $status = [int] $response.StatusCode
            if ($status -notin @(200,301,302,303,307,308,401,403)) { continue }
            $result.management = $true
            $result.scheme = $scheme
            $result.httpStatus = $status
            $result.status = 'web-detected'
            $page = ''
            if ($status -eq 200 -and [string] $response.ContentType -match 'text/html') {
                $reader = New-Object IO.StreamReader($response.GetResponseStream())
                try {
                    $chars = New-Object char[] 65536
                    $count = $reader.Read($chars,0,$chars.Length)
                    if ($count -gt 0) { $page = -join $chars[0..($count-1)] }
                } finally { $reader.Dispose() }
            }
            $result.authentication = Get-WifiRouterAccessState $status $page
            if ($page) {
                $identity = Get-WifiRouterIdentity $page
                $result.model = $identity.Model
                $result.firmware = $identity.Firmware
                $result.capabilities = Get-WifiRouterCapabilityHints $page
            }
            $result.explanation = switch ($result.authentication) {
                'login-required' { 'Панель требует авторизацию. Пароль и сеанс не запрашиваются программой.' }
                'redirect-unverified' { 'Веб-панель перенаправляет на другую страницу. Автопереход отключён.' }
                default { 'Панель доступна. Внутренний API конкретной прошивки не подтверждён.' }
            }
            break
        } catch {
            # Discovery must never interrupt Wi-Fi monitoring.
        } finally {
            if ($response) { $response.Dispose() }
        }
    }
    [pscustomobject] $result
}
