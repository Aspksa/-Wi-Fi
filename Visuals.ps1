function Get-SignalFootprint([string] $Band, [int] $Channel) {
    if ($Band -eq '2.4') {
        $primary = if ($Channel -eq 14) { 2484 } else { 2407 + $Channel * 5 }
        return [pscustomobject] @{ Primary = $primary; Left = $primary - 10; Right = $primary + 10; Width = 20 }
    }
    $primary = 5000 + $Channel * 5
    $block = Get-5GHzBlockStart $Channel
    if ($null -ne $block) {
        $left = 5000 + $block * 5 - 10
        return [pscustomobject] @{ Primary = $primary; Left = $left; Right = $left + 80; Width = 80 }
    }
    [pscustomobject] @{ Primary = $primary; Left = $primary - 10; Right = $primary + 10; Width = 20 }
}

function Get-SignalOverlap($First, $Second) {
    $left = [Math]::Max([int] $First.Left, [int] $Second.Left)
    $right = [Math]::Min([int] $First.Right, [int] $Second.Right)
    if ($right -gt $left) { [pscustomobject] @{ Left = $left; Right = $right } }
}

function New-ChannelTrail($Tracked, [object[]] $Points, [double] $At) {
    if (-not $Tracked) { return }
    $point = $Points | Where-Object { $_.BSSID -eq $Tracked.BSSID -and $_.Band -eq $Tracked.Band } |
        Sort-Object Signal -Descending | Select-Object -First 1
    if ($point -and $point.Channel -ne $Tracked.Channel) {
        [pscustomobject] @{
            BSSID = $point.BSSID
            Band = $point.Band
            From = $Tracked.Channel
            To = $point.Channel
            Signal = $point.Signal
            Started = $At
        }
    }
}

function Get-LatencyLevel([Nullable[int]] $Milliseconds, [bool] $Lost) {
    if ($Lost) { return 'loss' }
    if ($null -ne $Milliseconds -and $Milliseconds -gt 35) { return 'spike' }
    'normal'
}

function Get-SpectrumAxis($Panel) {
    $low, $high = if ($Panel.Tag -eq '2.4') { 2399, 2497 } else { 5145, 5910 }
    [pscustomobject] @{ Low = $low; Width = [Math]::Max(1.0, $Panel.ClientSize.Width - 28.0); Range = $high - $low }
}

function Get-SpectrumX($Axis, [double] $Frequency) {
    [single] (14 + ($Frequency - $Axis.Low) * $Axis.Width / $Axis.Range)
}

function Get-SpectrumHover($Axis, [object[]] $Points, [int] $X) {
    $nearest = $null
    $bestDistance = 12.0
    foreach ($point in $Points) {
        $footprint = Get-SignalFootprint $point.Band $point.Channel
        $distance = [Math]::Abs($X - (Get-SpectrumX $Axis $footprint.Primary))
        if ($distance -lt $bestDistance -or ($distance -eq $bestDistance -and $point.Signal -gt $nearest.Signal)) {
            $nearest = $point
            $bestDistance = $distance
        }
    }
    $nearest
}

function New-SignalArc([single] $Left, [single] $Right, [single] $Floor, [single] $Rise) {
    $path = [Drawing.Drawing2D.GraphicsPath]::new()
    $middle = ($Left + $Right) / 2
    $width = $Right - $Left
    $top = $Floor - $Rise
    $path.AddBezier($Left, $Floor, $Left + $width * 0.24, $Floor, $middle - $width * 0.28, $top, $middle, $top)
    $path.AddBezier($middle, $top, $middle + $width * 0.28, $top, $Right - $width * 0.24, $Floor, $Right, $Floor)
    return ,$path
}

function Draw-Spectrum($Panel, $Graphics, [object[]] $Points, $Plan, $Trail, [double] $Now, $Theme) {
    $Graphics.SmoothingMode = 'AntiAlias'
    $band = [string] $Panel.Tag
    $axis = Get-SpectrumAxis $Panel
    $floor = [single] [Math]::Max(24, $Panel.ClientSize.Height - 25)
    $space = [Math]::Max(1.0, $floor - 14.0)
    $grid = [Drawing.Pen]::new([Drawing.Color]::FromArgb(65, 70, 80))
    $text = [Drawing.SolidBrush]::new($Theme.Muted)
    $ownShape = $null
    try {
        for ($i = 0; $i -le 3; $i++) {
            $y = [single] ($floor - $space * $i / 3)
            $Graphics.DrawLine($grid, [single] 14, $y, [single] (14 + $axis.Width), $y)
        }
        if (-not $Points.Count) {
            $Graphics.DrawString('Сети не обнаружены', $Panel.Font, $text, [single] 18, [single] 12)
            return
        }
        $ownFootprint = $null
        if ($Plan.Home) {
            $ownFootprint = Get-SignalFootprint $band $Plan.Home.Channel
            $ownShape = New-SignalArc (Get-SpectrumX $axis $ownFootprint.Left) (Get-SpectrumX $axis $ownFootprint.Right) $floor (
                $space * [Math]::Max(0.06, $Plan.Home.Signal / 100.0)
            )
        }
        $age = if ($Trail) { [Math]::Max(0.0, $Now - $Trail.Started) } else { 3.0 }
        foreach ($point in ($Points | Sort-Object -Property Own, Signal)) {
            $footprint = Get-SignalFootprint $band $point.Channel
            $primary = $footprint.Primary
            $left = $footprint.Left
            $right = $footprint.Right
            $tint = if ($point.Own) { $Theme.Gold } else { $Theme.Neighbor }
            $moving = $Trail -and $age -lt 2.2 -and $point.BSSID -eq $Trail.BSSID -and $point.Channel -eq $Trail.To
            if ($moving) {
                $origin = Get-SignalFootprint $band $Trail.From
                $progress = [Math]::Min(1.0, $age / 0.75)
                $eased = 1.0 - [Math]::Pow(1.0 - $progress, 3)
                $left = $origin.Left + ($left - $origin.Left) * $eased
                $right = $origin.Right + ($right - $origin.Right) * $eased
                $primary = $origin.Primary + ($primary - $origin.Primary) * $eased
                $tint = $Theme.Trail
            }
            $rise = $space * [Math]::Max(0.06, $point.Signal / 100.0)
            $arc = New-SignalArc (Get-SpectrumX $axis $left) (Get-SpectrumX $axis $right) $floor $rise
            $outline = [Drawing.Pen]::new([Drawing.Color]::FromArgb(201, $tint), [single] $(if ($point.Own -or $moving) { 2 } else { 1 }))
            $fill = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb($(if ($point.Own) { 43 } else { 21 }), $tint))
            try {
                $Graphics.FillPath($fill, $arc)
                $overlap = if ($ownShape -and -not $point.Own -and (-not $moving -or $age -ge 0.75)) {
                    Get-SignalOverlap $ownFootprint $footprint
                }
                if ($overlap) {
                    $oldClip = $Graphics.Save()
                    $light = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb([int] (20 + $point.Signal * 0.65), $Theme.Glow))
                    try {
                        $Graphics.SetClip($ownShape, [Drawing.Drawing2D.CombineMode]::Intersect)
                        $Graphics.FillPath($light, $arc)
                    } finally {
                        $Graphics.Restore($oldClip)
                        $light.Dispose()
                    }
                }
                $Graphics.DrawPath($outline, $arc)
                $mark = Get-SpectrumX $axis $primary
                $Graphics.DrawLine($outline, $mark, [single] ($floor - 5), $mark, [single] ($floor + 4))
            } finally {
                $arc.Dispose()
                $outline.Dispose()
                $fill.Dispose()
            }
        }
        if ($Trail -and $age -lt 2.2) {
            $origin = Get-SignalFootprint $band $Trail.From
            $ghost = New-SignalArc (Get-SpectrumX $axis $origin.Left) (Get-SpectrumX $axis $origin.Right) $floor (
                $space * [Math]::Max(0.06, $Trail.Signal / 100.0)
            )
            $fade = [int] (180 * (1.0 - $age / 2.2))
            $ghostPen = [Drawing.Pen]::new([Drawing.Color]::FromArgb($fade, $Theme.Trail), [single] 1.4)
            $ghostText = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb($fade, $Theme.Trail))
            $ghostPen.DashStyle = 'Dash'
            try {
                $Graphics.DrawPath($ghostPen, $ghost)
                $startX = Get-SpectrumX $axis $origin.Primary
                $Graphics.DrawLine($ghostPen, $startX, [single] 12, $startX, $floor)
                $Graphics.DrawString("$($Trail.From) → $($Trail.To)", $Panel.Font, $ghostText, [single] 16, [single] 1)
            } finally {
                $ghost.Dispose()
                $ghostPen.Dispose()
                $ghostText.Dispose()
            }
        }
        $lastX = -100
        $axisRows = @($Plan.Rows | Where-Object {
            $band -eq '2.4' -or $_.Current -or $_.Count -gt 0 -or $_.Channel -in @(36, 48, 100, 149, 161)
        })
        foreach ($row in $axisRows) {
            $footprint = Get-SignalFootprint $band $row.Channel
            $x = Get-SpectrumX $axis $footprint.Primary
            if ($x - $lastX -lt 22 -and -not $row.Current) { continue }
            $Graphics.DrawString([string] $row.Channel, $Panel.Font, $text, [single] ($x - 6), [single] ($floor + 5))
            $lastX = $x
        }
    } finally {
        if ($ownShape) { $ownShape.Dispose() }
        $grid.Dispose()
        $text.Dispose()
    }
}

function Draw-LatencyGraph($Panel, $Graphics, [object[]] $Samples, [double] $Now, $Theme) {
    $Graphics.SmoothingMode = 'AntiAlias'
    $floor = [single] [Math]::Max(24, $Panel.ClientSize.Height - 10)
    $span = [single] [Math]::Max(1, $Panel.ClientSize.Width - 32)
    $height = [single] [Math]::Max(1, $floor - 22)
    $mutedInk = [Drawing.SolidBrush]::new($Theme.Muted)
    $grid = [Drawing.Pen]::new([Drawing.Color]::FromArgb(65, 70, 80))
    $line = [Drawing.Pen]::new($Theme.Neighbor, [single] 1.6)
    $hot = [Drawing.SolidBrush]::new($Theme.Glow)
    $loss = [Drawing.Pen]::new($Theme.Loss, [single] 1.8)
    try {
        $Graphics.DrawString('Отклик роутера · 60 секунд', $Panel.Font, $mutedInk, [single] 9, [single] 2)
        $Graphics.DrawLine($grid, [single] 10, $floor, [single] (10 + $span), $floor)
        $previous = $null
        foreach ($sample in $Samples) {
            $age = $Now - $sample.At
            if ($age -lt 0 -or $age -gt 60) { continue }
            $x = [single] (10 + $span * (1 - $age / 60))
            $y = if ($sample.Level -eq 'loss') { [single] ($floor - $height) } else {
                [single] ($floor - $height * [Math]::Min(1.0, $sample.Milliseconds / 120.0))
            }
            if ($sample.Level -ne 'loss' -and $previous -and ($sample.At - $previous.At) -lt 2.5) {
                $Graphics.DrawLine($line, $previous.X, $previous.Y, $x, $y)
            }
            if ($sample.Level -ne 'normal') {
                $pulseColor = $Theme.Glow
                if ($sample.Level -eq 'loss') {
                    $pulseColor = $Theme.Loss
                    $Graphics.DrawLine($loss, [single] ($x - 3), [single] ($y - 3), [single] ($x + 3), [single] ($y + 3))
                    $Graphics.DrawLine($loss, [single] ($x - 3), [single] ($y + 3), [single] ($x + 3), [single] ($y - 3))
                } else {
                    $Graphics.FillEllipse($hot, [single] ($x - 2.5), [single] ($y - 2.5), [single] 5, [single] 5)
                }
                if ($age -lt 1.1) {
                    $radius = [single] (4 + $age * 16)
                    $pulse = [Drawing.Pen]::new([Drawing.Color]::FromArgb([int] (190 * (1 - $age / 1.1)), $pulseColor), [single] 2)
                    try { $Graphics.DrawEllipse($pulse, [single] ($x - $radius), [single] ($y - $radius), [single] ($radius * 2), [single] ($radius * 2)) }
                    finally { $pulse.Dispose() }
                }
            }
            $previous = if ($sample.Level -ne 'loss') { [pscustomobject] @{ At = $sample.At; X = $x; Y = $y } }
        }
    } finally {
        $mutedInk.Dispose()
        $grid.Dispose()
        $line.Dispose()
        $hot.Dispose()
        $loss.Dispose()
    }
}
