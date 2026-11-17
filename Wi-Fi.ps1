$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Scan.ps1')
. (Join-Path $PSScriptRoot 'Monitor.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$background = [Drawing.Color]::FromArgb(17, 18, 20)
$surface = [Drawing.Color]::FromArgb(29, 31, 36)
$white = [Drawing.Color]::FromArgb(239, 233, 220)
$muted = [Drawing.Color]::FromArgb(171, 174, 181)
$gold = [Drawing.Color]::FromArgb(240, 193, 100)
$script:points = @()
$script:streak = @{}
$script:plans = @{}
$script:worker = $null
$script:scan = $null
$script:refreshingRows = $false
$script:lastScanAt = $null
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
$script:history = try {
    Read-MonitorHistory $historyFile
} catch {
    $script:storageNote = 'История недоступна. Новые записи остаются в памяти.'
    New-MonitorHistory
}

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
$homeInput.BackColor = $surface
$homeInput.ForeColor = $white
$homeInput.Margin = [Windows.Forms.Padding]::new(0, 6, 10, 0)
$refresh = New-WifiButton 'Обновить' 105
$toolbar.Controls.AddRange(@($brand, $homeLabel, $homeInput, $refresh))
$page.Controls.Add($toolbar, 0, 0)

$diagnostics = New-Grid 1 2
$diagnostics.BackColor = $surface
[void] $diagnostics.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 48))
[void] $diagnostics.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 52))
$probeValues = New-Label 'До роутера  ·  Ожидание замера                       До интернета  ·  Ожидание замера' $white
$linkLabel = New-Label '' $muted
$probeValues.Margin = [Windows.Forms.Padding]::new(9, 0, 4, 0)
$linkLabel.Margin = $probeValues.Margin
$diagnostics.Controls.Add($probeValues, 0, 0)
$diagnostics.Controls.Add($linkLabel, 0, 1)
$page.Controls.Add($diagnostics, 0, 1)

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
$column = 0
foreach ($band in @('2.4', '5')) {
    $card = New-Grid 1 2
    $card.BackColor = $surface
    [void] $card.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 28))
    [void] $card.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
    $headline = New-Label "$($band.Replace('.', ',')) ГГц   ·   Оценка помех по каналам" $white
    $headline.Margin = [Windows.Forms.Padding]::new(8, 0, 0, 0)
    $card.Controls.Add($headline, 0, 0)
    $panel = New-Object Windows.Forms.Panel
    $panel.Dock = 'Fill'
    $panel.Tag = $band
    $panel.Add_Paint({ param($sender, $eventArgs); Draw-Channels $sender $eventArgs.Graphics })
    $panel.Add_Resize({ param($sender, $eventArgs); $sender.Invalidate() })
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

function Draw-Channels($Panel, $Graphics) {
    $plan = $script:plans[[string] $Panel.Tag]
    $mutedBrush = [Drawing.SolidBrush]::new($muted)
    $goldPen = [Drawing.Pen]::new($gold, 2)
    $goldBrush = [Drawing.SolidBrush]::new($gold)
    try {
        if (-not $plan -or -not $plan.VisibleCount) {
            $Graphics.DrawString('Сети не обнаружены', $Panel.Font, $mutedBrush, 9, 9)
            return
        }
        $rows = @($plan.Rows)
        $graphWidth = [Math]::Max(1.0, $Panel.ClientSize.Width - 16.0)
        $step = $graphWidth / $rows.Count
        $scale = [Math]::Max(100.0, [double] (($rows | Measure-Object Score -Maximum).Maximum))
        $bottomY = [Math]::Max(27, $Panel.ClientSize.Height - 23)
        $barWidth = [int] [Math]::Max(3.0, [Math]::Min(29.0, $step - 4.0))
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $row = $rows[$i]
            $x = [int] (8 + $i * $step + ($step - $barWidth) / 2)
            $height = [int] [Math]::Max(3.0, ($bottomY - 25) * $row.Score / $scale)
            $fill = [Drawing.SolidBrush]::new((Get-HeatColor $row.Score $true))
            try { $Graphics.FillRectangle($fill, $x, $bottomY - $height, $barWidth, $height) }
            finally { $fill.Dispose() }
            if ($row.Current) { $Graphics.DrawRectangle($goldPen, $x, $bottomY - $height, $barWidth, $height) }
            $textBrush = if ($row.Current) { $goldBrush } else { $mutedBrush }
            if ($step -ge 19 -or $row.Current -or $i % 2 -eq 0) {
                $Graphics.DrawString([string] $row.Channel, $Panel.Font, $textBrush, [single] ($x - 1), [single] ($bottomY + 3))
                if ($step -ge 28 -and $row.Score -gt 0) {
                    $Graphics.DrawString([string] $row.Score, $Panel.Font, $textBrush, [single] $x, [single] ($bottomY - $height - 16))
                }
            }
        }
    } finally {
        $mutedBrush.Dispose()
        $goldPen.Dispose()
        $goldBrush.Dispose()
    }
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
$scanScript = {
    param([string] $DiagnosticsScript)
    $ErrorActionPreference = 'Stop'
    . $DiagnosticsScript

    function Invoke-Netsh([string] $Arguments) {
        $process = New-Object Diagnostics.Process
        $process.StartInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'netsh.exe'
        $process.StartInfo.Arguments = $Arguments
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $codePage = [Globalization.CultureInfo]::InstalledUICulture.TextInfo.OEMCodePage
        $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::GetEncoding($codePage)
        try {
            [void] $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(7000)) {
                $process.Kill()
                throw 'Сканирование Wi-Fi не ответило вовремя.'
            }
            [pscustomobject] @{
                Code = $process.ExitCode
                Text = $stdout.GetAwaiter().GetResult()
                ErrorText = $stderr.GetAwaiter().GetResult()
            }
        } finally {
            $process.Dispose()
        }
    }

    $networks = Invoke-Netsh 'wlan show networks mode=bssid'
    $output = $networks.Text + ' ' + $networks.ErrorText
    if ($output -match '(?i)location|местоположени|расположени|access (?:is )?denied|отказано в доступе|elevation|повышени.+прав') {
        if ($networks.Code -ne 0 -or $networks.Text -notmatch '(?m)^\s*SSID\s+\d+\s*:') {
            throw 'Windows ограничила доступ. Проверь разрешение на определение местоположения и права учётной записи.'
        }
    }
    if ($output -match '(?i)(?:not running|не запущена|не запущен|no wireless interface|беспроводн\w+ интерфейс\w+ отсутств|нет беспроводн|не найдено беспроводн)') {
        throw 'Адаптер Wi-Fi недоступен. Проверь, включены ли адаптер и служба WLAN.'
    }
    if ($networks.Code -ne 0) {
        throw "Windows не завершила сканирование (код $($networks.Code))."
    }
    $interfaces = Invoke-Netsh 'wlan show interfaces'
    $diagnostics = try { Get-WifiDiagnostics } catch { $null }
    [pscustomobject] @{ Networks = $networks.Text; Interfaces = $interfaces.Text; Diagnostics = $diagnostics }
}

function Write-History {
    if ($script:storageNote) { return }
    try { Save-MonitorHistory $script:history $historyFile }
    catch { $script:storageNote = 'История недоступна. Новые записи остаются в памяти.' }
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
    $canStart = $selected -and -not $selected.Own -and
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
                $name, $point.Band.Replace('.', ','), [string] $point.Channel, "$($point.Signal)%"
            ))
            $item.Tag = $point
            if ($point.Own) { $item.ForeColor = $gold }
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
    $probeValues.Text = "До роутера  ·  $(Format-Probe $Snapshot.Router)       До интернета  ·  $(Format-Probe $Snapshot.Internet)"
    $linkLabel.Text = switch ($State) {
        'unknown' { 'Для диагностики нужен доступный шлюз IPv4 через Wi-Fi.' }
        'router-no-reply' { 'Роутер не ответил на ICMP. Это может зависеть от его настроек.' }
        'local' { 'До роутера есть задержка или потери. Сверь график каналов с журналом.' }
        'external' { 'До роутера связь стабильна. До 1.1.1.1 есть задержка или потери.' }
        'ok' { 'Оба адреса отвечают. Потерь в этом замере нет.' }
        'router-ok' { 'Роутер отвечает. Внешний замер доступен, когда маршрут идёт через Wi-Fi.' }
    }
}

function Update-Recommendations([datetime] $At, [string[]] $Connected, [string] $State) {
    foreach ($band in @('2.4', '5')) {
        $past = Get-PastScores $script:history $At $band
        $plan = Get-ChannelPlan $script:points $band $Connected $past
        $script:plans[$band] = $plan
        $bandText = $band.Replace('.', ',') + ' ГГц'
        $previous = $script:streak[$band]
        $count = 0
        $key = "$($plan.Home.BSSID)|$($plan.Home.Channel)|$($plan.Best.Channel)"
        if (-not $plan.Home) {
            $message = 'Укажи SSID, чтобы определить свой канал.'
        } elseif ($State -eq 'external') {
            $message = "Канал $($plan.Home.Channel). Проблема видна только до внешнего адреса."
        } elseif ($plan.Improves) {
            $count = 1
            if ($previous -and $previous.Key -eq $key) { $count += $previous.Samples }
            if ($count -ge 3) {
                $current = $plan.Rows | Where-Object Current | Select-Object -First 1
                $message = "Канал $($plan.Home.Channel) → $($plan.Best.Channel): $($current.Score) → $($plan.Best.Score) баллов."
                if ($count -eq 3) { Add-MonitorEvent $script:history $At "$bandText · совет: $message" }
            } else {
                $message = "Кандидат $($plan.Best.Channel) · подтверждение $count из 3."
            }
        } else {
            $message = "Канал $($plan.Home.Channel). Выигрыш от смены пока не виден."
        }
        $script:streak[$band] = @{ Key = $key; Samples = $count }
        $adviceLabels[$band].Text = "$bandText · $message"
        $mapPanels[$band].Invalidate()
    }
}

$poll = New-Object Windows.Forms.Timer
$poll.Interval = 150
$autoRefresh = New-Object Windows.Forms.Timer
$autoRefresh.Interval = 30000

function Start-Scan {
    if ($script:worker) { return }
    $refresh.Enabled = $false
    $status.Text = 'Обновление Wi-Fi и диагностики…'
    $script:worker = [PowerShell]::Create()
    [void] $script:worker.AddScript($scanScript.ToString()).AddArgument((Join-Path $PSScriptRoot 'Monitor.ps1'))
    $script:scan = $script:worker.BeginInvoke()
    $poll.Start()
}

$poll.Add_Tick({
    if (-not $script:scan.IsCompleted) { return }
    $poll.Stop()
    try {
        $result = $script:worker.EndInvoke($script:scan) | Select-Object -Last 1
        if ($script:worker.HadErrors) { throw $script:worker.Streams.Error[0] }
        if (-not $result) { throw 'Windows не вернула результат сканирования.' }
        $connectedAddresses = @(Get-ConnectedAddresses $result.Interfaces)
        $script:points = @(Get-WifiPoints $result.Networks $connectedAddresses $homeInput.Text)
        $at = Get-Date
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
        Update-Recommendations $at $connectedAddresses $state
        Update-TrackedPoint $script:history $script:points $script:plans $at
        Update-HeatHistory $script:history $script:plans $at
        Write-History
        Show-Networks
        Show-Events
        $heatPanel.Invalidate()
        $script:lastScanAt = $at
        $status.Text = "Замер $($at.ToString('HH:mm:ss'))  ·  Точек: $($script:points.Count)  ·  Золотой контур — свой канал. $script:storageNote"
    } catch {
        $script:streak.Clear()
        foreach ($band in $adviceLabels.Keys) { $adviceLabels[$band].Text = 'Ожидание свежего замера' }
        $status.Text = if ($script:lastScanAt) {
            "Обновление не удалось. Последний замер $($script:lastScanAt.ToString('HH:mm:ss'))."
        } else { "Не удалось обновить: $($_.Exception.GetBaseException().Message)" }
    } finally {
        $script:worker.Dispose()
        $script:worker = $null
        $script:scan = $null
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
    if ($selected -and -not $selected.Own -and
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
    Write-History
    Show-Tracking
    Show-Events
})
$refresh.Add_Click({ Start-Scan })
$homeInput.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Enter') {
        $eventArgs.SuppressKeyPress = $true
        Start-Scan
    }
})
$autoRefresh.Add_Tick({ Start-Scan })
$form.Add_Shown({ Show-Events; Show-Tracking; Start-Scan; $autoRefresh.Start() })
try {
    [void] $form.ShowDialog()
} finally {
    $autoRefresh.Dispose()
    $poll.Dispose()
    if ($script:worker) { $script:worker.Dispose() }
    $form.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
