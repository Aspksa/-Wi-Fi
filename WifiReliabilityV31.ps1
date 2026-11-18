# v3.1 Reliability; all host diagnostics are read-only, no security bypass or router writes.
function New-WifiRecoveryState {
    @{Failures=0;LastFailureAt=0L;LastRetryAt=0L;Events=@();LastAlertAt=0L}
}
function Get-WifiFailureCategory([string]$Message,[bool]$Blocked,[bool]$TimedOut) {
    if($TimedOut){return 'timeout'}
    if($Blocked -or $Message -match '(?i)access.denied|отказано в доступе|location|местоположен|privacy|приватн'){return 'permissions'}
    if($Message -match '(?i)wlan.?autoconfig|wlansvc|служба wlan|service.+not running'){return 'wlan-service'}
    if($Message -match '(?i)adapter|interface|интерфейс|адаптер|radio.+off|выключен'){return 'adapter'}
    if($Message -match '(?i)driver|драйвер|win32|native|0x[0-9a-f]+'){return 'driver-or-api'}
    return 'unknown'
}
function Get-WifiRecoveryDelay([int]$Failures,[bool]$Blocked) {
    if($Blocked){return 120000}
    [int][Math]::Min(120000,10000*[Math]::Pow(2,[Math]::Min(4,[Math]::Max(0,$Failures-1))))
}
function Test-WifiRecoveryRetry($Recovery,[bool]$Blocked,[long]$Now) {
    if(-not $Blocked){return $false}
    if(-not $Recovery){return $false}
    if($Now -lt [long]$Recovery.LastRetryAt){return $false}
    return $Now - [long]$Recovery.LastRetryAt -ge 120000
}
function Add-WifiRecoveryEvent($Recovery,[long]$Now,[string]$Reason) {
    if(-not $Recovery){return}
    $Recovery.Failures=[Math]::Min(100,[int]$Recovery.Failures+1)
    $Recovery.LastFailureAt=$Now
    $category=Get-WifiFailureCategory $Reason $false ($Reason -match '(?i)timed.out|тайм.?аут|не ответило')
    $Recovery.Events=@([pscustomobject]@{at=$Now;kind=$category})+@($Recovery.Events | Select-Object -First 19)
}
function Reset-WifiRecovery($Recovery) {
    if(-not $Recovery){return}
    $Recovery.Failures=0
}
function Get-WifiAdapterInventory {
    $items=@()
    try {
        foreach($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){
            if($adapter.NetworkInterfaceType -ne [Net.NetworkInformation.NetworkInterfaceType]::Wireless80211){continue}
            $items+= [pscustomobject]@{
                id=[string]$adapter.Id;name=[string]$adapter.Name
                description=[string]$adapter.Description
                status=[string]$adapter.OperationalStatus
                supportedBands='not-verified'
            }
        }
    }catch{}
    @($items | Select-Object -First 16)
}
function Get-WifiBandEvidence([object[]]$Points) {
    @('2.4','5','6') | ForEach-Object {
        $band=$_
        $seen=@($Points | Where-Object {$_.Band -eq $band -and $_.Fresh -ne $false})
        [pscustomobject]@{
            band=$band;observed=$seen.Count
            hardwareSupport=$(if($seen.Count){'observed-receive'}else{'not-verified'})
            note='Отсутствие точек не доказывает отсутствие поддержки диапазона.'
        }
    }
}
function Get-WifiPerformanceSnapshot([long]$StartedAt,[long]$Now,[int]$FailureCount) {
    $process=[Diagnostics.Process]::GetCurrentProcess()
    [pscustomobject]@{
        processWorkingSetMb=[Math]::Round($process.WorkingSet64/1MB,1)
        cpuSeconds=[Math]::Round($process.TotalProcessorTime.TotalSeconds,1)
        scanElapsedMs=$(if($StartedAt -gt 0){[Math]::Max(0,$Now-$StartedAt)}else{0})
        consecutiveFailures=$FailureCount
        cpuPercent='unavailable-without-timed-samples'
    }
}
function Get-WifiAlertState($Recovery,[string]$FailureCategory,[long]$Now) {
    $serious=$FailureCategory -in @('permissions','timeout','wlan-service','driver-or-api')
    if(-not $serious -or -not $Recovery -or $Recovery.LastAlertAt -gt $Now -or
        ($Recovery.LastAlertAt -gt 0 -and $Now-$Recovery.LastAlertAt -lt 300000)){
        return [pscustomobject]@{new=$false;category=$FailureCategory}
    }
    $Recovery.LastAlertAt=$Now
    [pscustomobject]@{new=$true;category=$FailureCategory}
}
function Get-WifiLocalStartupChecks($Db,$AdapterInventory,[string]$WebRoot) {
    $codeReady=Test-Path -LiteralPath (Join-Path $PSScriptRoot 'WifiNativeScan.cs')
    $webReady=(Test-Path -LiteralPath (Join-Path $WebRoot 'index.html')) -and
        (Test-Path -LiteralPath (Join-Path $WebRoot 'app.js'))
    $dbReady=$false
    if($Db) {
        try{$dbReady=([string]$Db.Query('PRAGMA integrity_check',@())[0][0] -eq 'ok')}catch{}
    }
    [pscustomobject]@{
        codePresent=[bool]$codeReady;webFilesPresent=[bool]$webReady
        sqliteIntegrity=[bool]$dbReady;wifiAdapters=@($AdapterInventory).Count
        scanStatus='pending-first-hardware-scan';webPort='checked-by-web-server'
        note='Проверка целостности не заменяет тест реального радиоприёма.'
    }
}
