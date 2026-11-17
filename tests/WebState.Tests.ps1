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

$server = [WiFi.WebServer]::new((Join-Path $project 'web'))
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(4)
try {
    $server.SetState(($state | ConvertTo-Json -Depth 8 -Compress))
    Assert ($server.Address.StartsWith('http://127.0.0.1:')) 'The server binds to IPv4 loopback'
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
'Passed 16 web dashboard and local HTTP checks'
