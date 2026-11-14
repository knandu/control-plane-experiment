#Requires -Version 7.0
# Day 5.6 live harness: the VPS manager is the process of a real WFC Generic Application resource in the clustered
# role "VPS Management"; durable intent is the role's WFC registry checkpoint. The harness never launches a manager.
# It changes intent through the administrator cmdlets on the owner, and drives WFC (Move/Stop/Start, process kill)
# only as an operator would. Workload effects are counted independently from the fence logs on every node.
param([string] $ManifestPath='C:\vm\labs\wfclab\environment.json', [int] $Port=47055, [string] $SiteName='foobar.contoso.com')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
if(-not(Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "External lab manifest absent: $ManifestPath. No provisioning/repair attempted." }
$lab=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$nodes=@('Node-A','Node-B','Node-C')
$dc='Lab-DC'
foreach($name in $nodes+@($dc)) {
    if(@($lab.Machines | Where-Object Name -eq $name).Count -ne 1) { throw "Missing or ambiguous $name." }
}
foreach($file in @($lab.SSH.PrivateKey,$lab.SSH.KnownHosts)) {
    if(-not(Test-Path -LiteralPath $file -PathType Leaf)) { throw 'Dedicated identity/pins absent.' }
}
if($lab.Cluster.Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw 'Invalid cluster name.' }
$curl="$env:windir\System32\curl.exe"
$options=@('-F','NUL','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes',
    '-o',"UserKnownHostsFile=$($lab.SSH.KnownHosts)",'-o','GlobalKnownHostsFile=NUL','-o','ConnectTimeout=10','-i',$lab.SSH.PrivateKey)
$id=[guid]::NewGuid().ToString('N')
$marker=[guid]::NewGuid().ToString('N')
$remote="C:\Windows\Temp\ControlPlaneExperiment-Day56-$id.ps1"
$zipRemote="C:\Windows\Temp\ControlPlaneExperiment-Day56-$id.zip"
$adminRemote="C:\ProgramData\ControlPlaneExperiment\day-05.6-$id\admin.ps1"
$evidence=(New-Item -ItemType Directory -Path (Join-Path $root ".state\day-05.6-$id")).FullName
$staged=[Collections.Generic.List[string]]::new()
$summary=[Collections.Generic.List[object]]::new()
$count=0
$baseline=$null
$rootPath=$null
$created=$false
function Assert($condition,[string]$message) { if(-not $condition) { throw $message } }
function Address([string]$machine) {
    $address=($lab.Machines | Where-Object Name -eq $machine).Address
    Assert ($address -match '^\d{1,3}(\.\d{1,3}){3}$') 'Invalid address.'
    return $address
}
# Experiment-fixed projection of the configured topology onto this lab: domain-K is realized only on the K-th node.
$domainOf=@{ 'Node-A'='domain-1'; 'Node-B'='domain-2'; 'Node-C'='domain-3' }
$nodeOf=@{}; foreach($node in $nodes) { $nodeOf[$domainOf[$node]]=$node }
$fences=($nodes | ForEach-Object { "$($domainOf[$_])=$(Address $_):$Port" }) -join ','
function Remote([string]$machine,[string]$commandLine,[string]$label) {
    $info=[Diagnostics.ProcessStartInfo]::new('ssh.exe')
    $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($argument in @($options)+@('-l',$lab.SSH.User,(Address $machine),$commandLine)) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($info)
    try {
        $output=$process.StandardOutput.ReadToEndAsync(); $errorOutput=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(150000)) { $process.Kill(); $process.WaitForExit(); throw "SSH $label on $machine timed out." }
        Assert ($process.ExitCode -eq 0) "SSH $label on $machine failed: $($errorOutput.Result) $($output.Result)"
        $text=$output.Result
    } finally { $process.Dispose() }
    $script:count++
    $text | Set-Content -LiteralPath (Join-Path $evidence ('{0:d3}-{1}-{2}.json' -f $count,$machine,$label))
    return $text | ConvertFrom-Json
}
# Windows PowerShell 5.1: FailoverClusters must bind natively.
function Invoke-Node([string]$node,[string]$action,[string]$target='') {
    $line="powershell.exe -NoLogo -ExecutionPolicy Bypass -NoProfile -NonInteractive -File $remote -Action $action -RunId $id -ClusterName $($lab.Cluster.Name) -ExecutionDomain $($domainOf[$node]) -Fences $fences"+
        $(if($target) { " -TargetNode $target" })
    Remote $node $line $action
}
function Invoke-Dc([string]$action) {
    Remote $dc "pwsh.exe -NoLogo -NoProfile -NonInteractive -File $remote -Action $action -RunId $id -Marker $marker -Readers $($nodes -join ',')" $action
}
function Copy-To([string]$machine,[string]$source,[string]$destination) {
    & scp.exe @options -q $source "$($lab.SSH.User)@$(Address $machine):$destination"
    Assert ($LASTEXITCODE -eq 0) "Pinned SCP failed: $machine."
}
function Healthy($value) {
    Assert ($value.Cluster -ieq $lab.Cluster.Name) 'Cluster mismatch.'
    Assert (($value.Nodes -join ',') -ceq 'Node-A:Up,Node-B:Up,Node-C:Up') 'Nodes not Up.'
    Assert (@($value.Groups | Where-Object { $_.Name -eq 'Cluster Group' -and $_.State -eq 'Online' }).Count -eq 1) 'Core group unavailable.'
}
function Role {
    $snapshot=Invoke-Node 'Node-A' 'Inspect'
    return $snapshot.Snapshot.Management
}
function Wait-Role([scriptblock]$until,[string]$what,[int]$seconds=120) {
    $deadline=[datetime]::UtcNow.AddSeconds($seconds)
    do {
        try { $role=Role } catch { $role=$null }
        if($role -and (& $until $role)) { return $role }
        Start-Sleep -Milliseconds 500
    } while([datetime]::UtcNow -lt $deadline)
    throw "Not observed: $what."
}
# Durable intent: exactly the administrator's fields, nothing operational, one value per site.
function Intent($values) {
    $list=@($values.Values)
    if($list.Count -eq 0) { return $null }
    Assert ($list.Count -eq 1) "Expected at most one site value; found $($list.Count)."
    Assert ($list[0].Kind -eq 'String') "Intent value kind is $($list[0].Kind)."
    $document=$list[0].Raw | ConvertFrom-Json
    Assert (($document.PSObject.Properties.Name -join ',') -ceq 'SiteId,Name,RootPath,Desired,DesiredReplicas') "Intent carries non-intent fields: $($list[0].Raw)"
    Assert ($list[0].Name -ceq $document.SiteId) 'Value name is not the SiteId.'
    return $document
}
function Admin([string]$owner,[string]$verb,[int]$replicas=0) {
    $line="pwsh.exe -NoLogo -NoProfile -NonInteractive -File $adminRemote -Verb $verb -RunId $id -ClusterName $($lab.Cluster.Name) -SiteName $SiteName -Replicas $replicas -Fences $fences"+
        $(if($rootPath) { " -RootPath $rootPath" })
    $result=Remote $owner $line "admin-$verb"
    Assert ($result.LocalNode -ieq $owner) 'Admin ran on the wrong node.'
    $intent=Intent $result.After
    if($verb -ne 'get') { Write-Host "Admin $verb on $owner`: $($result.Output)" }
    return [pscustomobject]@{ Result=$result; Intent=$intent }
}
function Get-Site([string]$owner) { @((Admin $owner 'get').Result.Output | ConvertFrom-Json) }
function Http([string]$node,[string]$hostName=$SiteName) {
    $lines=& $curl -s -i -m 5 -H "Host: $hostName" "http://$(Address $node)/" 2>&1
    $exit=$LASTEXITCODE
    $text=($lines | ForEach-Object { "$_" }) -join "`n"
    $status=if($text -match '(?m)^HTTP/\S+ (\d{3})') { [int]$Matches[1] } else { 0 }
    $realization=if($text -match '(?m)^X-VPS-Realization: (.+?)\s*$') { $Matches[1] } else { $null }
    [pscustomobject]@{ Node=$node; Host=$hostName; CurlExit=$exit; Status=$status; Realization=$realization
        Marker=$text.Contains($marker); StatusLine=$(if($text -match '(?m)^(HTTP/\S+ \d{3}.*?)\s*$') { $Matches[1] } else { $null }) }
}
function Check-Http([string]$case,$identities) {
    $results=foreach($node in $nodes) {
        $r=Http $node
        $identity=$identities[$domainOf[$node]]
        if($identity) {
            Assert ($r.Status -eq 200 -and $r.Marker) "$case HTTP via $node expected 200 with RootPath content: $($r.StatusLine)"
            $runId=($identity -split '/runId=')[1]; $processId=(($identity -split '/pid=')[1] -split '/')[0]
            Assert ($r.Realization -like "*pid=$processId;runId=$runId") "$case HTTP via $node served by unexpected realization: $($r.Realization)"
        } else {
            Assert ($r.Status -ne 200) "$case HTTP via $node unexpectedly served the site."
        }
        Write-Host ("  HTTP {0} Host={1} -> {2}; {3}" -f $node,$r.Host,$r.StatusLine,$r.Realization)
        $r
    }
    $results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidence "http-$case.json")
    return @($results)
}
# Event accounting: line counts of every node's manager log and fence log before the event.
function Mark {
    $mark=@{}
    foreach($node in $nodes) { $s=Invoke-Node $node 'Status'; $mark[$node]=[pscustomobject]@{ Manager=@($s.ManagerLog).Count; Fence=@($s.Fence).Count } }
    return $mark
}
function Since([object[]]$lines,[int]$from) { @($lines | Select-Object -Skip $from) }
# Waits for the owner's newest manager incarnation to report convergence after the mark, then lets the system
# settle and counts every workload effect cluster-wide since the mark (manager decisions and fence requests).
function Settle([string]$case,[string]$owner,$mark,[int]$required,[string]$desired='Running',[switch]$Finalized,[int]$seconds=240) {
    $deadline=[datetime]::UtcNow.AddSeconds($seconds)
    $converged=$null; $segment=@()
    do {
        $s=Invoke-Node $owner 'Status'
        $new=Since $s.ManagerLog $mark[$owner].Manager
        $serve=@(for($i=0; $i -lt $new.Count; $i++) { if($new[$i] -like 'Serve: *') { $i } })
        $segment=if($serve.Count) { @($new | Select-Object -Skip $serve[-1]) } else { $new }
        $lines=@($segment | Where-Object { $_ -like "Result=Converged; desired=$desired; required=$required;*" })
        $done=$lines.Count -gt 0 -and (-not $Finalized -or @($segment | Where-Object { $_ -like 'Result=Finalized; intentDeleted=True;*' }).Count)
        $running=@($s.Managers)
        if($done -and $running.Count -eq 1 -and $lines[-1] -like "*; manager=$($running[0].ProcessId); *") { $converged=$lines[-1]; break }
        Start-Sleep -Milliseconds 1000
    } while([datetime]::UtcNow -lt $deadline)
    Assert $converged "$case`: no convergence (desired=$desired required=$required) by the current manager on $owner. Last lines: $(($segment | Select-Object -Last 8) -join ' | ')"
    Start-Sleep -Seconds 6
    $decisions=[Collections.Generic.List[string]]::new(); $faults=[Collections.Generic.List[string]]::new(); $serves=[Collections.Generic.List[string]]::new()
    $starts=0; $stops=0; $managers=@{}; $statuses=@{}
    foreach($node in $nodes) {
        $st=Invoke-Node $node 'Status'; $statuses[$node]=$st
        foreach($line in (Since $st.ManagerLog $mark[$node].Manager)) {
            if($line -like 'Decision=*') { $decisions.Add("$node $line") }
            if($line -like 'Fault:*') { $faults.Add("$node $line") }
            if($line -like 'Serve: *') { $serves.Add("$node $line") }
        }
        $fence=Since $st.Fence $mark[$node].Fence
        $starts+=@($fence | Where-Object { $_ -like 'Domain request: START *' }).Count
        $stops+=@($fence | Where-Object { $_ -like 'Domain request: STOP *' }).Count
        $managers[$node]=@($st.Managers)
    }
    foreach($node in $nodes) {
        $expected=if($node -eq $owner) { 1 } else { 0 }
        Assert ($managers[$node].Count -eq $expected) "$case`: $node runs $($managers[$node].Count) managers; expected $expected."
    }
    $manager=$managers[$owner][0]
    Assert ($faults.Count -eq 0) "$case`: manager faults: $($faults -join ' | ')"
    Assert ($manager.Parent -ieq 'rhs.exe') "$case`: manager parent is $($manager.Parent), not the WFC resource host."
    $later=@(Since $statuses[$owner].ManagerLog $mark[$owner].Manager | Where-Object { $_ -like 'Result=Converged;*' })
    Assert ($later[-1] -ceq $converged) "$case`: the state changed again after convergence: $($later[-1])"
    Assert ($converged -match '^Result=Converged; desired=(\w+); required=(\d+); realizations=\[(.*)\]; starts=\d+; stops=\d+; manager=(\d+); generations=\[(.*)\]; at=') "Unparsed convergence: $converged"
    $list=$Matches[3]; $generationText=$Matches[5]
    $identities=@{}
    foreach($entry in @($list -split '; ' | Where-Object { $_ })) {
        Assert ($entry -match '^node=([A-Za-z0-9-]+),domain=([A-Za-z0-9._-]+),state=Running,pid=(\d+),startTicks=(\d+),runId=([0-9a-f-]+)$') "Unparsed realization: $entry"
        $machine=$nodes | Where-Object { $_ -ieq $Matches[1] }
        Assert ($machine -and $domainOf[$machine] -eq $Matches[2]) "Realization $($Matches[2]) observed on $($Matches[1])."
        Assert (-not $identities.ContainsKey($Matches[2])) "Duplicate $($Matches[2])."
        $identities[$Matches[2]]="$machine/pid=$($Matches[3])/startTicks=$($Matches[4])/runId=$($Matches[5])"
    }
    Assert ($identities.Count -eq $required) "$case`: expected $required realizations, observed $($identities.Count)."
    $generations=[ordered]@{}
    foreach($pair in ($generationText -split ', ')) { $k,$v=$pair -split '='; $generations[$k]=[long]$v }
    $local=Intent $statuses[$owner].LocalIntent
    $children=foreach($node in $nodes) { @($statuses[$node].Children).Count }
    $result=[pscustomobject]@{ Case=$case; Owner=$owner; ManagerPid=$manager.ProcessId; ManagerParent=$manager.Parent; ManagerCreated=$manager.Created
        Converged=$converged; Identities=$identities; Generations=$generations; Starts=$starts; Stops=$stops; Decisions=@($decisions); Faults=@($faults)
        Incarnations=@($serves); OwnerIntent=$local; Children=@($children)
        Role=$statuses[$owner].Snapshot.Management; Finalized=@($segment | Where-Object { $_ -like 'Result=Finalized;*' }) }
    Write-Host "$case on $owner`: manager=$($result.ManagerPid) (parent $($manager.Parent)); fence starts=$starts stops=$stops; generations=$(($generations.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')"
    foreach($line in $serves) { Write-Host "  incarnation: $($line.Substring(0,[Math]::Min(80,$line.Length)))" }
    foreach($line in $decisions) { Write-Host "  $line" }
    foreach($line in $faults) { Write-Host "  $line" }
    foreach($domain in @($identities.Keys | Sort-Object)) { Write-Host "  $domain = $($identities[$domain])" }
    return $result
}
function Record($settled,$http,$get,[hashtable]$extra=@{}) {
    $entry=[ordered]@{ Case=$settled.Case; Owner=$settled.Owner; ManagerPid=$settled.ManagerPid; ManagerParent=$settled.ManagerParent
        ResourceType=$settled.Role.Resource.Type; ResourceState=$settled.Role.Resource.State; GroupState=$settled.Role.State
        OwnerIntent=$settled.OwnerIntent; Generations=$settled.Generations; Starts=$settled.Starts; Stops=$settled.Stops
        Decisions=$settled.Decisions; Faults=$settled.Faults; Incarnations=$settled.Incarnations; Identities=$settled.Identities
        Children=$settled.Children; Converged=$settled.Converged; Finalized=$settled.Finalized
        Http=@($http | ForEach-Object { "$($_.Node): $($_.StatusLine) $($_.Realization)" }); Get=$get }
    foreach($key in $extra.Keys) { $entry[$key]=$extra[$key] }
    $summary.Add([pscustomobject]$entry)
}
function Same($left,$right,[string[]]$domains,[string]$what) {
    foreach($domain in $domains) { Assert ($left.Identities[$domain] -ceq $right.Identities[$domain]) "$what`: $domain identity changed." }
}
function Newer($before,$after,[string]$what) {
    foreach($domain in $before.Generations.Keys) {
        Assert ($after.Generations[$domain] -gt $before.Generations[$domain]) "$what`: $domain generation did not advance ($($before.Generations[$domain]) -> $($after.Generations[$domain]))."
    }
}
function Quiet($settled,[string]$what) {
    Assert ($settled.Starts -eq 0 -and $settled.Stops -eq 0 -and $settled.Decisions.Count -eq 0) "$what`: expected zero workload effects; starts=$($settled.Starts) stops=$($settled.Stops)."
}
function Running-Nodes($site) { @($site.RunningNodes | ForEach-Object { "$_".ToUpperInvariant() } | Sort-Object) -join ',' }
function Other([string]$owner) { @($nodes | Where-Object { $_ -ne $owner })[0] }
try {
    foreach($node in $nodes) {
        Copy-To $node (Join-Path $PSScriptRoot 'day-05.6-node.ps1') $remote
        $staged.Add($node)
        $inspect=Invoke-Node $node 'Inspect'; Healthy $inspect.Snapshot
        Assert ($inspect.Snapshot.LocalNode -ieq $node) 'Wrong guest.'
        Assert ($null -eq $inspect.Snapshot.Management) "Residual 'VPS Management' group exists."
        Assert (@($inspect.Snapshot.Groups | Where-Object Name -like 'ControlPlaneExperiment-*').Count -eq 0) 'Prior experiment group exists.'
        Assert (@($inspect.ExperimentKeys).Count -eq 0) "Residual experiment registry keys on $node`: $($inspect.ExperimentKeys -join ',')"
        Assert (@($inspect.Staging).Count -eq 0) "Residual Day 5.6 staging on $node."
        if($null -eq $baseline) { $baseline=$inspect.Snapshot }
    }
    Copy-To $dc (Join-Path $PSScriptRoot 'day-05.6-dc.ps1') $remote
    $staged.Add($dc)
    $dcInfo=Invoke-Dc 'Inspect'
    Assert ($dcInfo.LocalNode -ieq $dc) 'Wrong DC guest.'
    Assert (@($dcInfo.Shares).Count -eq 0) 'Prior VPS shares exist on the DC.'

    $payload=Join-Path $evidence 'payload'
    & dotnet publish (Join-Path $root 'src\ControlPlaneExperiment\ControlPlaneExperiment.csproj') -c Release -r win-x64 --self-contained true -o $payload *> (Join-Path $evidence 'publish.log')
    Assert ($LASTEXITCODE -eq 0) 'Publish failed.'
    $dotnet=(Get-Command dotnet.exe).Source
    Copy-Item -LiteralPath $dotnet -Destination (Join-Path $payload 'dotnet.exe')
    $resolver=Get-ChildItem (Join-Path (Split-Path $dotnet -Parent) 'host\fxr') -Directory |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $resolverDestination=New-Item -ItemType Directory -Path (Join-Path $payload "host\fxr\$($resolver.Name)")
    Copy-Item -LiteralPath (Join-Path $resolver.FullName 'hostfxr.dll') -Destination $resolverDestination.FullName
    Copy-Item -LiteralPath (Join-Path $root 'tools\VPSSite.ps1') -Destination $payload
    $archive=Join-Path $evidence 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payload,$archive)
    foreach($node in $nodes) {
        Copy-To $node $archive $zipRemote
        $null=Invoke-Node $node 'Prepare'
        Copy-To $node (Join-Path $PSScriptRoot 'day-05.6-admin.ps1') $adminRemote
    }
    $staging=Invoke-Dc 'Stage'
    $rootPath=$staging.RootPath
    Write-Host "Staged RootPath=$rootPath (marker $marker). No intent share: intent is the WFC checkpoint."
    foreach($node in $nodes) {
        $open=Invoke-Node $node 'Open'
        Assert (@($open.Port80Listeners).Count -eq 0 -or @($open.Port80Listeners | Where-Object { $_ -ne 4 }).Count -eq 0) "$node port 80 is owned by another process."
        $null=Invoke-Node $node 'Fence'
    }
    foreach($node in $nodes) {
        $deadline=[datetime]::UtcNow.AddSeconds(60)
        while(-not ((Invoke-Node $node 'Status').Fence -join "`n").Contains('Domain fence serving')) {
            Assert ([datetime]::UtcNow -lt $deadline) "$node fence not serving."
            Start-Sleep -Milliseconds 750
        }
    }

    # SETUP: the clustered role. WFC, not this harness, launches the manager.
    $created=$true
    $create=Invoke-Node 'Node-A' 'Create'
    Write-Host "Created role: $($create.Snapshot.Management.Group) / $($create.Snapshot.Management.Resource.Name) ($($create.Snapshot.Management.Resource.Type)); checkpoints=$($create.Snapshot.Management.Resource.Checkpoints -join ',')"
    Write-Host "  CommandLine: $($create.CommandLine)"
    $mark=Mark
    $start=Invoke-Node 'Node-A' 'Start'
    $role=$start.Snapshot.Management
    Assert ($role.Owner -eq 'Node-A' -and $role.State -eq 'Online' -and $role.Resource.State -eq 'Online') "Role did not come Online on Node-A: $($role | ConvertTo-Json -Compress)"
    Write-Host "Role Online on $($role.Owner); policy RestartAction=$($role.Resource.RestartAction) RestartThreshold=$($role.Resource.RestartThreshold) RestartPeriod=$($role.Resource.RestartPeriod) FailoverThreshold=$($role.FailoverThreshold) FailoverPeriod=$($role.FailoverPeriod)"
    $base=Admin 'Node-A' 'show'
    Assert ($base.Result.After.KeyPresent -and $null -eq $base.Intent) 'Baseline intent not empty.'
    Assert (@(Get-Site 'Node-A').Count -eq 0) 'Get-VPSSite reported a site before New.'
    $null=Check-Http 'baseline' @{}

    # EXPERIMENT 1: intent declared through the checkpointed store; the WFC-hosted manager realizes it.
    $new=Admin 'Node-A' 'new' 3
    Assert ($new.Intent.Name -eq $SiteName -and $new.Intent.RootPath -eq $rootPath -and $new.Intent.Desired -eq 'Running' -and $new.Intent.DesiredReplicas -eq 3) 'Exp1 intent mismatch.'
    $e1=Settle 'exp1' 'Node-A' $mark 3
    Assert ($e1.Starts -eq 3 -and $e1.Stops -eq 0 -and $e1.Decisions.Count -eq 3) "Exp1 expected 3 starts; starts=$($e1.Starts) stops=$($e1.Stops)."
    Assert ($e1.Incarnations.Count -eq 1 -and $e1.Faults.Count -eq 0) 'Exp1 expected one manager incarnation and no faults.'
    Assert ($e1.OwnerIntent.SiteId -eq $new.Intent.SiteId -and $e1.OwnerIntent.DesiredReplicas -eq 3) 'Exp1 owner-local intent mismatch.'
    $h1=Check-Http 'exp1' $e1.Identities
    $g1=@(Get-Site 'Node-A')
    Assert ((Running-Nodes $g1[0]) -eq 'NODE-A,NODE-B,NODE-C') "Exp1 Get-VPSSite RunningNodes=$(Running-Nodes $g1[0])."
    Record $e1 $h1 $g1

    # EXPERIMENT 2: Move-ClusterGroup moves management, not the service.
    $mark=Mark
    $move=Invoke-Node 'Node-A' 'Move' 'Node-B'
    Assert ($move.Snapshot.Management.Owner -eq 'Node-B' -and $move.Snapshot.Management.State -eq 'Online') 'Exp2 move did not complete.'
    $e2=Settle 'exp2' 'Node-B' $mark 3
    Quiet $e2 'Exp2'
    Same $e1 $e2 @('domain-1','domain-2','domain-3') 'Exp2 adoption'
    Newer $e1 $e2 'Exp2'
    Assert ($e2.OwnerIntent.SiteId -eq $new.Intent.SiteId -and $e2.OwnerIntent.DesiredReplicas -eq 3) 'Exp2 intent did not follow the role.'
    $h2=Check-Http 'exp2' $e2.Identities
    Record $e2 $h2 @(Get-Site 'Node-B') @{ Move="Node-A -> Node-B requested $($move.Requested)" }

    # EXPERIMENT 3: administrative resource restart on the current owner (WFC Offline terminates, Online relaunches).
    $mark=Mark
    $restart=Invoke-Node 'Node-B' 'Restart'
    Assert (@($restart.AfterStop).Count -eq 0) 'Exp3 manager survived resource Offline.'
    Assert (@($restart.After).Count -eq 1 -and $restart.After[0].ProcessId -ne $restart.Before[0].ProcessId) 'Exp3 WFC did not launch a new manager.'
    $e3=Settle 'exp3' 'Node-B' $mark 3
    Quiet $e3 'Exp3'
    Same $e2 $e3 @('domain-1','domain-2','domain-3') 'Exp3 adoption'
    Newer $e2 $e3 'Exp3'
    $h3=Check-Http 'exp3' $e3.Identities
    Record $e3 $h3 @(Get-Site 'Node-B') @{ Restart="manager $($restart.Before[0].ProcessId) -> $($restart.After[0].ProcessId)" }

    # EXPERIMENT 4a: uncooperative manager failure (ClusSvc healthy). Observe what WFC does.
    $mark=Mark
    $kill1=Invoke-Node 'Node-B' 'KillManager'
    Write-Host "Exp4a killed manager PID $($kill1.Killed.ProcessId) on Node-B at $($kill1.At). WFC transitions:"
    foreach($t in $kill1.Transitions) { Write-Host "  $t" }
    $owner4a=$kill1.Snapshot.Management.Owner
    $e4a=Settle 'exp4a' $owner4a $mark 3
    Quiet $e4a 'Exp4a'
    Same $e3 $e4a @('domain-1','domain-2','domain-3') 'Exp4a adoption'
    Newer $e3 $e4a 'Exp4a'
    $h4a=Check-Http 'exp4a' $e4a.Identities
    $action4a=if($owner4a -eq 'Node-B') { 'local restart' } else { "failover to $owner4a" }
    Write-Host "Exp4a WFC recovery: $action4a."
    Record $e4a $h4a @(Get-Site $owner4a) @{ Killed=$kill1.Killed; KilledAt=$kill1.At; Transitions=$kill1.Transitions; Recovery=$action4a }

    # EXPERIMENT 4b: second failure on the same owner within RestartPeriod; the configured policy decides.
    $mark=Mark
    $kill2=Invoke-Node $owner4a 'KillManager'
    Write-Host "Exp4b killed manager PID $($kill2.Killed.ProcessId) on $owner4a at $($kill2.At). WFC transitions:"
    foreach($t in $kill2.Transitions) { Write-Host "  $t" }
    $role4b=Wait-Role { param($r) $r.State -eq 'Online' -and $r.Resource.State -eq 'Online' } 'Exp4b role Online'
    $owner4b=$role4b.Owner
    $e4b=Settle 'exp4b' $owner4b $mark 3
    Quiet $e4b 'Exp4b'
    Same $e4a $e4b @('domain-1','domain-2','domain-3') 'Exp4b adoption'
    Newer $e4a $e4b 'Exp4b'
    Assert ($e4b.OwnerIntent.SiteId -eq $new.Intent.SiteId -and $e4b.OwnerIntent.DesiredReplicas -eq 3) 'Exp4b intent unavailable after recovery.'
    $h4b=Check-Http 'exp4b' $e4b.Identities
    $action4b=if($owner4b -eq $owner4a) { 'local restart' } else { "failover $owner4a -> $owner4b" }
    Write-Host "Exp4b WFC recovery: $action4b."
    Record $e4b $h4b @(Get-Site $owner4b) @{ Killed=$kill2.Killed; KilledAt=$kill2.At; Transitions=$kill2.Transitions; Recovery=$action4b }

    # EXPERIMENT 5: the recovered manager repairs exactly one killed realization (on a node it does not own).
    $victimNode=Other $owner4b
    $victimDomain=$domainOf[$victimNode]
    $mark=Mark
    $killW=Invoke-Node $victimNode 'KillWorkload'
    Write-Host "Exp5 killed $victimDomain realization PID $($killW.KilledProcessId) on $victimNode at $($killW.At)."
    $e5=Settle 'exp5' $owner4b $mark 3
    Assert ($e5.Starts -eq 1 -and $e5.Stops -eq 0) "Exp5 expected exactly one start; starts=$($e5.Starts) stops=$($e5.Stops)."
    Assert (@($e5.Decisions | Where-Object { $_ -like "* Decision=Start; reason=required-domain-empty; domain=$victimDomain;*" }).Count -eq 1) "Exp5 did not start $victimDomain."
    Assert ($e5.Incarnations.Count -eq 0) 'Exp5 manager incarnation changed.'
    Same $e4b $e5 @($nodes | Where-Object { $_ -ne $victimNode } | ForEach-Object { $domainOf[$_] }) 'Exp5 peers'
    Assert ($e5.Identities[$victimDomain] -cne $e4b.Identities[$victimDomain]) 'Exp5 did not replace the killed realization.'
    $h5=Check-Http 'exp5' $e5.Identities
    Record $e5 $h5 @(Get-Site $owner4b) @{ KilledWorkload="$victimNode/$victimDomain pid=$($killW.KilledProcessId)" }

    # EXPERIMENT 6: updated intent follows the role through the checkpoint.
    $mark=Mark
    $set=Admin $owner4b 'set' 2
    Assert ($set.Intent.DesiredReplicas -eq 2 -and $set.Intent.SiteId -eq $new.Intent.SiteId) 'Exp6 set intent mismatch.'
    $e6a=Settle 'exp6a' $owner4b $mark 2
    Assert ($e6a.Starts -eq 0 -and $e6a.Stops -eq 1) "Exp6a expected one stop; starts=$($e6a.Starts) stops=$($e6a.Stops)."
    Assert (@($e6a.Decisions | Where-Object { $_ -like '* Decision=Stop; reason=not-required-domain; domain=domain-3;*' }).Count -eq 1) 'Exp6a did not stop domain-3.'
    Same $e5 $e6a @('domain-1','domain-2') 'Exp6a keepers'
    $h6a=Check-Http 'exp6a' $e6a.Identities
    $g6a=@(Get-Site $owner4b)
    Assert ((Running-Nodes $g6a[0]) -eq 'NODE-A,NODE-B') "Exp6a Get-VPSSite RunningNodes=$(Running-Nodes $g6a[0])."
    Record $e6a $h6a $g6a
    $target6=Other $owner4b
    $mark=Mark
    $move6=Invoke-Node $owner4b 'Move' $target6
    Assert ($move6.Snapshot.Management.Owner -eq $target6 -and $move6.Snapshot.Management.State -eq 'Online') 'Exp6b move did not complete.'
    $e6b=Settle 'exp6b' $target6 $mark 2
    Quiet $e6b 'Exp6b'
    Same $e6a $e6b @('domain-1','domain-2') 'Exp6b adoption'
    Newer $e6a $e6b 'Exp6b'
    Assert ($e6b.OwnerIntent.DesiredReplicas -eq 2 -and $e6b.OwnerIntent.SiteId -eq $new.Intent.SiteId) 'Exp6b destination did not read DesiredReplicas=2.'
    Assert (@($e6b.Incarnations).Count -eq 1 -and $e6b.Incarnations[0] -like "$target6 *") 'Exp6b expected one new incarnation on the destination.'
    $h6b=Check-Http 'exp6b' $e6b.Identities
    Record $e6b $h6b @(Get-Site $target6) @{ Move="$owner4b -> $target6 requested $($move6.Requested)" }

    # CLOSING: remove through the checkpointed store; the manager converges to zero and deletes the tombstone value.
    $mark=Mark
    $remove=Admin $target6 'remove'
    Assert ($remove.Intent.Desired -eq 'Removed' -and $remove.Intent.SiteId -eq $new.Intent.SiteId) 'Close tombstone mismatch.'
    $e7=Settle 'close' $target6 $mark 0 'Removed' -Finalized
    Assert ($e7.Starts -eq 0 -and $e7.Stops -eq 2) "Close expected two stops; starts=$($e7.Starts) stops=$($e7.Stops)."
    $final=Admin $target6 'show'
    Assert ($final.Result.After.KeyPresent -and $null -eq $final.Intent) 'Close: checkpointed key missing or intent value still present.'
    Assert (@(Get-Site $target6).Count -eq 0) 'Close: Get-VPSSite still reports the site.'
    $h7=Check-Http 'close' @{}
    Record $e7 $h7 @() @{ FinalValues=@($final.Result.After.Values).Count }
}
catch {
    $primary="$_`n$($_.ScriptStackTrace)"
    $primary | Set-Content (Join-Path $evidence 'primary-error.txt')
    Write-Host "PRIMARY FAILURE: $primary" -ForegroundColor Red
    throw
}
finally {
    $summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'summary.json')
    $errors=[Collections.Generic.List[string]]::new()
    try {
        foreach($node in @($staged | Where-Object { $_ -ne $dc })) {
            $st=Invoke-Node $node 'Status'
            $st | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence "final-status-$node.json")
        }
    } catch { $errors.Add("final status: $_") }
    # The owner node removes the group first (stopping the manager); then each node removes its local material.
    $order=@($staged | Sort-Object { if($_ -eq 'Node-A') { 0 } elseif($_ -eq $dc) { 2 } else { 1 } })
    foreach($machine in $order) {
        try {
            if($machine -eq $dc) { $after=Invoke-Dc 'Cleanup'; Assert (@($after.Shares).Count -eq 0) 'DC shares remain.'; continue }
            $after=Invoke-Node $machine 'Cleanup'; Healthy $after.Snapshot
            Assert ($null -eq $after.Snapshot.Management) "'VPS Management' remains."
            Assert (-not $after.KeyPresent -and -not $after.Staging -and $after.Tasks -eq 0 -and -not $after.Rule -and $after.Processes -eq 0) "$machine residue: $($after | ConvertTo-Json -Compress -Depth 3)"
            Assert ((@($after.Snapshot.Groups) | ConvertTo-Json -Compress) -ceq (@($baseline.Groups) | ConvertTo-Json -Compress)) 'Unrelated group state changed.'
            Assert ((@($after.Snapshot.Resources) | ConvertTo-Json -Compress) -ceq (@($baseline.Resources) | ConvertTo-Json -Compress)) 'Unrelated resource state changed.'
        } catch { $errors.Add("$machine cleanup: $_") }
    }
    if($errors.Count) { $errors | Set-Content (Join-Path $evidence 'cleanup-errors.txt'); throw ($errors -join "`n") }
}
Write-Host "PASS: Day 5.6 VPS management hosted as WFC role 'VPS Management': realized, moved, restarted, failed/recovered, repaired, rescaled+moved and removed. Evidence: $evidence"
