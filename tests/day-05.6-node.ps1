#Requires -Version 5.1
# Day 5.6 node helper. Runs under Windows PowerShell: FailoverClusters objects must bind natively (pwsh 7 loads the
# module through compatibility remoting, where Set-ClusterParameter/Add-ClusterCheckpoint piping fails).
# Configures the clustered "VPS Management" role, reports evidence and injects failures. It never launches a
# manager: the Generic Application resource is the only thing that starts ControlPlaneExperiment.exe vps-serve.
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Prepare','Open','Fence','Create','Start','Move','Restart','KillManager','Status','KillWorkload','Cleanup')]
    [string] $Action,
    [Parameter(Mandatory)][guid] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string] $ClusterName,
    [ValidatePattern('^Node-[ABC]$')][string] $TargetNode,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$')][string] $ExecutionDomain = 'domain-1',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,62}=\d{1,3}(\.\d{1,3}){3}:\d+(,[A-Za-z0-9][A-Za-z0-9._-]{0,62}=\d{1,3}(\.\d{1,3}){3}:\d+)*$')][string] $Fences = 'domain-1=127.0.0.1:47055'
)
$ErrorActionPreference='Stop'
$WarningPreference='SilentlyContinue'
Set-StrictMode -Version Latest
Import-Module FailoverClusters -WarningAction SilentlyContinue
$token=$RunId.ToString('N')
$groupName='VPS Management'
$resourceName='VPS Manager'
$keyPath="SOFTWARE\ControlPlaneExperiment\Day56-$token"
$ruleName="ControlPlaneExperiment-Day56-$token"
$taskPrefix="ControlPlaneExperiment-Day56-$token"
$directory=Join-Path $env:ProgramData "ControlPlaneExperiment\day-05.6-$token"
$archive=Join-Path $env:windir "Temp\ControlPlaneExperiment-Day56-$token.zip"
$exe=Join-Path $directory 'ControlPlaneExperiment.exe'
$assembly=Join-Path $directory 'ControlPlaneExperiment.dll'
$managerLog=Join-Path $directory 'manager.log'
$fenceGates=Join-Path $directory 'fence'
$generationFile=Join-Path $fenceGates 'generation'
$port=[int](($Fences -split ',')[0] -split ':')[-1]
$store="wfc-checkpoint:${ClusterName}:${groupName}:HKLM\$keyPath"

function Now { [datetimeoffset]::UtcNow.ToString('O') }
function Snapshot {
    if ((Get-Cluster).Name -ine $ClusterName) { throw 'Wrong local cluster.' }
    $group=Get-ClusterGroup -Name $groupName -ErrorAction SilentlyContinue
    $resource=Get-ClusterResource -Name $resourceName -ErrorAction SilentlyContinue
    # Explicit $null: in 5.1 an empty $(if ...) subexpression serializes as {} rather than null.
    $resourceInfo=$null
    if($resource) { $resourceInfo=[pscustomobject]@{ Name=$resource.Name; Type="$($resource.ResourceType)"; State="$($resource.State)"
        Owner="$($resource.OwnerNode)"; RestartAction=$resource.RestartAction; RestartThreshold=$resource.RestartThreshold
        RestartPeriod=$resource.RestartPeriod; RestartDelay=$resource.RestartDelay; RetryPeriodOnFailure=$resource.RetryPeriodOnFailure
        PendingTimeout=$resource.PendingTimeout
        Private=@($resource | Get-ClusterParameter | ForEach-Object { "$($_.Name)=$($_.Value)" })
        Checkpoints=@(Get-ClusterCheckpoint -ResourceName $resourceName -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)" }) } }
    $management=$null
    if($group) { $management=[pscustomobject]@{ Group=$group.Name; Owner="$($group.OwnerNode)"; State="$($group.State)"
        FailoverThreshold=$group.FailoverThreshold; FailoverPeriod=$group.FailoverPeriod; Resource=$resourceInfo } }
    [pscustomobject]@{
        At=(Now); LocalNode=$env:COMPUTERNAME; Cluster=(Get-Cluster).Name
        Nodes=@(Get-ClusterNode | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.State)" })
        Groups=@(Get-ClusterGroup | Where-Object Name -ne $groupName | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; Owner="$($_.OwnerNode)"; State="$($_.State)" } })
        Resources=@(Get-ClusterResource | Where-Object Name -ne $resourceName | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; Group="$($_.OwnerGroup)"; State="$($_.State)" } })
        Management=$management
    }
}
function Processes {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($directory+'\',[StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object {
        $parent=Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)" -ErrorAction SilentlyContinue
        [pscustomobject]@{ ProcessId=$_.ProcessId; ParentProcessId=$_.ParentProcessId; Parent=$(if($parent) { $parent.Name })
            Created=$_.CreationDate.ToUniversalTime().ToString('O'); CommandLine=$_.CommandLine } })
}
function Managers { @(Processes | Where-Object { $_.CommandLine -like '* vps-serve *' }) }
function Workloads { @(Processes | Where-Object { $_.CommandLine -like "*$assembly*--workload *" }) }
function Read-Log([string]$path) {
    if(Test-Path -LiteralPath $path) {
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]'ReadWrite, Delete')
        $reader=New-Object IO.StreamReader($stream)
        try { @($reader.ReadToEnd() -split '\r?\n' | Where-Object { $_ -ne '' }) }
        finally { $reader.Dispose() }
    } else { @() }
}
# This node's local copy of the checkpointed key: current intent only on the owner while the role is Online.
function Local-Intent {
    $key=Get-Item -LiteralPath "HKLM:\$keyPath" -ErrorAction SilentlyContinue
    [pscustomobject]@{ KeyPresent=[bool]$key
        Values=@(if($key) { $key.GetValueNames() | Sort-Object | ForEach-Object { [pscustomobject]@{ Name=$_; Kind="$($key.GetValueKind($_))"; Raw=$key.GetValue($_) } } }) }
}
function Wait-Group([string]$state,[int]$seconds) {
    $deadline=[datetime]::UtcNow.AddSeconds($seconds)
    while("$((Get-ClusterGroup -Name $groupName).State)" -ne $state) {
        if([datetime]::UtcNow -ge $deadline) { throw "Group did not reach $state." }
        Start-Sleep -Milliseconds 250
    }
}
function Launch([string]$name,[string[]]$arguments,[string]$gates,[int]$boundSeconds) {
    # Fences (node agents) are harness-launched SYSTEM tasks, as in Day 5.5; they are not the subject of Day 5.6.
    New-Item -ItemType Directory -Path $gates -Force | Out-Null
    $wrapper=Join-Path $gates 'run.cmd'
    $lines=@('@echo off',"set PATH=$directory;%PATH%",
        "`"$exe`" $($arguments -join ' ') >`"$gates\process.log`" 2>`"$gates\process.stderr`"",
        ">`"$gates\exit.txt`" echo %ERRORLEVEL%")
    [IO.File]::WriteAllLines($wrapper,$lines)
    $task="$taskPrefix-$name"
    $principal=New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $boundSeconds) -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $taskAction=New-ScheduledTaskAction -Execute "$env:windir\System32\cmd.exe" -Argument "/d /c `"$wrapper`""
    Register-ScheduledTask -TaskName $task -Action $taskAction -Principal $principal -Settings $settings | Out-Null
    Start-ScheduledTask -TaskName $task
    [pscustomobject]@{ Task=$task; Started=(Now) } | ConvertTo-Json -Compress
}
# Polls the WFC view of the role after a disruptive action, recording each distinct (resource, owner, local manager) state.
function Transitions([int]$seconds) {
    $states=New-Object Collections.Generic.List[string]
    $deadline=[datetime]::UtcNow.AddSeconds($seconds)
    while([datetime]::UtcNow -lt $deadline) {
        $r=Get-ClusterResource -Name $resourceName; $g=Get-ClusterGroup -Name $groupName
        $state="resource=$($r.State) group=$($g.State) owner=$($g.OwnerNode) localManagers=$((@(Managers) | ForEach-Object ProcessId) -join '+')"
        if($states.Count -eq 0 -or $states[$states.Count-1].Substring(13) -ne $state) {
            $states.Add("$([datetimeoffset]::UtcNow.ToString('HH:mm:ss.fff')) $state")
        }
        Start-Sleep -Milliseconds 200
    }
    ,$states.ToArray()
}
switch($Action) {
    'Inspect' {
        [pscustomobject]@{ Snapshot=Snapshot; ExperimentKeys=@(Get-ChildItem 'HKLM:\SOFTWARE\ControlPlaneExperiment' -ErrorAction SilentlyContinue | ForEach-Object Name)
            Staging=@(Get-ChildItem (Join-Path $env:ProgramData 'ControlPlaneExperiment') -Directory -Filter 'day-05.6-*' -ErrorAction SilentlyContinue | ForEach-Object Name)
        } | ConvertTo-Json -Depth 8 -Compress
    }
    'Prepare' {
        if(Test-Path -LiteralPath $directory) { throw 'Staging already exists.' }
        Expand-Archive -LiteralPath $archive -DestinationPath $directory
        [pscustomobject]@{ Prepared=$true; LocalNode=$env:COMPUTERNAME; Exe=(Test-Path -LiteralPath $exe) } | ConvertTo-Json -Compress
    }
    'Open' {
        New-NetFirewallRule -DisplayName $ruleName -Name $ruleName -Direction Inbound -Protocol TCP -LocalPort @("$port",'80') `
            -RemoteAddress LocalSubnet -Action Allow | Out-Null
        $listeners=@(Get-NetTCPConnection -State Listen -LocalPort 80 -ErrorAction SilentlyContinue | ForEach-Object OwningProcess)
        [pscustomobject]@{ Rule=$ruleName; Ports=@($port,80); Port80Listeners=$listeners } | ConvertTo-Json -Compress
    }
    'Fence' {
        Launch 'fence' @('fence-execution-domain',$ClusterName,"`"$groupName`"","$port","`"$generationFile`"","`"$fenceGates`"",$ExecutionDomain) $fenceGates 14400
    }
    'Create' {
        if(Get-ClusterGroup -Name $groupName -ErrorAction SilentlyContinue) { throw "Group '$groupName' already exists." }
        if(Test-Path -LiteralPath "HKLM:\$keyPath") { throw 'Intent key already exists.' }
        Add-ClusterGroup -Name $groupName | Out-Null
        Add-ClusterResource -Name $resourceName -Group $groupName -ResourceType 'Generic Application' | Out-Null
        # The configured eligible topology is passed to the manager exactly as configured, never derived from cluster nodes.
        $domains=($Fences -split ',') -join ' '
        $commandLine="`"$exe`" vps-serve `"$store`" $ClusterName `"$groupName`" `"$managerLog`" $domains"
        Get-ClusterResource -Name $resourceName | Set-ClusterParameter -Multiple @{ CommandLine=$commandLine; CurrentDirectory=$directory }
        # The key exists (empty) before it is checkpointed; afterwards it is never deleted or recreated while in use.
        $parentPath="HKLM:\$(Split-Path $keyPath -Parent)"
        if(-not (Test-Path -LiteralPath $parentPath)) { New-Item -Path $parentPath | Out-Null }
        New-Item -Path "HKLM:\$keyPath" | Out-Null
        Add-ClusterCheckpoint -ResourceName $resourceName -RegistryCheckpoint $keyPath | Out-Null
        Move-ClusterGroup -Name $groupName -Node $env:COMPUTERNAME | Out-Null
        [pscustomobject]@{ Snapshot=Snapshot; CommandLine=$commandLine; Store=$store } | ConvertTo-Json -Depth 8 -Compress
    }
    'Start' {
        Start-ClusterGroup -Name $groupName -Wait 60 | Out-Null
        Wait-Group 'Online' 60
        [pscustomobject]@{ Snapshot=Snapshot; Managers=@(Managers) } | ConvertTo-Json -Depth 8 -Compress
    }
    'Move' {
        $before=Get-ClusterGroup -Name $groupName
        $at=Now
        Move-ClusterGroup -Name $groupName -Node $TargetNode -Wait 60 | Out-Null
        Wait-Group 'Online' 60
        [pscustomobject]@{ From="$($before.OwnerNode)"; Requested=$at; Snapshot=Snapshot } | ConvertTo-Json -Depth 8 -Compress
    }
    'Restart' {
        # Administrative restart through WFC on the current owner: WFC terminates the process (Offline) and launches a new one.
        $before=@(Managers)
        $stopAt=Now
        Stop-ClusterResource -Name $resourceName | Out-Null
        $afterStop=@(Managers)
        $startAt=Now
        Start-ClusterResource -Name $resourceName -Wait 60 | Out-Null
        Wait-Group 'Online' 60
        [pscustomobject]@{ Before=$before; StopRequested=$stopAt; AfterStop=$afterStop; StartRequested=$startAt; After=@(Managers); Snapshot=Snapshot } |
            ConvertTo-Json -Depth 8 -Compress
    }
    'KillManager' {
        # Uncooperative failure of the management process only; ClusSvc and the node stay healthy. WFC decides what follows.
        $victims=@(Managers)
        if($victims.Count -ne 1) { throw "Expected exactly one local manager, found $($victims.Count)." }
        $at=Now
        Stop-Process -Id $victims[0].ProcessId -Force
        $transitions=Transitions 25
        [pscustomobject]@{ Killed=$victims[0]; At=$at; Transitions=$transitions; Snapshot=Snapshot; LocalManagers=@(Managers) } |
            ConvertTo-Json -Depth 8 -Compress
    }
    'Status' {
        $exitFile=Join-Path $fenceGates 'exit.txt'
        [pscustomobject]@{
            LocalNode=$env:COMPUTERNAME; At=(Now); Snapshot=Snapshot; LocalIntent=Local-Intent; Managers=@(Managers); Children=@(Workloads)
            ManagerLog=@(Read-Log $managerLog)
            Fence=@(Read-Log (Join-Path $fenceGates 'process.log')); FenceError=@(Read-Log (Join-Path $fenceGates 'process.stderr'))
            FenceExit=$(if(Test-Path -LiteralPath $exitFile) { ([IO.File]::ReadAllText($exitFile)).Trim() } else { $null })
            Generation=$(if(Test-Path -LiteralPath $generationFile) { [IO.File]::ReadAllText($generationFile) } else { $null })
        } | ConvertTo-Json -Depth 8 -Compress
    }
    'KillWorkload' {
        $victims=@(Workloads)
        if($victims.Count -ne 1) { throw "Expected exactly one local realization, found $($victims.Count)." }
        Stop-Process -Id $victims[0].ProcessId -Force
        [pscustomobject]@{ KilledProcessId=$victims[0].ProcessId; At=(Now) } | ConvertTo-Json -Compress
    }
    'Cleanup' {
        # Group first: WFC terminates the manager, so nothing restarts realizations while they are removed.
        if(Get-ClusterGroup -Name $groupName -ErrorAction SilentlyContinue) {
            Stop-ClusterGroup -Name $groupName -ErrorAction SilentlyContinue | Out-Null
            Get-ClusterCheckpoint -ResourceName $resourceName -ErrorAction SilentlyContinue | Remove-ClusterCheckpoint -Force -ErrorAction SilentlyContinue
            Remove-ClusterGroup -Name $groupName -Force -RemoveResources
        }
        foreach($task in @(Get-ScheduledTask -TaskName "$taskPrefix-*" -ErrorAction SilentlyContinue)) {
            Stop-ScheduledTask -TaskName $task.TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
        }
        foreach($identity in @(Processes)) { Stop-Process -Id $identity.ProcessId -Force -ErrorAction SilentlyContinue }
        Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        Remove-Item -LiteralPath "HKLM:\$keyPath" -Recurse -Force -ErrorAction SilentlyContinue
        if(-not (Get-ChildItem 'HKLM:\SOFTWARE\ControlPlaneExperiment' -ErrorAction SilentlyContinue)) {
            Remove-Item 'HKLM:\SOFTWARE\ControlPlaneExperiment' -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
        if(Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        if(Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        [pscustomobject]@{ Snapshot=Snapshot; KeyPresent=(Test-Path "HKLM:\$keyPath"); Staging=(Test-Path -LiteralPath $directory)
            Tasks=@(Get-ScheduledTask -TaskName "$taskPrefix-*" -ErrorAction SilentlyContinue).Count
            Rule=[bool](Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue); Processes=@(Processes).Count } | ConvertTo-Json -Depth 8 -Compress
        Remove-Item -LiteralPath $PSCommandPath -Force
    }
}
