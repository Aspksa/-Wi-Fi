function New-MonitorHistory {
    [pscustomobject] @{ Hours = @(); Events = @(); Tracked = $null }
}

function Read-MonitorHistory([string] $Path) {
    if (Test-Path -LiteralPath $Path) {
        $record = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $record -or -not $record.PSObject.Properties['Hours'] -or
                -not $record.PSObject.Properties['Events'] -or -not $record.PSObject.Properties['Tracked']) {
            throw 'Формат истории Wi-Fi не распознан.'
        }
        return $record
    }
    New-MonitorHistory
}

function Save-MonitorHistory($History, [string] $Path) {
    $folder = Split-Path -Parent $Path
    [void] [IO.Directory]::CreateDirectory($folder)
    $temp = Join-Path $folder ([Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = ConvertTo-Json -InputObject $History -Depth 8 -Compress
        [IO.File]::WriteAllText($temp, $json, [Text.Encoding]::UTF8)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Add-MonitorEvent($History, [datetime] $At, [string] $Message) {
    $History.Events = @(
        [pscustomobject] @{ At = $At.ToString('yyyy-MM-dd HH:mm:ss'); Message = $Message }
    ) + @($History.Events | Select-Object -First 99)
}

function Update-TrackedPoint($History, [object[]] $Points, $Plans, [datetime] $At) {
    $tracked = $History.Tracked
    if (-not $tracked) { return }
    $point = $Points | Where-Object { $_.BSSID -eq $tracked.BSSID -and $_.Band -eq $tracked.Band -and $_.Fresh -ne $false } |
        Sort-Object Signal -Descending | Select-Object -First 1
    if (-not $point) { return }
    if ($tracked.Channel -ne $point.Channel) {
        Add-MonitorEvent $History $At "$($tracked.SSID) · $($tracked.Band) ГГц: канал $($tracked.Channel) → $($point.Channel)"
        $tracked.Channel = $point.Channel
    }
    $ownPoint = $Plans[$tracked.Band].Home
    if (-not $ownPoint) { return }
    $ownFootprint = Get-SignalFootprint $tracked.Band $ownPoint.Channel $ownPoint
    $neighborFootprint = Get-SignalFootprint $tracked.Band $point.Channel $point
    $overlap = [bool] (Get-SignalOverlap $ownFootprint $neighborFootprint)
    if ($null -ne $tracked.Overlap -and $tracked.Overlap -ne $overlap) {
        $message = if ($overlap) { 'появилось расчётное пересечение' } else { 'расчётное пересечение исчезло' }
        Add-MonitorEvent $History $At "$($tracked.SSID) · $message с твоим каналом $($ownPoint.Channel)."
    }
    $tracked.Overlap = $overlap
}

function Get-PastScores($History, [datetime] $At, [string] $Band) {
    $hour = $At.ToString('HH')
    $currentKey = $At.ToString('yyyy-MM-dd HH')
    $cutoff = $At.AddDays(-7).ToString('yyyy-MM-dd HH')
    $sums = @{}
    $counts = @{}
    foreach ($entry in $History.Hours) {
        if ($entry.Band -ne $Band -or $entry.Key -lt $cutoff -or $entry.Key -ge $currentKey -or
                -not $entry.Key.EndsWith(" $hour")) { continue }
        foreach ($value in $entry.Channels) {
            $channel = [int] $value.Channel
            if (-not $sums.ContainsKey($channel)) { $sums[$channel] = 0.0; $counts[$channel] = 0 }
            $sums[$channel] += $value.Sum / $value.Count
            $counts[$channel]++
        }
    }
    $scores = @{}
    foreach ($channel in $sums.Keys) { $scores[$channel] = $sums[$channel] / $counts[$channel] }
    $scores
}

function Update-HeatHistory($History, $Plans, [datetime] $At) {
    $key = $At.ToString('yyyy-MM-dd HH')
    $cutoff = $At.AddDays(-7).ToString('yyyy-MM-dd HH')
    $History.Hours = @($History.Hours | Where-Object { $_.Key -ge $cutoff -and $_.Key -le $key })
    foreach ($band in @('2.4', '5')) {
        $plan = $Plans[$band]
        if (-not $plan.Rows -or -not $plan.VisibleCount) { continue }
        $entry = $History.Hours | Where-Object { $_.Key -eq $key -and $_.Band -eq $band } | Select-Object -First 1
        if (-not $entry) {
            $entry = [pscustomobject] @{ Key = $key; Band = $band; OwnSum = 0.0; OwnCount = 0; Channels = @() }
            $History.Hours += $entry
        }
        foreach ($row in ($plan.Rows | Where-Object { $_.Candidate -or $_.Current })) {
            $value = $entry.Channels | Where-Object { $_.Channel -eq $row.Channel } | Select-Object -First 1
            if (-not $value) {
                $value = [pscustomobject] @{ Channel = $row.Channel; Sum = 0.0; Count = 0 }
                $entry.Channels += $value
            }
            $value.Sum += $row.Score
            $value.Count++
            if ($row.Current) {
                $entry.OwnSum += $row.Score
                $entry.OwnCount++
            }
        }
    }
}

function Get-InternetRouteAddress($Target) {
    $socket = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork,
        [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
    try {
        # Connecting this UDP socket queries the route without sending any payload.
        $socket.Connect($Target, 443)
        $socket.LocalEndPoint.Address
    } catch {
        return
    } finally {
        $socket.Dispose()
    }
}

function Get-WifiDiagnostics {
    $target = [Net.IPAddress]::Parse('1.1.1.1')
    $routeAddress = Get-InternetRouteAddress $target

    $wifiInterfaces = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.NetworkInterfaceType -eq 'Wireless80211' -and $_.OperationalStatus -eq 'Up' }
    $gateway = $null
    $wifiRoute = $false
    $adapterId = $null
    foreach ($adapter in $wifiInterfaces) {
        $properties = $adapter.GetIPProperties()
        $candidate = $properties.GatewayAddresses | ForEach-Object { $_.Address } |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -ne '0.0.0.0' } | Select-Object -First 1
        if (-not $gateway -and $candidate) {
            $gateway = $candidate
            $adapterId = $adapter.Id
        }
        if ($routeAddress -and ($properties.UnicastAddresses | Where-Object { $_.Address.Equals($routeAddress) })) {
            $wifiRoute = $true
            $gateway = $candidate
            $adapterId = $adapter.Id
            break
        }
    }

    $pairs = @()
    foreach ($destination in @($gateway, $target)) {
        $samples = @()
        if ($destination -and ($destination -ne $target -or $wifiRoute)) {
            $ping = [Net.NetworkInformation.Ping]::new()
            try {
                for ($i = 0; $i -lt 3; $i++) {
                    try {
                        $reply = $ping.Send($destination, 650)
                        if ($reply.Status -eq 'Success') { $samples += $reply.RoundtripTime }
                    } catch [Net.NetworkInformation.PingException] {
                        continue
                    }
                }
            } finally {
                $ping.Dispose()
            }
        }
        $tested = $null -ne $destination -and ($destination -ne $target -or $wifiRoute)
        $average = if ($samples.Count) {
            [Math]::Round(($samples | Measure-Object -Average).Average)
        } else { $null }
        $pairs += [pscustomobject] @{ Tested = $tested; Lost = 3 - $samples.Count; Average = $average }
    }
    [pscustomobject] @{ Router = $pairs[0]; Internet = $pairs[1]; Gateway = $gateway; WifiRoute = $wifiRoute; AdapterId = $adapterId }
}

function Get-LinkState($Diagnostics) {
    if (-not $Diagnostics -or -not $Diagnostics.Router.Tested) { return 'unknown' }
    if ($Diagnostics.Router.Lost -eq 3) { return 'router-no-reply' }
    if ($Diagnostics.Router.Lost -gt 0 -or $Diagnostics.Router.Average -gt 35) { return 'local' }
    if ($Diagnostics.Internet.Tested -and
            ($Diagnostics.Internet.Lost -gt 0 -or $Diagnostics.Internet.Average -gt 180)) { return 'external' }
    if ($Diagnostics.Internet.Tested) { return 'ok' }
    'router-ok'
}
