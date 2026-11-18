# Restores a verified local SQLite snapshot only while the Wi-Fi server is stopped.
# Replaces no data until explicit invocation, preserves the original DB and WAL files.
function Restore-WifiVerifiedBackup([string]$BackupPath,[string]$DatabasePath,[string]$RollbackRoot) {
    if(-not [IO.File]::Exists($BackupPath)){throw 'Резервная копия не найдена.'}
    if([IO.Path]::GetExtension($BackupPath) -ne '.sqlite'){throw 'Требуется файл .sqlite.'}
    $verify=[WiFi.Sqlite]::new($BackupPath)
    try{
        if([string]$verify.Query('PRAGMA integrity_check',@())[0][0] -ne 'ok'){
            throw 'Резервная копия SQLite повреждена.'
        }
    }finally{$verify.Dispose()}
    [void][IO.Directory]::CreateDirectory($RollbackRoot)
    $rollback=Join-Path $RollbackRoot ('rollback-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($rollback)
    $file=[IO.Path]::GetFileName($DatabasePath)
    $previous=Join-Path $rollback $file
    $tmp=$DatabasePath+'.restore-'+[guid]::NewGuid().ToString('N')
    $originalExists=[IO.File]::Exists($DatabasePath)
    $suffixes=@('','-wal','-shm')
    foreach($suffix in $suffixes){
        $source=$DatabasePath+$suffix
        if([IO.File]::Exists($source)) {
            [IO.File]::Copy($source,(Join-Path $rollback ($file+$suffix)), $false)
        }
    }
    try{
        [IO.File]::Copy($BackupPath,$tmp,$false)
        $fresh=[WiFi.Sqlite]::new($tmp)
        try{
            if([string]$fresh.Query('PRAGMA integrity_check',@())[0][0] -ne 'ok'){
                throw 'Проверка временной копии не прошла.'
            }
        }finally{$fresh.Dispose()}
        if($originalExists){[IO.File]::Replace($tmp,$DatabasePath,(Join-Path $rollback ($file+'.replaced')))}
        else{[IO.File]::Move($tmp,$DatabasePath)}
        foreach($suffix in @('-wal','-shm')){
            if([IO.File]::Exists($DatabasePath+$suffix)){[IO.File]::Delete($DatabasePath+$suffix)}
        }
        $check=[WiFi.Sqlite]::new($DatabasePath)
        try{
            if([string]$check.Query('PRAGMA integrity_check',@())[0][0] -ne 'ok'){
                throw 'Проверка восстановленной БД не прошла.'
            }
        }finally{$check.Dispose()}
        return [pscustomobject]@{
            status='restored';rollbackFolder=$rollback
            note='Старая база и файлы WAL сохранены отдельно. Проверь приложение после запуска.'
        }
    }catch{
        foreach($suffix in $suffixes){
            $original=Join-Path $rollback ($file+$suffix)
            $target=$DatabasePath+$suffix
            if([IO.File]::Exists($original)){[IO.File]::Copy($original,$target,$true)}
            elseif([IO.File]::Exists($target)){[IO.File]::Delete($target)}
        }
        throw
    }finally{
        if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}
    }
}
