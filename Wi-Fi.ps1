$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Scan.ps1')
. (Join-Path $PSScriptRoot 'Monitor.ps1')
. (Join-Path $PSScriptRoot 'Visuals.ps1')
. (Join-Path $PSScriptRoot 'Intelligence.ps1')
. (Join-Path $PSScriptRoot 'Database.ps1')
. (Join-Path $PSScriptRoot 'Recommendation.ps1')
. (Join-Path $PSScriptRoot 'ScanJob.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$background = [Drawing.Color]::FromArgb(17, 18, 20)
$surface = [Drawing.Color]::FromArgb(29, 31, 36)
$white = [Drawing.Color]::FromArgb(239, 233, 220)
$muted = [Drawing.Color]::FromArgb(171, 174, 181)
$gold = [Drawing.Color]::FromArgb(240, 193, 100)
$script:points = @()
$theme = @{
    Muted = $muted
    Gold = $gold
    Neighbor = [Drawing.Color]::FromArgb(112, 177, 221)
    Glow = [Drawing.Color]::FromArgb(255, 132, 58)
    Loss = [Drawing.Color]::FromArgb(255, 91, 111)
    Trail = [Drawing.Color]::FromArgb(171, 154, 255)
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$script:trail = $null
$script:pulseUntil = 0.0
$script:latencySamples = @()
$script:gateway = $null
$script:pingTask = $null
$script:nextProbe = 0.0
$script:streak = @{}
$script:plans = @{}
$script:worker = $null
$script:scan = $null
$script:refreshingRows = $false
$script:lastScanAt = $null
$script:lastActiveRadioScan = -90.0
$script:activeRadioScan = $false
$script:lanDuringScan = $false
$script:linkState = ''
$script:storageNote = ''
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$mutex = [Threading.Mutex]::new($false, "Local\WiFiDashboard-$($identity.User.Value)")
try {
    $ownsMutex = $mutex.WaitOne(0)
} catch [Threading.AbandonedMutexException] {
    $ownsMutex = $true
}
if (-not $ownsMutex) {
    $mutex.Dispose()
    [void] [Windows.Forms.MessageBox]::Show('Окно Wi Fi уже открыто.', 'Wi Fi')
    return
}
$localData = [Environment]::GetFolderPath('LocalApplicationData')
$historyFile = Join-Path $localData 'Wi Fi\history.json'
$databaseFile = Join-Path $localData 'Wi Fi\wifi.sqlite'
$script:database = $null
$script:engine = New-WifiIntelligence
$script:forecast = $null
$script:nextPruneAt = (Get-UnixMilliseconds) + 3600000
try {
    $script:database = Open-WifiDatabase $databaseFile
    Remove-ExpiredMeasurements $script:database (Get-UnixMilliseconds)
} catch {
    if ($script:database) { $script:database.Dispose(); $script:database = $null }
    $script:storageNote = 'SQLite недоступна. Новые измерения остаются в памяти.'
}
$script:history = try {
    if ($script:database) { Get-DatabaseHistory $script:database $historyFile }
    else { Read-MonitorHistory $historyFile }
} catch {
    New-MonitorHistory
}
$script:savedHomeName = if ($script:database) {
    try { Get-DatabaseSetting $script:database 'home_ssid' } catch { '' }
} else { '' }

function New-Grid([int] $Columns, [int] $Rows) {
    $grid = New-Object Windows.Forms.TableLayoutPanel
    $grid.Dock = 'Fill'
    $grid.ColumnCount = $Columns
    $grid.RowCount = $Rows
    $grid
}

function New-Label([string] $Caption, [Drawing.Color] $Color, [int] $Size = 10) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Caption
    $label.ForeColor = $Color
    $label.Font = [Drawing.Font]::new('Segoe UI', $Size)
    $label.TextAlign = 'MiddleLeft'
    $label.Dock = 'Fill'
    $label
}

function New-WifiButton([string] $Caption, [int] $Width) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Caption
    $button.Size = [Drawing.Size]::new($Width, 30)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(91, 75, 49)
    $button.BackColor = $surface
    $button.ForeColor = $gold
    $button
}

function New-WifiList([string[]] $Columns, [int[]] $Widths) {
    $list = New-Object Windows.Forms.ListView
    $list.Dock = 'Fill'
    $list.BackColor = $surface
    $list.ForeColor = $white
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.HeaderStyle = 'Nonclickable'
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        [void] $list.Columns.Add($Columns[$i], $Widths[$i])
    }
    $list
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Wi Fi'
$form.ClientSize = [Drawing.Size]::new(1140, 740)
$form.MinimumSize = [Drawing.Size]::new(850, 650)
$form.BackColor = $background
$form.ForeColor = $white
$form.Font = [Drawing.Font]::new('Segoe UI', 10)
$form.StartPosition = 'CenterScreen'

$page = New-Grid 1 7
$page.Padding = [Windows.Forms.Padding]::new(14, 8, 14, 8)
[void] $page.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
[void] $page.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 46))
[void] $page.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 70))
[void] $page.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 51))
[void] $page.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 45))
[void] $page.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 99))
[void] $page.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 49))
[void] $page.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 26))
$form.Controls.Add($page)

$toolbar = New-Object Windows.Forms.FlowLayoutPanel
$toolbar.Dock = 'Fill'
$toolbar.WrapContents = $false
$brand = New-Label 'Wi Fi' $gold 23
$brand.Dock = 'None'
$brand.Size = [Drawing.Size]::new(112, 39)
$homeLabel = New-Label 'Своя сеть' $muted
$homeLabel.Dock = 'None'
$homeLabel.Size = [Drawing.Size]::new(75, 32)
$homeInput = New-Object Windows.Forms.TextBox
$homeInput.Width = 178
$homeInput.MaxLength = 64
$homeInput.Text = [string] $script:savedHomeName
$homeInput.BackColor = $surface
$homeInput.ForeColor = $white
$homeInput.Margin = [Windows.Forms.Padding]::new(0, 6, 10, 0)
$refresh = New-WifiButton 'Обновить' 105
$toolbar.Controls.AddRange(@($brand, $homeLabel, $homeInput, $refresh))
$page.Controls.Add($toolbar, 0, 0)

function New-GraphPanel {
    $panel = New-Object Windows.Forms.Panel
    $panel.Dock = 'Fill'
    $flags = [Reflection.BindingFlags]'Instance, NonPublic'
    [Windows.Forms.Control].GetProperty('DoubleBuffered', $flags).SetValue($panel, $true, $null)
    $panel.Add_Resize({ param($sender, $eventArgs); $sender.Invalidate() })
    $panel
}

$diagnosticArea = New-Grid 2 1
$diagnosticArea.BackColor = $surface
[void] $diagnosticArea.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 59))
[void] $diagnosticArea.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 41))
$diagnostics = New-Grid 1 3
[void] $diagnostics.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 19))
[void] $diagnostics.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 19))
[void] $diagnostics.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$routerProbeLabel = New-Label 'До роутера  ·  Ожидание замера' $white 9
$internetProbeLabel = New-Label 'До интернета  ·  Ожидание замера' $white 9
$linkLabel = New-Label '' $muted 9
foreach ($label in @($routerProbeLabel, $internetProbeLabel, $linkLabel)) {
    $label.Margin = [Windows.Forms.Padding]::new(9, 0, 0, 0)
}
$diagnostics.Controls.Add($routerProbeLabel, 0, 0)
$diagnostics.Controls.Add($internetProbeLabel, 0, 1)
$diagnostics.Controls.Add($linkLabel, 0, 2)
$diagnosticArea.Controls.Add($diagnostics, 0, 0)
$latencyPanel = New-GraphPanel
$latencyPanel.Add_Paint({
    param($sender, $eventArgs)
    Draw-LatencyGraph $sender $eventArgs.Graphics $script:latencySamples $clock.Elapsed.TotalSeconds $theme
})
$diagnosticArea.Controls.Add($latencyPanel, 1, 0)
$page.Controls.Add($diagnosticArea, 0, 1)

$maps = New-Grid 2 1
[void] $maps.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 50))
[void] $maps.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 50))
$page.Controls.Add($maps, 0, 2)

$mapPanels = @{}
$adviceLabels = @{}
$advice = New-Grid 2 1
[void] $advice.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 50))
[void] $advice.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 50))
$page.Controls.Add($advice, 0, 3)
$toolTip = New-Object Windows.Forms.ToolTip
$column = 0
foreach ($band in @('2.4', '5')) {
    $card = New-Grid 1 2
    $card.BackColor = $surface
    [void] $card.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 28))
    [void] $card.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
    $headline = New-Label "$($band.Replace('.', ',')) ГГц   ·   Карта каналов" $white
    $headline.Margin = [Windows.Forms.Padding]::new(8, 0, 0, 0)
    $card.Controls.Add($headline, 0, 0)
    $panel = New-GraphPanel
    $panel.Tag = $band
    $panel.Add_Paint({
        param($sender, $eventArgs)
        $currentBand = [string] $sender.Tag
        $visible = @($script:points | Where-Object Band -eq $currentBand)
        $trail = if ($script:trail -and $script:trail.Band -eq $currentBand) { $script:trail }
        Draw-Spectrum $sender $eventArgs.Graphics $visible $script:plans[$currentBand] $trail $clock.Elapsed.TotalSeconds $theme
    })
    $panel.Add_MouseMove({
        param($sender, $eventArgs)
        $currentBand = [string] $sender.Tag
        $axis = Get-SpectrumAxis $sender
        $visible = @($script:points | Where-Object Band -eq $currentBand)
        $nearest = Get-SpectrumHover $axis $visible $eventArgs.X
        $caption = if ($nearest) {
            $ssid = if ($nearest.SSID) { $nearest.SSID } else { 'Скрытая сеть' }
            Format-WifiPointTip $nearest $ssid
        } else { '' }
        if ($toolTip.GetToolTip($sender) -ne $caption) { $toolTip.SetToolTip($sender, $caption) }
    })
    $card.Controls.Add($panel, 0, 1)
    $maps.Controls.Add($card, $column, 0)
    $mapPanels[$band] = $panel
    $label = New-Label 'Ожидание замера' $gold
    $advice.Controls.Add($label, $column, 0)
    $adviceLabels[$band] = $label
    $column++
}

$heat = New-Grid 1 2
$heat.BackColor = $surface
[void] $heat.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 24))
[void] $heat.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$heatHeader = New-Label 'Последние 24 часа · помехи на своём канале · ярче — выше оценка · серый — нет замера' $muted 9
$heatHeader.Margin = [Windows.Forms.Padding]::new(8, 0, 0, 0)
$heat.Controls.Add($heatHeader, 0, 0)
$heatPanel = New-Object Windows.Forms.Panel
$heatPanel.Dock = 'Fill'
$heatPanel.Add_Paint({ param($sender, $eventArgs); Draw-Heatmap $sender $eventArgs.Graphics })
$heatPanel.Add_Resize({ param($sender, $eventArgs); $sender.Invalidate() })
$heat.Controls.Add($heatPanel, 0, 1)
$page.Controls.Add($heat, 0, 4)

$bottom = New-Grid 2 1
[void] $bottom.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 52))
[void] $bottom.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 48))
$page.Controls.Add($bottom, 0, 5)
$pointsCard = New-Grid 1 2
[void] $pointsCard.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 34))
[void] $pointsCard.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$pointControls = New-Object Windows.Forms.FlowLayoutPanel
$pointControls.Dock = 'Fill'
$pointControls.WrapContents = $false
$pointTitle = New-Label 'Точки доступа' $white
$pointTitle.Dock = 'None'
$pointTitle.Size = [Drawing.Size]::new(100, 29)
$trackButton = New-WifiButton 'Следить' 86
$trackButton.Enabled = $false
$trackStatus = New-Label '' $gold 9
$trackStatus.Dock = 'None'
$trackStatus.Size = [Drawing.Size]::new(175, 29)
$trackStatus.AutoEllipsis = $true
$pointControls.Controls.AddRange(@($pointTitle, $trackButton, $trackStatus))
$pointsCard.Controls.Add($pointControls, 0, 0)
$networkList = New-WifiList @('Сеть', 'ГГц', 'Канал', 'Сигнал') @(205, 47, 61, 63)
$pointsCard.Controls.Add($networkList, 0, 1)
$bottom.Controls.Add($pointsCard, 0, 0)

$eventsCard = New-Grid 1 2
[void] $eventsCard.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 34))
[void] $eventsCard.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$eventTitle = New-Label 'Журнал событий' $white
$eventsCard.Controls.Add($eventTitle, 0, 0)
$eventList = New-WifiList @('Время', 'Событие') @(128, 445)
$eventsCard.Controls.Add($eventList, 0, 1)
$bottom.Controls.Add($eventsCard, 1, 0)

$status = New-Label 'Ожидание замера' $muted 9
$page.Controls.Add($status, 0, 6)

function Get-HeatColor([double] $Score, [bool] $Measured) {
    if (-not $Measured) { return [Drawing.Color]::FromArgb(57, 59, 65) }
    $intensity = [Math]::Min(1.0, $Score / 100.0)
    [Drawing.Color]::FromArgb([int] (59 + 177 * $intensity), [int] (51 + 121 * $intensity), [int] (38 + 40 * $intensity))
}

function Draw-Heatmap($Panel, $Graphics) {
    $labelBrush = [Drawing.SolidBrush]::new($muted)
    $hours = @{}
    foreach ($entry in $script:history.Hours) {
        $hours["$($entry.Band)|$($entry.Key)"] = $entry
    }
    try {
        $now = Get-Date
        $step = [Math]::Max(1.0, ($Panel.ClientSize.Width - 76.0) / 24.0)
        for ($i = 0; $i -lt 24; $i++) {
            $time = $now.AddHours($i - 23)
            $key = $time.ToString('yyyy-MM-dd HH')
            $x = [int] (68 + $i * $step)
            $y = 5
            foreach ($band in @('2.4', '5')) {
                $entry = $hours["$band|${key}"]
                $measured = $entry -and $entry.OwnCount -gt 0
                $score = if ($measured) { $entry.OwnSum / $entry.OwnCount } else { 0.0 }
                $brush = [Drawing.SolidBrush]::new((Get-HeatColor $score $measured))
                try { $Graphics.FillRectangle($brush, $x, $y, [Math]::Max(1, [int] $step - 2), 15) }
                finally { $brush.Dispose() }
                $y += 19
            }
            if ($i % 3 -eq 0 -or $i -eq 23) {
                $Graphics.DrawString($time.ToString('HH'), $Panel.Font, $labelBrush, [single] $x, 44)
            }
        }
        $Graphics.DrawString('2,4 ГГц', $Panel.Font, $labelBrush, 5, 4)
        $Graphics.DrawString('5 ГГц', $Panel.Font, $labelBrush, 5, 23)
    } finally {
        $labelBrush.Dispose()
    }
}
function Write-History {
    if (-not $script:database) { return }
    try {
        Set-DatabaseSetting $script:database 'history' (ConvertTo-Json -InputObject $script:history -Depth 8 -Compress)
        if ($homeInput.Text -cne $script:savedHomeName) {
            Set-DatabaseSetting $script:database 'home_ssid' $homeInput.Text
            $script:savedHomeName = $homeInput.Text
        }
    } catch {
        $script:storageNote = 'Сохранение истории SQLite не удалось.'
    }
}

function Write-Measurements {
    if (-not $script:database) {
        $script:engine.PendingSamples.Clear()
        $script:engine.PendingScans.Clear()
        $script:engine.PendingIncidents.Clear()
        $script:engine.PendingTrials.Clear()
        $script:engine.PendingChecks.Clear()
        return
    }
    if (-not ($script:engine.PendingSamples.Count -or $script:engine.PendingScans.Count -or
            $script:engine.PendingIncidents.Count -or $script:engine.PendingTrials.Count -or
            $script:engine.PendingChecks.Count)) { return }
    try {
        Save-Intelligence $script:database $script:engine
        $now = Get-UnixMilliseconds
        if ($now -ge $script:nextPruneAt) {
            Remove-ExpiredMeasurements $script:database $now
            $script:nextPruneAt = $now + 3600000
        }
        $script:storageNote = ''
    } catch {
        $script:storageNote = 'SQLite временно недоступна. Повторю запись.'
    }
}

function Publish-Intelligence([object[]] $Entries) {
    foreach ($entry in $Entries) {
        Add-MonitorEvent $script:history (Get-Date) $entry.Message
        if ($entry.Forecast) {
            $radio = $script:engine.Radio
            $script:forecast = @{ At = (Get-UnixMilliseconds); Band = $radio.Band; Network = $radio.Network; Text = $entry.Message }
            if ($radio -and $adviceLabels[$radio.Band]) {
                $adviceLabels[$radio.Band].Text = $entry.Message
            }
        }
    }
    if ($Entries.Count) { Show-Events; Write-History; Write-Measurements }
}

function Show-Events {
    $eventList.BeginUpdate()
    try {
        $eventList.Items.Clear()
        foreach ($entry in $script:history.Events) {
            $item = [Windows.Forms.ListViewItem]::new([string[]] @($entry.At, $entry.Message))
            [void] $eventList.Items.Add($item)
        }
    } finally { $eventList.EndUpdate() }
}

function Get-SelectedPoint {
    if ($networkList.SelectedItems.Count) { $networkList.SelectedItems[0].Tag }
}

function Show-Tracking {
    $selected = Get-SelectedPoint
    $tracked = $script:history.Tracked
    $canStart = $selected -and -not $selected.Own -and $selected.Fresh -ne $false -and
        (-not $tracked -or $selected.BSSID -ne $tracked.BSSID -or $selected.Band -ne $tracked.Band)
    $trackButton.Enabled = [bool] ($canStart -or $tracked)
    $trackButton.Text = if ($canStart -or -not $tracked) { 'Следить' } else { 'Остановить' }
    $trackStatus.Text = if ($tracked) { "$($tracked.SSID) · канал $($tracked.Channel)" } else { 'Выбери соседа' }
}

function Show-Networks {
    $selected = Get-SelectedPoint
    $script:refreshingRows = $true
    $networkList.BeginUpdate()
    try {
        $networkList.Items.Clear()
        foreach ($point in ($script:points | Sort-Object -Property @{ Expression = 'Own'; Descending = $true },
                    @{ Expression = 'Signal'; Descending = $true })) {
            $name = if ($point.SSID) { $point.SSID } else { 'Скрытая сеть' }
            $item = [Windows.Forms.ListViewItem]::new([string[]] @(
                $name, $point.Band.Replace('.', ','), [string] $point.Channel, (Format-WifiSignal $point)
            ))
            $item.Tag = $point
            if ($point.Fresh -eq $false) { $item.ForeColor = $muted }
            elseif ($point.Own) { $item.ForeColor = $gold }
            [void] $networkList.Items.Add($item)
            if ($selected -and $point.BSSID -eq $selected.BSSID -and $point.Band -eq $selected.Band) {
                $item.Selected = $true
            }
        }
    } finally {
        $script:refreshingRows = $false
        $networkList.EndUpdate()
    }
    Show-Tracking
}

function Format-Probe($Probe) {
    if (-not $Probe -or -not $Probe.Tested) { return 'нет замера' }
    if ($Probe.Lost -eq 3) { return 'нет ответов (3 из 3)' }
    "$($Probe.Average) мс, потери $($Probe.Lost) из 3"
}

function Show-Diagnostics($Snapshot, [string] $State) {
    $routerProbeLabel.Text = "До роутера  ·  $(Format-Probe $Snapshot.Router)"
    $internetProbeLabel.Text = "До интернета  ·  $(Format-Probe $Snapshot.Internet)"
    $linkLabel.Text = switch ($State) {
        'unknown' { 'Для диагностики нужен доступный шлюз IPv4 через Wi-Fi.' }
        'router-no-reply' { 'Роутер не ответил на ICMP. Это может зависеть от его настроек.' }
        'local' { 'До роутера есть задержка или потери. Сверь график каналов с журналом.' }
        'external' { 'До роутера связь стабильна. До 1.1.1.1 есть задержка или потери.' }
        'ok' { 'Оба адреса отвечают. Потерь в этом замере нет.' }
        'router-ok' { 'Роутер отвечает. Внешний замер доступен, когда маршрут идёт через Wi-Fi.' }
    }
}

function Update-Recommendations([datetime] $At, [string[]] $Connected, [string] $State, $Native) {
    foreach ($band in @('2.4', '5')) {
        $result = Get-WifiRecommendation $script:points $band $Connected $At $State $Native $script:history `
            $script:database $script:streak[$band] $script:forecast
        $script:plans[$band] = $result.Plan
        $script:streak[$band] = $result.Streak
        if ($result.StorageNote) { $script:storageNote = $result.StorageNote }
        $adviceLabels[$band].Text = "$($band.Replace('.', ',')) ГГц · $($result.Text)"
        $mapPanels[$band].Invalidate()
    }
}

$poll = New-Object Windows.Forms.Timer
$poll.Interval = 150
$autoRefresh = New-Object Windows.Forms.Timer
$autoRefresh.Interval = 30000
$animation = New-Object Windows.Forms.Timer
$animation.Interval = 33
$probeTimer = New-Object Windows.Forms.Timer
$probeTimer.Interval = 100
$ping = [Net.NetworkInformation.Ping]::new()
$wanPing = [Net.NetworkInformation.Ping]::new()
$wanTarget = [Net.IPAddress]::Parse('1.1.1.1')
$script:wanTask = $null
$script:wanResult = $null
$script:wanEnabled = $false
$script:networkEpoch = 0
$script:lanEpoch = 0
$script:wanEpoch = 0
$script:nextWan = 0.0
$script:adapter = $null
$script:trafficPoint = $null
$storageTimer = New-Object Windows.Forms.Timer
$storageTimer.Interval = 10000
$storageTimer.Add_Tick({ Write-Measurements })

function Set-WifiTelemetryRoute($Snapshot) {
    $adapterId = $Snapshot.AdapterId
    $wanEnabled = [bool] ($Snapshot.WifiRoute -and $Snapshot.Gateway)
    if ([string] $script:gateway -ne [string] $Snapshot.Gateway -or
            [string] $script:adapter.Id -ne [string] $adapterId -or $script:wanEnabled -ne $wanEnabled) {
        Reset-WifiMeasurementContext $script:engine (Get-UnixMilliseconds)
        $script:networkEpoch++
        $script:wanResult = $null
        $script:trafficPoint = $null
        $script:wanEnabled = $wanEnabled
        $script:adapter = if ($adapterId) {
            [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object Id -eq $adapterId | Select-Object -First 1
        }
    }
    Set-ProbeGateway $Snapshot.Gateway
}

function Add-LatencyMeasurement([long] $At, $Milliseconds, [bool] $Lost, [bool] $Scanning) {
    $radio = $script:engine.Radio
    if ($radio -and ($At - $radio.At -gt 45000 -or
            ($radio.ObservedAt -and $At - $radio.ObservedAt -gt 45000))) { $radio = $null }
    $upload = $null
    if ($script:adapter) {
        try {
            $bytes = $script:adapter.GetIPv4Statistics().BytesSent
            $upload = Get-UploadRate $script:trafficPoint $bytes $At
            $script:trafficPoint = @{ At = $At; Bytes = $bytes }
        } catch { $script:trafficPoint = $null }
    }
    $external = $script:wanResult
    $script:wanResult = $null
    if ($external -and $At - $external.At -gt 1400) { $external = $null }
    $overlap = if ($radio) {
        if ($radio.ChangedAt -gt 0 -and $At - $radio.ChangedAt -lt 45000) { 'changed' }
        elseif ($radio.Signature) { 'strong' }
        else { 'clear' }
    }
    $measurement = [pscustomobject] @{
        At = $At; Network = [string] $radio.Network; Channel = $radio.Channel; Width = $radio.Width; Signal = $radio.Signal
        Upload = $upload; Overlap = $overlap; Lan = $Milliseconds; LanLoss = $Lost
        Wan = $external.Milliseconds; WanLoss = $external.Lost; Scanning = $Scanning
    }
    $entries = @(Add-WifiSample $script:engine $measurement {
        param($network, $context)
        if ($script:database) {
            try { Get-ForecastEvidence $script:database $network $context } catch { return }
        }
    })
    if ($entries.Count) { Publish-Intelligence $entries }
}

function Set-ProbeGateway($Address) {
    if ([string] $Address -eq [string] $script:gateway) { return }
    $script:gateway = $Address
    $script:latencySamples = @()
    $script:pulseUntil = 0.0
    $script:nextProbe = 0.0
    $latencyPanel.Invalidate()
}

$probeTimer.Add_Tick({
    $now = $clock.Elapsed.TotalSeconds
    $at = Get-UnixMilliseconds
    if ($script:lastProbeTick -and ($at - $script:lastProbeTick -gt 8000 -or $at -lt $script:lastProbeTick)) {
        $poll.Stop()
        Close-WifiScanJob $script:worker
        $script:worker = $null
        Set-WifiTelemetryRoute $null
        Reset-WifiMeasurementContext $script:engine $at
        $script:streak.Clear()
        $script:plans.Clear()
        $script:forecast = $null
        Start-Scan $true
    }
    $script:lastProbeTick = $at
    if ($script:retryScanAt -and $at -ge $script:retryScanAt -and -not $script:worker) {
        $script:retryScanAt = 0L
        Start-Scan $true
    }
    if ($script:wanTask -and $script:wanTask.IsCompleted) {
        $task = $script:wanTask
        $script:wanTask = $null
        if ($task.Status -eq 'Faulted') { [void] $task.Exception }
        if ($task.Status -eq 'RanToCompletion' -and $script:wanEnabled -and -not $script:activeRadioScan -and $script:wanEpoch -eq $script:networkEpoch) {
            $reply = $task.Result
            $lost = $reply.Status -ne 'Success'
            $script:wanResult = @{
                At = $at; Lost = $lost; Milliseconds = $(if (-not $lost) { [int] $reply.RoundtripTime })
            }
        }
    }
    if ($script:wanEnabled -and -not $script:activeRadioScan -and -not $script:wanTask -and $now -ge $script:nextWan) {
        $script:wanEpoch = $script:networkEpoch
        $script:nextWan = $now + 3.0
        try {
            $route = Get-InternetRouteAddress $wanTarget
            if ($route -and $script:adapter -and ($script:adapter.GetIPProperties().UnicastAddresses |
                        Where-Object { $_.Address.Equals($route) } | Select-Object -First 1)) {
                $script:wanTask = $wanPing.SendPingAsync($wanTarget, 650)
            }
        } catch { $script:wanTask = $null }
    }
    if ($script:pingTask -and $script:pingTask.IsCompleted) {
        $task = $script:pingTask
        $script:pingTask = $null
        if ($task.Status -eq 'Faulted') { [void] $task.Exception }
        if ($task.Status -eq 'RanToCompletion' -and $script:lanEpoch -eq $script:networkEpoch) {
            $reply = $task.Result
            $lost = $reply.Status -ne 'Success'
            $milliseconds = if (-not $lost) { [int] $reply.RoundtripTime }
            $level = Get-LatencyLevel $milliseconds $lost
            Add-LatencyMeasurement $at $milliseconds $lost ($script:activeRadioScan -or $script:lanDuringScan)
            $script:latencySamples = @($script:latencySamples | Where-Object { $now - $_.At -le 60 }) +
                @([pscustomobject] @{ At = $now; Milliseconds = $milliseconds; Level = $level })
            if ($level -ne 'normal') {
                $script:pulseUntil = $now + 1.1
                $animation.Start()
            }
            $latencyPanel.Invalidate()
        }
    }
    if ($script:gateway -and -not $script:pingTask -and $now -ge $script:nextProbe) {
        $interval = if ($at -lt $script:engine.BurstUntil) { 0.35 } else { 1.0 }
        $script:nextProbe = $now + $interval
        $script:lanEpoch = $script:networkEpoch
        $script:lanDuringScan = $script:activeRadioScan
        try {
            $script:pingTask = $ping.SendPingAsync($script:gateway, 650)
        } catch [Net.NetworkInformation.PingException] {
            $script:pingTask = $null
        }
    }
})

$animation.Add_Tick({
    $now = $clock.Elapsed.TotalSeconds
    $pulse = $now -lt $script:pulseUntil
    if ($script:trail) {
        $band = $script:trail.Band
        if ($now - $script:trail.Started -ge 2.2) { $script:trail = $null }
        $mapPanels[$band].Invalidate()
    }
    if ($script:pulseUntil -gt 0) {
        $latencyPanel.Invalidate()
        if (-not $pulse) { $script:pulseUntil = 0.0 }
    }
    if (-not $pulse -and -not $script:trail) { $animation.Stop() }
})

function Start-Scan([bool] $Force = $false) {
    if ($script:worker) { return }
    $now = $clock.Elapsed.TotalSeconds
    $diagnosticsOnly = [bool] ($script:scanBlocked -and -not $Force)
    $active = -not $diagnosticsOnly -and ($Force -or ($now - $script:lastActiveRadioScan -ge 90 -and -not $script:engine.Incident))
    $script:activeRadioScan = $active
    if ($active) {
        $script:lastActiveRadioScan = $now
        $script:wanResult = $null
    }
    $refresh.Enabled = $false
    $status.Text = if ($diagnosticsOnly) { 'Обновление диагностики связи…' } else { 'Обновление Wi-Fi и диагностики…' }
    try { $script:worker = Start-WifiScanJob $active $diagnosticsOnly }
    catch {
        $status.Text = $_.Exception.GetBaseException().Message
        $script:activeRadioScan = $false
        $script:retryScanAt = (Get-UnixMilliseconds) + 5000
        $refresh.Enabled = $true
        return
    }
    $poll.Start()
}

$poll.Add_Tick({
    if (-not (Test-WifiScanJobReady $script:worker)) { return }
    $poll.Stop()
    try {
        $result = Receive-WifiScanJob $script:worker
        $script:retryScanAt = 0L
        $script:scanBlocked = [bool] $result.ScanBlocked
        if ($script:scanBlocked) {
            $script:points = @()
            $script:trail = $null
            $script:streak.Clear()
            $script:plans.Clear()
            $script:forecast = $null
            Set-WifiTelemetryRoute $result.Diagnostics
            Update-WifiRadio $script:engine $null (Get-UnixMilliseconds)
            $script:linkState = Get-LinkState $result.Diagnostics
            Show-Diagnostics $result.Diagnostics $script:linkState
            foreach ($band in $adviceLabels.Keys) {
                $adviceLabels[$band].Text = 'Для совета нужен снимок эфира.'
                $mapPanels[$band].Invalidate()
            }
            Show-Networks
            $status.Text = 'Диагностика связи · Сканирование ограничено Windows.'
            return
        }
        $previousPoints = $script:points
        if ($result.Native) {
            $connectedAddresses = @($result.Native.Connected | Where-Object { $_ })
            $script:points = @(ConvertFrom-NativeScan $result.Native $homeInput.Text)
            $source = 'Windows WLAN'
        } else {
            $connectedAddresses = @(Get-ConnectedAddresses $result.Interfaces)
            $script:points = @(Get-WifiPoints $result.Networks $connectedAddresses $homeInput.Text)
            $source = 'netsh'
        }
        $at = Get-Date
        $trail = New-ChannelTrail $script:history.Tracked $script:points $clock.Elapsed.TotalSeconds $previousPoints
        if ($trail) {
            $script:trail = $trail
            $animation.Start()
        }
        Set-WifiTelemetryRoute $result.Diagnostics
        $tickAt = if ($result.Native) { $result.Native.FinishedAt } else { Get-UnixMilliseconds }
        $radio = Get-WifiRadioContext $script:points $connectedAddresses $script:engine.Radio $tickAt
        Update-WifiRadio $script:engine $radio $tickAt
        if ($script:database -and $script:engine.PendingScans.Count -lt 120) {
            $script:engine.PendingScans.Add([pscustomobject] @{
                At = $tickAt; Network = [string] $radio.Network; Points = $script:points
            })
        }
        $state = Get-LinkState $result.Diagnostics
        if ($state -ne $script:linkState) {
            if ($state -eq 'local') { Add-MonitorEvent $script:history $at 'Задержка или потери до роутера.' }
            if ($state -eq 'external') { Add-MonitorEvent $script:history $at 'Роутер отвечает стабильно, до 1.1.1.1 есть задержка или потери.' }
            if ($state -eq 'ok' -and $script:linkState -in @('local', 'external')) {
                Add-MonitorEvent $script:history $at 'Оба адреса снова отвечают без потерь.'
            }
            $script:linkState = $state
        }
        Show-Diagnostics $result.Diagnostics $state
        Update-Recommendations $at $connectedAddresses $state $result.Native
        Update-TrackedPoint $script:history $script:points $script:plans $at
        Update-HeatHistory $script:history $script:plans $at
        Write-History
        Show-Networks
        Show-Events
        $heatPanel.Invalidate()
        $script:lastScanAt = $at
        $status.Text = "Замер $($at.ToString('HH:mm:ss'))  ·  $source  ·  Точек: $($script:points.Count)  ·  Золотой контур — свой канал. $script:storageNote"
    } catch {
        $script:retryScanAt = (Get-UnixMilliseconds) + 5000
        $script:streak.Clear()
        $script:plans.Clear()
        $script:forecast = $null
        Set-WifiTelemetryRoute $null
        foreach ($band in $adviceLabels.Keys) { $adviceLabels[$band].Text = 'Ожидание свежего замера' }
        $status.Text = if ($script:lastScanAt) {
            "Обновление не удалось. Последний замер $($script:lastScanAt.ToString('HH:mm:ss'))."
        } else { "Не удалось обновить: $($_.Exception.GetBaseException().Message)" }
    } finally {
        Close-WifiScanJob $script:worker
        $script:worker = $null
        $script:activeRadioScan = $false
        $refresh.Enabled = $true
    }
})

$networkList.Add_SelectedIndexChanged({
    if (-not $script:refreshingRows) { Show-Tracking }
})
$trackButton.Add_Click({
    $selected = Get-SelectedPoint
    $tracked = $script:history.Tracked
    $at = Get-Date
    if ($selected -and -not $selected.Own -and $selected.Fresh -ne $false -and
            (-not $tracked -or $selected.BSSID -ne $tracked.BSSID -or $selected.Band -ne $tracked.Band)) {
        $name = if ($selected.SSID) { $selected.SSID } else { 'Скрытая сеть' }
        $script:history.Tracked = [pscustomobject] @{
            SSID = $name; BSSID = $selected.BSSID; Band = $selected.Band; Channel = $selected.Channel; Overlap = $null
        }
        Add-MonitorEvent $script:history $at "Наблюдение: $name · канал $($selected.Channel)."
        Update-TrackedPoint $script:history $script:points $script:plans $at
    } elseif ($tracked) {
        Add-MonitorEvent $script:history $at "Наблюдение завершено: $($tracked.SSID)."
        $script:history.Tracked = $null
    }
    if ($script:trail) {
        $mapPanels[$script:trail.Band].Invalidate()
        $script:trail = $null
    }
    Write-History
    Show-Tracking
    Show-Events
})
$refresh.Add_Click({ Start-Scan $true })
$homeInput.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Enter') {
        $eventArgs.SuppressKeyPress = $true
        Start-Scan $true
    }
})
$autoRefresh.Add_Tick({ Start-Scan })
$form.Add_Shown({ Show-Events; Show-Tracking; Start-Scan $true; $autoRefresh.Start(); $probeTimer.Start(); $storageTimer.Start() })
try {
    [void] $form.ShowDialog()
} finally {
    $autoRefresh.Dispose()
    $poll.Dispose()
    $animation.Dispose()
    $probeTimer.Dispose()
    $storageTimer.Dispose()
    $closed = Complete-WifiEpisode $script:engine
    if ($closed) { Add-MonitorEvent $script:history (Get-Date) $closed.Message }
    Write-History
    Write-Measurements
    if ($script:database) { $script:database.Dispose() }
    $ping.Dispose()
    $wanPing.Dispose()
    $toolTip.Dispose()
    if ($script:worker) { Close-WifiScanJob $script:worker }
    $form.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
