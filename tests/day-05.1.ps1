#Requires -Version 7.0
param([string] $ManifestPath = 'C:\vm\labs\wfclab\environment.json')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "External lab manifest is absent: $ManifestPath. This test does not provision or repair the lab."
}
# Reload pins and identity for each invocation; never fall back to normal user SSH configuration.
$lab = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$nodeNames = @('Node-A', 'Node-B', 'Node-C')
foreach ($name in $nodeNames) {
    if (@($lab.Machines | Where-Object Name -eq $name).Count -ne 1) {
        throw "External lab manifest must supply exactly one $name."
    }
}
foreach ($path in @($lab.SSH.PrivateKey, $lab.SSH.KnownHosts)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Dedicated lab SSH identity or pins are absent.' }
}
if ($lab.Cluster.Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw 'Invalid cluster name in manifest.' }
$sshOptions = @('-F', 'NUL', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
    '-o', 'IdentitiesOnly=yes', '-o', "UserKnownHostsFile=$($lab.SSH.KnownHosts)",
    '-o', 'GlobalKnownHostsFile=NUL', '-o', 'ConnectTimeout=10', '-i', $lab.SSH.PrivateKey)
$runId = [guid]::NewGuid().ToString('N')
$groupName = "ControlPlaneExperiment-Day51-$runId"
$remoteScript = "C:\Windows\Temp\ControlPlaneExperiment-Day51-$runId.ps1"
$remoteArchive = "C:\Windows\Temp\ControlPlaneExperiment-Day51-$runId.zip"
$evidence = (New-Item -ItemType Directory -Path (Join-Path $root ".state\day-05.1-$runId")).FullName
$stagedNodes = [System.Collections.Generic.List[string]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$cleanup = [System.Collections.Generic.List[object]]::new()
$groupMayExist = $false

function Assert($condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Node([string] $name) {
    $machine = $lab.Machines | Where-Object Name -eq $name
    Assert ($machine.Address -match '^\d{1,3}(\.\d{1,3}){3}$') "Invalid address for $name."
    return $machine
}

function Copy-ToNode([string] $name, [string] $source, [string] $destination) {
    $machine = Node $name
    & scp.exe @sshOptions -q $source "$($lab.SSH.User)@$($machine.Address):$destination"
    if ($LASTEXITCODE -ne 0) { throw "Pinned SCP failed for $name." }
}

function Invoke-Node([string] $name, [string] $action, [string] $target = '') {
    $machine = Node $name
    $arguments = "powershell.exe -NoLogo -NoProfile -NonInteractive -File $remoteScript -Action $action -RunId $runId -ClusterName $($lab.Cluster.Name)"
    if ($target) { $arguments += " -TargetNode $target" }
    $output = @(& ssh.exe @sshOptions -l $lab.SSH.User $machine.Address $arguments)
    if ($LASTEXITCODE -ne 0) { throw "Pinned SSH $action failed on $name." }
    $text = $output -join "`n"
    $text | Set-Content -LiteralPath (Join-Path $evidence "$($results.Count)-$name-$action-$target.json")
    $value = $text | ConvertFrom-Json
    $results.Add([pscustomobject]@{ Action = $action; Node = $name; Target = $target; Evidence = $value })
    return $value
}

function Assert-Healthy($snapshot) {
    Assert ($snapshot.Cluster -ieq $lab.Cluster.Name) 'Cluster name differs from manifest.'
    Assert ($snapshot.Domain -ieq $lab.Domain) 'Guest domain differs from manifest.'
    Assert ($snapshot.OS -like '*Windows Server 2025*') 'Expected Windows Server 2025.'
    Assert ((@($snapshot.Nodes.Name | Sort-Object) -join ',') -ceq ($nodeNames -join ',')) 'Unexpected cluster nodes.'
    Assert (@($snapshot.Nodes | Where-Object State -ne 'Up').Count -eq 0) 'Required cluster nodes are not all Up.'
    $core = @($snapshot.Groups | Where-Object Name -eq 'Cluster Group')
    Assert ($core.Count -eq 1 -and $core[0].State -eq 'Online') 'Cluster core group is not Online.'
    Assert (@($snapshot.Resources | Where-Object Group -eq 'Cluster Group' |
        Where-Object State -ne 'Online').Count -eq 0) 'Cluster core resource is not Online.'
}

try {
    foreach ($name in $nodeNames) {
        Copy-ToNode $name (Join-Path $PSScriptRoot 'day-05.1-node.ps1') $remoteScript
        $stagedNodes.Add($name)
        $snapshot = Invoke-Node $name 'Inspect'
        Assert-Healthy $snapshot
        Assert ($snapshot.LocalNode -ieq $name) 'SSH executed on the wrong guest.'
        Assert (@($snapshot.Groups | Where-Object Name -like 'ControlPlaneExperiment-Day51-*').Count -eq 0) `
            'Existing Day 5.1 group found; inspect prior cleanup before starting another run.'
    }
    $baseline = $results[0].Evidence
    $payload = Join-Path $evidence 'payload'
    & dotnet publish (Join-Path $root 'src\ControlPlaneExperiment\ControlPlaneExperiment.csproj') `
        -c Release -r win-x64 --self-contained true -o $payload *> (Join-Path $evidence 'publish.log')
    Assert ($LASTEXITCODE -eq 0) 'Self-contained publish failed; see publish.log.'
    $stateFile = Join-Path $payload 'intent.json'
    & (Join-Path $payload 'ControlPlaneExperiment.exe') intent $stateFile --replicas 3 | Out-Host
    Assert ($LASTEXITCODE -eq 0) 'Intent creation failed.'
    $intentHash = (Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash
    $executableHash = (Get-FileHash -LiteralPath (Join-Path $payload 'ControlPlaneExperiment.exe') -Algorithm SHA256).Hash
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $archive = Join-Path $evidence 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $archive)
    foreach ($name in $nodeNames) {
        Copy-ToNode $name $archive $remoteArchive
        $prepared = Invoke-Node $name 'Prepare'
        Assert ($prepared.StateHash -ceq $intentHash -and $prepared.ExecutableHash -ceq $executableHash) `
            'Guest did not receive the exact binary and intent.'
    }
    # Set before Create so a lost SSH response still enters checked cleanup of this exact name.
    $groupMayExist = $true
    $created = Invoke-Node 'Node-A' 'Create'
    Assert-Healthy $created
    foreach ($owner in $nodeNames) {
        $moved = Invoke-Node 'Node-A' 'Move' $owner
        $group = @($moved.Groups | Where-Object Name -eq $groupName)
        Assert ($group.Count -eq 1 -and $group[0].Owner -ieq $owner -and $group[0].State -in @('Online', 'Offline')) `
            'Wrong cluster authority placement.'
        foreach ($name in $nodeNames) {
            $observation = Invoke-Node $name 'Observe'
            Assert ($observation.LocalNode -ieq $name) 'Manager evidence came from the wrong node.'
            Assert ($observation.WorkloadId -eq $state.WorkloadId) 'Logical intent changed.'
            Assert ($observation.StateHashBefore -ceq $intentHash -and $observation.StateHashAfter -ceq $intentHash) `
                'Authority movement or management observation changed durable intent bytes.'
            Assert (($observation.StateProperties -join ',') -ceq 'WorkloadId,Desired,Replicas') 'Unexpected durable state fields.'
            $lines = @($observation.Output)
            $checks = @($lines | Where-Object { $_ -like 'Cluster authority:*' })
            $passes = @($lines | Where-Object { $_ -like 'Cluster reconciliation:*' })
            Assert ($checks.Count -eq 2 -and $passes.Count -eq 2) 'Expected two freshly gated passes per manager.'
            $expected = ($name -ieq $owner).ToString().ToLowerInvariant()
            foreach ($line in $checks) {
                Assert ($line -match "localNode=$name; ownerNode=$owner; groupState=$($group[0].State); nodeState=Up; authoritative=$expected;") `
                    "Wrong guest-derived authority decision: $line"
            }
            foreach ($line in $passes) {
                if ($name -ieq $owner) {
                    Assert ($line -match 'admission=admitted; reconciliationAttempted=true;' -and
                        $line -match 'desiredReplicas=3; liveCount=0;' -and $line -match 'scope=local-observation-only;') `
                        'Owner did not enter bounded reconciliation observation.'
                }
                else {
                    Assert ($line -match 'admission=skipped;' -and $line -match 'reconciliationAttempted=false;') `
                        'Non-owner entered authoritative reconciliation.'
                }
                Assert ($line -match 'effects=disabled; starts=0; stops=0\.') 'Cluster probe attempted workload effects.'
            }
            Assert (@($lines | Where-Object { $_ -match '^Decision=|^Action=(start|stop)' }).Count -eq 0) `
                'Unexpected workload effect decision.'
            Write-Host "Owner=$owner; guest=$name; authoritative=$expected; passes=2; intent=$intentHash; starts=0; stops=0."
        }
    }
    Assert ((Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash -ceq $intentHash) 'Host intent changed.'
}
finally {
    # Attempt every cleanup even if another node is unavailable, then fail explicitly on any omission.
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
    if ($groupMayExist) {
        try {
            $after = Invoke-Node 'Node-A' 'RemoveGroup'
            Assert-Healthy $after
            Assert (($after.Groups | ConvertTo-Json -Compress) -ceq ($baseline.Groups | ConvertTo-Json -Compress)) `
                'Unrelated group ownership/state differs from preflight.'
            Assert (($after.Resources | ConvertTo-Json -Compress) -ceq ($baseline.Resources | ConvertTo-Json -Compress)) `
                'Unrelated cluster resources differ from preflight.'
            $cleanup.Add([pscustomobject]@{ GroupRemoved = $true; ClusterHealthy = $true; UnrelatedStateUnchanged = $true })
        }
        catch { $cleanupErrors.Add("Group cleanup/health verification: $_") }
    }
    foreach ($name in $stagedNodes) {
        try { $cleanup.Add((Invoke-Node $name 'Cleanup')) }
        catch { $cleanupErrors.Add("Staging cleanup on $name`: $_") }
    }
    [pscustomobject]@{ RunId = $runId; Group = $groupName; Results = @($results); Cleanup = @($cleanup); CleanupErrors = @($cleanupErrors) } |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
    if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join "`n") }
}
Write-Host "PASS: Day 5.1 live cluster ownership, owner-only observation admission, unchanged intent, and checked cleanup. Evidence: $evidence"
