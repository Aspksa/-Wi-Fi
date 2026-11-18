function Start-WifiScanJob([bool] $Active, [bool] $DiagnosticsOnly = $false, [string]$AdapterId = '') {
    $worker = (Join-Path $PSScriptRoot 'ScanWorker.ps1').Replace("'", "''")
    $monitor = (Join-Path $PSScriptRoot 'Monitor.ps1').Replace("'", "''")
    $native = (Join-Path $PSScriptRoot 'WifiNativeScan.cs').Replace("'", "''")
    $activeFlag = '$' + $Active.ToString().ToLowerInvariant()
    $diagnosticsFlag = '
    $command = @"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
`$ErrorActionPreference = 'Stop'
try {
    `$result = & '$worker' '$monitor' '$native' $activeFlag $diagnosticsFlag '$safeAdapter'
    if (`$result.Diagnostics.Gateway) { `$result.Diagnostics.Gateway = [string] `$result.Diagnostics.Gateway }
    ConvertTo-Json -InputObject @{ Result = `$result } -Depth 8 -Compress
} catch {
    ConvertTo-Json -InputObject @{ Error = `$_.Exception.GetBaseException().Message } -Compress
}
"@
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process.StartInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    # StandardOutputEncoding configures decoding in the parent. The child also sets encoding.
    try {
        [void] $process.Start()
        @{
            Process = $process; Output = $process.StandardOutput.ReadToEndAsync()
            Errors = $process.StandardError.ReadToEndAsync(); Clock = [Diagnostics.Stopwatch]::StartNew()
        }
    } catch {
        $process.Dispose()
        throw
    }
}

function Test-WifiScanJobReady($Job) {
    ($Job.Process.HasExited -and $Job.Output.IsCompleted -and $Job.Errors.IsCompleted) -or
        $Job.Clock.Elapsed.TotalSeconds -ge 25
}

function Receive-WifiScanJob($Job) {
    if (-not ($Job.Process.HasExited -and $Job.Output.IsCompleted -and $Job.Errors.IsCompleted)) {
        throw 'Сканирование не завершилось вовремя. Wi Fi повторит попытку.'
    }
    $output = $Job.Output.GetAwaiter().GetResult()
    if (-not $output) { throw 'Windows не вернула результат сканирования.' }
    $reply = ConvertFrom-Json -InputObject $output
    if ($reply.Error) { throw $reply.Error }
    if (-not $reply.Result) { throw 'Windows не вернула результат сканирования.' }
    if ($reply.Result.Diagnostics.Gateway) {
        $reply.Result.Diagnostics.Gateway = [Net.IPAddress]::Parse($reply.Result.Diagnostics.Gateway)
    }
    $reply.Result
}

function Close-WifiScanJob($Job) {
    if (-not $Job) { return }
    try {
        if (-not $Job.Process.HasExited) { $Job.Process.Kill() }
    } catch [InvalidOperationException] {
        # The process may have exited between HasExited and Kill.
    } finally {
        $Job.Process.Dispose()
    }
}
 + $DiagnosticsOnly.ToString().ToLowerInvariant()
    if ($AdapterId -and $AdapterId -notmatch '^[{(]?[0-9a-fA-F-]{36}[)}]?
    $command = @"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
`$ErrorActionPreference = 'Stop'
try {
    `$result = & '$worker' '$monitor' '$native' $activeFlag $diagnosticsFlag
    if (`$result.Diagnostics.Gateway) { `$result.Diagnostics.Gateway = [string] `$result.Diagnostics.Gateway }
    ConvertTo-Json -InputObject @{ Result = `$result } -Depth 8 -Compress
} catch {
    ConvertTo-Json -InputObject @{ Error = `$_.Exception.GetBaseException().Message } -Compress
}
"@
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process.StartInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    # StandardOutputEncoding configures decoding in the parent. The child also sets encoding.
    try {
        [void] $process.Start()
        @{
            Process = $process; Output = $process.StandardOutput.ReadToEndAsync()
            Errors = $process.StandardError.ReadToEndAsync(); Clock = [Diagnostics.Stopwatch]::StartNew()
        }
    } catch {
        $process.Dispose()
        throw
    }
}

function Test-WifiScanJobReady($Job) {
    ($Job.Process.HasExited -and $Job.Output.IsCompleted -and $Job.Errors.IsCompleted) -or
        $Job.Clock.Elapsed.TotalSeconds -ge 25
}

function Receive-WifiScanJob($Job) {
    if (-not ($Job.Process.HasExited -and $Job.Output.IsCompleted -and $Job.Errors.IsCompleted)) {
        throw 'Сканирование не завершилось вовремя. Wi Fi повторит попытку.'
    }
    $output = $Job.Output.GetAwaiter().GetResult()
    if (-not $output) { throw 'Windows не вернула результат сканирования.' }
    $reply = ConvertFrom-Json -InputObject $output
    if ($reply.Error) { throw $reply.Error }
    if (-not $reply.Result) { throw 'Windows не вернула результат сканирования.' }
    if ($reply.Result.Diagnostics.Gateway) {
        $reply.Result.Diagnostics.Gateway = [Net.IPAddress]::Parse($reply.Result.Diagnostics.Gateway)
    }
    $reply.Result
}

function Close-WifiScanJob($Job) {
    if (-not $Job) { return }
    try {
        if (-not $Job.Process.HasExited) { $Job.Process.Kill() }
    } catch [InvalidOperationException] {
        # The process may have exited between HasExited and Kill.
    } finally {
        $Job.Process.Dispose()
    }
}
) {throw 'Недопустимый идентификатор Wi-Fi адаптера.'}
    $safeAdapter=$AdapterId.Replace("'", "''")
    $command = @"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
`$ErrorActionPreference = 'Stop'
try {
    `$result = & '$worker' '$monitor' '$native' $activeFlag $diagnosticsFlag
    if (`$result.Diagnostics.Gateway) { `$result.Diagnostics.Gateway = [string] `$result.Diagnostics.Gateway }
    ConvertTo-Json -InputObject @{ Result = `$result } -Depth 8 -Compress
} catch {
    ConvertTo-Json -InputObject @{ Error = `$_.Exception.GetBaseException().Message } -Compress
}
"@
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process.StartInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    # StandardOutputEncoding configures decoding in the parent. The child also sets encoding.
    try {
        [void] $process.Start()
        @{
            Process = $process; Output = $process.StandardOutput.ReadToEndAsync()
            Errors = $process.StandardError.ReadToEndAsync(); Clock = [Diagnostics.Stopwatch]::StartNew()
        }
    } catch {
        $process.Dispose()
        throw
    }
}

function Test-WifiScanJobReady($Job) {
    ($Job.Process.HasExited -and $Job.Output.IsCompleted -and $Job.Errors.IsCompleted) -or
        $Job.Clock.Elapsed.TotalSeconds -ge 25
}

function Receive-WifiScanJob($Job) {
    if (-not ($Job.Process.HasExited -and $Job.Output.IsCompleted -and $Job.Errors.IsCompleted)) {
        throw 'Сканирование не завершилось вовремя. Wi Fi повторит попытку.'
    }
    $output = $Job.Output.GetAwaiter().GetResult()
    if (-not $output) { throw 'Windows не вернула результат сканирования.' }
    $reply = ConvertFrom-Json -InputObject $output
    if ($reply.Error) { throw $reply.Error }
    if (-not $reply.Result) { throw 'Windows не вернула результат сканирования.' }
    if ($reply.Result.Diagnostics.Gateway) {
        $reply.Result.Diagnostics.Gateway = [Net.IPAddress]::Parse($reply.Result.Diagnostics.Gateway)
    }
    $reply.Result
}

function Close-WifiScanJob($Job) {
    if (-not $Job) { return }
    try {
        if (-not $Job.Process.HasExited) { $Job.Process.Kill() }
    } catch [InvalidOperationException] {
        # The process may have exited between HasExited and Kill.
    } finally {
        $Job.Process.Dispose()
    }
}
