# Read-only v3 inference over existing WLAN, history and spectrum models.
function New-WifiRoamTracker {
    @{ Last=$null; LastAt=0L; Changes=@() }
}
function Update-WifiRoamTracker($Tracker,[string]$Bssid,[string]$Ssid,[long]$At,
    [bool]$Confirmed,[object[]]$Latency) {
    if(-not $Tracker -or -not $Confirmed -or $At -le 0 -or
        $At -le [long]$Tracker.LastAt -or
        $Bssid -notmatch '^(?i:[0-9a-f]{2}:){5}(?i:[0-9a-f]{2})$') {return $false}
    $current=[pscustomobject]@{bssid=$Bssid.ToLowerInvariant();ssid=$Ssid}
    if($Tracker.Last -and $Tracker.Last.bssid -ne $current.bssid -and
        $Ssid -and $Tracker.Last.ssid -eq $Ssid) {
        $samples=@($Latency | Where-Object {
            $At-[long]$_.at -ge 0 -and $At-[long]$_.at -le 30000 -and
            ($_.lost -or ($null -ne $_.ms -and [double]$_.ms -gt 35))
        })
        $Tracker.Changes=@([pscustomobject]@{
            at=$At;ssid=$Ssid;from=$Tracker.Last.bssid;to=$current.bssid
            localProblemsNearby=$samples.Count
            cause='unverified'
        })+@($Tracker.Changes | Select-Object -First 19)
    }
    $Tracker.Last=$current
    $Tracker.LastAt=$At
    return $true
}
function Get-WifiV3RadioSummary([object[]]$Points,$Roaming,[long]$Now,
    [bool]$NativeCompleted) {
    $visible=@($Points | Where-Object {$_.Fresh -ne $false -and $_.BSSID})
    $hidden=@($visible | Where-Object {-not $_.SSID -or $_.HiddenSsid})
    $he=@($visible | Where-Object {$_.Capabilities -and $_.Capabilities.He})
    $eht=@($visible | Where-Object {$_.Capabilities -and $_.Capabilities.Eht})
    $p2p=@($visible | Where-Object {$_.Capabilities -and $_.Capabilities.WifiDirect})
    $widths=@($visible | Where-Object {$_.RadioWidth -and $_.RadioWidth.Width -gt 0} |
        ForEach-Object {[pscustomobject]@{
            bssid=$_.BSSID; band=$_.Band;channel=$_.Channel
            width=[int]$_.RadioWidth.Width
            center=[int]$_.RadioWidth.Center
            secondary=$_.RadioWidth.SecondaryCenter
        }} | Select-Object -First 20)
    [pscustomobject]@{
        completeSurvey=$NativeCompleted; hidden=$hidden.Count;he=$he.Count;eht=$eht.Count
        p2pAdvertised=$p2p.Count
        widthGeometry=@($widths)
        recentRoams=@($(if($Roaming){$Roaming.Changes}) |
            Where-Object {$Now-[long]$_.at -ge 0 -and $Now-[long]$_.at -le 3600000} |
            Select-Object -First 8)
        note='Beacon IE capabilities indicate advertised AP features, not the client negotiated PHY mode.'
    }
}
function Get-WifiV3CaptureCapabilities {
    $npcap=$null
    try {$npcap=Get-Service -Name npcap -ErrorAction SilentlyContinue} catch {}
    [pscustomobject]@{
        npcapPresent=[bool]$npcap
        monitorCapture='requires-explicit-driver-and-hardware-check'
        captureEnabled=$false
        note='Npcap service presence alone does not prove 802.11 monitor support; live capture remains disabled.'
    }
}
function Get-WifiV3DirectInventory {
    $found=@()
    try {
        $found=@(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop |
            Where-Object { $_.Name -match 'Wi-Fi Direct|WiFi Direct' } |
            Select-Object -First 8 |
            ForEach-Object { [pscustomobject]@{name=$_.Name;status=[string]$_.NetConnectionStatus} })
    } catch {}
    [pscustomobject]@{
        virtualAdapters=@($found)
        discovery='not-available-without-supported-WinRT-discovery'
        note='Virtual adapters are local capability hints; no nearby Wi-Fi Direct devices have been discovered.'
    }
}
function Get-WifiV3Hypotheses($Summary,$Evolution,[object[]]$HourlyDensity) {
    $items=@()
    if($Summary -and $Summary.eht -gt 0) {
        $items+='В эфире видны точки, объявляющие EHT (возможности Wi-Fi 7); режим подключения не установлен.'
    }
    if($Evolution -and $Evolution.volatile -gt 0) {
        $items+='Некоторые BSSID меняют канал или сигнал; проверь положение ноутбука и качество своего соединения.'
    }
    if(@($HourlyDensity | Where-Object {$_.averageNeighbors -ge 5 -and $null -ne $_.localBadPercent -and $_.localBadPercent -ge 15}).Count -gt 0) {
        $items+='Высокая плотность точек и плохие локальные пробы наблюдались в одни часы; причинная связь не подтверждена.'
    }
    [pscustomobject]@{
        status=$(if($items.Count){'hypotheses'}else{'insufficient-evidence'})
        items=@($items | Select-Object -First 4)
        automaticChanges=$false
    }
}
