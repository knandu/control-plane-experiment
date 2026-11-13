#Requires -Version 7.0
param([string] $ManifestPath='C:\vm\labs\wfclab\environment.json', [int] $Port=47054)
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
$group="ControlPlaneExperiment-Day54-$id"
$remote="C:\Windows\Temp\ControlPlaneExperiment-Day54-$id.ps1"
$zipRemote="C:\Windows\Temp\ControlPlaneExperiment-Day54-$id.zip"
$evidence=(New-Item -ItemType Directory -Path (Join-Path $root ".state\day-05.4-$id")).FullName
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
# Experiment-fixed projection: domain-K is realized only on the K-th node. Not persisted in PlatformState.
$domainOf=@{ 'Node-A'='domain-1'; 'Node-B'='domain-2'; 'Node-C'='domain-3' }
$fences=($nodes | ForEach-Object { "$(Address $_):$Port" }) -join ','
function Arguments([string]$node,[string]$action,[string]$case,[string]$target) {
    return "powershell.exe -NoLogo -NoProfile -NonInteractive -File $remote -Action $action -RunId $id -ClusterName $($lab.Cluster.Name) -Case $case -ExecutionDomain $($domainOf[$node]) -Fences $fences"+$(if($target) { " -TargetNode $target" })
}
function Ssh([string]$node,[string]$action,[string]$case,[string]$target) {
    $info=[Diagnostics.ProcessStartInfo]::new('ssh.exe')
    $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($argument in @($options)+@('-l',$lab.SSH.User,(Address $node),(Arguments $node $action $case $target))) { $info.ArgumentList.Add($argument) }
    return [Diagnostics.Process]::Start($info)
}
function Invoke-Node([string]$node,[string]$action,[string]$case='none',[string]$target='') {
    $process=Ssh $node $action $case $target
    try {
        $output=$process.StandardOutput.ReadToEndAsync(); $errorOutput=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(150000)) { $process.Kill(); $process.WaitForExit(); throw "SSH $action on $node timed out." }
        Assert ($process.ExitCode -eq 0) "SSH $action on $node failed: $($errorOutput.Result)"
        $text=$output.Result
    } finally { $process.Dispose() }
    $script:count++
    $text | Set-Content -LiteralPath (Join-Path $evidence ('{0:d3}-{1}-{2}-{3}.json' -f $count,$node,$action,$case))
    return $text | ConvertFrom-Json
}
function Start-Node([string]$node,[string]$action,[string]$case) {
    $process=Ssh $node $action $case ''
    $sessions.Add([pscustomobject]@{ Process=$process; Output=$process.StandardOutput.ReadToEndAsync(); Error=$process.StandardError.ReadToEndAsync(); Name="$node-$action-$case" })
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
        Start-Sleep -Milliseconds 500
    } while([datetime]::UtcNow -lt $deadline)
    throw "Not observed: $what ($node/$case)."
}
function Text($status) { $status.Manager -join "`n" }
function Manage([string]$node,[string]$case,[int]$seconds=240) {
    Start-Node $node 'Run' $case
    $status=Wait-Status $node $case { param($s) $null -ne $s.ManagerExit } "$case manager exit" $seconds
    Assert ($status.ManagerExit -eq '0') "Manager failed on $node/$case`: $((Text $status)) $($status.ManagerError -join ' ')"
    $converged=@($status.Manager | Where-Object { $_ -like 'Result=Converged;*' })
    Assert ($converged.Count -eq 1) "No convergence line on $node/$case."
    Assert ($converged[0] -match '^Result=Converged; starts=(\d+); stops=(\d+); realizations=\[(.*)\]; at=') 'Unparsed convergence.'
    $starts=[int]$Matches[1]; $stops=[int]$Matches[2]; $list=$Matches[3]
    $identities=@{}
    foreach($entry in $list -split '; ') {
        Assert ($entry -match '^fence=([\d.]+):\d+,domain=(domain-\d),state=Running,pid=(\d+),startTicks=(\d+),runId=([0-9a-f-]+)$') "Unparsed realization: $entry"
        $machine=($lab.Machines | Where-Object Address -eq $Matches[1]).Name
        Assert ($domainOf[$machine] -eq $Matches[2]) "Realization $($Matches[2]) observed on $machine."
        Assert (-not $identities.ContainsKey($Matches[2])) "Duplicate $($Matches[2])."
        $identities[$Matches[2]]="$machine/pid=$($Matches[3])/startTicks=$($Matches[4])/runId=$($Matches[5])"
    }
    Assert ($identities.Count -eq 3) "Expected three realizations after $case."
    $usable=@($status.Manager | Where-Object { $_ -like 'Authority usable:*' })
    Assert ($usable.Count -eq 1) "No authority establishment on $node/$case."
    $result=[pscustomobject]@{ Case=$case; Node=$node; Starts=$starts; Stops=$stops; Identities=$identities; Generations=$usable[0]; Status=$status }
    Write-Host "$case on $node`: starts=$starts stops=$stops; $($usable[0])"
    foreach($domain in @('domain-1','domain-2','domain-3')) { Write-Host "  $domain = $($identities[$domain])" }
    return $result
}
function Same($left,$right,[string[]]$domains,[string]$what) {
    foreach($domain in $domains) { Assert ($left.Identities[$domain] -ceq $right.Identities[$domain]) "$what`: $domain identity changed." }
}
function Changed($left,$right,[string]$domain,[string]$what) {
    Assert ($left.Identities[$domain] -cne $right.Identities[$domain]) "$what`: $domain was not replaced."
}
function Children {
    foreach($node in $nodes) {
        $s=Invoke-Node $node 'Status'
        Assert (@($s.Children).Count -eq 1) "$node hosts $(@($s.Children).Count) realizations."
    }
}
try {
    foreach($node in $nodes) {
        Copy-ToNode $node (Join-Path $PSScriptRoot 'day-05.4-node.ps1') $remote
        $staged.Add($node)
        $snapshot=Invoke-Node $node 'Inspect'; Healthy $snapshot
        Assert ($snapshot.LocalNode -ieq $node) 'Wrong guest.'
        Assert (@($snapshot.Groups | Where-Object Name -like 'ControlPlaneExperiment-Day5*').Count -eq 0) 'Prior experiment group exists.'
        if($null -eq $baseline) { $baseline=$snapshot }
    }
    $payload=Join-Path $evidence 'payload'
    & dotnet publish (Join-Path $root 'src\ControlPlaneExperiment\ControlPlaneExperiment.csproj') -c Release -r win-x64 --self-contained true -o $payload *> (Join-Path $evidence 'publish.log')
    Assert ($LASTEXITCODE -eq 0) 'Publish failed.'
    $dotnet=(Get-Command dotnet.exe).Source
    Copy-Item -LiteralPath $dotnet -Destination (Join-Path $payload 'dotnet.exe')
    $resolver=Get-ChildItem (Join-Path (Split-Path $dotnet -Parent) 'host\fxr') -Directory |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $resolverDestination=New-Item -ItemType Directory -Path (Join-Path $payload "host\fxr\$($resolver.Name)")
    Copy-Item -LiteralPath (Join-Path $resolver.FullName 'hostfxr.dll') -Destination $resolverDestination.FullName
    # One intent document, copied identically to every node: stand-in for shared durable intent storage.
    & (Join-Path $payload 'dotnet.exe') (Join-Path $payload 'ControlPlaneExperiment.dll') intent (Join-Path $payload 'intent.json') --replicas 3 | Out-Host
    Assert ($LASTEXITCODE -eq 0) 'Intent creation failed.'
    Copy-Item -LiteralPath (Join-Path $payload 'intent.json') -Destination (Join-Path $evidence 'intent.json')
    $archive=Join-Path $evidence 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payload,$archive)
    foreach($node in $nodes) { Copy-ToNode $node $archive $zipRemote; $null=Invoke-Node $node 'Prepare' }
    $null=Invoke-Node 'Node-A' 'Create'
    foreach($node in $nodes) {
        $null=Invoke-Node $node 'Open'
        Start-Node $node 'Fence' 'none'
        $null=Wait-Status $node 'none' { param($s) ($s.Fence -join "`n") -match 'Domain fence serving' } "$node fence serving"
    }

    # EXPERIMENT 1: Node-A manager converges an empty platform to one realization per node.
    Move-Authority 'Node-A'
    $e1=Manage 'Node-A' 'exp1'
    Assert ($e1.Starts -eq 3 -and $e1.Stops -eq 0) 'Exp1 expected 3 starts, 0 stops.'
    Assert (@($e1.Identities.Values | ForEach-Object { ($_ -split '/')[1..3] -join '/' } | Sort-Object -Unique).Count -eq 3) 'Exp1 identities not distinct.'
    Children

    # EXPERIMENT 2: cooperative WFC move; new manager adopts every realization.
    Move-Authority 'Node-B'
    $e2=Manage 'Node-B' 'exp2'
    Assert ($e2.Starts -eq 0 -and $e2.Stops -eq 0) 'Exp2 expected adoption without effects.'
    Same $e1 $e2 @('domain-1','domain-2','domain-3') 'Exp2 adoption'

    # EXPERIMENT 3: realization failure on Node-C under owner Node-B.
    $kill=Invoke-Node 'Node-C' 'KillWorkload'
    Write-Host "Killed Node-C realization PID $($kill.KilledProcessId) at $($kill.At)."
    $e3=Manage 'Node-B' 'exp3'
    Assert ($e3.Starts -eq 1 -and $e3.Stops -eq 0) 'Exp3 expected one replacement start.'
    Same $e2 $e3 @('domain-1','domain-2') 'Exp3 peers'; Changed $e2 $e3 'domain-3' 'Exp3'
    Assert ($e3.Identities['domain-3'] -notmatch "pid=$($kill.KilledProcessId)/") 'Exp3 kept the killed PID.'

    # EXPERIMENT 4: uncooperative authority loss on Node-B; WFC fails over to Node-C.
    $owners=Invoke-Node 'Node-A' 'Owners' -target 'Node-B,Node-C'
    Assert ((@($owners.Owners) -join ',') -eq 'Node-B,Node-C') 'Preferred owners not set.'
    $kill=Invoke-Node 'Node-B' 'KillClusSvc'
    Write-Host "Killed Node-B ClusSvc PID $($kill.KilledProcessId) at $($kill.At); no relinquish/Offline/cleanup issued."
    $failed=$null; $deadline=[datetime]::UtcNow.AddSeconds(120)
    do {
        try { $snapshot=Invoke-Node 'Node-A' 'Inspect' } catch { $snapshot=$null }
        if($snapshot -and (Owner $snapshot).Owner -eq 'Node-C' -and (Owner $snapshot).State -eq 'Online') { $failed=$snapshot; break }
        Start-Sleep -Milliseconds 500
    } while([datetime]::UtcNow -lt $deadline)
    Assert $failed 'WFC did not fail the group over to Node-C.'
    Write-Host "WFC failover: owner=Node-C at $($failed.At); nodes=$($failed.Nodes -join ',')."
    $e4=Manage 'Node-C' 'exp4' 360
    Assert ($e4.Starts -eq 0 -and $e4.Stops -eq 0) 'Exp4 expected adoption without effects.'
    Same $e3 $e4 @('domain-1','domain-2','domain-3') 'Exp4 adoption'

    # EXPERIMENT 5: realization failure on Node-A under failover owner Node-C.
    $kill=Invoke-Node 'Node-A' 'KillWorkload'
    Write-Host "Killed Node-A realization PID $($kill.KilledProcessId) at $($kill.At)."
    $e5=Manage 'Node-C' 'exp5'
    Assert ($e5.Starts -eq 1 -and $e5.Stops -eq 0) 'Exp5 expected one replacement start.'
    Same $e4 $e5 @('domain-2','domain-3') 'Exp5 peers'; Changed $e4 $e5 'domain-1' 'Exp5'
    Children
    $fenceLogs=foreach($node in $nodes) { $s=Invoke-Node $node 'Status'; "$node generation=$($s.Generation)" }
    Write-Host ($fenceLogs -join '; ')
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
Write-Host "PASS: Day 5.4 one WFC-placed manager reconciled Replicas=3 across three nodes (converge, adopt, replace, failover adopt, replace). Evidence: $evidence"
