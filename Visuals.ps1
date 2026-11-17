function New-ChannelTrail($Tracked, [object[]] $Points, [double] $At, [object[]] $Previous) {
    if (-not $Tracked) { return }
    $point = $Points | Where-Object { $_.BSSID -eq $Tracked.BSSID -and $_.Band -eq $Tracked.Band -and $_.Fresh -ne $false } |
        Sort-Object Signal -Descending | Select-Object -First 1
    if ($point -and $point.Channel -ne $Tracked.Channel) {
        $origin = $Previous | Where-Object { $_.BSSID -eq $Tracked.BSSID -and $_.Band -eq $Tracked.Band -and
            $_.Channel -eq $Tracked.Channel } | Select-Object -First 1
        [pscustomobject] @{
            BSSID = $point.BSSID
            Band = $point.Band
            From = $Tracked.Channel
            To = $point.Channel
            Signal = $point.Signal
            Started = $At
            Origin = Get-SignalFootprint $point.Band $Tracked.Channel $origin
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
        $footprint = Get-SignalFootprint $point.Band $point.Channel $point
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
    $ownShapes = @()
    try {
        for ($i = 0; $i -le 3; $i++) {
            $y = [single] ($floor - $space * $i / 3)
            $Graphics.DrawLine($grid, [single] 14, $y, [single] (14 + $axis.Width), $y)
        }
        if (-not $Points.Count) {
            $Graphics.DrawString('Сети не обнаружены', $Panel.Font, $text, [single] 18, [single] 12)
            return
        }
        if ($Plan.Home) {
            $ownFootprint = Get-SignalFootprint $band $Plan.Home.Channel $Plan.Home
            $rise = $space * [Math]::Max(0.06, $Plan.Home.Signal / 100.0)
            foreach ($segment in (Get-SignalSegments $ownFootprint)) {
                $ownShapes += New-SignalArc (Get-SpectrumX $axis $segment.Left) (Get-SpectrumX $axis $segment.Right) $floor $rise
            }
        }
        $age = if ($Trail) { [Math]::Max(0.0, $Now - $Trail.Started) } else { 3.0 }
        foreach ($point in ($Points | Sort-Object -Property Own, Signal)) {
            $footprint = Get-SignalFootprint $band $point.Channel $point
            $tint = if ($point.Own) { $Theme.Gold } else { $Theme.Neighbor }
            $moving = $Trail -and $age -lt 2.2 -and $point.BSSID -eq $Trail.BSSID -and $point.Channel -eq $Trail.To
            $shift = 0.0
            if ($moving) {
                $progress = [Math]::Min(1.0, $age / 0.75)
                $shift = ($Trail.Origin.Primary - $footprint.Primary) * [Math]::Pow(1.0 - $progress, 3)
                $tint = $Theme.Trail
            }
            $rise = $space * [Math]::Max(0.06, $point.Signal / 100.0)
            $opacity = if ($point.Fresh -eq $false) { 83 } else { 201 }
            $outline = [Drawing.Pen]::new([Drawing.Color]::FromArgb($opacity, $tint), [single] $(if ($point.Own -or $moving) { 2 } else { 1 }))
            $fillOpacity = if ($point.Fresh -eq $false) { 8 } elseif ($point.Own) { 43 } else { 21 }
            $fill = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb($fillOpacity, $tint))
            try {
                $arcShift = $shift
                foreach ($segment in (Get-SignalSegments $footprint)) {
                    $arc = New-SignalArc (Get-SpectrumX $axis ($segment.Left + $arcShift)) (
                        Get-SpectrumX $axis ($segment.Right + $arcShift)
                    ) $floor $rise
                    $arcShift = 0.0
                    try {
                        $Graphics.FillPath($fill, $arc)
                        if (-not $point.Own -and $point.Fresh -ne $false -and (-not $moving -or $age -ge 0.75) -and
                                $ownShapes.Count -and (Get-SignalOverlap $ownFootprint $footprint)) {
                            foreach ($ownShape in $ownShapes) {
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
                        }
                        $Graphics.DrawPath($outline, $arc)
                    } finally { $arc.Dispose() }
                }
                $mark = Get-SpectrumX $axis ($footprint.Primary + $shift)
                $Graphics.DrawLine($outline, $mark, [single] ($floor - 5), $mark, [single] ($floor + 4))
            } finally {
                $outline.Dispose()
                $fill.Dispose()
            }
        }
        if ($Trail -and $age -lt 2.2) {
            $origin = $Trail.Origin
            $fade = [int] (180 * (1.0 - $age / 2.2))
            $ghostPen = [Drawing.Pen]::new([Drawing.Color]::FromArgb($fade, $Theme.Trail), [single] 1.4)
            $ghostText = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb($fade, $Theme.Trail))
            $ghostPen.DashStyle = 'Dash'
            try {
                $rise = $space * [Math]::Max(0.06, $Trail.Signal / 100.0)
                foreach ($segment in (Get-SignalSegments $origin)) {
                    $ghost = New-SignalArc (Get-SpectrumX $axis $segment.Left) (Get-SpectrumX $axis $segment.Right) $floor $rise
                    try { $Graphics.DrawPath($ghostPen, $ghost) }
                    finally { $ghost.Dispose() }
                }
                $startX = Get-SpectrumX $axis $origin.Primary
                $Graphics.DrawLine($ghostPen, $startX, [single] 12, $startX, $floor)
                $Graphics.DrawString("$($Trail.From) → $($Trail.To)", $Panel.Font, $ghostText, [single] 16, [single] 1)
            } finally {
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
        foreach ($ownShape in $ownShapes) { $ownShape.Dispose() }
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
