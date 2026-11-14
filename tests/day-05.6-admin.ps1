#Requires -Version 7.0
# Day 5.6 administrator helper. Runs the VPS cmdlets on the current owner of the "VPS Management" role, against
# the role's checkpointed registry key. It reports the raw values before and after so that the driver can check
# that the store carries administrator intent only.
param(
    [Parameter(Mandatory)][ValidateSet('new','set','remove','get','show')][string] $Verb,
    [Parameter(Mandatory)][guid] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string] $ClusterName,
    [ValidatePattern('^[a-z0-9.-]+$')][string] $SiteName = 'none',
    [ValidatePattern('^\\\\[A-Za-z0-9.-]+\\[A-Za-z0-9.-]+$')][string] $RootPath = '\\localhost\none',
    [ValidateRange(0, 64)][int] $Replicas = 0,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,62}=\d{1,3}(\.\d{1,3}){3}:\d+(,[A-Za-z0-9][A-Za-z0-9._-]{0,62}=\d{1,3}(\.\d{1,3}){3}:\d+)*$')][string] $Fences = 'domain-1=127.0.0.1:47055'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$token=$RunId.ToString('N')
$keyPath="SOFTWARE\ControlPlaneExperiment\Day56-$token"
$directory=Join-Path $env:ProgramData "ControlPlaneExperiment\day-05.6-$token"
function Values {
    $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath)
    if(-not $key) { return [pscustomobject]@{ KeyPresent=$false; Values=@() } }
    try {
        [pscustomobject]@{ KeyPresent=$true; Values=@($key.GetValueNames() | Sort-Object | ForEach-Object {
            [pscustomobject]@{ Name=$_; Kind="$($key.GetValueKind($_))"; Raw="$($key.GetValue($_))" } }) }
    } finally { $key.Dispose() }
}
. (Join-Path $directory 'VPSSite.ps1')
$env:VPS_EXE=Join-Path $directory 'ControlPlaneExperiment.exe'
$env:VPS_STORE="wfc-checkpoint:${ClusterName}:VPS Management:HKLM\$keyPath"
$env:VPS_DOMAINS=$Fences -replace ',',' '
$before=Values
$output=switch($Verb) {
    'new' { New-VPSSite -Name $SiteName -RootPath $RootPath -DesiredReplicas $Replicas }
    'set' { Set-VPSSite -Name $SiteName -DesiredReplicas $Replicas }
    'remove' { Remove-VPSSite -Name $SiteName }
    'get' { ConvertTo-Json -InputObject @(Get-VPSSite) -Depth 8 -Compress }
    'show' { '' }
}
[pscustomobject]@{ Verb=$Verb; LocalNode=$env:COMPUTERNAME; Store=$env:VPS_STORE; At=[datetimeoffset]::UtcNow.ToString('O')
    Output="$output"; Before=$before; After=(Values) } | ConvertTo-Json -Depth 6 -Compress
