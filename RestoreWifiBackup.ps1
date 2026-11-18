param(
    [Parameter(Mandatory=$true)][string]$BackupPath,
    [switch]$ConfirmRestore
)
$ErrorActionPreference='Stop'
if(-not $ConfirmRestore){throw 'Для восстановления требуется -ConfirmRestore. Сначала закрой Wi-Fi.bat и проверь имя копии.'}
. (Join-Path $PSScriptRoot 'Database.ps1')
. (Join-Path $PSScriptRoot 'WifiRestoreV31.ps1')
$folder=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Wi Fi'
$root=Join-Path $folder 'backups'
$resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $BackupPath -ErrorAction Stop).ProviderPath)
$prefix=[IO.Path]::GetFullPath($root).TrimEnd('\')+'\'
if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($resolved) -notmatch '^wifi-\d+\.sqlite$'){
    throw 'Восстанавливать можно только проверенные копии из локальной папки Wi Fi\backups.'
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$mutex=[Threading.Mutex]::new($false,"Local\WiFiDashboard-$($identity.User.Value)")
$owns=$false
try{
    try{$owns=$mutex.WaitOne(0)}catch[Threading.AbandonedMutexException]{$owns=$true}
    if(-not $owns){throw 'Сначала закрой работающий Wi-Fi: восстановление во время записи запрещено.'}
    $database=Join-Path $folder 'wifi.sqlite'
    $result=Restore-WifiVerifiedBackup $resolved $database (Join-Path $folder 'rollback')
    Write-Host $result.note
    Write-Host ('Сохранён оригинал: '+$result.rollbackFolder)
}finally{
    if($owns){$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
