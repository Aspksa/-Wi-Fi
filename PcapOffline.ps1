# Offline, read-only parsing of previously authorized capture files.
# No live capture, driver changes, scanning or packet transmission.
function Read-WifiPcap([string]$Path,[int]$MaxRecords=3000) {
    if (-not [IO.File]::Exists($Path)) { throw 'PCAP файл не найден.' }
    if ($MaxRecords -lt 1 -or $MaxRecords -gt 10000) { throw 'Некорректный предел записей.' }
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $reader=[IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 24 -or $stream.Length -gt 128MB) { throw 'Размер PCAP недопустим.' }
        $header=$reader.ReadBytes(24)
        $magic=[BitConverter]::ToString($header,0,4)
        $little=$magic -eq 'D4-C3-B2-A1' -or $magic -eq '4D-3C-B2-A1'
        if (-not $little -and $magic -ne 'A1-B2-C3-D4' -and $magic -ne 'A1-B2-3C-4D') {
            throw 'Поддерживается только обычный PCAP; PCAPNG требует отдельного импортера.'
        }
        $number = {
            param([byte[]]$Bytes,[int]$At)
            if ($little) { return [BitConverter]::ToUInt32($Bytes,$At) }
            $copy=[byte[]]@($Bytes[$At+3],$Bytes[$At+2],$Bytes[$At+1],$Bytes[$At])
            [BitConverter]::ToUInt32($copy,0)
        }
        $link=& $number $header 20
        if ($link -notin @(105,127)) { throw 'Только IEEE 802.11 (105) или radiotap (127).' }
        $records=0
        $frames=@()
        while($stream.Position+16 -le $stream.Length -and $records -lt $MaxRecords) {
            $record=$reader.ReadBytes(16)
            $length=[long](& $number $record 8)
            $records++
            if($length -gt 65535 -or $stream.Position+$length -gt $stream.Length) { break }
            $payload=$reader.ReadBytes([int]$length)
            $offset=0
            if($link -eq 127) {
                if($payload.Length -lt 8 -or $payload[0] -ne 0) { continue }
                $offset=[BitConverter]::ToUInt16($payload,2)
                if($offset -lt 8 -or $offset -gt $payload.Length) {continue}
            }
            if($payload.Length-$offset -lt 38) {continue}
            $control=$payload[$offset]
            if(($control -band 0x0c) -ne 0 -or (($control -shr 4) -notin @(5,8))) {continue}
            $bssid=[BitConverter]::ToString($payload,($offset+16),6).Replace('-',':').ToLowerInvariant()
            $ie=$offset+36
            $ssid=$null
            $caps=@{he=$false;eht=$false;ht=$false;vht=$false;rsn=$false;p2p=$false}
            $valid=$true
            while($ie+2 -le $payload.Length) {
                $id=[int]$payload[$ie]
                $size=[int]$payload[$ie+1]
                $ie+=2
                if($ie+$size -gt $payload.Length) {$valid=$false;break}
                if($id -eq 0 -and $null -eq $ssid) {
                    $ssid=$(if($size -eq 0){''}else{
                        [Text.Encoding]::UTF8.GetString($payload,$ie,$size)
                    })
                }
                if($id -in @(45,61)) {$caps.ht=$true}
                if($id -in @(191,192)) {$caps.vht=$true}
                if($id -eq 48) {$caps.rsn=$true}
                if($id -eq 255 -and $size -ge 2) {
                    if($payload[$ie] -in @(35,36)){$caps.he=$true}
                    if($payload[$ie] -in @(106,108)){$caps.eht=$true}
                }
                if($id -eq 221 -and $size -ge 4 -and
                        $payload[$ie] -eq 0x50 -and $payload[$ie+1] -eq 0x6f -and
                        $payload[$ie+2] -eq 0x9a -and $payload[$ie+3] -eq 9) {$caps.p2p=$true}
                $ie+=$size
            }
            if(-not $valid) {continue}
            $frames += [pscustomobject]@{
                bssid=$bssid;ssid=$ssid;hiddenSsid=$ssid -eq ''
                frameType=$(if(($control -shr 4) -eq 8){'beacon'}else{'probe-response'})
                ht=$caps.ht;vht=$caps.vht;he=$caps.he;eht=$caps.eht;rsn=$caps.rsn;p2p=$caps.p2p
                source='offline-pcap';notLive=$true
            }
            if($frames.Count -ge 500) {break}
        }
        [pscustomobject]@{
            format='pcap';linkType=[int]$link;packetsRead=$records
            networks=@($frames);containsRadioMeasurements=$false
            note='Только управление 802.11 из ранее сохранённого PCAP; RSSI и загрузка эфира здесь не измеряются.'
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}
