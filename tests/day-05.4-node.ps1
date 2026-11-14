#Requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Prepare','Create','Move','Owners','Open','Fence','Run','Status','KillWorkload','KillClusSvc','Cleanup')]
    [string] $Action,
    [Parameter(Mandatory)][guid] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string] $ClusterName,
    [ValidatePattern('^Node-[ABC](,Node-[ABC])*$')][string] $TargetNode,
    [ValidateSet('none','exp1','exp2','exp3','exp4','exp5')][string] $Case = 'none',
    [ValidatePattern('^domain-[1-3]$')][string] $ExecutionDomain = 'domain-1',
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}:\d+,\d{1,3}(\.\d{1,3}){3}:\d+,\d{1,3}(\.\d{1,3}){3}:\d+$')][string] $Fences = '127.0.0.1:47053,127.0.0.1:47053,127.0.0.1:47053'
)
$ErrorActionPreference='Stop'
$WarningPreference='SilentlyContinue'
Set-StrictMode -Version Latest
$token=$RunId.ToString('N')
$groupName="ControlPlaneExperiment-Day54-$token"
$ruleName="ControlPlaneExperiment-Day54-$token"
$directory=Join-Path $env:ProgramData "ControlPlaneExperiment\day-05.4-$token"
$archive=Join-Path $env:windir "Temp\ControlPlaneExperiment-Day54-$token.zip"
$fenceGates=Join-Path $directory 'fence'
$generationFile=Join-Path $fenceGates 'generation'
$managerGates=Join-Path $directory "manager-$Case"
$stateFile=Join-Path $directory 'intent.json'
$assembly=Join-Path $directory 'ControlPlaneExperiment.dll'
$port=[int](($Fences -split ',')[0] -split ':')[1]

function Snapshot {
    Import-Module FailoverClusters -ErrorAction Stop -WarningAction SilentlyContinue
    if ((Get-Cluster).Name -ine $ClusterName) { throw 'Wrong local cluster.' }
    [pscustomobject]@{
        At=[datetimeoffset]::UtcNow.ToString('O'); LocalNode=$env:COMPUTERNAME; Cluster=(Get-Cluster).Name
        Nodes=@(Get-ClusterNode | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.State)" })
        Groups=@(Get-ClusterGroup | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; Owner="$($_.OwnerNode)"; State=$_.State.ToString() }
        })
        Resources=@(Get-ClusterResource | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; Group="$($_.OwnerGroup)"; State=$_.State.ToString() }
        })
    }
}
function Processes {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($directory+'\',[StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object { [pscustomobject]@{ ProcessId=$_.ProcessId; CommandLine=$_.CommandLine } })
}
function Workloads {
    $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    @(Processes | Where-Object CommandLine -like "*$assembly*--workload $($state.WorkloadId) *")
}
function Read-Log([string]$path) {
    if(Test-Path -LiteralPath $path) {
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $reader=[IO.StreamReader]::new($stream)
        try { $reader.ReadToEnd() -split '\r?\n' | Where-Object { $_ -ne '' } }
        finally { $reader.Dispose() }
    }
}
function Launch([string[]]$arguments,[string]$gates,[int]$boundSeconds) {
    New-Item -ItemType Directory -Path $gates -Force | Out-Null
    $env:PATH=$directory+';'+$env:PATH
    $process=Start-Process -FilePath (Join-Path $directory 'ControlPlaneExperiment.exe') -ArgumentList $arguments `
        -RedirectStandardOutput (Join-Path $gates 'process.log') -RedirectStandardError (Join-Path $gates 'process.stderr') -PassThru
    $null=$process.Handle # PS 5.1 reports a null ExitCode unless the handle is cached while the process is alive.
    if(-not $process.WaitForExit($boundSeconds*1000)) { throw 'Process exceeded experiment bound.' }
    [IO.File]::WriteAllText((Join-Path $gates 'exit.txt'),"$($process.ExitCode)")
    exit $process.ExitCode
}
switch($Action) {
    'Inspect' { Snapshot | ConvertTo-Json -Depth 6 -Compress }
    'Prepare' {
        if(Test-Path -LiteralPath $directory) { throw 'Staging already exists.' }
        Expand-Archive -LiteralPath $archive -DestinationPath $directory
        [pscustomobject]@{ Prepared=$true; LocalNode=$env:COMPUTERNAME } | ConvertTo-Json -Compress
    }
    'Create' {
        $null=Snapshot
        if(@(Get-ClusterGroup | Where-Object Name -eq $groupName).Count) { throw 'Group already exists.' }
        Add-ClusterGroup -Name $groupName | Out-Null
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'Move' {
        $null=Snapshot
        $group=Get-ClusterGroup -Name $groupName
        if("$($group.OwnerNode)" -ine $TargetNode) { Move-ClusterGroup -Name $groupName -Node $TargetNode -Wait 30 | Out-Null }
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'Owners' {
        $null=Snapshot
        Set-ClusterOwnerNode -Group $groupName -Owners $TargetNode.Split(',') | Out-Null
        [pscustomobject]@{ Owners=@((Get-ClusterOwnerNode -Group $groupName).OwnerNodes | ForEach-Object { "$_" }); Snapshot=Snapshot } |
            ConvertTo-Json -Depth 6 -Compress
    }
    'Open' {
        # Experiment-owned inbound rule for this node's fence only; removed by Cleanup.
        New-NetFirewallRule -DisplayName $ruleName -Name $ruleName -Direction Inbound -Protocol TCP -LocalPort $port `
            -RemoteAddress LocalSubnet -Action Allow | Out-Null
        [pscustomobject]@{ Rule=$ruleName; Port=$port } | ConvertTo-Json -Compress
    }
    'Fence' {
        # Long-lived: owns this node's generation and spawns this node's realization in its own session.
        Launch @('fence-execution-domain',$ClusterName,$groupName,"$port",$generationFile,$fenceGates,$ExecutionDomain) $fenceGates 3600
    }
    'Run' {
        Launch (@('experiment-active-active',$stateFile,$ClusterName,$groupName)+($Fences -split ',')) $managerGates 600
    }
    'Status' {
        $snapshot=$null; $clusterError=$null
        try { $snapshot=Snapshot } catch { $clusterError="$_" }
        $exitFile=Join-Path $managerGates 'exit.txt'
        [pscustomobject]@{
            LocalNode=$env:COMPUTERNAME; Case=$Case
            ManagerExit=$(if(Test-Path -LiteralPath $exitFile) { [IO.File]::ReadAllText($exitFile) } else { $null })
            Manager=@(Read-Log (Join-Path $managerGates 'process.log')); ManagerError=@(Read-Log (Join-Path $managerGates 'process.stderr'))
            Fence=@(Read-Log (Join-Path $fenceGates 'process.log'))
            Generation=$(if(Test-Path -LiteralPath $generationFile) { [IO.File]::ReadAllText($generationFile) } else { $null })
            Children=@(Workloads); Snapshot=$snapshot; ClusterError=$clusterError
        } | ConvertTo-Json -Depth 8 -Compress
    }
    'KillWorkload' {
        # Uncooperative realization failure on this node; no manager or fence participates.
        $victims=@(Workloads)
        if($victims.Count -ne 1) { throw "Expected exactly one local realization, found $($victims.Count)." }
        Stop-Process -Id $victims[0].ProcessId -Force
        [pscustomobject]@{ KilledProcessId=$victims[0].ProcessId; At=[datetimeoffset]::UtcNow.ToString('O') } | ConvertTo-Json -Compress
    }
    'KillClusSvc' {
        # Uncooperative loss of this node's WFC participation: no Offline, relinquish or cleanup runs here.
        $service=Get-CimInstance Win32_Service -Filter "Name='ClusSvc'"
        if($service.State -ne 'Running' -or $service.ProcessId -le 0) { throw 'ClusSvc not running.' }
        Stop-Process -Id $service.ProcessId -Force
        [pscustomobject]@{ KilledProcessId=$service.ProcessId; At=[datetimeoffset]::UtcNow.ToString('O') } | ConvertTo-Json -Compress
    }
    'Cleanup' {
        foreach($identity in @(Processes)) { Stop-Process -Id $identity.ProcessId -Force -ErrorAction SilentlyContinue }
        Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        if((Get-Service ClusSvc).Status -ne 'Running') { Start-Service ClusSvc }
        $deadline=[datetime]::UtcNow.AddSeconds(120)
        while($true) {
            try { $snapshot=Snapshot; if(($snapshot.Nodes -join ',') -ceq 'Node-A:Up,Node-B:Up,Node-C:Up') { break } } catch { }
            if([datetime]::UtcNow -ge $deadline) { throw 'Cluster did not return to all nodes Up.' }
            Start-Sleep -Seconds 2
        }
        if(@($snapshot.Groups | Where-Object Name -eq $groupName).Count) { Remove-ClusterGroup -Name $groupName -Force -RemoveResources }
        Start-Sleep -Milliseconds 500
        if(Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        if(Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        Snapshot | ConvertTo-Json -Depth 6 -Compress
        Remove-Item -LiteralPath $PSCommandPath -Force
    }
}
