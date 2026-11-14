#Requires -Version 7.0
# Day 5.5 administrator surface for declarative VPS site intent.
# Dot-source this file. These functions only write or read durable intent (and, for Get, freshly observe
# realizations through the node fences). None of them starts or stops processes; reconciliation does that.
#
#   $env:VPS_EXE    path to ControlPlaneExperiment.exe (self-contained) or .dll
#   $env:VPS_STORE  durable site-intent directory (one JSON document per site)
#   $env:VPS_FENCES optional, space-separated node fence endpoints in domain order, used only by Get

function Invoke-VPSSiteCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = $env:VPS_EXE
    $store = $env:VPS_STORE
    if (-not $exe -or -not $store) { throw 'Set $env:VPS_EXE and $env:VPS_STORE before using VPS site commands.' }
    $all = @('vps', $Arguments[0], $store) + @($Arguments | Select-Object -Skip 1)
    if ($exe.EndsWith('.dll')) { $output = & dotnet $exe @all 2>&1 } else { $output = & $exe @all 2>&1 }
    $code = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ($code -ne 0) { throw "VPS $($Arguments[0]) failed (exit $code): $text" }
    $text
}

function New-VPSSite {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][ValidateRange(1, 3)][int]$DesiredReplicas)
    Invoke-VPSSiteCommand @('new', $Name, $RootPath, "$DesiredReplicas")
}

function Set-VPSSite {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateRange(1, 3)][int]$DesiredReplicas)
    Invoke-VPSSiteCommand @('set', $Name, "$DesiredReplicas")
}

function Suspend-VPSSite {
    param([Parameter(Mandatory)][string]$Name)
    Invoke-VPSSiteCommand @('suspend', $Name)
}

function Resume-VPSSite {
    param([Parameter(Mandatory)][string]$Name)
    Invoke-VPSSiteCommand @('resume', $Name)
}

function Remove-VPSSite {
    # Writes the Removed tombstone. The manager deletes the document only after it has observed zero realizations.
    param([Parameter(Mandatory)][string]$Name)
    Invoke-VPSSiteCommand @('remove', $Name)
}

function Get-VPSSite {
    # Intent from durable state; realizations and RunningNodes freshly observed, never persisted.
    param([string]$Name)
    $fences = @(if ($env:VPS_FENCES) { $env:VPS_FENCES -split ' ' | Where-Object { $_ } })
    $sites = @((Invoke-VPSSiteCommand (@('get') + $fences)) | ConvertFrom-Json)
    if ($Name) { $sites = @($sites | Where-Object { $_.Intent.Name -eq $Name }) }
    $sites
}
