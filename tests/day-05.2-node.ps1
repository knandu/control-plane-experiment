#Requires -Version 5.1
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Prepare','Create','Move','Run','Status','Release','Reset','Cleanup')]
    [string] $Action,
    [Parameter(Mandatory)][guid] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string] $ClusterName,
    [ValidateSet('Node-A','Node-B','Node-C')][string] $TargetNode,
    [ValidateSet('baseline','stale','cold','recheck')][string] $Case = 'baseline',
    [ValidateSet('none','decision','recheck','complete')][string] $Stage = 'none'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$token=$RunId.ToString('N')
$groupName="ControlPlaneExperiment-Day52-$token"
$directory=Join-Path $env:ProgramData "ControlPlaneExperiment\day-05.2-$token"
$archive=Join-Path $env:windir "Temp\ControlPlaneExperiment-Day52-$token.zip"
$gates=Join-Path $directory $Case
$stateFile=Join-Path $directory "intent-$Case.json"
$assembly=Join-Path $directory 'ControlPlaneExperiment.dll'

function Snapshot {
    Import-Module FailoverClusters -ErrorAction Stop
    if ((Get-Cluster).Name -ine $ClusterName) { throw 'Wrong local cluster.' }
    [pscustomobject]@{
        At=[datetimeoffset]::UtcNow.ToString('O'); LocalNode=$env:COMPUTERNAME; Cluster=(Get-Cluster).Name
        Nodes=@(Get-ClusterNode | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.State)" })
        Groups=@(Get-ClusterGroup | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; Owner=$_.OwnerNode.Name; State=$_.State.ToString() }
        })
        Resources=@(Get-ClusterResource | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; Group=$_.OwnerGroup.Name; State=$_.State.ToString() }
        })
    }
}
function Processes {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($directory+'\',[StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object { [pscustomobject]@{ ProcessId=$_.ProcessId; CommandLine=$_.CommandLine } })
}
function Stop-Owned([switch]$ChildrenOnly) {
    foreach($identity in @(Processes | Where-Object { -not $ChildrenOnly -or $_.CommandLine -match ' --workload ' })) {
        Stop-Process -Id $identity.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
function Read-Log([string]$path) {
    if(Test-Path -LiteralPath $path) {
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $reader=[IO.StreamReader]::new($stream)
        try { $reader.ReadToEnd() -split '\r?\n' | Where-Object { $_ -ne '' } }
        finally { $reader.Dispose() }
    }
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
        if(-not $TargetNode) { throw 'Target required.' }
        $group=Get-ClusterGroup -Name $groupName
        if($group.OwnerNode.Name -ine $TargetNode) { $group | Move-ClusterGroup -Node $TargetNode -Wait 30 | Out-Null }
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'Run' {
        New-Item -ItemType Directory -Path $gates | Out-Null
        $env:PATH=$directory+';'+$env:PATH
        $process=Start-Process -FilePath (Join-Path $directory 'ControlPlaneExperiment.exe') -ArgumentList @(
            'experiment-cluster-start',$stateFile,$ClusterName,$groupName,$gates,$Stage
        ) -RedirectStandardOutput (Join-Path $gates 'manager.log') -RedirectStandardError (Join-Path $gates 'manager.stderr') -PassThru
        if(-not $process.WaitForExit(180000)) { throw 'Manager exceeded experiment bound.' }
        $exitCode=$process.ExitCode
        [IO.File]::WriteAllText((Join-Path $gates 'exit.txt'),"$exitCode")
        exit $exitCode
    }
    'Status' {
        $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $reached=@(if(Test-Path -LiteralPath $gates) {
            foreach($file in [IO.Directory]::GetFiles($gates,'*.reached')) { [IO.Path]::GetFileNameWithoutExtension($file) }
        })
        $allProcesses=@(Processes)
        $children=@($allProcesses | Where-Object CommandLine -like "*$assembly*--workload $($state.WorkloadId) *" | ForEach-Object {
            if($_.CommandLine -notmatch '--workload [0-9a-f-]+ ([0-9a-f-]+) ') { throw 'Missing run identity.' }
            $run=[guid]$Matches[1]; $handle=$null
            $ready=$false
            if([Threading.EventWaitHandle]::TryOpenExisting("Local\ControlPlaneExperiment-$($run.ToString('N'))",[ref]$handle)) {
                try { $ready=$handle.WaitOne(0) } finally { $handle.Dispose() }
            }
            [pscustomobject]@{ Identity=$_; RunId=$run; Ready=$ready }
        })
        $snapshot=Snapshot
        $output=@(Read-Log (Join-Path $gates 'manager.log'))
        $errorOutput=@(Read-Log (Join-Path $gates 'manager.stderr'))
        $record=[pscustomobject]@{
            Snapshot=$snapshot; Case=$Case
            Reached=$reached; Output=$output; ErrorOutput=$errorOutput
            Children=$children
        }
        $record | ConvertTo-Json -Depth 8 -Compress
    }
    'Release' {
        [IO.File]::WriteAllText((Join-Path $gates "$Stage.release"),[datetimeoffset]::UtcNow.ToString('O'))
        [pscustomobject]@{ Released=$Stage; At=[datetimeoffset]::UtcNow.ToString('O') } | ConvertTo-Json -Compress
    }
    'Reset' {
        Stop-Owned -ChildrenOnly
        [pscustomobject]@{ Processes=@(Processes).Count } | ConvertTo-Json -Compress
    }
    'Cleanup' {
        Stop-Owned
        $snapshot=Snapshot
        if(@($snapshot.Groups | Where-Object Name -eq $groupName).Count) { Remove-ClusterGroup -Name $groupName -Force }
        if(Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        if(Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        Snapshot | ConvertTo-Json -Depth 6 -Compress
        Remove-Item -LiteralPath $PSCommandPath -Force
    }
}
