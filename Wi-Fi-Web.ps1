$ErrorActionPreference = 'Stop'
foreach ($file in @('Scan.ps1', 'Monitor.ps1', 'Intelligence.ps1', 'Database.ps1', 'Recommendation.ps1', 'ScanJob.ps1', 'WebState.ps1', 'RouterDiscovery.ps1', 'RouterTelemetry.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}
Add-Type -Path (Join-Path $PSScriptRoot 'WifiWebServer.cs')

function Save-WebHistory($Run) {
    if (-not $Run.Database) { return }
    try {
        Set-DatabaseSetting $Run.Database 'history' (ConvertTo-Json -InputObject $Run.History -Depth 8 -Compress)
        Set-DatabaseSetting $Run.Database 'home_ssid' $Run.HomeName
    } catch { $Run.Storage = 'Не удалось сохранить историю SQLite.' }
}

function Save-WebMeasurements($Run, [long] $Now) {
    $engine = $Run.Engine
    if (-not $Run.Database) {
        foreach ($buffer in @($engine.PendingSamples, $engine.PendingScans, $engine.PendingIncidents, $engine.PendingTrials, $engine.PendingChecks)) {
            if ($buffer) { $buffer.Clear() }
        }
        return
    }
    try {
        if ($engine.PendingSamples.Count -or $engine.PendingScans.Count -or $engine.PendingIncidents.Count -or
                $engine.PendingTrials.Count -or $engine.PendingChecks.Count) {
            Save-Intelligence $Run.Database $engine
        }
        if ($Now -ge $Run.NextPrune) {
            Remove-ExpiredMeasurements $Run.Database $Now
            $Run.NextPrune = $Now + 3600000
        }
        $Run.Storage = ''
    } catch { $Run.Storage = 'SQLite временно недоступна. Повторю запись.' }
}

function Start-WebScan($Run, [long] $Now, [bool] $Force) {
    if ($Run.Worker) { return }
    $diagnosticsOnly = [bool] ($Run.ScanBlocked -and -not $Force)
    $active = -not $diagnosticsOnly -and ($Force -or ($Now - $Run.LastActive -ge 90000 -and -not $Run.Engine.Incident))
    $Run.Active = $active
    if ($active) { $Run.LastActive = $Now; $Run.WanSample = $null }
    try { $Run.Worker = Start-WifiScanJob $active $diagnosticsOnly }
    catch {
        $Run.Issue = $_.Exception.GetBaseException().Message
        $Run.Active = $false
        $Run.NextScan = $Now + 5000
        return
    }
    $Run.ScanStartedAt = $Now
    $Run.NextScan = $Now + 30000
}

function Set-WebRoute($Run, $Diagnostics) {
    if ([string] $Run.Gateway -eq [string] $Diagnostics.Gateway -and
            [string] $Run.AdapterId -eq [string] $Diagnostics.AdapterId -and
            $Run.WifiRoute -eq [bool] $Diagnostics.WifiRoute) { return }
    Reset-WifiMeasurementContext $Run.Engine (Get-UnixMilliseconds)
    $Run.Epoch++
    $Run.Gateway = $Diagnostics.Gateway
    $Run.WifiRoute = [bool] $Diagnostics.WifiRoute
    $Run.AdapterId = $Diagnostics.AdapterId
    $Run.Adapter = if ($Run.AdapterId) {
        [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object Id -eq $Run.AdapterId | Select-Object -First 1
    }
    $Run.WanSample = $null
    $Run.Traffic = $null
    $Run.Latency = @()
}

function Use-WebRouterFallback($Run, [long] $Now) {
    $gateway = Get-WifiRouterAddress $Run.Diagnostics
    $telemetry = Read-RouterTelemetry $Run.RouterTelemetryPath $gateway $Now
    $Run.RouterTelemetry = $telemetry
    if (-not $telemetry -or -not @($telemetry.points).Count) { return }
    $Run.Points = @($telemetry.points)
    $Run.ScanAt = $telemetry.capturedAt
    $Run.Source = 'router-export'
    $connected = @($Run.Points | Where-Object Own | ForEach-Object BSSID)
    $Run.Plans.Clear()
    $Run.Streak.Clear()
    $Run.Evidence.Clear()
    foreach ($band in @('2.4','5')) {
        $plan = Get-ChannelPlan $Run.Points $band $connected
        $Run.Plans[$band] = $plan
        $Run.Advice[$band] = 'Импортирован снимок RE3L: оценка кандидатов доступна, но рекомендация не подтверждена живыми замерами.'
        $Run.Evidence[$band] = Get-WifiRecommendationEvidence $plan $null $telemetry
    }
    $frames = @(Update-SpectrumFrames $Run.Spectrum (Get-SpectrumFrame $Run.ScanAt $Run.Points))
    if ($frames.Count) {
        $Run.Spectrum = $frames
        $Run.Server.SetSpectrum((ConvertTo-Json -InputObject $frames -Depth 8 -Compress))
    }
}

function Receive-WebScan($Run) {
    try {
        $result = Receive-WifiScanJob $Run.Worker
        $Run.ScanBlocked = [bool] $result.ScanBlocked
        if ($Run.ScanBlocked) {
            $Run.Issue = ''
            $Run.Points = @()
            $Run.Source = ''
            $Run.ScanAt = 0L
            $Run.Plans.Clear()
            $Run.Streak.Clear()
            $Run.Forecast = $null
            foreach ($band in @('2.4', '5')) { $Run.Advice[$band] = 'Для совета нужен снимок эфира.' }
            $Run.Diagnostics = $result.Diagnostics
            $Run.Link = Get-LinkState $result.Diagnostics
            Set-WebRoute $Run $result.Diagnostics
            Update-WifiRadio $Run.Engine $null (Get-UnixMilliseconds)
            Use-WebRouterFallback $Run (Get-UnixMilliseconds)
            return
        }
        if ($result.Native) {
            $connected = @($result.Native.Connected | Where-Object { $_ })
            $Run.Points = @(ConvertFrom-NativeScan $result.Native $Run.HomeName)
            $Run.Source = 'Windows WLAN'
            $Run.ScanAt = $result.Native.FinishedAt
        } else {
            $connected = @(Get-ConnectedAddresses $result.Interfaces)
            $Run.Points = @(Get-WifiPoints $result.Networks $connected $Run.HomeName)
            $Run.Source = 'netsh'
            $Run.ScanAt = Get-UnixMilliseconds
        }
        $frames = @(Update-SpectrumFrames $Run.Spectrum (Get-SpectrumFrame $Run.ScanAt $Run.Points))
        if ($frames.Count -and (-not $Run.Spectrum.Count -or $frames[-1].key -ne $Run.Spectrum[-1].key)) {
            $Run.Spectrum = $frames
            $Run.Server.SetSpectrum((ConvertTo-Json -InputObject $frames -Depth 8 -Compress))
        }
        $Run.Issue = ''
        $Run.Diagnostics = $result.Diagnostics
        $Run.Link = Get-LinkState $result.Diagnostics
        Set-WebRoute $Run $result.Diagnostics
        $at = Get-Date
        $radio = Get-WifiRadioContext $Run.Points $connected $Run.Engine.Radio $Run.ScanAt
        Update-WifiRadio $Run.Engine $radio $Run.ScanAt
        if ($Run.Database -and $Run.Engine.PendingScans.Count -lt 120) {
            $Run.Engine.PendingScans.Add([pscustomobject] @{
                At = $Run.ScanAt; Network = [string] $radio.Network; Points = $Run.Points
            })
        }
        $latencyEvidence = Get-WifiLatencyEvidence @($Run.Engine.Samples) ([string] $radio.Network) (Get-UnixMilliseconds)
        $Run.Evidence.Clear()
        foreach ($band in @('2.4', '5')) {
            $advice = Get-WifiRecommendation $Run.Points $band $connected $at $Run.Link $result.Native $Run.History `
                $Run.Database $Run.Streak[$band] $Run.Forecast $latencyEvidence
            $Run.Streak[$band] = $advice.Streak
            $Run.Plans[$band] = $advice.Plan
            $Run.Evidence[$band] = Get-WifiRecommendationEvidence $advice.Plan $latencyEvidence $Run.RouterTelemetry
            $Run.Advice[$band] = $advice.Text
            if ($advice.StorageNote) { $Run.Storage = $advice.StorageNote }
        }
        Update-TrackedPoint $Run.History $Run.Points $Run.Plans $at
        Update-HeatHistory $Run.History $Run.Plans $at
        Save-WebHistory $Run
    } catch {
        $Run.Issue = $_.Exception.GetBaseException().Message
        $Run.NextScan = (Get-UnixMilliseconds) + 5000
        $Run.LastActive = 0L
        $Run.Streak.Clear()
        $Run.Advice.Clear()
        $Run.Plans.Clear()
        $Run.Forecast = $null
        $Run.Diagnostics = $null
        $Run.Link = 'unknown'
        Set-WebRoute $Run $null
    } finally {
        Close-WifiScanJob $Run.Worker
        $Run.Worker = $null
        $Run.Active = $false
    }
}

function Add-WebLatency($Run, [long] $At, $Milliseconds, [bool] $Lost) {
    $liveSample = [pscustomobject] @{
        at = $At; ms = $Milliseconds; lost = $Lost
        scan = [bool] ($Run.Active -or $Run.LanDuringScan)
        band = $null; wanMs = $null; wanLost = $null
    }
    $Run.Latency = @($Run.Latency | Where-Object { $At - $_.at -le 60000 }) + @($liveSample)

    $radio = $Run.Engine.Radio
    if ($radio -and ($At - $radio.At -gt 45000 -or
            ($radio.ObservedAt -and $At - $radio.ObservedAt -gt 45000))) { $radio = $null }
    $upload = $null
    if ($Run.Adapter) {
        try {
            $bytes = $Run.Adapter.GetIPv4Statistics().BytesSent
            $upload = Get-UploadRate $Run.Traffic $bytes $At
            $Run.Traffic = @{ At = $At; Bytes = $bytes }
        } catch { $Run.Traffic = $null }
    }
    $external = $Run.WanSample
    $Run.WanSample = $null
    if ($external -and $At - $external.At -gt 1400) { $external = $null }
    $liveSample.scan = $liveSample.scan -or $At -lt $Run.Engine.SettleUntil
    $liveSample.band = $radio.Band
    $liveSample.wanMs = $external.Milliseconds
    $liveSample.wanLost = $external.Lost
    $overlap = if ($radio) {
        if ($radio.ChangedAt -gt 0 -and $At - $radio.ChangedAt -lt 45000) { 'changed' }
        elseif ($radio.Signature) { 'strong' }
        else { 'clear' }
    }
    $measurement = [pscustomobject] @{
        At = $At; Network = [string] $radio.Network; Channel = $radio.Channel; Width = $radio.Width; Signal = $radio.Signal
        Upload = $upload; Overlap = $overlap; Lan = $Milliseconds; LanLoss = $Lost
        Wan = $external.Milliseconds; WanLoss = $external.Lost
        Scanning = [bool] ($Run.Active -or $Run.LanDuringScan)
    }
    $entries = @(Add-WifiSample $Run.Engine $measurement {
        param($network, $context)
        if ($Run.Database) {
            try { Get-ForecastEvidence $Run.Database $network $context } catch { return }
        }
    })
    foreach ($entry in $entries) {
        Add-MonitorEvent $Run.History (Get-Date) $entry.Message
        if ($entry.Cause) {
            $Run.Episodes = @((Get-WebEpisode $entry)) + @($Run.Episodes | Select-Object -First 7)
        }
        if ($entry.Forecast -and $radio) {
            $Run.Forecast = @{ At = $At; Band = $radio.Band; Network = $radio.Network; Text = $entry.Message }
            $Run.Advice[$radio.Band] = $entry.Message
        }
    }
    if ($entries.Count) { Save-WebHistory $Run }
}

function Update-WebProbes($Run, [long] $Now) {
    if ($Run.WanTask -and $Run.WanTask.IsCompleted) {
        $task = $Run.WanTask
        $Run.WanTask = $null
        if ($task.Status -eq 'Faulted') { [void] $task.Exception }
        if ($task.Status -eq 'RanToCompletion' -and -not $Run.Active -and $Run.WanEpoch -eq $Run.Epoch) {
            $lost = $task.Result.Status -ne 'Success'
            $Run.WanSample = @{ At = $Now; Lost = $lost; Milliseconds = $(if (-not $lost) { [int] $task.Result.RoundtripTime }) }
        }
    }
    if ($Run.WifiRoute -and $Run.Adapter -and -not $Run.Active -and -not $Run.WanTask -and $Now -ge $Run.NextWan) {
        $Run.NextWan = $Now + 3000
        try {
            $route = Get-InternetRouteAddress $Run.WanTarget
            if ($route -and ($Run.Adapter.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.Equals($route) })) {
                $Run.WanTask = $Run.WanPing.SendPingAsync($Run.WanTarget, 650)
                $Run.WanEpoch = $Run.Epoch
            }
        } catch { $Run.WanTask = $null }
    }
    if ($Run.LanTask -and $Run.LanTask.IsCompleted) {
        $task = $Run.LanTask
        $Run.LanTask = $null
        if ($task.Status -eq 'Faulted') { [void] $task.Exception }
        if ($task.Status -eq 'RanToCompletion' -and $Run.LanEpoch -eq $Run.Epoch) {
            $lost = $task.Result.Status -ne 'Success'
            $ms = if (-not $lost) { [int] $task.Result.RoundtripTime }
            Add-WebLatency $Run $Now $ms $lost
        }
    }
    if ($Run.Gateway -and -not $Run.LanTask -and $Now -ge $Run.NextLan) {
        $Run.NextLan = $Now + $(if ($Now -lt $Run.Engine.BurstUntil) { 350 } else { 1000 })
        try {
            $Run.LanTask = $Run.LanPing.SendPingAsync($Run.Gateway, 650)
            $Run.LanEpoch = $Run.Epoch
            $Run.LanDuringScan = $Run.Active
        } catch { $Run.LanTask = $null }
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$mutex = [Threading.Mutex]::new($false, "Local\WiFiDashboard-$($identity.User.Value)")
try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
if (-not $ownsMutex) {
    $mutex.Dispose()
    throw 'Wi Fi уже запущен. Закрой предыдущий экземпляр и попробуй ещё раз.'
}
$run = @{
    Engine = New-WifiIntelligence; History = New-MonitorHistory; Database = $null
    HomeName = ''; Points = @(); Spectrum = @(); Plans = @{}; Advice = @{}; Streak = @{}; Latency = @(); Episodes = @()
    Link = 'unknown'; Issue = ''; Storage = ''; Source = ''; WifiRoute = $false; Epoch = 0
    NextScan = 0L; NextLan = 0L; NextWan = 0L; LastActive = 0L; ScanAt = 0L
    NextPrune = 0L; NextRouterCheck = 0L; NextRouterTelemetry = 0L; Router = $null; RouterTelemetry = $null
    RouterTelemetryPath = ''; Evidence = @{}; Automation = Get-RouterAutomationPolicy $null $null
}
$server = $null
try {
    $folder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Wi Fi'
    $legacy = Join-Path $folder 'history.json'
    $run.RouterTelemetryPath = Join-Path $folder 'router-telemetry.json'
    try {
        $run.Database = Open-WifiDatabase (Join-Path $folder 'wifi.sqlite')
        $run.HomeName = [string] (Get-DatabaseSetting $run.Database 'home_ssid')
        $run.History = Get-DatabaseHistory $run.Database $legacy
    } catch {
        Write-Warning ("SQLite: " + $_.Exception.GetBaseException().Message)
        if ($run.Database) { $run.Database.Dispose(); $run.Database = $null }
        try { $run.History = Read-MonitorHistory $legacy } catch { }
        $run.Storage = 'SQLite недоступна. История этой сессии останется в памяти.'
    }
    $run.LanPing = [Net.NetworkInformation.Ping]::new()
    $run.WanPing = [Net.NetworkInformation.Ping]::new()
    $run.WanTarget = [Net.IPAddress]::Parse('1.1.1.1')
    $server = [WiFi.WebServer]::new((Join-Path $PSScriptRoot 'web'))
    $run.Server = $server
    if ($run.Database) {
        try {
            $now = Get-UnixMilliseconds
            $run.Spectrum = @(Read-WebSpectrum $run.Database $now)
            $run.Episodes = @(Read-WebEpisodes $run.Database $now)
        }
        catch { $run.Storage = 'Не удалось прочитать предыдущие снимки эфира.' }
    }
    $server.SetSpectrum((ConvertTo-Json -InputObject $run.Spectrum -Depth 8 -Compress))
    Start-WebScan $run (Get-UnixMilliseconds) $true
    $server.SetState((Get-WebState $run (Get-UnixMilliseconds) (Get-Date) | ConvertTo-Json -Depth 8 -Compress))
    Write-Host "Wi Fi открыт по адресу $($server.Address). Для остановки нажми Ctrl+C."
    try { Start-Process $server.Address } catch { }
    $publishAt = 0L
    $flushAt = 0L
    $previousLoop = 0L
    while ($true) {
        $now = Get-UnixMilliseconds
        if ($previousLoop -and ($now - $previousLoop -gt 8000 -or $now -lt $previousLoop)) {
            Close-WifiScanJob $run.Worker
            $run.Worker = $null
            $run.Active = $false
            $run.NextScan = 0L
            $run.LastActive = 0L
            Set-WebRoute $run $null
            Reset-WifiMeasurementContext $run.Engine $now
            $run.Streak.Clear()
            $run.Plans.Clear()
            $run.Forecast = $null
        }
        $previousLoop = $now
        if ($run.Worker -and (Test-WifiScanJobReady $run.Worker)) { Receive-WebScan $run }
        while ($command = $server.TakeCommand()) {
            switch ($command.Name) {
                'refresh' { Start-WebScan $run $now $true }
                'home' {
                    if ($command.Value -cne $run.HomeName) {
                        $run.HomeName = $command.Value
                        Save-WebHistory $run
                        Start-WebScan $run $now $true
                    }
                }
                'track' {
                    Set-WebTrackedPoint $run $command.Value (Get-Date)
                    Save-WebHistory $run
                }
            }
            $publishAt = 0L
        }
        if ($now -ge $run.NextScan) { Start-WebScan $run $now $false }
        if ($now -ge $run.NextRouterCheck) {
            $run.NextRouterCheck = $now + 60000
            try { $run.Router = Get-WifiRouterInfo $run.Diagnostics }
            catch { $run.Router = [pscustomobject] @{ address = ''; status = 'unverified'; model = ''; firmware = ''; management = $false; spectrum = 'unverified'; explanation = 'Проверка роутера недоступна.' } }
        }
        if ($now -ge $run.NextRouterTelemetry) {
            $run.NextRouterTelemetry = $now + 5000
            try {
                $run.RouterTelemetry = Read-RouterTelemetry $run.RouterTelemetryPath (Get-WifiRouterAddress $run.Diagnostics) $now
            } catch { $run.RouterTelemetry = $null }
            if ($run.ScanBlocked -and -not $run.Worker) {
                if ($run.RouterTelemetry) {
                    Use-WebRouterFallback $run $now
                } elseif ($run.Source -eq 'router-export') {
                    $run.Points = @()
                    $run.ScanAt = 0L
                    $run.Source = ''
                    $run.Plans.Clear()
                    $run.Evidence.Clear()
                }
            }
        }
        Update-WebProbes $run $now
        if ($now -ge $flushAt) {
            Save-WebMeasurements $run $now
            $flushAt = $now + 10000
        }
        if ($now -ge $publishAt) {
            $server.SetState((Get-WebState $run $now (Get-Date) | ConvertTo-Json -Depth 8 -Compress))
            $publishAt = $now + 850
        }
        Start-Sleep -Milliseconds 90
    }
} finally {
    if ($server) { $server.Dispose() }
    if ($run.Worker) { Close-WifiScanJob $run.Worker }
    $entry = Complete-WifiEpisode $run.Engine
    if ($entry) { Add-MonitorEvent $run.History (Get-Date) $entry.Message }
    Save-WebHistory $run
    Save-WebMeasurements $run (Get-UnixMilliseconds)
    if ($run.Database) { $run.Database.Dispose() }
    if ($run.LanPing) { $run.LanPing.Dispose() }
    if ($run.WanPing) { $run.WanPing.Dispose() }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
