#Requires -Version 7.0
# Day 5.6 Lab-DC helper. Stages only the site content share (the RootPath). Unlike Day 5.5 there is no shared
# intent directory: durable intent lives in the WFC checkpointed registry key of the management role.
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Stage','Cleanup')][string] $Action,
    [Parameter(Mandatory)][guid] $RunId,
    [ValidatePattern('^[0-9a-f]{32}$')][string] $Marker = '00000000000000000000000000000000',
    [ValidatePattern('^Node-[ABC](,Node-[ABC])*$')][string] $Readers = 'Node-A'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$short=$RunId.ToString('N').Substring(0,8)
$data="C:\ControlPlaneExperiment-Day56-$short"
$contentPath=Join-Path $data 'content'
$contentShare="vps-content-$short"
switch($Action) {
    'Inspect' {
        [pscustomobject]@{ LocalNode=$env:COMPUTERNAME; Domain=$env:USERDOMAIN
            Shares=@(Get-SmbShare | Where-Object Name -like 'vps-*' | ForEach-Object Name) } | ConvertTo-Json -Compress
    }
    'Stage' {
        if(Test-Path -LiteralPath $data) { throw 'Data directory already exists.' }
        New-Item -ItemType Directory -Path $contentPath | Out-Null
        $html="<!doctype html><title>foobar.contoso.com</title><p>Day 5.6 VPS content marker $Marker</p>`n"
        [IO.File]::WriteAllText((Join-Path $contentPath 'index.html'),$html,[Text.UTF8Encoding]::new($false))
        $accounts=@($Readers.Split(',') | ForEach-Object { "$env:USERDOMAIN\$($_)`$" })
        foreach($account in $accounts) {
            & icacls.exe $contentPath /grant "${account}:(OI)(CI)RX" | Out-Null; if($LASTEXITCODE) { throw "icacls content $account" }
        }
        New-SmbShare -Name $contentShare -Path $contentPath -ReadAccess $accounts | Out-Null
        [pscustomobject]@{ RootPath="\\$env:COMPUTERNAME\$contentShare"; Accounts=$accounts; Index=$html } | ConvertTo-Json -Compress
    }
    'Cleanup' {
        if(Get-SmbShare -Name $contentShare -ErrorAction SilentlyContinue) { Remove-SmbShare -Name $contentShare -Force }
        if(Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force }
        [pscustomobject]@{ Cleaned=$true; Shares=@(Get-SmbShare | Where-Object Name -like 'vps-*' | ForEach-Object Name) } | ConvertTo-Json -Compress
        Remove-Item -LiteralPath $PSCommandPath -Force
    }
}
