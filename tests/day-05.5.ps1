#Requires -Version 7.0
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
$group="ControlPlaneExperiment-Day55-$id"
$remote="C:\Windows\Temp\ControlPlaneExperiment-Day55-$id.ps1"
$zipRemote="C:\Windows\Temp\ControlPlaneExperiment-Day55-$id.zip"
$evidence=(New-Item -ItemType Directory -Path (Join-Path $root ".state\day-05.5-$id")).FullName
$staged=[Collections.Generic.List[string]]::new()
$summary=[Collections.Generic.List[object]]::new()
$count=0
$baseline=$null
$rootPath=$null; $store=$null
function Assert($condition,[string]$message) { if(-not $condition) { throw $message } }
function Address([string]$machine) {
    $address=($lab.Machines | Where-Object Name -eq $machine).Address
    Assert ($address -match '^\d{1,3}(\.\d{1,3}){3}$') 'Invalid address.'
    return $address
}
# Experiment-fixed projection, not a scheduler: domain-K is realized only on the K-th node; replicas=N means domain-1..N.
$domainOf=@{ 'Node-A'='domain-1'; 'Node-B'='domain-2'; 'Node-C'='domain-3' }
$fences=($nodes | ForEach-Object { "$(Address $_):$Port" }) -join ','
function Remote([string]$machine,[string]$commandLine,[string]$label) {
    $info=[Diagnostics.ProcessStartInfo]::new('ssh.exe')
    $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($argument in @($options)+@('-l',$lab.SSH.User,(Address $machine),$commandLine)) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($info)
    try {
        $output=$process.StandardOutput.ReadToEndAsync(); $errorOutput=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(150000)) { $process.Kill(); $process.WaitForExit(); throw "SSH $label on $machine timed out." }
        Assert ($process.ExitCode -eq 0) "SSH $label on $machine failed: $($errorOutput.Result)"
        $text=$output.Result
    } finally { $process.Dispose() }
    $script:count++
    $text | Set-Content -LiteralPath (Join-Path $evidence ('{0:d3}-{1}-{2}.json' -f $count,$machine,$label))
    return $text | ConvertFrom-Json
}
function Invoke-Node([string]$node,[string]$action,[string]$case='none',[string]$target='') {
    $line="pwsh.exe -NoLogo -NoProfile -NonInteractive -File $remote -Action $action -RunId $id -ClusterName $($lab.Cluster.Name) -Case $case -ExecutionDomain $($domainOf[$node]) -Fences $fences"+
        $(if($store) { " -Store $store" })+$(if($target) { " -TargetNode $target" })
    Remote $node $line "$action-$case"
}
function Invoke-Dc([string]$action,[string]$verb='none',[int]$replicas=0) {
    $line="pwsh.exe -NoLogo -NoProfile -NonInteractive -File $remote -Action $action -RunId $id -Verb $verb -SiteName $SiteName -Replicas $replicas -Marker $marker -Fences $fences -Readers $($nodes -join ',')"+
        $(if($rootPath) { " -RootPath $rootPath" })
    Remote $dc $line "$action-$verb"
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
function Owner($snapshot) { @($snapshot.Groups | Where-Object Name -eq $group)[0] }
function Move-Authority([string]$target) {
    $snapshot=Invoke-Node 'Node-A' 'Move' -target $target
    Assert ((Owner $snapshot).Owner -ieq $target -and (Owner $snapshot).State -eq 'Online') 'Move did not complete.'
    Write-Host "WFC management owner: $target at $($snapshot.At)."
}
function Wait-Status([string]$node,[string]$case,[scriptblock]$until,[string]$what,[int]$seconds=60) {
    $deadline=[datetime]::UtcNow.AddSeconds($seconds)
    do {
        $status=Invoke-Node $node 'Status' $case
        if(& $until $status) { return $status }
        Start-Sleep -Milliseconds 750
    } while([datetime]::UtcNow -lt $deadline)
    throw "Not observed: $what ($node/$case)."
}
# Durable intent: exactly the administrator's fields, nothing operational.
function Intent($admin) {
    $documents=@($admin.After)
    if($documents.Count -eq 0) { return $null }
    Assert ($documents.Count -eq 1) 'Expected at most one site document.'
    $document=$documents[0].Raw | ConvertFrom-Json
    Assert (($document.PSObject.Properties.Name -join ',') -ceq 'SiteId,Name,RootPath,Desired,DesiredReplicas') "Intent carries non-intent fields: $($documents[0].Raw)"
    return $document
}
function Admin([string]$verb,[int]$replicas=0) {
    $result=Invoke-Dc 'Admin' $verb $replicas
    $intent=Intent $result
    Write-Host "Admin $verb`: $($result.Output)"
    return [pscustomobject]@{ Result=$result; Intent=$intent }
}
function Get-Site {
    $result=Invoke-Dc 'Admin' 'get'
    return @($result.Output | ConvertFrom-Json)
}
function Http([string]$node,[string]$hostName=$SiteName) {
    $lines=& $curl -s -i -m 5 -H "Host: $hostName" "http://$(Address $node)/" 2>&1
    $exit=$LASTEXITCODE
    $text=($lines | ForEach-Object { "$_" }) -join "`n"
    $status=if($text -match '(?m)^HTTP/\S+ (\d{3})') { [int]$Matches[1] } else { 0 }
    $realization=if($text -match '(?m)^X-VPS-Realization: (.+?)\s*$') { $Matches[1] } else { $null }
    [pscustomobject]@{ Node=$node; Host=$hostName; CurlExit=$exit; Status=$status; Realization=$realization
        Marker=$text.Contains($marker); StatusLine=$(if($text -match '(?m)^(HTTP/\S+ \d{3}.*?)\s*$') { $Matches[1] } else { $null }) }
}
# Serving nodes must answer for the site with the observed realization; every other node must not.
function Check-Http([string]$case,$identities,[string[]]$serving) {
    $results=foreach($node in $nodes) {
        $r=Http $node
        if($serving -contains $node) {
            $identity=$identities[$domainOf[$node]]
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
function Manage([string]$node,[string]$case,[int]$expected,[int]$seconds=240) {
    $null=Invoke-Node $node 'Run' $case
    $status=Wait-Status $node $case { param($s) $null -ne $s.ManagerExit } "$case manager exit" $seconds
    Assert ($status.ManagerExit -eq '0') "Manager failed on $node/$case`: $($status.Manager -join "`n") $($status.ManagerError -join ' ')"
    $converged=@($status.Manager | Where-Object { $_ -like 'Result=Converged;*' })
    Assert ($converged.Count -eq 1) "No convergence line on $node/$case."
    Assert ($converged[0] -match '^Result=Converged; desired=(\w+); required=(\d+); starts=(\d+); stops=(\d+); realizations=\[(.*)\]; at=') 'Unparsed convergence.'
    $desired=$Matches[1]; $required=[int]$Matches[2]; $starts=[int]$Matches[3]; $stops=[int]$Matches[4]; $list=$Matches[5]
    $identities=@{}
    foreach($entry in @($list -split '; ' | Where-Object { $_ })) {
        Assert ($entry -match '^node=([A-Za-z0-9-]+),domain=(domain-\d),state=Running,pid=(\d+),startTicks=(\d+),runId=([0-9a-f-]+)$') "Unparsed realization: $entry"
        $machine=$nodes | Where-Object { $_ -ieq $Matches[1] }
        Assert ($machine -and $domainOf[$machine] -eq $Matches[2]) "Realization $($Matches[2]) observed on $($Matches[1])."
        Assert (-not $identities.ContainsKey($Matches[2])) "Duplicate $($Matches[2])."
        $identities[$Matches[2]]="$machine/pid=$($Matches[3])/startTicks=$($Matches[4])/runId=$($Matches[5])"
    }
    Assert ($required -eq $expected -and $identities.Count -eq $expected) "Expected $expected realizations after $case; required=$required observed=$($identities.Count)."
    for($k=1; $k -le $expected; $k++) { Assert $identities.ContainsKey("domain-$k") "$case missing required domain-$k." }
    $usable=@($status.Manager | Where-Object { $_ -like 'Authority usable:*' })
    Assert ($usable.Count -eq 1) "No authority establishment on $node/$case."
    $withheld=@($status.Manager | Where-Object { $_ -like 'Authority establishment:*effects=withheld*' }).Count
    $decisions=@($status.Manager | Where-Object { $_ -like 'Decision=*' })
    $finalized=@($status.Manager | Where-Object { $_ -like 'Result=Finalized;*' })
    $result=[pscustomobject]@{ Case=$case; Owner=$node; Desired=$desired; Required=$required; Starts=$starts; Stops=$stops
        Identities=$identities; Generations=$usable[0]; WithheldRounds=$withheld; Decisions=$decisions
        Finalized=$(if($finalized.Count) { $finalized[0] } else { $null }); Status=$status }
    Write-Host "$case on $node`: desired=$desired required=$required starts=$starts stops=$stops withheldRounds=$withheld; $($usable[0])"
    foreach($decision in $decisions) { Write-Host "  $decision" }
    foreach($domain in @('domain-1','domain-2','domain-3')) { if($identities.ContainsKey($domain)) { Write-Host "  $domain = $($identities[$domain])" } }
    return $result
}
function Record($manage,$intent,$http,$get,[hashtable]$extra=@{}) {
    $entry=[ordered]@{ Case=$manage.Case; Owner=$manage.Owner; Intent=$intent; Generations=$manage.Generations; WithheldRounds=$manage.WithheldRounds
        Decisions=$manage.Decisions; Starts=$manage.Starts; Stops=$manage.Stops; Identities=$manage.Identities; Finalized=$manage.Finalized
        Http=@($http | ForEach-Object { "$($_.Node): $($_.StatusLine) $($_.Realization)" }); Get=$get }
    foreach($key in $extra.Keys) { $entry[$key]=$extra[$key] }
    $summary.Add([pscustomobject]$entry)
}
function Same($left,$right,[string[]]$domains,[string]$what) {
    foreach($domain in $domains) { Assert ($left.Identities[$domain] -ceq $right.Identities[$domain]) "$what`: $domain identity changed." }
}
function Running-Nodes($site) { @($site.RunningNodes | ForEach-Object { "$_".ToUpperInvariant() } | Sort-Object) -join ',' }
function Children([int[]]$expected) {
    for($i=0; $i -lt 3; $i++) {
        $s=Invoke-Node $nodes[$i] 'Status'
        Assert (@($s.Children).Count -eq $expected[$i]) "$($nodes[$i]) hosts $(@($s.Children).Count) realizations; expected $($expected[$i])."
    }
}
try {
    foreach($node in $nodes) {
        Copy-To $node (Join-Path $PSScriptRoot 'day-05.5-node.ps1') $remote
        $staged.Add($node)
        $snapshot=Invoke-Node $node 'Inspect'; Healthy $snapshot
        Assert ($snapshot.LocalNode -ieq $node) 'Wrong guest.'
        Assert (@($snapshot.Groups | Where-Object Name -like 'ControlPlaneExperiment-Day5*').Count -eq 0) 'Prior experiment group exists.'
        if($null -eq $baseline) { $baseline=$snapshot }
    }
    Copy-To $dc (Join-Path $PSScriptRoot 'day-05.5-dc.ps1') $remote
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
    foreach($machine in $nodes+@($dc)) {
        Copy-To $machine $archive $zipRemote
        if($machine -eq $dc) { $null=Invoke-Dc 'Prepare' } else { $null=Invoke-Node $machine 'Prepare' }
    }
    # Content and shared intent storage are staged outside the control plane (no SMB provisioning by VPS).
    $staging=Invoke-Dc 'Stage'
    $rootPath=$staging.RootPath; $store=$staging.Store
    Write-Host "Staged RootPath=$rootPath (marker $marker); intent store=$store (DC-local $($staging.LocalStore))."
    $null=Invoke-Node 'Node-A' 'Create'
    foreach($node in $nodes) {
        $open=Invoke-Node $node 'Open'
        Assert (@($open.Port80Listeners).Count -eq 0 -or @($open.Port80Listeners | Where-Object { $_ -ne 4 }).Count -eq 0) "$node port 80 is owned by another process."
        $null=Invoke-Node $node 'Fence'
        $null=Wait-Status $node 'none' { param($s) ($s.Fence -join "`n") -match 'Domain fence serving' } "$node fence serving"
    }

    # BASELINE: no site intent, no realizations, nobody serves the virtual host.
    $base=Admin 'show'
    Assert ($null -eq $base.Intent) 'Site intent already exists.'
    Assert (@(Get-Site).Count -eq 0) 'Get-VPSSite reported a site before New.'
    Children @(0,0,0)
    $null=Check-Http 'baseline' @{} @()

    # EXPERIMENT 1: administrator declares the site; reconciliation realizes it on domain-1..3.
    $new=Admin 'new' 3
    Assert ($new.Intent.Name -eq $SiteName -and $new.Intent.RootPath -eq $rootPath -and $new.Intent.Desired -eq 'Running' -and $new.Intent.DesiredReplicas -eq 3) 'Exp1 intent mismatch.'
    Move-Authority 'Node-A'
    $e1=Manage 'Node-A' 'exp1' 3
    Assert ($e1.Starts -eq 3 -and $e1.Stops -eq 0) 'Exp1 expected 3 starts, 0 stops.'
    Assert (@($e1.Identities.Values | ForEach-Object { ($_ -split '/',2)[1] } | Sort-Object -Unique).Count -eq 3) 'Exp1 identities not distinct.'
    Children @(1,1,1)
    $h1=Check-Http 'exp1' $e1.Identities $nodes
    $other=Http 'Node-A' 'other.contoso.com'
    Assert ($other.Status -ne 200) 'An unrelated Host was served by the site realization.'
    Write-Host "  HTTP Node-A Host=other.contoso.com -> $($other.StatusLine) (no virtual site registered for that host)"
    $g1=@(Get-Site)
    Assert ((Running-Nodes $g1[0]) -eq 'NODE-A,NODE-B,NODE-C') "Exp1 Get-VPSSite RunningNodes=$(Running-Nodes $g1[0])."
    Record $e1 $new.Intent $h1 $g1 @{ OtherHost="Node-A: $($other.StatusLine)" }

    # EXPERIMENT 2: management moves; service does not.
    Move-Authority 'Node-B'
    $e2=Manage 'Node-B' 'exp2' 3
    Assert ($e2.Starts -eq 0 -and $e2.Stops -eq 0) 'Exp2 expected zero effects.'
    Same $e1 $e2 @('domain-1','domain-2','domain-3') 'Exp2 adoption'
    $h2=Check-Http 'exp2' $e2.Identities $nodes
    Record $e2 $new.Intent $h2 @(Get-Site)

    # EXPERIMENT 3: declarative scale-down; the reconciler, not the administrator, picks the effect.
    $set=Admin 'set' 2
    Assert ($set.Intent.DesiredReplicas -eq 2 -and $set.Intent.Desired -eq 'Running' -and $set.Intent.SiteId -eq $new.Intent.SiteId) 'Exp3 intent mismatch.'
    $e3=Manage 'Node-B' 'exp3' 2
    Assert ($e3.Starts -eq 0 -and $e3.Stops -eq 1) 'Exp3 expected exactly one stop.'
    Assert (@($e3.Decisions | Where-Object { $_ -like 'Decision=Stop; reason=not-required-domain; domain=domain-3;*' }).Count -eq 1) 'Exp3 did not stop domain-3.'
    Same $e2 $e3 @('domain-1','domain-2') 'Exp3 keepers'
    Children @(1,1,0)
    $h3=Check-Http 'exp3' $e3.Identities @('Node-A','Node-B')
    $g3=@(Get-Site)
    Assert ((Running-Nodes $g3[0]) -eq 'NODE-A,NODE-B') "Exp3 Get-VPSSite RunningNodes=$(Running-Nodes $g3[0])."
    Record $e3 $set.Intent $h3 $g3

    # EXPERIMENT 4: suspend keeps intent and converges to zero; resume rebuilds from intent + fresh observation.
    $suspend=Admin 'suspend'
    Assert ($suspend.Intent.Desired -eq 'Stopped' -and $suspend.Intent.DesiredReplicas -eq 2 -and $suspend.Intent.RootPath -eq $rootPath) 'Exp4 suspend intent mismatch.'
    $e4a=Manage 'Node-B' 'exp4a' 0
    Assert ($e4a.Starts -eq 0 -and $e4a.Stops -eq 2 -and $e4a.Desired -eq 'Stopped') 'Exp4a expected two stops.'
    Children @(0,0,0)
    $h4a=Check-Http 'exp4a' @{} @()
    $after=Admin 'show'
    Assert ($after.Intent.SiteId -eq $new.Intent.SiteId -and $after.Intent.Desired -eq 'Stopped') 'Exp4 site object did not survive suspend.'
    Record $e4a $after.Intent $h4a @(Get-Site)
    $resume=Admin 'resume'
    Assert ($resume.Intent.Desired -eq 'Running' -and $resume.Intent.DesiredReplicas -eq 2) 'Exp4 resume intent mismatch.'
    $e4b=Manage 'Node-B' 'exp4b' 2
    Assert ($e4b.Starts -eq 2 -and $e4b.Stops -eq 0) 'Exp4b expected two starts.'
    foreach($domain in @('domain-1','domain-2')) { Assert ($e4b.Identities[$domain] -cne $e3.Identities[$domain]) "Exp4b $domain was not a new incarnation." }
    Children @(1,1,0)
    $h4b=Check-Http 'exp4b' $e4b.Identities @('Node-A','Node-B')
    Record $e4b $resume.Intent $h4b @(Get-Site)

    # EXPERIMENT 5: uncooperative management failure on Node-B (which also serves domain-2).
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
    $h5pre=Check-Http 'exp5-before-manager' $e4b.Identities @('Node-A','Node-B')
    $e5=Manage 'Node-C' 'exp5' 2 360
    Assert ($e5.Starts -eq 0 -and $e5.Stops -eq 0) 'Exp5 expected zero effects.'
    Same $e4b $e5 @('domain-1','domain-2') 'Exp5 adoption'
    $h5=Check-Http 'exp5' $e5.Identities @('Node-A','Node-B')
    Record $e5 $resume.Intent $h5 @(Get-Site) @{ Failover="owner=Node-C at $($failed.At); nodes=$($failed.Nodes -join ',')"
        HttpBeforeManager=@($h5pre | ForEach-Object { "$($_.Node): $($_.StatusLine)" }) }

    # EXPERIMENT 6: realization failure on Node-A; the failover authority repairs exactly that domain.
    $kill=Invoke-Node 'Node-A' 'KillWorkload'
    Write-Host "Killed Node-A realization PID $($kill.KilledProcessId) at $($kill.At)."
    $h6pre=Check-Http 'exp6-before-repair' $e5.Identities @('Node-B')
    $e6=Manage 'Node-C' 'exp6' 2
    Assert ($e6.Starts -eq 1 -and $e6.Stops -eq 0) 'Exp6 expected one replacement start.'
    Assert (@($e6.Decisions | Where-Object { $_ -like 'Decision=Start; reason=required-domain-empty; domain=domain-1;*' }).Count -eq 1) 'Exp6 did not start domain-1.'
    Same $e5 $e6 @('domain-2') 'Exp6 peer'
    Assert ($e6.Identities['domain-1'] -cne $e5.Identities['domain-1'] -and $e6.Identities['domain-1'] -notmatch "pid=$($kill.KilledProcessId)/") 'Exp6 did not replace domain-1.'
    Children @(1,1,0)
    $h6=Check-Http 'exp6' $e6.Identities @('Node-A','Node-B')
    Record $e6 $resume.Intent $h6 @(Get-Site) @{ HttpBeforeRepair=@($h6pre | ForEach-Object { "$($_.Node): $($_.StatusLine)" }) }

    # EXPERIMENT 7: remove = absorbing tombstone; realizations converge away; then the manager deletes intent.
    $remove=Admin 'remove'
    Assert ($remove.Intent.Desired -eq 'Removed' -and $remove.Intent.SiteId -eq $new.Intent.SiteId) 'Exp7 tombstone mismatch.'
    $refused=$null
    try { $null=Admin 'resume' } catch { $refused="$_" }
    Assert ($refused -match 'Removed is terminal') 'Resume of a removed site was not refused.'
    Write-Host "  Resume after Remove refused: Removed is terminal."
    $e7=Manage 'Node-C' 'exp7' 0
    Assert ($e7.Starts -eq 0 -and $e7.Stops -eq 2 -and $e7.Desired -eq 'Removed') 'Exp7 expected two stops.'
    Assert ($e7.Finalized -match '^Result=Finalized; intentDeleted=True;') "Exp7 not finalized: $($e7.Finalized)"
    $final=Admin 'show'
    Assert ($null -eq $final.Intent) 'Exp7 durable intent still present.'
    Assert (@(Get-Site).Count -eq 0) 'Exp7 Get-VPSSite still reports the site.'
    Children @(0,0,0)
    $h7=Check-Http 'exp7' @{} @()
    Record $e7 $remove.Intent $h7 @() @{ FinalIntentDocuments=@($final.Result.After).Count; Finalized=$e7.Finalized }
    $fenceLogs=foreach($node in $nodes) { $s=Invoke-Node $node 'Status'; "$node generation=$($s.Generation)" }
    Write-Host ($fenceLogs -join '; ')
}
finally {
    $summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'summary.json')
    $errors=[Collections.Generic.List[string]]::new()
    foreach($machine in @($staged | Sort-Object { if($_ -eq 'Node-B') { 0 } else { 1 } })) {
        try {
            if($machine -eq $dc) { $after=Invoke-Dc 'Cleanup'; Assert (@($after.Shares).Count -eq 0) 'DC shares remain.'; continue }
            $after=Invoke-Node $machine 'Cleanup'; Healthy $after
            Assert ((@($after.Groups | Where-Object Name -notlike 'ControlPlaneExperiment-*') | ConvertTo-Json -Compress) -ceq (@($baseline.Groups) | ConvertTo-Json -Compress)) 'Unrelated group state changed.'
            Assert ((@($after.Resources) | ConvertTo-Json -Compress) -ceq (@($baseline.Resources) | ConvertTo-Json -Compress)) 'Unrelated resource state changed.'
        } catch { $errors.Add("$machine cleanup: $_") }
    }
    if($errors.Count) { $errors | Set-Content (Join-Path $evidence 'cleanup-errors.txt'); throw ($errors -join "`n") }
}
Write-Host "PASS: Day 5.5 administrator intent for $SiteName realized, moved, scaled, suspended/resumed, failed over, repaired and removed. Evidence: $evidence"
