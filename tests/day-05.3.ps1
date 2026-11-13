#Requires -Version 7.0
param([string] $ManifestPath='C:\vm\labs\wfclab\environment.json', [int] $Port=47053)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
if(-not(Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "External lab manifest absent: $ManifestPath. No provisioning/repair attempted." }
$lab=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$nodes=@('Node-A','Node-B','Node-C')
foreach($name in $nodes) {
    if(@($lab.Machines | Where-Object Name -eq $name).Count -ne 1) { throw "Missing or ambiguous $name." }
}
foreach($file in @($lab.SSH.PrivateKey,$lab.SSH.KnownHosts)) {
    if(-not(Test-Path -LiteralPath $file -PathType Leaf)) { throw 'Dedicated identity/pins absent.' }
}
if($lab.Cluster.Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw 'Invalid cluster name.' }
$options=@('-F','NUL','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes',
    '-o',"UserKnownHostsFile=$($lab.SSH.KnownHosts)",'-o','GlobalKnownHostsFile=NUL','-o','ConnectTimeout=10','-i',$lab.SSH.PrivateKey)
$id=[guid]::NewGuid().ToString('N')
$group="ControlPlaneExperiment-Day53-$id"
$remote="C:\Windows\Temp\ControlPlaneExperiment-Day53-$id.ps1"
$zipRemote="C:\Windows\Temp\ControlPlaneExperiment-Day53-$id.zip"
$evidence=(New-Item -ItemType Directory -Path (Join-Path $root ".state\day-05.3-$id")).FullName
$sessions=[Collections.Generic.List[object]]::new()
$staged=[Collections.Generic.List[string]]::new()
$count=0
$baseline=$null
function Assert($condition,[string]$message) { if(-not $condition) { throw $message } }
function Address([string]$node) {
    $address=($lab.Machines | Where-Object Name -eq $node).Address
    Assert ($address -match '^\d{1,3}(\.\d{1,3}){3}$') 'Invalid node address.'
    return $address
}
$domain="$(Address 'Node-C'):$Port"
function Arguments([string]$action,[string]$case,[string]$stage,[string]$target) {
    return "powershell.exe -NoLogo -NoProfile -NonInteractive -File $remote -Action $action -RunId $id -ClusterName $($lab.Cluster.Name) -Case $case -Stage $stage -Domain $domain"+$(if($target) { " -TargetNode $target" })
}
function Ssh([string]$node,[string]$action,[string]$case,[string]$stage,[string]$target) {
    $info=[Diagnostics.ProcessStartInfo]::new('ssh.exe')
    $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($argument in @($options)+@('-l',$lab.SSH.User,(Address $node),(Arguments $action $case $stage $target))) { $info.ArgumentList.Add($argument) }
    return [Diagnostics.Process]::Start($info)
}
function Invoke-Node([string]$node,[string]$action,[string]$case='none',[string]$stage='none',[string]$target='') {
    $process=Ssh $node $action $case $stage $target
    try {
        $output=$process.StandardOutput.ReadToEndAsync(); $errorOutput=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(150000)) { $process.Kill(); $process.WaitForExit(); throw "SSH $action on $node timed out." }
        Assert ($process.ExitCode -eq 0) "SSH $action on $node failed: $($errorOutput.Result)"
        $text=$output.Result
    } finally { $process.Dispose() }
    $script:count++
    $text | Set-Content -LiteralPath (Join-Path $evidence ('{0:d3}-{1}-{2}-{3}-{4}.json' -f $count,$node,$action,$case,$stage))
    return $text | ConvertFrom-Json
}
function Start-Node([string]$node,[string]$action,[string]$case,[string]$stage='none') {
    $process=Ssh $node $action $case $stage ''
    $session=[pscustomobject]@{ Process=$process; Output=$process.StandardOutput.ReadToEndAsync(); Error=$process.StandardError.ReadToEndAsync(); Name="$node-$action-$case" }
    $sessions.Add($session)
}
function Copy-ToNode([string]$node,[string]$source,[string]$destination) {
    & scp.exe @options -q $source "$($lab.SSH.User)@$(Address $node):$destination"
    Assert ($LASTEXITCODE -eq 0) "Pinned SCP failed: $node."
}
function Healthy($value) {
    Assert ($value.Cluster -ieq $lab.Cluster.Name) 'Cluster mismatch.'
    Assert (($value.Nodes -join ',') -ceq 'Node-A:Up,Node-B:Up,Node-C:Up') 'Nodes not Up.'
    Assert (@($value.Groups | Where-Object { $_.Name -eq 'Cluster Group' -and $_.State -eq 'Online' }).Count -eq 1) 'Core group unavailable.'
}
function Owner($snapshot) { @($snapshot.Groups | Where-Object Name -eq $group)[0] }
function Move-Authority([string]$target) {
    $snapshot=Invoke-Node 'Node-A' 'Move' -target $target
    Assert ((Owner $snapshot).Owner -ieq $target -and (Owner $snapshot).State -eq 'Online') 'Move did not complete.'
    Write-Host "WFC moved $group to $target at $($snapshot.At)."
}
function Wait-Status([string]$node,[string]$case,[scriptblock]$until,[string]$what,[int]$seconds=60) {
    $deadline=[datetime]::UtcNow.AddSeconds($seconds)
    do {
        $status=Invoke-Node $node 'Status' $case
        if(& $until $status) { return $status }
        Start-Sleep -Milliseconds 250
    } while([datetime]::UtcNow -lt $deadline)
    throw "Not observed: $what ($node/$case)."
}
function Start-Fence([string]$case,[string]$stage='none') {
    Start-Node 'Node-C' 'Fence' $case $stage
    $null=Wait-Status 'Node-C' $case { param($s) ($s.Fence -join "`n") -match 'Domain fence serving' } 'fence serving'
}
function Exited([string]$node,[string]$case) {
    $status=Wait-Status $node $case { param($s) $null -ne $s.ManagerExit } 'manager exit'
    Assert ($status.ManagerExit -eq '0') "Manager failed on $node/$case`: $($status.ManagerError -join ' ')"
    return $status
}
function Text($status) { $status.Manager -join "`n" }
try {
    foreach($node in $nodes) {
        Copy-ToNode $node (Join-Path $PSScriptRoot 'day-05.3-node.ps1') $remote
        $staged.Add($node)
        $snapshot=Invoke-Node $node 'Inspect'; Healthy $snapshot
        Assert ($snapshot.LocalNode -ieq $node) 'Wrong guest.'
        Assert (@($snapshot.Groups | Where-Object Name -like 'ControlPlaneExperiment-Day5*').Count -eq 0) 'Prior experiment group exists.'
        if($null -eq $baseline) { $baseline=$snapshot }
    }
    $payload=Join-Path $evidence 'payload'
    & dotnet publish (Join-Path $root 'src\ControlPlaneExperiment\ControlPlaneExperiment.csproj') -c Release -r win-x64 --self-contained true -o $payload *> (Join-Path $evidence 'publish.log')
    Assert ($LASTEXITCODE -eq 0) 'Publish failed.'
    # Workload.Start launches "dotnet"; stage the host/resolver beside the bundled runtime. Nothing is installed.
    $dotnet=(Get-Command dotnet.exe).Source
    Copy-Item -LiteralPath $dotnet -Destination (Join-Path $payload 'dotnet.exe')
    $resolver=Get-ChildItem (Join-Path (Split-Path $dotnet -Parent) 'host\fxr') -Directory |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $resolverDestination=New-Item -ItemType Directory -Path (Join-Path $payload "host\fxr\$($resolver.Name)")
    Copy-Item -LiteralPath (Join-Path $resolver.FullName 'hostfxr.dll') -Destination $resolverDestination.FullName
    foreach($case in @('movement','effect','failover')) {
        & (Join-Path $payload 'dotnet.exe') (Join-Path $payload 'ControlPlaneExperiment.dll') intent (Join-Path $payload "intent-$case.json") | Out-Host
        Assert ($LASTEXITCODE -eq 0) 'Intent creation failed.'
    }
    $archive=Join-Path $evidence 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payload,$archive)
    foreach($node in $nodes) { Copy-ToNode $node $archive $zipRemote; $null=Invoke-Node $node 'Prepare' }
    $null=Invoke-Node 'Node-A' 'Create'
    $null=Invoke-Node 'Node-C' 'Open'

    # CASE B: authority advance wins; the stale incarnation's effect is rejected at the domain.
    Move-Authority 'Node-A'
    Start-Fence 'movement'
    Start-Node 'Node-A' 'Run' 'movement' 'decision'
    $paused=Wait-Status 'Node-A' 'movement' { param($s) $s.ManagerReached -contains 'decision' } 'A decision'
    Assert ((Text $paused) -match 'GENERATION 1' -and (Text $paused) -match 'OBSERVED Stopped') 'A did not hold generation 1 with a Start decision.'
    Move-Authority 'Node-B'
    Start-Node 'Node-B' 'Run' 'movement'
    $b=Exited 'Node-B' 'movement'
    Assert ((Text $b) -match 'GENERATION 2' -and (Text $b) -match 'Effect reply: STARTED pid=') 'Cold Node-B did not establish generation 2 and start.'
    $null=Invoke-Node 'Node-A' 'Release' 'movement' 'decision'
    $a=Exited 'Node-A' 'movement'
    Assert ((Text $a) -match 'Effect reply: REJECTED Authority rejected: boundary=process creation; offeredEpoch=1; currentEpoch=2') 'Stale generation-1 Start was not rejected.'
    $c=Invoke-Node 'Node-C' 'Status' 'movement'
    Assert (@($c.Children).Count -eq 1 -and $c.Generation -eq '2') 'Advance-first case did not leave exactly one workload.'
    Write-Host "ADVANCE FIRST: Node-B gen 2 started PID $($c.Children[0].ProcessId); Node-A gen 1 Start rejected."
    $null=Invoke-Node 'Node-C' 'StopFence' 'movement'

    # CASE A: the effect wins; advance is ordered after the completed Start.
    Move-Authority 'Node-A'
    Start-Fence 'effect' 'inside'
    Start-Node 'Node-A' 'Run' 'effect'
    $null=Wait-Status 'Node-C' 'effect' { param($s) $s.FenceReached -contains 'inside' } 'effect inside fence'
    Move-Authority 'Node-B'
    Start-Node 'Node-B' 'Run' 'effect'
    $blocked=Wait-Status 'Node-B' 'effect' { param($s) (Text $s) -match 'Authority advance requested' } 'B advance requested'
    Start-Sleep -Seconds 3
    $blocked=Invoke-Node 'Node-B' 'Status' 'effect'
    $inside=Invoke-Node 'Node-C' 'Status' 'effect'
    Assert ((Text $blocked) -notmatch 'advance reply' -and $inside.Generation -eq '1' -and @($inside.Children).Count -eq 0) 'Advance was not held behind the in-flight effect.'
    Write-Host 'Node-B ADVANCE is waiting while Node-A generation-1 Start is inside the fence; WFC move already completed.'
    $null=Invoke-Node 'Node-C' 'Release' 'effect' 'inside'
    $a=Exited 'Node-A' 'effect'
    $b=Exited 'Node-B' 'effect'
    $c=Invoke-Node 'Node-C' 'Status' 'effect'
    $fence=$c.Fence -join "`n"
    Assert ((Text $a) -match 'Effect reply: STARTED pid=') 'Generation-1 effect did not complete.'
    Assert ((Text $b) -match 'GENERATION 2' -and (Text $b) -match 'OBSERVED (Starting|Running)' -and (Text $b) -match 'Result=Converged') 'Node-B did not converge on the completed effect.'
    $advanceB=$fence.IndexOf('Domain request: ADVANCE Node-B',[StringComparison]::OrdinalIgnoreCase)
    Assert ($advanceB -gt 0 -and $fence.IndexOf('Domain reply: STARTED') -lt $advanceB) 'Fence log does not show effect before advance.'
    Assert (@($c.Children).Count -eq 1 -and $c.Generation -eq '2') 'Effect-first case did not leave exactly one workload.'
    Write-Host "EFFECT FIRST: gen 1 started PID $($c.Children[0].ProcessId) before gen 2 was minted; Node-B observed and did not Start."
    $null=Invoke-Node 'Node-C' 'StopFence' 'effect'

    # CASE C: uncooperative loss. Node-B's cluster service dies while its manager holds generation 1.
    Move-Authority 'Node-B'
    $owners=Invoke-Node 'Node-A' 'Owners' -target 'Node-B,Node-C'
    Assert ((@($owners.Owners) -join ',') -eq 'Node-B,Node-C') 'Preferred owners not set.'
    Start-Fence 'failover'
    Start-Node 'Node-B' 'Run' 'failover' 'decision'
    $paused=Wait-Status 'Node-B' 'failover' { param($s) $s.ManagerReached -contains 'decision' } 'B decision'
    Assert ((Text $paused) -match 'GENERATION 1') 'Node-B did not hold generation 1.'
    $kill=Invoke-Node 'Node-B' 'KillClusSvc' 'failover'
    Write-Host "Killed Node-B ClusSvc PID $($kill.KilledProcessId) at $($kill.At); no relinquish/Offline/cleanup issued."
    $failed=$null; $deadline=[datetime]::UtcNow.AddSeconds(120)
    do {
        try { $snapshot=Invoke-Node 'Node-A' 'Inspect' } catch { $snapshot=$null }
        if($snapshot -and (Owner $snapshot).Owner -eq 'Node-C' -and (Owner $snapshot).State -eq 'Online') { $failed=$snapshot; break }
        Start-Sleep -Milliseconds 500
    } while([datetime]::UtcNow -lt $deadline)
    Assert $failed 'WFC did not fail the group over to Node-C.'
    Write-Host "WFC failover: owner=Node-C at $($failed.At); nodes=$($failed.Nodes -join ',')."
    Start-Node 'Node-C' 'Run' 'failover'
    $new=Exited 'Node-C' 'failover'
    Assert ((Text $new) -match 'GENERATION 2' -and (Text $new) -match 'Effect reply: STARTED pid=') 'Node-C could not establish generation 2 after uncooperative loss.'
    $null=Invoke-Node 'Node-B' 'Release' 'failover' 'decision'
    $zombie=Exited 'Node-B' 'failover'
    Assert ((Text $zombie) -match 'Effect reply: REJECTED Authority rejected: boundary=process creation; offeredEpoch=1; currentEpoch=2') 'Zombie generation-1 Start was not rejected.'
    $c=Invoke-Node 'Node-C' 'Status' 'failover'
    Assert (@($c.Children).Count -eq 1 -and $c.Generation -eq '2') 'Failover case did not leave exactly one workload.'
    Write-Host "UNCOOPERATIVE LOSS: Node-C gen 2 started PID $($c.Children[0].ProcessId); zombie Node-B gen 1 Start rejected."
    $null=Invoke-Node 'Node-C' 'StopFence' 'failover'
}
finally {
    $errors=[Collections.Generic.List[string]]::new()
    foreach($node in @($staged | Sort-Object { if($_ -eq 'Node-B') { 0 } else { 1 } })) {
        try { $after=Invoke-Node $node 'Cleanup'; Healthy $after
            Assert ((@($after.Groups | Where-Object Name -notlike 'ControlPlaneExperiment-*') | ConvertTo-Json -Compress) -ceq (@($baseline.Groups) | ConvertTo-Json -Compress)) 'Unrelated group state changed.'
            Assert ((@($after.Resources) | ConvertTo-Json -Compress) -ceq (@($baseline.Resources) | ConvertTo-Json -Compress)) 'Unrelated resource state changed.'
        } catch { $errors.Add("$node cleanup: $_") }
    }
    foreach($session in $sessions) {
        if(-not $session.Process.WaitForExit(15000)) { $session.Process.Kill(); $errors.Add("SSH session $($session.Name) required forced cleanup.") }
        $session.Output.GetAwaiter().GetResult() | Set-Content (Join-Path $evidence "$($session.Name)-ssh.log")
        $session.Error.GetAwaiter().GetResult() | Set-Content (Join-Path $evidence "$($session.Name)-ssh.stderr")
        $session.Process.Dispose()
    }
    if($errors.Count) { $errors | Set-Content (Join-Path $evidence 'cleanup-errors.txt'); throw ($errors -join "`n") }
}
Write-Host "PASS: Day 5.3 fenced effects by authority generation (effect-first, advance-first, uncooperative loss). Evidence: $evidence"
