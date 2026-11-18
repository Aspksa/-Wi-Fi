$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
foreach ($file in @('Scan.ps1', 'Monitor.ps1', 'Intelligence.ps1', 'Recommendation.ps1', 'WebState.ps1')) {
    . (Join-Path $project $file)
}
Add-Type -Path (Join-Path $project 'WifiWebServer.cs')
Add-Type -AssemblyName System.Net.Http

function Assert($Value, [string] $Message) {
    if (-not $Value) { throw $Message }
}

$ownPoint = [pscustomobject] @{
    SSID='Домашняя сеть'; BSSID='00:00:00:00:00:01'; Band='5'; Channel=40
    Own=$true; Signal=92; Rssi=-47; Fresh=$true; Frequency=5200; RadioWidth=@{ Width=160; Center=5250 }
}
$neighbor = [pscustomobject] @{
    SSID='<b>Соседняя сеть</b>'; BSSID='00:00:00:00:00:02'; Band='5'; Channel=56; Own=$false; Signal=84; Fresh=$true
}
$now = Get-Date
$run = @{ Points=@($ownPoint,$neighbor); Plans=@{}; History=New-MonitorHistory; Advice=@{}; Latency=@() }
$advice = Get-WifiRecommendation $run.Points '5' @($ownPoint.BSSID) $now 'local' $null $run.History $null $null $null
$run.Plans['5'] = $advice.Plan
$run.Advice['5'] = $advice.Text
Assert ($advice.Text -match '40 / 80 МГц' -and $advice.Streak.Samples -eq 1) 'Dashboard uses shared width recommendations'
$run.Plans['5'].ReplayEligible = $true
Update-HeatHistory $run.History $run.Plans $now
$state = Get-WebState $run (Get-UnixMilliseconds) $now
Assert ($state.bands.Count -eq 2 -and $state.bands[1].width -eq 160 -and $state.bands[1].heat.Count -eq 24) 'State contains both bands and heat history'
Assert ($state.points[0].segments.Count -eq 1 -and $state.points[0].signalText -eq '-47 дБм') 'Native channel geometry and RSSI reach the browser'
Set-WebTrackedPoint $run (Get-WebPointId $ownPoint) $now
Assert ($null -eq $run.History.Tracked) 'The dashboard cannot track its own access point'
Set-WebTrackedPoint $run (Get-WebPointId $neighbor) $now
Assert (($run.History.Tracked.BSSID -eq $neighbor.BSSID) -and $run.History.Events.Count -eq 1) 'Tracking uses the selected access point identifier'
Set-WebTrackedPoint $run '' $now
Assert ($null -eq $run.History.Tracked -and $run.History.Events.Count -eq 2) 'Stopping tracking is recorded'

$ownPoint | Add-Member -NotePropertyName ObservedAt -NotePropertyValue 100000L
$neighbor.Fresh = $false
$frame = Get-SpectrumFrame 100000L @($ownPoint, $neighbor)
Assert ($frame.points.Count -eq 1 -and $frame.points[0].own) 'Stale observations are excluded from spectrum history'
$duplicates = @(Update-SpectrumFrames @($frame) (Get-SpectrumFrame 130000L @($ownPoint)))
Assert ($duplicates.Count -eq 1 -and $duplicates[0].at -eq 100000L) 'Repeated native snapshots do not create history rows'
$spectrum = @($frame)
for ($i = 1; $i -le 20; $i++) {
    $ownPoint.ObservedAt += 30000
    $spectrum = @(Update-SpectrumFrames $spectrum (Get-SpectrumFrame $ownPoint.ObservedAt @($ownPoint)))
}
Assert ($spectrum.Count -eq 16 -and $spectrum[-1].at -eq $ownPoint.ObservedAt) 'History keeps only the latest sixteen distinct records'

$archive = [pscustomobject] @{ Rows = @(
    ,@(200000L, 'invalid json')
    ,@(175000L, (ConvertTo-Json -InputObject @($ownPoint) -Depth 4 -Compress))
    ,@(145000L, (ConvertTo-Json -InputObject @($ownPoint) -Depth 4 -Compress))
) }
$archive | Add-Member -MemberType ScriptMethod -Name Query -Value { param($sql, $arguments) return ,$this.Rows }
$restored = @(Read-WebSpectrum $archive 200000L)
Assert ($restored.Count -eq 1 -and $restored[0].at -eq 145000L -and $restored[0].points[0].id -eq (Get-WebPointId $ownPoint)) 'Archived JSON restores chronologically and skips malformed or duplicate records'

$run.Streak = @{ '5' = @{ Samples = 3; Confirmed = $true } }
$run.Episodes = @((Get-WebEpisode @{
    Id='probe-1'; At=195000L; Ended=196000L; Network='5|mesh'; Cause='local-overlap'; Message='Скачок'
}))
$projection = Get-WebState $run (Get-UnixMilliseconds) $now
Assert ($projection.bands[1].preview.confirmed -and $projection.bands[1].preview.width -eq 80 -and
    $projection.bands[1].preview.segments.Count -gt 0) 'The browser receives the confirmed candidate geometry'
Assert ($projection.episodes[0].band -eq '5' -and $projection.episodes[0].route -eq 'router') 'Archived WLAN evidence identifies the correct radio'
$externalEpisode = Get-WebEpisode @{ Id='wan'; At=195500L; Network='2.4|mesh'; Cause='upload'; Message='Внешняя задержка' }
Assert ($externalEpisode.route -eq 'external') 'External episodes keep their route classification'

$healthRun = @{ Database = $true; ScanAt = 100000L; Source = 'Windows WLAN'; Points = @() }
$health = Get-WebHealth @{} 100000L
Assert ($health.adapter -eq 'pending' -and $health.scan -eq 'pending' -and $health.storage -eq 'unavailable') 'Startup distinguishes pending WLAN and missing storage'
Assert ((Get-WebHealth $healthRun 101000L).scan -eq 'empty') 'An empty scan still confirms adapter access'
$healthRun.Points = @(@{ Fresh = $true; ObservedAt = 55000L })
Assert ((Get-WebHealth $healthRun 100000L).scan -eq 'fresh') 'An observation at the freshness threshold is accepted'
Assert ((Get-WebHealth $healthRun 100001L).scan -eq 'stale') 'A recent cache read does not renew the observation timestamp'
$healthRun.Source = 'netsh'
Assert ((Get-WebHealth $healthRun 101000L).scan -eq 'unverified') 'Netsh cache age is unknown'
$healthRun.Worker = $true
$healthRun.ScanStartedAt = 100000L
Assert ((Get-WebHealth $healthRun 125001L).scan -eq 'slow') 'A stalled WLAN worker is detected while the server remains responsive'
$healthRun.Issue = 'Access denied'
$healthRun.Storage = 'Write failed'
$health = Get-WebHealth $healthRun 101000L
Assert ($health.scan -eq 'failed' -and $health.adapter -eq 'unverified' -and $health.storage -eq 'degraded') 'WLAN and storage failures can be reported together'

$server = [WiFi.WebServer]::new((Join-Path $project 'web'))
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(4)
try {
    $server.SetState(($state | ConvertTo-Json -Depth 8 -Compress))
    $server.SetSpectrum((ConvertTo-Json -InputObject $spectrum -Depth 8 -Compress))
    $items = @($client.GetStringAsync($server.Address + '/api/spectrum').GetAwaiter().GetResult() | ConvertFrom-Json)
    Assert ($items.Count -eq 16 -and $items[-1].points[0].segments.Count -eq 1) 'Archived footprint data is served as JSON'
    Assert ($server.Address.StartsWith('http://127.0.0.1:')) 'The server binds to IPv4 loopback'
    $air = $client.GetStringAsync($server.Address + '/air-map.js').GetAwaiter().GetResult()
    Assert ($air.Contains('drawVolume')) 'The perspective renderer is available locally'
    $page = $client.GetStringAsync($server.Address).GetAwaiter().GetResult()
    Assert ($page.Contains('spectrum-24') -and $page.Contains('spectrum-5')) 'The dashboard page is served'
    $json = $client.GetStringAsync($server.Address + '/api/state').GetAwaiter().GetResult() | ConvertFrom-Json
    Assert ($json.points[1].name -eq '<b>Соседняя сеть</b>') 'The API preserves SSID text'
    $external = $client.GetAsync($server.Address + '/README.md').GetAwaiter().GetResult()
    Assert ([int] $external.StatusCode -eq 404) 'Only fixed asset paths are exposed'
    $wrongHost = [System.Net.Http.HttpRequestMessage]::new('GET', $server.Address + '/api/state')
    $wrongHost.Headers.Host = 'untrusted.example'
    Assert ([int] $client.SendAsync($wrongHost).GetAwaiter().GetResult().StatusCode -eq 403) 'Unexpected Host header is rejected'
    $badOrigin = [System.Net.Http.HttpRequestMessage]::new('POST', $server.Address + '/api/refresh')
    $badOrigin.Headers.Add('Origin', 'https://untrusted.example')
    $badOrigin.Headers.Add('X-WiFi-Dashboard', '1')
    Assert ([int] $client.SendAsync($badOrigin).GetAwaiter().GetResult().StatusCode -eq 403) 'Other origins cannot enqueue commands'
    $sameOrigin = [System.Net.Http.HttpRequestMessage]::new('POST', $server.Address + '/api/refresh')
    $sameOrigin.Headers.Add('Sec-Fetch-Site', 'same-origin')
    $sameOrigin.Headers.Add('X-WiFi-Dashboard', '1')
    Assert ([int] $client.SendAsync($sameOrigin).GetAwaiter().GetResult().StatusCode -eq 204) 'A same-origin browser request without Origin is accepted'
    Assert ($server.TakeCommand().Name -eq 'refresh') 'Refresh is available through the queue'
    $name = 'Домашняя + сеть?'
    $setHome = [System.Net.Http.HttpRequestMessage]::new('POST', $server.Address + '/api/home?' + [uri]::EscapeDataString($name))
    $setHome.Headers.Add('Origin', $server.Address)
    $setHome.Headers.Add('X-WiFi-Dashboard', '1')
    Assert ([int] $client.SendAsync($setHome).GetAwaiter().GetResult().StatusCode -eq 204) 'The browser can submit a same-origin command'
    $command = $server.TakeCommand()
    Assert ($command.Name -eq 'home' -and $command.Value -ceq $name) 'Command arguments are decoded as UTF-8'
} finally {
    $client.Dispose()
    $server.Dispose()
}
'Passed 25 web dashboard, history and local HTTP checks'
