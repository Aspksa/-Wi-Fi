# Durable summaries and safe backup; all retention is bounded and read-only reporting.
function Initialize-WifiLongMemory($Db) {
    [void]$Db.Query(@'
CREATE TABLE IF NOT EXISTS hourly_quality (
 hour_ms INTEGER NOT NULL, network TEXT NOT NULL, channel INTEGER NOT NULL,
 observations INTEGER NOT NULL, bad_observations INTEGER NOT NULL,
 avg_lan_ms REAL, PRIMARY KEY(hour_ms,network,channel)
)
'@,@())
    [void]$Db.Query(@'
CREATE TABLE IF NOT EXISTS daily_quality (
 day_ms INTEGER NOT NULL, network TEXT NOT NULL, channel INTEGER NOT NULL,
 observations INTEGER NOT NULL, bad_observations INTEGER NOT NULL,
 avg_lan_ms REAL, PRIMARY KEY(day_ms,network,channel)
)
'@,@())
}
function Update-WifiLongMemory($Db,[long]$Now) {
    if(-not $Db){return}
    Initialize-WifiLongMemory $Db
    # Complete UTC hours only; raw rows can be replayed safely via REPLACE.
    $cutoff=[long]([Math]::Floor($Now/3600000.0)*3600000)
    [void]$Db.Query(@'
INSERT OR REPLACE INTO hourly_quality
SELECT CAST(at_ms / 3600000 AS INTEGER)*3600000,network,
 COALESCE(channel,0),COUNT(*),
 SUM(CASE WHEN lan_loss=1 OR lan>35 THEN 1 ELSE 0 END),
 AVG(lan)
FROM samples
WHERE at_ms >= ? AND at_ms < ?
GROUP BY CAST(at_ms / 3600000 AS INTEGER),network,COALESCE(channel,0)
'@,@(($Now-3L*86400000),$cutoff))
    # Rebuild recent day summaries only from already complete hours.
    $dayCutoff=[long]([Math]::Floor($Now/86400000.0)*86400000)
    [void]$Db.Query(@'
INSERT OR REPLACE INTO daily_quality
SELECT CAST(hour_ms / 86400000 AS INTEGER)*86400000,network,channel,
 SUM(observations),SUM(bad_observations),
 CASE WHEN SUM(observations)>0 THEN SUM(COALESCE(avg_lan_ms,0)*observations)/SUM(observations) ELSE NULL END
FROM hourly_quality WHERE hour_ms>=? AND hour_ms<?
GROUP BY CAST(hour_ms / 86400000 AS INTEGER),network,channel
'@,@(($Now-32L*86400000),$dayCutoff))
    [void]$Db.Query('DELETE FROM hourly_quality WHERE hour_ms < ?',@(($Now-31L*86400000)))
    [void]$Db.Query('DELETE FROM daily_quality WHERE day_ms < ?',@(($Now-366L*86400000)))
}
function Get-WifiHistoricalQuality($Db) {
    if(-not $Db){return @()}
    $rows=$Db.Query(@'
SELECT day_ms,network,channel,observations,bad_observations
FROM daily_quality ORDER BY day_ms DESC LIMIT 60
'@,@())
    @($rows | ForEach-Object {
        [pscustomobject]@{
            dayUtc=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$_[0]).ToString('yyyy-MM-dd')
            network=[string]$_[1];channel=[int]$_[2];samples=[int]$_[3]
            badPercent=$(if([int]$_[3]-gt 0){[Math]::Round([double]$_[4]*100/[double]$_[3],1)}else{$null})
        }
    })
}
function Save-WifiVerifiedBackup($Db,[string]$Folder,[long]$Now) {
    if(-not $Db){return [pscustomobject]@{status='unavailable';note='SQLite недоступна.'}}
    [void][IO.Directory]::CreateDirectory($Folder)
    $tmp=Join-Path $Folder ('snapshot-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $target=Join-Path $Folder ('wifi-'+$Now+'.sqlite')
    try {
        $Db.Backup($tmp)
        $check=[WiFi.Sqlite]::new($tmp)
        try {if([string]$check.Query('PRAGMA integrity_check',@())[0][0] -ne 'ok'){throw 'Integrity check failed.'}}
        finally {$check.Dispose()}
        [IO.File]::Move($tmp,$target)
        $previous=@(Get-ChildItem -LiteralPath $Folder -Filter 'wifi-*.sqlite' -File | Sort-Object LastWriteTimeUtc -Descending)
        foreach($old in @($previous | Select-Object -Skip 5)) {[IO.File]::Delete($old.FullName)}
        return [pscustomobject]@{status='verified';at=$Now;note='Резервная SQLite-копия прошла integrity_check.'}
    } catch {
        return [pscustomobject]@{status='error';at=$Now;note='Не удалось проверить резервную копию: '+$_.Exception.Message}
    } finally {
        if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}
    }
}
function Get-WifiHourlyRisk([object[]]$History) {
    $groups=@($History | Where-Object {$_.samples -ge 10 -and $null -ne $_.badPercent} |
        Group-Object {([string]$_.dayUtc) + '|' + ([string]$_.channel)})
    $risky=@($groups | Where-Object { $_.Count -ge 3 })
    [pscustomobject]@{
        status=$(if($risky.Count){'historical-indication'}else{'insufficient'})
        repeatGroups=$risky.Count
        note='Статистика указывает на повторение, но не доказывает причину помех.'
    }
}
