param(
    [Parameter(Mandatory=$true)][string]$Path,
    [ValidateRange(1,10000)][int]$MaxRecords=3000
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PcapOffline.ps1')
. (Join-Path $PSScriptRoot 'PcapngOfflineV31.ps1')
$source=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
$result=if([IO.Path]::GetExtension($source) -ieq '.pcapng'){Read-WifiPcapng $source $MaxRecords}else{Read-WifiPcap $source $MaxRecords}
ConvertTo-Json -InputObject $result -Depth 6
