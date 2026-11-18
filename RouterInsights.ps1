# V2.1: passive evidence. No router HTTP API calls and no credentials.
function Get-RouterApiCaptureSummary([string] $Path, [string] $Gateway) {
    $empty = [pscustomobject] @{ status='not-provided'; entries=@(); readEndpoints=0; warning='API RE3L не подтверждён: нужен очищенный журнал запросов из панели.' }
    if (-not $Gateway -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($file.Length -gt 65536) { return [pscustomobject] @{status='invalid';entries=@();readEndpoints=0;warning='Файл исследования API слишком большой.'} }
        $capture = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)) -ErrorAction Stop
        if ([string] $capture.routerAddress -cne $Gateway -or [string] $capture.model -cne 'RE3L') {
            return [pscustomobject] @{status='mismatch';entries=@();readEndpoints=0;warning='Снимок API относится к другому адресу или модели.'}
        }
        $safe = @()
        foreach ($entry in @($capture.requests)) {
            if (-not $entry) { continue }
            $method = ([string] $entry.method).ToUpperInvariant()
            $pathName = [string] $entry.path
            $code = 0
            if (-not [int]::TryParse([string] $entry.status,[ref] $code)) { continue }
            if ($method -ne 'GET' -or $code -ne 200 -or $pathName.Length -gt 120 -or
                $pathName -notmatch '^/[a-zA-Z0-9_./-]*$' -or $pathName -match '(?i)(?:token|auth|login|pass|session|key|cookie)') { continue }
            $safe += [pscustomobject] @{ method='GET'; path=$pathName; status=200
                purpose='не подтверждено'; usable=$false }
            if ($safe.Count -ge 25) { break }
        }
        [pscustomobject] @{
            status='inspection-only'; entries=@($safe); readEndpoints=$safe.Count
            warning='Пути GET найдены в очищенной записи. Схемы ответов и доступ без секретов не проверены. Запросы роутеру не отправляются.'
        }
    } catch {
        [pscustomobject] @{status='invalid';entries=@();readEndpoints=0;warning='Файл исследования API не читается.'}
    }
}

function Get-WifiTrendSignal([object[]] $Samples, [string] $Network, [long] $Now) {
    $quiet = @($Samples | Where-Object {
        $_ -and $Network -and $_.Network -eq $Network -and
        $_.At -ge ($Now - 120000) -and $_.At -le $Now -and
        -not $_.Scanning -and $null -ne $_.LanLoss
    })
    $first = @($quiet | Where-Object { $_.At -lt ($Now - 60000) })
    $last = @($quiet | Where-Object { $_.At -ge ($Now - 60000) })
    if ($first.Count -lt 10 -or $last.Count -lt 10) {
        return [pscustomobject] @{status='insufficient';samples=$quiet.Count;beforeBad=$null;afterBad=$null;reason='Недостаточно локальных проб в обоих интервалах по 60 секунд.'}
    }
    $beforeBad = @($first | Where-Object { $_.LanLoss -eq $true -or ($null -ne $_.Lan -and [double] $_.Lan -gt 35) }).Count
    $afterBad = @($last | Where-Object { $_.LanLoss -eq $true -or ($null -ne $_.Lan -and [double] $_.Lan -gt 35) }).Count
    $oldRate = [Math]::Round(100.0*$beforeBad/$first.Count,1)
    $newRate = [Math]::Round(100.0*$afterBad/$last.Count,1)
    $status = 'stable-or-unclear'
    if ($afterBad -ge 3 -and ($newRate - $oldRate) -ge 15) { $status = 'worsening' }
    if ($beforeBad -ge 3 -and ($oldRate - $newRate) -ge 15) { $status = 'improving' }
    [pscustomobject] @{
        status=$status; samples=$quiet.Count; beforeBad=$oldRate; afterBad=$newRate
        reason=('Доля локальных сбоев за два окна по 60 секунд: {0}% → {1}%. Это тенденция, не прогноз неисправности.' -f $oldRate,$newRate)
    }
}

function Get-WifiHourlyEfficiency($Db, [long] $Now) {
    if (-not $Db) { return @() }
    $rows = $Db.Query(@'
SELECT network, channel, COALESCE(width_mhz,0), CAST(at_ms / 3600000 AS INTEGER),
       COUNT(*),
       SUM(CASE WHEN lan_loss=1 OR (lan IS NOT NULL AND lan > 35) THEN 1 ELSE 0 END),
       SUM(CASE WHEN lan_loss=1 THEN 1 ELSE 0 END),
       AVG(CASE WHEN lan_loss=0 THEN lan ELSE NULL END)
FROM samples
WHERE at_ms >= ? AND at_ms <= ? AND channel IS NOT NULL AND network <> ''
GROUP BY network, channel, width_mhz, CAST(at_ms / 3600000 AS INTEGER)
ORDER BY 4 DESC LIMIT 160
'@,@(($Now - 48L * 3600000),$Now))
    $result=@()
    foreach ($row in @($rows)) {
        if (-not $row -or [int] $row[4] -lt 3) { continue }
        $band = ([string] $row[0] -split '\|',2)[0]
        if ($band -notin @('2.4','5')) { continue }
        $hour = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$row[3]*3600000)
        $result += [pscustomobject] @{
            band=$band; channel=[int] $row[1]; width=[int] $row[2]
            hourUtc=$hour.ToString('yyyy-MM-dd HH:mm')
            samples=[int] $row[4]; badPercent=[Math]::Round(100.0*[double]$row[5]/[double]$row[4],1)
            lossPercent=[Math]::Round(100.0*[double]$row[6]/[double]$row[4],1)
            averageMs=$(if ($null -ne $row[7]) { [Math]::Round([double]$row[7],1) })
        }
    }
    @($result | Select-Object -First 60)
}

function Get-WifiRecentTrials($Db,[long]$Now) {
    if (-not $Db) { return @() }
    $rows=$Db.Query(@'
SELECT at_ms, old_channel, new_channel, improved, pairs, before_bad, after_bad
FROM channel_trials WHERE at_ms >= ? AND at_ms <= ?
ORDER BY at_ms DESC LIMIT 8
'@,@(($Now-30L*86400000),$Now))
    @($rows | ForEach-Object {
        [pscustomobject] @{
            at=[long]$_[0]; old=[int]$_[1]; new=[int]$_[2]; pairs=[int]$_[4]
            beforeBad=[int]$_[5]; afterBad=[int]$_[6]
            outcome=$(if ($null -eq $_[3]) {'insufficient'} elseif ([int]$_[3] -gt 0) {'improved'} elseif ([int]$_[3] -lt 0) {'worse'} else {'unclear'})
        }
    })
}
