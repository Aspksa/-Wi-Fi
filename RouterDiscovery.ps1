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

function Get-WifiRouterInfo($Diagnostics) {
    $address = Get-WifiRouterAddress $Diagnostics
    $result = [ordered] @{
        address = [string] $address
        status = 'no-wifi-gateway'
        model = ''
        firmware = ''
        management = $false
        spectrum = 'unverified'
        capabilities = Get-WifiRouterCapabilityHints ''
        explanation = 'Шлюз Wi-Fi не определён.'
    }
    if (-not $address) { return [pscustomobject] $result }
    $result.status = 'unverified'
    $result.explanation = 'Доступность веб-интерфейса ещё не подтверждена.'
    $url = 'http://' + $address + '/'
    try {
        $request = [Net.HttpWebRequest] [Net.WebRequest]::Create($url)
        $request.Method = 'GET'
        $request.Timeout = 1300
        $request.ReadWriteTimeout = 1300
        $request.AllowAutoRedirect = $false
        $request.Proxy = $null
        $request.UserAgent = 'Wi-Fi local read-only discovery'
        $response = $request.GetResponse()
    } catch [Net.WebException] {
        # Authentication errors still indicate an accessible management service.
        $response = $_.Exception.Response
        if (-not $response) {
            $result.status = 'unreachable'
            $result.explanation = 'Панель управления не ответила на локальном шлюзе.'
            return [pscustomobject] $result
        }
    } catch {
        $result.status = 'unreachable'
        $result.explanation = 'Панель управления не ответила на локальном шлюзе.'
        return [pscustomobject] $result
    }
    try {
        $code = [int] $response.StatusCode
        $result.management = $code -in @(200, 301, 302, 303, 307, 308, 401, 403)
        $result.status = if ($result.management) { 'web-detected' } else { 'unverified' }
        $result.explanation = 'Веб-интерфейс найден. Для сведений о прошивке может потребоваться вход в панель.'
        if ($code -eq 200 -and $response.ContentType -match 'text/html') {
            $stream = $response.GetResponseStream()
            $reader = New-Object IO.StreamReader($stream)
            try {
                $chars = New-Object char[] 131072
                $count = $reader.Read($chars, 0, $chars.Length)
                if ($count -gt 0) {
                    $identity = Get-WifiRouterIdentity (-join $chars[0..($count - 1)])
                    $result.model = $identity.Model
                    $result.firmware = $identity.Firmware
                    $result.capabilities = Get-WifiRouterCapabilityHints (-join $chars[0..($count - 1)])
                }
            } finally { $reader.Dispose() }
        }
        if ($result.model -eq 'RE3L') {
            $result.explanation = 'RE3L обнаружен по странице управления. Доступ к списку соседних сетей API пока не подтверждён.'
        }
    } finally { $response.Dispose() }
    [pscustomobject] $result
}
