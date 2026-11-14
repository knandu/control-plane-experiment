#Requires -Version 7.0
# Day 5.5 Lab-DC helper. Stages (outside the control plane) the shared durable-intent directory and the site
# content share, and runs the administrator's VPS cmdlets. The DC is simply where the administrator and the
# shared intent document live in this lab; it is not a cluster node and hosts no realization.
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Prepare','Stage','Admin','Cleanup')][string] $Action,
    [Parameter(Mandatory)][guid] $RunId,
    [ValidateSet('none','new','set','suspend','resume','remove','get','show')][string] $Verb = 'none',
    [ValidatePattern('^[a-z0-9.-]+$')][string] $SiteName = 'none',
    [ValidatePattern('^\\\\[A-Za-z0-9.-]+\\[A-Za-z0-9.-]+$')][string] $RootPath = '\\localhost\none',
    [ValidateRange(0, 3)][int] $Replicas = 0,
    [ValidatePattern('^[0-9a-f]{32}$')][string] $Marker = '00000000000000000000000000000000',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,62}=\d{1,3}(\.\d{1,3}){3}:\d+(,[A-Za-z0-9][A-Za-z0-9._-]{0,62}=\d{1,3}(\.\d{1,3}){3}:\d+)*$')][string] $Fences = 'domain-1=127.0.0.1:47055',
    [ValidatePattern('^Node-[ABC](,Node-[ABC])*$')][string] $Readers = 'Node-A'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$token=$RunId.ToString('N')
$short=$token.Substring(0,8)
$directory=Join-Path $env:ProgramData "ControlPlaneExperiment\day-05.5-$token"
$archive=Join-Path $env:windir "Temp\ControlPlaneExperiment-Day55-$token.zip"
$data="C:\ControlPlaneExperiment-Day55-$short"
$intentPath=Join-Path $data 'intent'
$contentPath=Join-Path $data 'content'
$intentShare="vps-intent-$short"
$contentShare="vps-content-$short"

function Documents {
    @(if(Test-Path -LiteralPath $intentPath) {
        Get-ChildItem -LiteralPath $intentPath -File | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ File=$_.Name; Raw=[IO.File]::ReadAllText($_.FullName) }
        }
    })
}
switch($Action) {
    'Inspect' {
        [pscustomobject]@{ LocalNode=$env:COMPUTERNAME; Domain=$env:USERDOMAIN
            Shares=@(Get-SmbShare | Where-Object Name -like 'vps-*' | ForEach-Object Name) } | ConvertTo-Json -Compress
    }
    'Prepare' {
        if(Test-Path -LiteralPath $directory) { throw 'Staging already exists.' }
        Expand-Archive -LiteralPath $archive -DestinationPath $directory
        [pscustomobject]@{ Prepared=$true; LocalNode=$env:COMPUTERNAME } | ConvertTo-Json -Compress
    }
    'Stage' {
        if(Test-Path -LiteralPath $data) { throw 'Data directory already exists.' }
        New-Item -ItemType Directory -Path $intentPath,$contentPath | Out-Null
        $html="<!doctype html><title>foobar.contoso.com</title><p>Day 5.5 VPS content marker $Marker</p>`n"
        [IO.File]::WriteAllText((Join-Path $contentPath 'index.html'),$html,[Text.UTF8Encoding]::new($false))
        $accounts=@($Readers.Split(',') | ForEach-Object { "$env:USERDOMAIN\$($_)`$" })
        foreach($account in $accounts) {
            & icacls.exe $contentPath /grant "${account}:(OI)(CI)RX" | Out-Null; if($LASTEXITCODE) { throw "icacls content $account" }
            # Modify: the manager deletes the Removed tombstone after observing zero realizations.
            & icacls.exe $intentPath /grant "${account}:(OI)(CI)M" | Out-Null; if($LASTEXITCODE) { throw "icacls intent $account" }
        }
        New-SmbShare -Name $contentShare -Path $contentPath -ReadAccess $accounts | Out-Null
        New-SmbShare -Name $intentShare -Path $intentPath -ChangeAccess $accounts | Out-Null
        [pscustomobject]@{ RootPath="\\$env:COMPUTERNAME\$contentShare"; Store="\\$env:COMPUTERNAME\$intentShare"
            LocalStore=$intentPath; Accounts=$accounts; Index=$html } | ConvertTo-Json -Compress
    }
    'Admin' {
        . (Join-Path $directory 'VPSSite.ps1')
        $env:VPS_EXE=Join-Path $directory 'ControlPlaneExperiment.exe'
        $env:VPS_STORE=$intentPath
        $env:VPS_DOMAINS=$Fences -replace ',',' '
        $before=@(Documents)
        $output=switch($Verb) {
            'new' { New-VPSSite -Name $SiteName -RootPath $RootPath -DesiredReplicas $Replicas }
            'set' { Set-VPSSite -Name $SiteName -DesiredReplicas $Replicas }
            'suspend' { Suspend-VPSSite -Name $SiteName }
            'resume' { Resume-VPSSite -Name $SiteName }
            'remove' { Remove-VPSSite -Name $SiteName }
            'get' { ConvertTo-Json -InputObject @(Get-VPSSite) -Depth 8 -Compress }
            'show' { '' }
        }
        [pscustomobject]@{ Verb=$Verb; At=[datetimeoffset]::UtcNow.ToString('O'); Output="$output"; Before=$before; After=@(Documents) } |
            ConvertTo-Json -Depth 6 -Compress
    }
    'Cleanup' {
        foreach($share in @($intentShare,$contentShare)) { if(Get-SmbShare -Name $share -ErrorAction SilentlyContinue) { Remove-SmbShare -Name $share -Force } }
        if(Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force }
        if(Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        if(Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        [pscustomobject]@{ Cleaned=$true; Shares=@(Get-SmbShare | Where-Object Name -like 'vps-*' | ForEach-Object Name) } | ConvertTo-Json -Compress
        Remove-Item -LiteralPath $PSCommandPath -Force
    }
}
