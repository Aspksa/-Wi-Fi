param(
    [Parameter(Mandatory=$true)][string]$Path,
    [ValidateRange(1,10000)][int]$MaxRecords=3000
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PcapOffline.ps1')
$source=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
$result=Read-WifiPcap $source $MaxRecords
ConvertTo-Json -InputObject $result -Depth 6
