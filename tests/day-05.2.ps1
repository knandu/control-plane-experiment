#Requires -Version 7.0
param([string] $ManifestPath='C:\vm\labs\wfclab\environment.json')
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
$group="ControlPlaneExperiment-Day52-$id"
$remote="C:\Windows\Temp\ControlPlaneExperiment-Day52-$id.ps1"
$zipRemote="C:\Windows\Temp\ControlPlaneExperiment-Day52-$id.zip"
$evidence=(New-Item -ItemType Directory -Path (Join-Path $root ".state\day-05.2-$id")).FullName
$sessions=[Collections.Generic.List[object]]::new()
$staged=[Collections.Generic.List[string]]::new()
$results=[Collections.Generic.List[object]]::new()
$baseline=$null
function Assert($condition,[string]$message) { if(-not $condition) { throw $message } }
function Address([string]$node) {
    $address=($lab.Machines | Where-Object Name -eq $node).Address
    Assert ($address -match '^\d{1,3}(\.\d{1,3}){3}$') 'Invalid node address.'
    return $address
}
function Arguments([string]$action,[string]$case='baseline',[string]$stage='none',[string]$target='') {
    return "pwsh.exe -NoLogo -NoProfile -NonInteractive -File $remote -Action $action -RunId $id -ClusterName $($lab.Cluster.Name) -Case $case -Stage $stage"+$(if($target) { " -TargetNode $target" })
}
function Invoke-Node([string]$node,[string]$action,[string]$case='baseline',[string]$stage='none',[string]$target='') {
    $info=[Diagnostics.ProcessStartInfo]::new('ssh.exe')
    $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($argument in @($options)+@('-l',$lab.SSH.User,(Address $node),(Arguments $action $case $stage $target))) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($info)
    try {
        $output=$process.StandardOutput.ReadToEndAsync(); $errorOutput=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(45000)) {
            $process.Kill(); $process.WaitForExit()
            throw "SSH $action on $node exceeded 45 seconds."
        }
        Assert ($process.ExitCode -eq 0) "SSH $action on $node failed: $($errorOutput.Result)"
        $text=$output.Result
    } finally { $process.Dispose() }
    $value=$text | ConvertFrom-Json
    $record=[pscustomobject]@{ Node=$node; Action=$action; Evidence=$value }
    $results.Add($record)
    $text | Set-Content -LiteralPath (Join-Path $evidence "$($results.Count)-$node-$action-$case-$stage.json")
    return $value
}
function Copy-ToNode([string]$node,[string]$source,[string]$destination) {
    & scp.exe @options -q $source "$($lab.SSH.User)@$(Address $node):$destination"
    Assert ($LASTEXITCODE -eq 0) "Pinned SCP failed: $node."
}
function Healthy($value) {
    Assert ($value.Cluster -ieq $lab.Cluster.Name) 'Cluster mismatch.'
    Assert (($value.Nodes -join ',') -ceq 'Node-A:Up,Node-B:Up,Node-C:Up') 'Nodes not Up.'
    Assert (@($value.Groups | Where-Object { $_.Name -eq 'Cluster Group' -and $_.State -eq 'Online' }).Count -eq 1) 'Core group unavailable.'
    Assert (@($value.Resources | Where-Object { $_.Group -eq 'Cluster Group' -and $_.State -ne 'Online' }).Count -eq 0) 'Core resources unavailable.'
}
function Move-Authority([string]$target) {
    $snapshot=Invoke-Node 'Node-A' 'Move' -target $target
    $actual=@($snapshot.Groups | Where-Object Name -eq $group)
    Assert ($actual.Count -eq 1 -and $actual[0].Owner -ieq $target -and $actual[0].State -in @('Online','Offline')) 'Move did not complete.'
    return $snapshot
}
function Run([string]$node,[string]$case,[string]$stage='none') {
    $info=[Diagnostics.ProcessStartInfo]::new('ssh.exe')
    $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($argument in @($options)+@('-l',$lab.SSH.User,(Address $node),(Arguments 'Run' $case $stage))) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($info)
    $session=[pscustomobject]@{ Process=$process; Output=$process.StandardOutput.ReadToEndAsync(); Error=$process.StandardError.ReadToEndAsync(); Node=$node; Case=$case }
    $sessions.Add($session)
    return $session
}
function Wait-Stage([string]$node,[string]$case,[string]$stage) {
    $deadline=[datetime]::UtcNow.AddSeconds(45)
    do {
        $status=Invoke-Node $node 'Status' $case
        if($status.Reached -contains $stage) { return $status }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline)
    throw "Witness not reached: $node/$case/$stage."
}
function Finish($session) {
    $null=Invoke-Node $session.Node 'Reset'
    $null=Invoke-Node $session.Node 'Release' $session.Case 'complete'
    Assert ($session.Process.WaitForExit(15000)) 'SSH manager did not exit.'
    Assert ($session.Process.ExitCode -eq 0) "Manager failed: $($session.Error.Result)"
}
try {
    foreach($node in $nodes) {
        Copy-ToNode $node (Join-Path $PSScriptRoot 'day-05.2-node.ps1') $remote
        $staged.Add($node)
        $snapshot=Invoke-Node $node 'Inspect'; Healthy $snapshot
        Assert ($snapshot.LocalNode -ieq $node) 'Wrong guest.'
        Assert (@($snapshot.Groups | Where-Object Name -like 'ControlPlaneExperiment-Day52-*').Count -eq 0) 'Prior Day 5.2 group exists.'
        if($null -eq $baseline) { $baseline=$snapshot }
    }
    $payload=Join-Path $evidence 'payload'
    & dotnet publish (Join-Path $root 'src\ControlPlaneExperiment\ControlPlaneExperiment.csproj') -c Release -r win-x64 --self-contained true -o $payload *> (Join-Path $evidence 'publish.log')
    Assert ($LASTEXITCODE -eq 0) 'Publish failed.'
    # Stage the standard host/resolver alongside the bundled runtime; nothing is installed on guests.
    $dotnet=(Get-Command dotnet.exe).Source
    Copy-Item -LiteralPath $dotnet -Destination (Join-Path $payload 'dotnet.exe')
    $resolver=Get-ChildItem (Join-Path (Split-Path $dotnet -Parent) 'host\fxr') -Directory |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $resolverDestination=New-Item -ItemType Directory -Path (Join-Path $payload "host\fxr\$($resolver.Name)")
    Copy-Item -LiteralPath (Join-Path $resolver.FullName 'hostfxr.dll') -Destination $resolverDestination.FullName
    foreach($case in @('baseline','stale','cold','recheck')) {
        & (Join-Path $payload 'dotnet.exe') (Join-Path $payload 'ControlPlaneExperiment.dll') intent (Join-Path $payload "intent-$case.json") | Out-Host
        Assert ($LASTEXITCODE -eq 0) 'App-local dotnet host/intent failed.'
    }
    $archive=Join-Path $evidence 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payload,$archive)
    foreach($node in $nodes) { Copy-ToNode $node $archive $zipRemote; $null=Invoke-Node $node 'Prepare' }
    $null=Invoke-Node 'Node-A' 'Create'
    $null=Move-Authority 'Node-A'
    $normal=Run 'Node-A' 'baseline'
    $status=Wait-Stage 'Node-A' 'baseline' 'complete'
    Assert ($status.Children.Count -eq 1 -and $status.Children[0].Ready) 'Owner baseline did not create a ready process.'
    Write-Host "Baseline: Node-A created ready PID $($status.Children[0].Identity.ProcessId)."
    Finish $normal
    $old=Run 'Node-A' 'stale' 'decision'
    $paused=Wait-Stage 'Node-A' 'stale' 'decision'
    Assert ($paused.Children.Count -eq 0 -and $paused.Output -match 'Decision=Start') 'No missing-workload pre-effect decision.'
    $null=Move-Authority 'Node-B'
    $null=Invoke-Node 'Node-A' 'Release' 'stale' 'decision'
    $stale=Wait-Stage 'Node-A' 'stale' 'complete'
    Assert ($stale.Children.Count -eq 1 -and $stale.Children[0].Ready -and $stale.Output -match 'observedOwner=Node-B') 'Stale-owner failure not reproduced.'
    Write-Host "LIMITATION REPRODUCED: Node-A started PID $($stale.Children[0].Identity.ProcessId) after verified ownership moved to Node-B."
    Finish $old
    $current=Run 'Node-B' 'cold'
    $cold=Wait-Stage 'Node-B' 'cold' 'complete'
    Assert ($cold.Children.Count -eq 1 -and $cold.Children[0].Ready -and $cold.Output -match 'local=Node-B; owner=Node-B; authoritative=True') 'New owner did not act.'
    Finish $current
    $null=Move-Authority 'Node-A'
    $recheck=Run 'Node-A' 'recheck' 'recheck'
    $checked=Wait-Stage 'Node-A' 'recheck' 'recheck'
    Assert ($checked.Children.Count -eq 0 -and $checked.Output -match 'Boundary recheck:.*authoritative=True') 'Recheck witness missing.'
    $null=Move-Authority 'Node-B'
    $null=Invoke-Node 'Node-A' 'Release' 'recheck' 'recheck'
    $checked=Wait-Stage 'Node-A' 'recheck' 'complete'
    Assert ($checked.Children.Count -eq 1 -and $checked.Children[0].Ready -and $checked.Output -match 'observedOwner=Node-B') 'Unlocked recheck race not reproduced.'
    Write-Host "RECHECK RACE REPRODUCED: valid fresh query still allowed stale PID $($checked.Children[0].Identity.ProcessId)."
    Finish $recheck
}
finally {
    $errors=[Collections.Generic.List[string]]::new()
    foreach($node in $staged) {
        try { $after=Invoke-Node $node 'Cleanup'; Healthy $after
            Assert (($after.Groups | ConvertTo-Json -Compress) -ceq ($baseline.Groups | ConvertTo-Json -Compress)) 'Unrelated group state changed.'
            Assert (($after.Resources | ConvertTo-Json -Compress) -ceq ($baseline.Resources | ConvertTo-Json -Compress)) 'Unrelated resource state changed.'
        } catch { $errors.Add("$node cleanup: $_") }
    }
    foreach($session in $sessions) {
        if(-not $session.Process.WaitForExit(10000)) { $session.Process.Kill(); $errors.Add('SSH session required forced cleanup.') }
        $session.Output.GetAwaiter().GetResult() | Set-Content (Join-Path $evidence "$($session.Node)-$($session.Case)-ssh.log")
        $session.Error.GetAwaiter().GetResult() | Set-Content (Join-Path $evidence "$($session.Node)-$($session.Case)-ssh.stderr")
        $session.Process.Dispose()
    }
    [pscustomobject]@{ RunId=$id; Results=@($results); CleanupErrors=@($errors) } | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $evidence 'results.json')
    if($errors.Count) { throw ($errors -join "`n") }
}
Write-Host "PASS: Day 5.2 reproduced stale Start by a former WFC owner, including after a pre-Start ownership recheck. Evidence: $evidence"
