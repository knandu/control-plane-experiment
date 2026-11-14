#Requires -Version 7.0
# Day 5.5 administrator surface for declarative VPS site intent.
# Dot-source this file. These functions only write or read durable intent (and, for Get, freshly observe
# realizations through the node fences). None of them starts or stops processes; reconciliation does that.
#
#   $env:VPS_EXE    path to ControlPlaneExperiment.exe (self-contained) or .dll
#   $env:VPS_STORE  durable site-intent store: a directory (Day 5.5, one JSON document per site), or (Day 5.6)
#                    wfc-checkpoint:<cluster>:<group>:HKLM\SOFTWARE\ControlPlaneExperiment\<key>, the WFC
#                    registry-checkpointed key of the management role. The checkpoint form must be used on the
#                    role's current owner while the role is Online; elsewhere the command refuses.
#   $env:VPS_DOMAINS configured eligible execution-domain topology: space-separated name=host:port entries in
#                    preference order. Required by New and Set (DesiredReplicas must not exceed its size) and used
#                    by Get to observe. It is configuration, not cluster membership: nothing here queries WFC nodes.

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

function Get-VPSDomains {
    # The upper bound on DesiredReplicas is the configured topology size; the command validates it, not this wrapper.
    param([switch]$Required)
    $domains = @(if ($env:VPS_DOMAINS) { $env:VPS_DOMAINS -split ' ' | Where-Object { $_ } })
    if ($Required -and $domains.Count -eq 0) { throw 'Set $env:VPS_DOMAINS to the configured eligible execution domains (name=host:port ...).' }
    , $domains
}

function New-VPSSite {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$DesiredReplicas)
    Invoke-VPSSiteCommand (@('new', $Name, $RootPath, "$DesiredReplicas") + (Get-VPSDomains -Required))
}

function Set-VPSSite {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$DesiredReplicas)
    Invoke-VPSSiteCommand (@('set', $Name, "$DesiredReplicas") + (Get-VPSDomains -Required))
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
    $sites = @((Invoke-VPSSiteCommand (@('get') + (Get-VPSDomains))) | ConvertFrom-Json)
    if ($Name) { $sites = @($sites | Where-Object { $_.Intent.Name -eq $Name }) }
    $sites
}
