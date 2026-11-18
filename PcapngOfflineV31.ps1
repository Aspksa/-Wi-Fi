# Import a bounded subset of PCAPNG without installing capture drivers.
# Supports little-endian SHB, IDB and EPB with linktypes 105/127 only.
function Read-WifiPcapng([string]$Path,[int]$MaxRecords=3000){
    if(-not [IO.File]::Exists($Path)){throw 'PCAPNG файл не найден.'}
    if($MaxRecords -lt 1 -or $MaxRecords -gt 10000){throw 'Некорректный предел записей.'}
    $inputStream=[IO.File]::OpenRead($Path)
    $reader=[IO.BinaryReader]::new($inputStream)
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('aspksa-'+[guid]::NewGuid().ToString('N')+'.pcap')
    $output=$null;$writer=$null
    try{
        if($inputStream.Length -lt 28 -or $inputStream.Length -gt 128MB){throw 'Размер PCAPNG недопустим.'}
        $type=$reader.ReadUInt32()
        if($type -ne 0x0A0D0D0A){throw 'Нет заголовка PCAPNG SHB.'}
        $length=$reader.ReadUInt32()
        if($length -lt 28 -or $length -gt 1048576 -or $length%4 -ne 0 -or $length -gt $inputStream.Length){throw 'Неверный SHB размер.'}
        $body=$reader.ReadBytes([int]$length-12)
        $end=$reader.ReadUInt32()
        if($end -ne $length -or [BitConverter]::ToUInt32($body,0) -ne 0x1A2B3C4D){throw 'Нужен корректный little-endian PCAPNG.'}
        $interfaces=@()
        $count=0
        while($inputStream.Position+12 -le $inputStream.Length -and $count -lt $MaxRecords){
            $type=$reader.ReadUInt32()
            $length=$reader.ReadUInt32()
            if($length -lt 12 -or $length%4 -ne 0 -or $length -gt 1048576 -or
               $length -gt $inputStream.Length-$inputStream.Position+8){break}
            $data=$reader.ReadBytes([int]$length-12)
            if($reader.ReadUInt32() -ne $length){throw 'Неверная конечная длина блока PCAPNG.'}
            if($type -eq 1 -and $data.Length -ge 8){
                $interfaces+= [int][BitConverter]::ToUInt16($data,0)
                continue
            }
            if($type -ne 6 -or $data.Length -lt 20){continue}
            $count++
            $iface=[long][BitConverter]::ToUInt32($data,0)
            $captured=[long][BitConverter]::ToUInt32($data,12)
            if($iface -ge $interfaces.Count -or $captured -gt 65535 -or
                $captured -gt $data.Length-20){continue}
            $link=$interfaces[$iface]
            if($link -notin @(105,127)){continue}
            if(-not $writer){
                $output=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
                $writer=[IO.BinaryWriter]::new($output)
                $writer.Write([byte[]]@(0xd4,0xc3,0xb2,0xa1,2,0,4,0,0,0,0,0,0,0,0,0,255,255,0,0))
                $writer.Write([uint32]$link)
            }
            if($link -ne [int][BitConverter]::ToUInt32([IO.File]::ReadAllBytes($temporary),20)){continue}
            $writer.Write([byte[]]::new(8))
            $writer.Write([uint32]$captured)
            $writer.Write([uint32]$captured)
            $writer.Write($data,20,[int]$captured)
            $writer.Flush()
        }
        if(-not $writer){throw 'Нет поддерживаемых IEEE 802.11 кадров.'}
        $writer.Dispose();$output.Dispose();$writer=$null;$output=$null
        $parsed=Read-WifiPcap $temporary $MaxRecords
        $parsed.format='pcapng'
        $parsed.note='Офлайн PCAPNG через проверенный IEEE 802.11 декодер; только сохранённые разрешённые записи.'
        return $parsed
    }finally{
        if($writer){$writer.Dispose()}
        if($output){$output.Dispose()}
        $reader.Dispose();$inputStream.Dispose()
        if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
    }
}
