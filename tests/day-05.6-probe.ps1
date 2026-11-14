#Requires -Version 7.0
# Day 5.6 Phase 1/2: measure built-in Generic Application health/recovery and registry-checkpoint semantics with a
# disposable payload before any control-plane code depends on them. Evidence only; asserts nothing architectural.
param([string] $ManifestPath='C:\vm\labs\wfclab\environment.json')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$lab=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$nodes=@('Node-A','Node-B','Node-C')
$options=@('-F','NUL','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes',
    '-o',"UserKnownHostsFile=$($lab.SSH.KnownHosts)",'-o','GlobalKnownHostsFile=NUL','-o','ConnectTimeout=10','-i',$lab.SSH.PrivateKey)
$id=[guid]::NewGuid().ToString('N')
$remote="C:\Windows\Temp\ControlPlaneExperiment-Day56Probe-$id.ps1"
$evidence=(New-Item -ItemType Directory -Path (Join-Path $root ".state\day-05.6-probe-$id")).FullName
$script:count=0
function Address([string]$machine) { ($lab.Machines | Where-Object Name -eq $machine).Address }
function Probe([string]$node,[string]$action,[string]$value='',[string]$target='') {
    $line="powershell.exe -NoLogo -ExecutionPolicy Bypass -NoProfile -NonInteractive -File $remote -Action $action -RunId $id"+
        $(if($value) { " -Value $value" })+$(if($target) { " -TargetNode $target" })
    $text=& ssh.exe @options -l $lab.SSH.User (Address $node) $line 2>&1
    if($LASTEXITCODE -ne 0) { throw "Probe $action on $node failed: $text" }
    $script:count++
    $text | Set-Content -LiteralPath (Join-Path $evidence ('{0:d3}-{1}-{2}.json' -f $count,$node,$action))
    $result=$text | ConvertFrom-Json
    return $result
}
function Show([string]$label,$s) {
    $r=$s.Resource
    Write-Host ("{0,-44} local={1} owner={2} res={3} key={4} value={5} pids={6}" -f $label,$s.LocalNode,$s.Group.Owner,$r.State,
        $s.LocalKeyPresent,$s.LocalValue,(@($s.Monitored | ForEach-Object ProcessId) -join '+'))
}
foreach($node in $nodes) {
    & scp.exe @options -q (Join-Path $PSScriptRoot 'day-05.6-probe-node.ps1') "$($lab.SSH.User)@$(Address $node):$remote"
    if($LASTEXITCODE -ne 0) { throw "SCP to $node failed." }
}
try {
    $created=Probe 'Node-A' 'Create'
    Show 'created on Node-A' $created
    Write-Host "Resource policy: $($created.Resource | ConvertTo-Json -Compress -Depth 3)"
    Write-Host "Group policy: $($created.Group | ConvertTo-Json -Compress)"
    Show 'non-owner Node-B before any move' (Probe 'Node-B' 'Read')

    # Owner write, then a controlled move; read on the destination.
    Show 'owner Node-A writes v1' (Probe 'Node-A' 'Write' 'v1')
    Start-Sleep -Seconds 3
    Show 'non-owner Node-B 3s after v1' (Probe 'Node-B' 'Read')
    $null=Probe 'Node-A' 'Move' -target 'Node-B'
    Show 'destination Node-B after move' (Probe 'Node-B' 'Read')
    Show 'old owner Node-A after move' (Probe 'Node-A' 'Read')

    # Capture timing: owner write followed immediately by a move.
    Show 'owner Node-B writes v2' (Probe 'Node-B' 'Write' 'v2')
    $null=Probe 'Node-B' 'Move' -target 'Node-C'
    Show 'destination Node-C after immediate move' (Probe 'Node-C' 'Read')

    # A non-owner write is not durable intent: overwritten when the role arrives there.
    Show 'non-owner Node-A writes stale-nonowner' (Probe 'Node-A' 'Write' 'stale-nonowner')
    $null=Probe 'Node-C' 'Move' -target 'Node-A'
    Show 'destination Node-A after move' (Probe 'Node-A' 'Read')

    # Writes while the checkpointed resource is offline on its owner.
    $null=Probe 'Node-A' 'StopResource'
    Show 'owner Node-A writes v3-offline' (Probe 'Node-A' 'Write' 'v3-offline')
    Show 'owner Node-A after resource start' (Probe 'Node-A' 'StartResource')

    # Same-node restart after uncooperative process death: is an online write retained?
    Show 'owner Node-A writes v4' (Probe 'Node-A' 'Write' 'v4')
    $kill1=Probe 'Node-A' 'Kill'
    Write-Host "kill #1 pid=$($kill1.Killed)"; $kill1.Transitions | ForEach-Object { Write-Host "  $_" }
    Show 'after kill #1 (same node)' $kill1.After

    # Second failure inside RestartPeriod: does the most recent intent follow a policy failover?
    $owner=$kill1.After.Group.Owner
    Show "owner $owner writes v5" (Probe $owner 'Write' 'v5')
    $kill2=Probe $owner 'Kill'
    Write-Host "kill #2 pid=$($kill2.Killed) on $owner"; $kill2.Transitions | ForEach-Object { Write-Host "  $_" }
    $owner2=$kill2.After.Group.Owner
    Show "recovered owner $owner2" (Probe $owner2 'Read')

    # Deleting/recreating the checkpointed key (not done by the store; measured because the first probe run did it).
    Show "owner $owner2 recreates key with v6" (Probe $owner2 'RecreateKey' 'v6')
    $other=@($nodes | Where-Object { $_ -ne $owner2 })[0]
    $null=Probe $owner2 'Move' -target $other
    Show "destination $other after recreate+move" (Probe $other 'Read')
}finally {
    foreach($node in $nodes) {
        try { $c=Probe $node 'Cleanup'; Write-Host "cleanup $node`: $($c | ConvertTo-Json -Compress)" } catch { Write-Warning "$_" }
        & ssh.exe @options -l $lab.SSH.User (Address $node) "pwsh -NoProfile -Command Remove-Item -LiteralPath $remote -Force -ErrorAction SilentlyContinue" | Out-Null
    }
    Write-Host "Evidence: $evidence"
}
