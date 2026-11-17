$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'Scan.ps1')
. (Join-Path $project 'Visuals.ps1')
Add-Type -Path (Join-Path $project 'WifiNativeScan.cs')

function Assert($Value, [string] $Message) {
    if (-not $Value) { throw $Message }
}

$ht = [byte[]]::new(24)
$ht[0] = 61; $ht[1] = 22; $ht[2] = 6; $ht[3] = 5
$width = [WiFi.NativeScanner]::DecodeWidth($ht, '2.4', 6, 2437)
Assert ($width.Width -eq 40 -and $width.Center -eq 2447) 'HT secondary channel above primary'
$wide24 = [pscustomobject] @{ Channel=6; Frequency=2437; RadioWidth=$width }
Assert ($null -eq (Get-CandidateFootprint '2.4' 11 $wide24)) 'A 40 MHz candidate cannot move a secondary channel outside the band'
$ht[3] = 7
$width = [WiFi.NativeScanner]::DecodeWidth($ht, '2.4', 6, 2437)
Assert ($width.Width -eq 40 -and $width.Center -eq 2427) 'HT secondary channel below primary'
$ht[3] = 0
Assert (([WiFi.NativeScanner]::DecodeWidth($ht, '2.4', 6, 2437)).Width -eq 20) 'HT 20 MHz'

$vht80 = [byte[]] @(192, 5, 1, 42, 0, 0, 0)
$width = [WiFi.NativeScanner]::DecodeWidth($vht80, '5', 36, 5180)
Assert ($width.Width -eq 80 -and $width.Center -eq 5210) 'VHT 80 MHz'
$wide = [WiFi.NativeScanner]::DecodeWidth([byte[]] @(192, 5, 1, 42, 50, 0, 0), '5', 36, 5180)
Assert ($wide.Width -eq 160 -and $wide.Center -eq 5250) 'Revised VHT 160 MHz'
Assert (([WiFi.NativeScanner]::DecodeWidth([byte[]] @(192, 5, 2, 50, 0, 0, 0), '5', 36, 5180)).Width -eq 160) 'Legacy VHT 160 MHz'
$split = [WiFi.NativeScanner]::DecodeWidth([byte[]] @(192, 5, 1, 42, 155, 0, 0), '5', 36, 5180)
Assert ($split.Width -eq 80 -and $split.SecondaryCenter -eq 5775) 'Two non-contiguous VHT segments'
Assert ($null -eq [WiFi.NativeScanner]::DecodeWidth([byte[]] @(192, 5, 1, 42), '5', 36, 5180)) 'Corrupt information element'
Assert ($null -eq [WiFi.NativeScanner]::DecodeWidth($vht80, '5', 149, 5745)) 'Reported segment conflicts with the primary channel'
$eht = [byte[]] ($vht80 + @(255, 9, 106, 1, 0, 0, 0, 0, 3, 42, 50))
Assert (([WiFi.NativeScanner]::DecodeWidth($eht, '5', 36, 5180)).Width -eq 160) 'EHT operation takes precedence'
Assert ($null -eq [WiFi.NativeScanner]::DecodeWidth([byte[]] @(192, 5, 1, 58, 0, 0, 0), '5', 36, 5180)) 'Out-of-band primary and segment pair rejected'

$now = 1773835000000L
# Two native entries followed by a separate information-element blob.
$size = 8 + 2 * 360 + $vht80.Length
$buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
$parse = [WiFi.NativeScanner].GetMethod('ReadBssList', [Reflection.BindingFlags]'Static, NonPublic')
try {
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($size), 0, $buffer, $size)
    [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 0, $size)
    [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 4, 2)
    for ($i = 0; $i -lt 2; $i++) {
        $offset = 8 + 360 * $i
        $ssid = [Text.Encoding]::UTF8.GetBytes('Сосед')
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $offset, $ssid.Length)
        [Runtime.InteropServices.Marshal]::Copy($ssid, 0, [IntPtr]::Add($buffer, $offset + 4), $ssid.Length)
        [Runtime.InteropServices.Marshal]::WriteByte($buffer, $offset + 45, [byte] ($i + 1))
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $offset + 48, 1)
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $offset + 56, -61)
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $offset + 60, 78)
        [Runtime.InteropServices.Marshal]::WriteInt64($buffer, $offset + 80, [long] (116444736000000000L + ($now - 49000 * $i) * 10000))
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $offset + 92, 5180000)
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $offset + 352, (2 - $i) * 360)
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $offset + 356, $vht80.Length)
    }
    [Runtime.InteropServices.Marshal]::Copy($vht80, 0, [IntPtr]::Add($buffer, $size - $vht80.Length), $vht80.Length)
    $nativePoints = @($parse.Invoke($null, [object[]] @($buffer, $size, $now)) | ForEach-Object { $_ })
    Assert ($nativePoints.Count -eq 2 -and $nativePoints[1].Width.Center -eq 5210) 'Per-entry relative IE offsets'
    Assert ($nativePoints[0].Name -eq 'Сосед' -and $nativePoints[0].Rssi -eq -61 -and $nativePoints[0].Channel -eq 36) 'Binary BSS entry fields'
    Assert ($nativePoints[0].SeenAt -eq $now -and $nativePoints[1].SeenAt -eq ($now - 49000)) 'Windows FILETIME converted to Unix milliseconds'
    $result = @{ Points=$nativePoints; Connected=$nativePoints[0].Address; Completed=$false; FinishedAt=$now }
    $points = @(ConvertFrom-NativeScan $result '')
    Assert ($points.Count -eq 2 -and $points[0].Own -and $points[0].Fresh -and -not $points[1].Fresh) 'Connected and stale points are marked independently'
    Assert ((Get-ScanObservationKey $result $points '5' (Get-Date)) -eq $now) 'Repeated list reads share an observation key'
    Assert ((Format-WifiPointTip $points[0] 'Своя') -match '5180 МГц.*-61 дБм.*заявленная полоса 80 МГц') 'Native tooltip includes exact signal and stated width'
    Assert ((Get-ChannelPlan @($points[1]) '5' @()).VisibleCount -eq 0) 'Stale point cannot affect advice'
    [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 8 + 352, 4)
    $bad = @($parse.Invoke($null, [object[]] @($buffer, $size, $now)) | ForEach-Object { $_ })
    Assert ($null -eq $bad[0].Width -and $bad[1].Width.Width -eq 80) 'An invalid IE pointer cannot read the fixed entry or contaminate a valid neighbor'
} finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }

$first = [pscustomobject] @{ Channel=36; Frequency=5180; RadioWidth=$split; Signal=100 }
$primary = Get-SignalFootprint '5' 36 $first
$second = Get-SignalFootprint '5' 149
Assert (@(Get-SignalOverlap $primary $second).Count -eq 1) 'The secondary segment participates in overlap'
Assert ((Get-ChannelScore 149 '5' @($first)) -eq 100) 'Interference includes the secondary segment'
Assert ($null -eq (Get-CandidateFootprint '5' 149 $first)) 'Moving onto the retained secondary segment is excluded'
Assert ((Format-WifiSignal @{ Signal=77 }) -eq '77%') 'Fallback signal display is localized'
'Passed 24 native scan and channel geometry checks'
