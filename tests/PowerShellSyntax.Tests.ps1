$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File)
$errorsFound = 0
foreach ($file in $files) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasNonAscii = @($bytes | Where-Object { $_ -ge 128 }).Count -gt 0
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    if ($hasNonAscii -and -not $hasBom) {
        Write-Host ("{0}: UTF-8 BOM missing; Windows PowerShell 5.1 may misread Cyrillic text" -f $file.Name)
        $errorsFound++
    }
    $tokens = $null
    $errors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
    foreach ($parseError in @($errors)) {
        Write-Host ("{0}:{1}:{2} {3}" -f $file.Name, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
        $errorsFound++
    }
}
if ($errorsFound -gt 0) { throw "$errorsFound PowerShell parse errors across $($files.Count) scripts." }
Write-Host "Passed: $($files.Count) PowerShell scripts parse successfully."
