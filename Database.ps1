function Open-WifiDatabase([string] $Path) {
    if (-not ('WiFi.Sqlite' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'WifiSqlite.cs') -ErrorAction Stop
    }
    [void] [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $db = [WiFi.Sqlite]::new($Path)
    try {
        [void] $db.Query('PRAGMA journal_mode=WAL', @())
        [void] $db.Query('PRAGMA synchronous=NORMAL', @())
        [void] $db.Query('BEGIN IMMEDIATE', @())
        try {
            $version = $db.Query('PRAGMA user_version', @())[0][0]
            if ($version -gt 2) { throw 'База Wi Fi создана более новой версией программы.' }
            [void] $db.Query('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)', @())
            [void] $db.Query(@'
CREATE TABLE IF NOT EXISTS samples (
    session_id TEXT NOT NULL, at_ms INTEGER NOT NULL, network TEXT NOT NULL, channel INTEGER,
    signal INTEGER, upload_kbps REAL, overlap TEXT, lan REAL, lan_loss INTEGER,
    wan REAL, wan_loss INTEGER,
    PRIMARY KEY (session_id, at_ms)
)
'@, @())
            [void] $db.Query('CREATE INDEX IF NOT EXISTS samples_time ON samples(at_ms)', @())
            [void] $db.Query(@'
CREATE TABLE IF NOT EXISTS radio_scans (
    session_id TEXT NOT NULL, at_ms INTEGER NOT NULL, network TEXT NOT NULL,
    observed_points TEXT NOT NULL, PRIMARY KEY (session_id, at_ms)
)
'@, @())
            [void] $db.Query('CREATE INDEX IF NOT EXISTS radio_scans_time ON radio_scans(at_ms)', @())
            [void] $db.Query(@'
CREATE TABLE IF NOT EXISTS incidents (
    id TEXT PRIMARY KEY, at_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL,
    network TEXT NOT NULL, cause TEXT NOT NULL, description TEXT NOT NULL
)
'@, @())
            [void] $db.Query(@'
CREATE TABLE IF NOT EXISTS channel_trials (
    id TEXT PRIMARY KEY, at_ms INTEGER NOT NULL, network TEXT NOT NULL, old_channel INTEGER,
    new_channel INTEGER, improved INTEGER, before_bad INTEGER, after_bad INTEGER, pairs INTEGER,
    before_p90 REAL, after_p90 REAL, description TEXT
)
'@, @())
            [void] $db.Query(@'
CREATE TABLE IF NOT EXISTS context_checks (
    id TEXT PRIMARY KEY, at_ms INTEGER NOT NULL, network TEXT NOT NULL, context TEXT NOT NULL,
    predicted INTEGER NOT NULL, actual INTEGER NOT NULL
)
'@, @())
            [void] $db.Query('CREATE INDEX IF NOT EXISTS checks_network_context ON context_checks(network, context, at_ms)', @())
            if ($version -lt 2) {
                [void] $db.Query('ALTER TABLE samples ADD COLUMN width_mhz INTEGER', @())
                [void] $db.Query('ALTER TABLE channel_trials ADD COLUMN old_width_mhz INTEGER', @())
                [void] $db.Query('ALTER TABLE channel_trials ADD COLUMN new_width_mhz INTEGER', @())
                [void] $db.Query('PRAGMA user_version=2', @())
            }
            [void] $db.Query('COMMIT', @())
        } catch {
            [void] $db.Query('ROLLBACK', @())
            throw
        }
    } catch {
        $db.Dispose()
        throw
    }
    $db
}

function Get-DatabaseSetting($Db, [string] $Key) {
    $rows = $Db.Query('SELECT value FROM settings WHERE key=?', @($Key))
    if ($rows.Count) { $rows[0][0] }
}

function Set-DatabaseSetting($Db, [string] $Key, [string] $Value) {
    [void] $Db.Query('INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)', @($Key, $Value))
}

function Get-DatabaseHistory($Db, [string] $LegacyPath) {
    $saved = Get-DatabaseSetting $Db 'history'
    if ($saved) { return ($saved | ConvertFrom-Json) }
    $history = Read-MonitorHistory $LegacyPath
    if (Test-Path -LiteralPath $LegacyPath) {
        Set-DatabaseSetting $Db 'history' (ConvertTo-Json -InputObject $history -Depth 8 -Compress)
    }
    $history
}

function Save-Intelligence($Db, $Engine) {
    [void] $Db.Query('BEGIN IMMEDIATE', @())
    try {
        foreach ($sample in $Engine.PendingSamples) {
            [void] $Db.Query(@'
INSERT OR IGNORE INTO samples
    (session_id, at_ms, network, channel, signal, upload_kbps, overlap, lan, lan_loss, wan, wan_loss, width_mhz)
VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
'@, @(
                $Engine.Session, $sample.At, $sample.Network, $sample.Channel, $sample.Signal, $sample.Upload, $sample.Overlap,
                $sample.Lan, $sample.LanLoss, $sample.Wan, $sample.WanLoss, $sample.Width
            ))
        }
        foreach ($entry in $Engine.PendingScans) {
            [void] $Db.Query('INSERT OR IGNORE INTO radio_scans VALUES(?,?,?,?)', @(
                $Engine.Session, $entry.At, $entry.Network, (ConvertTo-Json -InputObject $entry.Points -Depth 3 -Compress)
            ))
        }
        foreach ($entry in $Engine.PendingIncidents) {
            [void] $Db.Query('INSERT OR IGNORE INTO incidents VALUES(?,?,?,?,?,?)', @(
                $entry.Id, $entry.At, $entry.Ended, $entry.Network, $entry.Cause, $entry.Message
            ))
        }
        foreach ($entry in $Engine.PendingTrials) {
            [void] $Db.Query(@'
INSERT OR IGNORE INTO channel_trials
    (id, at_ms, network, old_channel, new_channel, improved, before_bad, after_bad, pairs,
     before_p90, after_p90, description, old_width_mhz, new_width_mhz)
VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
'@, @(
                $entry.Id, $entry.At, $entry.Network, $entry.Old, $entry.New, $entry.Improved, $entry.BeforeBad,
                $entry.AfterBad, $entry.Pairs, $entry.BeforeP90, $entry.AfterP90, $entry.Message, $entry.OldWidth, $entry.NewWidth
            ))
        }
        foreach ($entry in $Engine.PendingChecks) {
            [void] $Db.Query('INSERT OR IGNORE INTO context_checks VALUES(?,?,?,?,?,?)', @(
                $entry.Id, $entry.At, $entry.Network, $entry.Context, $entry.Predicted, $entry.Actual
            ))
        }
        [void] $Db.Query('COMMIT', @())
        $Engine.PendingSamples.Clear()
        $Engine.PendingScans.Clear()
        $Engine.PendingIncidents.Clear()
        $Engine.PendingTrials.Clear()
        $Engine.PendingChecks.Clear()
    } catch {
        [void] $Db.Query('ROLLBACK', @())
        throw
    }
}

function Remove-ExpiredMeasurements($Db, [long] $Now) {
    [void] $Db.Query('DELETE FROM samples WHERE at_ms < ?', @($Now - 2L * 86400000))
    [void] $Db.Query('DELETE FROM radio_scans WHERE at_ms < ?', @($Now - 2L * 86400000))
    [void] $Db.Query('DELETE FROM incidents WHERE at_ms < ?', @($Now - 30L * 86400000))
    [void] $Db.Query('DELETE FROM channel_trials WHERE at_ms < ?', @($Now - 90L * 86400000))
    [void] $Db.Query('DELETE FROM context_checks WHERE at_ms < ?', @($Now - 30L * 86400000))
}

function Get-TrialMemory($Db, [string] $Network, [int] $Channel, [Nullable[int]] $Width) {
    $rows = $Db.Query(@'
SELECT new_channel, COUNT(*), SUM(CASE WHEN improved > 0 THEN 1 ELSE 0 END),
       SUM(CASE WHEN improved < 0 THEN 1 ELSE 0 END), SUM(before_bad), SUM(after_bad), SUM(pairs), new_width_mhz
FROM channel_trials WHERE network=? AND old_channel=? AND old_width_mhz IS ? AND improved IS NOT NULL
GROUP BY new_channel, new_width_mhz
'@, @($Network, $Channel, $Width))
    $memory = @{}
    foreach ($row in $rows) {
        $memory[(Get-WidthTrialKey $row[0] $row[7])] = [pscustomobject] @{
            Count = $row[1]; Wins = $row[2]; Losses = $row[3]; BeforeBad = $row[4]; AfterBad = $row[5]; Pairs = $row[6]
        }
    }
    $memory
}

function Get-ForecastEvidence($Db, [string] $Network, [string] $Context) {
    if (-not $Db) { return }
    $rows = $Db.Query(@'
SELECT COUNT(*), COALESCE(SUM(actual),0), COALESCE(SUM(predicted),0),
       COALESCE(SUM(predicted * actual),0) FROM context_checks WHERE network=? AND context=?
'@, @($Network, $Context))
    if ($rows.Count) {
        [pscustomobject] @{ Count = $rows[0][0]; Bad = $rows[0][1]; Predicted = $rows[0][2]; Correct = $rows[0][3] }
    }
}

function Get-RecentChannelScans($Db, [long] $Before) {
    $rows = $Db.Query(@'
SELECT at_ms, observed_points FROM radio_scans WHERE at_ms >= ? AND at_ms < ?
ORDER BY at_ms DESC LIMIT 40
'@, @($Before - 900000, $Before))
    foreach ($row in $rows) {
        try {
            [pscustomobject] @{ At = $row[0]; Points = @($row[1] | ConvertFrom-Json -ErrorAction Stop) }
        } catch { continue }
    }
}
