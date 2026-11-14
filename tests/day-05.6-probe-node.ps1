#Requires -Version 5.1
# Runs under Windows PowerShell: FailoverClusters objects must bind natively (pwsh loads it via compatibility remoting).
# Day 5.6 Phase 1/2 probe: what do a built-in Generic Application resource and a registry checkpoint actually do?
# Uses a disposable PING.EXE payload so no control-plane code is involved in the semantics being measured.
param(
    [Parameter(Mandatory)][ValidateSet('Create','Read','Write','RecreateKey','Kill','StopResource','StartResource','Move','Cleanup')]
    [string] $Action,
    [Parameter(Mandatory)][guid] $RunId,
    [ValidatePattern('^Node-[ABC]$')][string] $TargetNode,
    [ValidatePattern('^[A-Za-z0-9-]{0,64}$')][string] $Value = ''
)
$ErrorActionPreference='Stop'
$WarningPreference='SilentlyContinue'
Set-StrictMode -Version Latest
Import-Module FailoverClusters -WarningAction SilentlyContinue
$token=$RunId.ToString('N')
$groupName="ControlPlaneExperiment-Day56Probe-$token"
$resourceName="ControlPlaneExperiment-Day56Probe-App-$token"
$keyPath="SOFTWARE\ControlPlaneExperiment\Day56Probe-$token"
$ping="$env:windir\System32\PING.EXE"

function Monitored {
    # Generic Application children of the resource host monitor (rhs.exe) running this probe's payload.
    $hosts=@(Get-CimInstance Win32_Process -Filter "Name='rhs.exe'" | ForEach-Object ProcessId)
    @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { $hosts -contains $_.ParentProcessId } |
        ForEach-Object { [pscustomobject]@{ ProcessId=$_.ProcessId; ParentProcessId=$_.ParentProcessId; Created="$($_.CreationDate.ToUniversalTime().ToString('O'))" } })
}
function Snapshot {
    $group=Get-ClusterGroup -Name $groupName -ErrorAction SilentlyContinue
    $resource=Get-ClusterResource -Name $resourceName -ErrorAction SilentlyContinue
    $local=Get-Item -LiteralPath "HKLM:\$keyPath" -ErrorAction SilentlyContinue
    [pscustomobject]@{
        At=[datetimeoffset]::UtcNow.ToString('O'); LocalNode=$env:COMPUTERNAME
        Group=$(if($group) { [pscustomobject]@{ Owner="$($group.OwnerNode)"; State="$($group.State)";
            FailoverThreshold=$group.FailoverThreshold; FailoverPeriod=$group.FailoverPeriod } })
        Resource=$(if($resource) { [pscustomobject]@{ Type="$($resource.ResourceType)"; State="$($resource.State)"; Owner="$($resource.OwnerNode)"
            RestartAction=$resource.RestartAction; RestartThreshold=$resource.RestartThreshold; RestartPeriod=$resource.RestartPeriod
            RestartDelay=$resource.RestartDelay; RetryPeriodOnFailure=$resource.RetryPeriodOnFailure
            LooksAlive=$resource.LooksAlivePollInterval; IsAlive=$resource.IsAlivePollInterval; PendingTimeout=$resource.PendingTimeout
            Private=@($resource | Get-ClusterParameter | ForEach-Object { "$($_.Name)=$($_.Value)" })
            Checkpoints=@(Get-ClusterCheckpoint -ResourceName $resourceName -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)" }) } })
        LocalKeyPresent=[bool]$local
        LocalValue=$(if($local) { $local.GetValue('Intent') })
        Monitored=@(Monitored)
    }
}
switch($Action) {
    'Create' {
        if(Get-ClusterGroup -Name $groupName -ErrorAction SilentlyContinue) { throw 'Probe group exists.' }
        Add-ClusterGroup -Name $groupName | Out-Null
        Add-ClusterResource -Name $resourceName -Group $groupName -ResourceType 'Generic Application' | Out-Null
        Get-ClusterResource -Name $resourceName | Set-ClusterParameter -Multiple @{ CommandLine="`"$ping`" -t 127.0.0.1"; CurrentDirectory="$env:windir\Temp" }
        New-Item -Path "HKLM:\$keyPath" -Force | Out-Null
        Set-ItemProperty -Path "HKLM:\$keyPath" -Name Intent -Value 'created'
        Add-ClusterCheckpoint -ResourceName $resourceName -RegistryCheckpoint $keyPath | Out-Null
        Move-ClusterGroup -Name $groupName -Node $env:COMPUTERNAME | Out-Null
        Start-ClusterGroup -Name $groupName -Wait 60 | Out-Null
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'Read' { Snapshot | ConvertTo-Json -Depth 6 -Compress }
    'Write' {
        # Values only: the checkpointed key itself must not be deleted/recreated (New-Item -Force would do exactly that).
        if(-not (Test-Path "HKLM:\$keyPath")) { New-Item -Path "HKLM:\$keyPath" | Out-Null }
        Set-ItemProperty -Path "HKLM:\$keyPath" -Name Intent -Value $Value
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'RecreateKey' {
        # Deliberate: delete and recreate the checkpointed key, then write, to measure whether capture survives it.
        New-Item -Path "HKLM:\$keyPath" -Force | Out-Null
        Set-ItemProperty -Path "HKLM:\$keyPath" -Name Intent -Value $Value
        Snapshot | ConvertTo-Json -Depth 6 -Compress
    }
    'Kill' {
        $victims=@(Monitored)
        if($victims.Count -ne 1) { throw "Expected one monitored process, found $($victims.Count)." }
        Stop-Process -Id $victims[0].ProcessId -Force
        $states=[Collections.Generic.List[string]]::new()
        $deadline=[datetime]::UtcNow.AddSeconds(20)
        while([datetime]::UtcNow -lt $deadline) {
            $r=Get-ClusterResource -Name $resourceName; $g=Get-ClusterGroup -Name $groupName
            $line="$([datetimeoffset]::UtcNow.ToString('HH:mm:ss.fff')) res=$($r.State) owner=$($g.OwnerNode) pids=$((@(Monitored) | ForEach-Object ProcessId) -join '+')"
            if($states.Count -eq 0 -or $states[-1].Substring(13) -ne $line.Substring(13)) { $states.Add($line) }
            Start-Sleep -Milliseconds 200
        }
        [pscustomobject]@{ Killed=$victims[0].ProcessId; Transitions=$states; After=Snapshot } | ConvertTo-Json -Depth 6 -Compress
    }
    'StopResource' { Stop-ClusterResource -Name $resourceName | Out-Null; Snapshot | ConvertTo-Json -Depth 6 -Compress }
    'StartResource' { Start-ClusterResource -Name $resourceName -Wait 60 | Out-Null; Snapshot | ConvertTo-Json -Depth 6 -Compress }
    'Move' { Move-ClusterGroup -Name $groupName -Node $TargetNode -Wait 60 | Out-Null; Snapshot | ConvertTo-Json -Depth 6 -Compress }
    'Cleanup' {
        if(Get-ClusterGroup -Name $groupName -ErrorAction SilentlyContinue) {
            Get-ClusterCheckpoint -ResourceName $resourceName -ErrorAction SilentlyContinue | Remove-ClusterCheckpoint -Force -ErrorAction SilentlyContinue
            Remove-ClusterGroup -Name $groupName -Force -RemoveResources
        }
        Remove-Item -LiteralPath "HKLM:\$keyPath" -Recurse -Force -ErrorAction SilentlyContinue
        if(-not (Get-ChildItem 'HKLM:\SOFTWARE\ControlPlaneExperiment' -ErrorAction SilentlyContinue)) {
            Remove-Item 'HKLM:\SOFTWARE\ControlPlaneExperiment' -Force -ErrorAction SilentlyContinue
        }
        [pscustomobject]@{ LocalNode=$env:COMPUTERNAME; GroupPresent=[bool](Get-ClusterGroup -Name $groupName -ErrorAction SilentlyContinue)
            KeyPresent=(Test-Path "HKLM:\$keyPath") } | ConvertTo-Json -Compress
    }
}
