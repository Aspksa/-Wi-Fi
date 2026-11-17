$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Scan.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$background = [Drawing.Color]::FromArgb(17, 18, 20)
$surface = [Drawing.Color]::FromArgb(27, 29, 33)
$white = [Drawing.Color]::FromArgb(239, 233, 220)
$muted = [Drawing.Color]::FromArgb(170, 174, 181)
$gold = [Drawing.Color]::FromArgb(240, 193, 100)
$script:points = @()
$script:connected = @()
$script:history = @{}
$script:plans = @{}
$script:worker = $null
$script:scan = $null
$script:rendering = $false
$script:lastScanAt = $null

$form = New-Object Windows.Forms.Form
$form.Text = 'Wi Fi'
$form.ClientSize = [Drawing.Size]::new(900, 620)
$form.MinimumSize = [Drawing.Size]::new(760, 510)
$form.BackColor = $background
$form.ForeColor = $white
$form.Font = [Drawing.Font]::new('Segoe UI', 10)
$form.StartPosition = 'CenterScreen'

$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.Padding = [Windows.Forms.Padding]::new(18, 12, 18, 12)
$layout.ColumnCount = 1
$layout.RowCount = 6
foreach ($height in @(54, 44, 34, 42)) {
    [void] $layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', $height))
}
[void] $layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
[void] $layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 35))
$form.Controls.Add($layout)

$title = New-Object Windows.Forms.Label
$title.Text = 'Wi Fi'
$title.ForeColor = $gold
$title.Font = [Drawing.Font]::new('Segoe UI', 24, [Drawing.FontStyle]::Bold)
$title.Dock = 'Fill'
$layout.Controls.Add($title, 0, 0)

$toolbar = New-Object Windows.Forms.FlowLayoutPanel
$toolbar.Dock = 'Fill'
$toolbar.WrapContents = $false
$layout.Controls.Add($toolbar, 0, 1)

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

$refresh = New-WifiButton 'Обновить' 100
$band24 = New-WifiButton '2,4 ГГц' 82
$band5 = New-WifiButton '5 ГГц' 82
$clear = New-WifiButton 'Все сети' 92
$homeInput = New-Object Windows.Forms.TextBox
$homeInput.Width = 180
$homeInput.MaxLength = 64
$homeInput.BackColor = $surface
$homeInput.ForeColor = $white
$homeInput.Margin = [Windows.Forms.Padding]::new(3, 6, 3, 3)
$homeLabel = New-Object Windows.Forms.Label
$homeLabel.Text = 'Своя сеть'
$homeLabel.AutoSize = $true
$homeLabel.Margin = [Windows.Forms.Padding]::new(13, 8, 3, 3)
$toolbar.Controls.AddRange(@($refresh, $band24, $band5, $clear, $homeLabel, $homeInput))

$summary = New-Object Windows.Forms.Label
$summary.Dock = 'Fill'
$summary.ForeColor = $white
$summary.TextAlign = 'MiddleLeft'
$layout.Controls.Add($summary, 0, 2)

$advice = New-Object Windows.Forms.Label
$advice.Dock = 'Fill'
$advice.ForeColor = $gold
$advice.TextAlign = 'MiddleLeft'
$layout.Controls.Add($advice, 0, 3)

$tables = New-Object Windows.Forms.TableLayoutPanel
$tables.Dock = 'Fill'
$tables.ColumnCount = 2
$tables.RowCount = 1
[void] $tables.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 284))
[void] $tables.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
[void] $tables.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$layout.Controls.Add($tables, 0, 4)

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

$channelList = New-WifiList @('Канал', 'Соседей', 'Баллы') @(104, 78, 78)
$networkList = New-WifiList @('Сеть', 'Канал', 'Сигнал', 'Точка доступа') @(178, 62, 70, 134)
$tables.Controls.Add($channelList, 0, 0)
$tables.Controls.Add($networkList, 1, 0)

$status = New-Object Windows.Forms.Label
$status.Dock = 'Fill'
$status.ForeColor = $muted
$status.TextAlign = 'MiddleLeft'
$layout.Controls.Add($status, 0, 5)

$script:band = '2.4'
$script:filter = $null

function Show-Networks {
    $networkList.BeginUpdate()
    try {
        $networkList.Items.Clear()
        $visible = $script:points | Where-Object {
            $_.Band -eq $script:band -and ($null -eq $script:filter -or $_.Channel -eq $script:filter)
        }
        foreach ($point in ($visible | Sort-Object -Property @{ Expression = 'Own'; Descending = $true },
                    @{ Expression = 'Signal'; Descending = $true })) {
            $name = if ($point.SSID) { $point.SSID } else { 'Скрытая сеть' }
            $item = [Windows.Forms.ListViewItem]::new([string[]] @(
                $name, [string] $point.Channel, "$($point.Signal)%", $point.BSSID
            ))
            if ($point.Own) { $item.ForeColor = $gold }
            [void] $networkList.Items.Add($item)
        }
    } finally {
        $networkList.EndUpdate()
    }
}

function Show-Plan {
    $script:rendering = $true
    $channelList.BeginUpdate()
    try {
        $channelList.Items.Clear()
        $band24.BackColor = $surface
        $band5.BackColor = $surface
        $active = if ($script:band -eq '2.4') { $band24 } else { $band5 }
        $active.BackColor = [Drawing.Color]::FromArgb(63, 48, 26)
        $plan = $script:plans[$script:band]
        if (-not $plan) {
            $summary.Text = 'Ожидание первого замера'
            $advice.Text = ''
            return
        }
        foreach ($row in $plan.Rows) {
            $label = if ($row.Current) { "$($row.Channel) · свой" } else { [string] $row.Channel }
            $item = [Windows.Forms.ListViewItem]::new([string[]] @(
                $label, [string] $row.Count, [string] $row.Score
            ))
            $item.Tag = $row.Channel
            if ($row.Current) { $item.ForeColor = $gold }
            [void] $channelList.Items.Add($item)
            if ($row.Channel -eq $script:filter) { $item.Selected = $true }
        }

        $ranked = $script:history[$script:band]
        $bandText = $script:band.Replace('.', ',') + ' ГГц'
        if ($plan.Home) {
            $summary.Text = "$bandText  ·  Своя сеть: $($plan.Home.SSID)  ·  Канал $($plan.Home.Channel)"
            if ($plan.Improves -and $ranked.Count -ge 3) {
                $current = $plan.Rows | Where-Object Current | Select-Object -First 1
                $advice.Text = "Канал $($plan.Best.Channel) выглядит свободнее: $($current.Score) → $($plan.Best.Score) баллов. Проверь его доступность в роутере."
            } elseif ($plan.Improves) {
                $advice.Text = "Кандидат: канал $($plan.Best.Channel). Подтверждение: $($ranked.Count) из 3 замеров."
            } else {
                $advice.Text = 'По текущему замеру оснований менять канал нет.'
            }
        } elseif (@($script:points | Where-Object Band -eq $script:band).Count -gt 0) {
            $summary.Text = "$bandText  ·  Своя сеть не определена"
            $advice.Text = 'Подключись к роутеру по Wi-Fi или укажи точное имя своей сети.'
        } else {
            $summary.Text = "$bandText  ·  Сети не обнаружены"
            $advice.Text = 'Проверь, видит ли этот диапазон адаптер Windows.'
        }
    } finally {
        $script:rendering = $false
        $channelList.EndUpdate()
        Show-Networks
    }
}

$scanScript = {
    $ErrorActionPreference = 'Stop'

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
    [pscustomobject] @{ Networks = $networks.Text; Interfaces = $interfaces.Text }
}

$poll = New-Object Windows.Forms.Timer
$poll.Interval = 150
$autoRefresh = New-Object Windows.Forms.Timer
$autoRefresh.Interval = 30000

function Start-Scan {
    if ($script:worker) { return }
    $refresh.Enabled = $false
    $status.Text = 'Обновление списка сетей…'
    $script:worker = [PowerShell]::Create()
    [void] $script:worker.AddScript($scanScript.ToString())
    $script:scan = $script:worker.BeginInvoke()
    $poll.Start()
}

$poll.Add_Tick({
    if (-not $script:scan.IsCompleted) { return }
    $poll.Stop()
    try {
        $result = $script:worker.EndInvoke($script:scan) | Select-Object -Last 1
        if ($script:worker.HadErrors -or -not $result) {
            throw $script:worker.Streams.Error[0]
        }
        $connectedAddresses = @(Get-ConnectedAddresses $result.Interfaces)
        $scannedPoints = @(Get-WifiPoints $result.Networks $connectedAddresses $homeInput.Text)
        $script:connected = $connectedAddresses
        $script:points = $scannedPoints
        foreach ($band in @('2.4', '5')) {
            $plan = Get-ChannelPlan $script:points $band $script:connected
            $script:plans[$band] = $plan
            $previous = $script:history[$band]
            $count = 0
            if ($plan.Improves) {
                $count = 1
                if ($previous -and $previous.Best -eq $plan.Best.Channel -and
                        $previous.Current -eq $plan.Home.Channel -and $previous.Home -eq $plan.Home.BSSID) {
                    $count += $previous.Count
                }
            }
            $script:history[$band] = @{
                Best = $plan.Best.Channel
                Current = $plan.Home.Channel
                Home = $plan.Home.BSSID
                Count = $count
            }
        }
        $script:lastScanAt = Get-Date
        Show-Plan
        $status.Text = "Замер $($script:lastScanAt.ToString('HH:mm:ss'))  ·  Точек: $($script:points.Count)  ·  Баллы — оценка помех"
    } catch {
        $status.Text = if ($script:lastScanAt) {
            "Обновление не удалось. На экране замер от $($script:lastScanAt.ToString('HH:mm:ss'))."
        } else {
            "Не удалось обновить: $($_.Exception.GetBaseException().Message)"
        }
        $script:history.Clear()
        $advice.Text = 'Рекомендация появится после успешных замеров.'
    } finally {
        $script:worker.Dispose()
        $script:worker = $null
        $script:scan = $null
        $refresh.Enabled = $true
    }
})

$refresh.Add_Click({ Start-Scan })
$homeInput.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Enter') {
        $eventArgs.SuppressKeyPress = $true
        Start-Scan
    }
})
$band24.Add_Click({ $script:band = '2.4'; $script:filter = $null; Show-Plan })
$band5.Add_Click({ $script:band = '5'; $script:filter = $null; Show-Plan })
$clear.Add_Click({ $script:filter = $null; Show-Plan })
$channelList.Add_SelectedIndexChanged({
    if (-not $script:rendering) {
        $script:filter = if ($channelList.SelectedItems.Count) { $channelList.SelectedItems[0].Tag } else { $null }
        Show-Networks
    }
})
$autoRefresh.Add_Tick({ Start-Scan })
$form.Add_Shown({ Show-Plan; Start-Scan; $autoRefresh.Start() })
try {
    [void] $form.ShowDialog()
} finally {
    $autoRefresh.Dispose()
    $poll.Dispose()
    if ($script:worker) { $script:worker.Dispose() }
    $form.Dispose()
}
