$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File)
$errorsFound = 0
foreach ($file in $files) {
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
