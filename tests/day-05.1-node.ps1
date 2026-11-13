#Requires -Version 5.1
param(
    [Parameter(Mandatory)][ValidateSet('Inspect', 'Prepare', 'Create', 'Move', 'Observe', 'RemoveGroup', 'Cleanup')]
    [string] $Action,
    [Parameter(Mandatory)][guid] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string] $ClusterName,
    [ValidateSet('Node-A', 'Node-B', 'Node-C')][string] $TargetNode
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$token = $RunId.ToString('N')
$groupName = "ControlPlaneExperiment-Day51-$token"
$directory = Join-Path $env:ProgramData "ControlPlaneExperiment\day-05.1-$token"
$archive = Join-Path $env:windir "Temp\ControlPlaneExperiment-Day51-$token.zip"
if ($Action -ne 'Cleanup') {
    Import-Module FailoverClusters -ErrorAction Stop
    if ((Get-Cluster).Name -ine $ClusterName) { throw 'Local cluster does not match the manifest.' }
}

function Snapshot {
    [pscustomobject]@{
        At = [datetimeoffset]::UtcNow.ToString('O')
        LocalNode = $env:COMPUTERNAME
        Cluster = (Get-Cluster).Name
        Domain = (Get-CimInstance Win32_ComputerSystem).Domain
        OS = (Get-CimInstance Win32_OperatingSystem).Caption
        Nodes = @(Get-ClusterNode | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; State = $_.State.ToString() }
        })
        Groups = @(Get-ClusterGroup | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Owner = $_.OwnerNode.Name; State = $_.State.ToString() }
        })
        Resources = @(Get-ClusterResource | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Group = $_.OwnerGroup.Name; State = $_.State.ToString() }
        })
    }
}

function Owned-Group {
    $group = @(Get-ClusterGroup | Where-Object Name -eq $groupName)
    if ($group.Count -ne 1) { throw "Expected exactly one experiment group: $groupName." }
    if (@($group[0] | Get-ClusterResource).Count -ne 0) {
        throw 'Refusing to move/remove an experiment group containing unexpected resources.'
    }
    return $group[0]
}

switch ($Action) {
    'Inspect' {
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'Prepare' {
        if (Test-Path -LiteralPath $directory) { throw "Run directory already exists: $directory." }
        Expand-Archive -LiteralPath $archive -DestinationPath $directory
        [pscustomobject]@{
            LocalNode = $env:COMPUTERNAME
            StateHash = (Get-FileHash -LiteralPath (Join-Path $directory 'intent.json') -Algorithm SHA256).Hash
            ExecutableHash = (Get-FileHash -LiteralPath (Join-Path $directory 'ControlPlaneExperiment.exe') -Algorithm SHA256).Hash
        } | ConvertTo-Json -Compress
    }
    'Create' {
        if (@(Get-ClusterGroup | Where-Object Name -eq $groupName).Count -ne 0) {
            throw 'Refusing to reuse a pre-existing experiment group.'
        }
        Add-ClusterGroup -Name $groupName | Out-Null
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'Move' {
        if (-not $TargetNode) { throw 'Move requires TargetNode.' }
        $group = Owned-Group
        if ($group.OwnerNode.Name -ine $TargetNode) {
            $group | Move-ClusterGroup -Node $TargetNode -Wait 30 | Out-Null
        }
        $group = Owned-Group
        if ($group.OwnerNode.Name -ine $TargetNode -or $group.State.ToString() -notin @('Online', 'Offline')) {
            throw 'Experiment group did not reach the requested stable owner.'
        }
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'Observe' {
        $stateFile = Join-Path $directory 'intent.json'
        $before = (Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash
        $executable = Join-Path $directory 'ControlPlaneExperiment.exe'
        $output = @(& $executable manage-cluster-observe $stateFile $ClusterName $groupName --effects-disabled 2)
        if ($LASTEXITCODE -ne 0) { throw "Cluster manager exited $LASTEXITCODE." }
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        [pscustomobject]@{
            At = [datetimeoffset]::UtcNow.ToString('O')
            LocalNode = $env:COMPUTERNAME
            StateHashBefore = $before
            StateHashAfter = (Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash
            StateProperties = @($state.PSObject.Properties.Name)
            WorkloadId = $state.WorkloadId
            Output = $output
        } | ConvertTo-Json -Depth 4 -Compress
    }
    'RemoveGroup' {
        $group = @(Get-ClusterGroup | Where-Object Name -eq $groupName)
        if ($group.Count -gt 0) {
            Owned-Group | Remove-ClusterGroup -Force
        }
        if (@(Get-ClusterGroup | Where-Object Name -eq $groupName).Count -ne 0) {
            throw 'Experiment group survived cleanup.'
        }
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'Cleanup' {
        $leftovers = @(Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($directory + '\', [StringComparison]::OrdinalIgnoreCase)
        })
        if ($leftovers.Count -ne 0) { throw 'Experiment processes remain; refusing to remove their files.' }
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        if (Test-Path -LiteralPath $directory) { throw 'Remote staging directory survived cleanup.' }
        [pscustomobject]@{ LocalNode = $env:COMPUTERNAME; Processes = 0; StagingRemoved = $true } |
            ConvertTo-Json -Compress
        Remove-Item -LiteralPath $PSCommandPath -Force
    }
}
