#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$evidence = Join-Path $root ".state\day-02.2-$([guid]::NewGuid().ToString('N'))"
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
$orphan = $null
New-Item -ItemType Directory -Path $evidence | Out-Null
. "$PSScriptRoot\process-helpers.ps1"

function Assert-ReadyWorkload($identity) {
    $process = [System.Diagnostics.Process]::GetProcessById($identity.ProcessId)
    try {
        Assert ($process.StartTime.ToUniversalTime().Ticks -eq $identity.StartTimeUtcTicks) `
            'PID identifies a different process.'
        $eventName = "Local\ControlPlaneExperiment-$(([guid] $identity.RunId).ToString('N'))"
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while ([datetime]::UtcNow -lt $deadline) {
            Assert (-not $process.HasExited) 'Expected workload exited.'
            $readiness = $null
            if ([System.Threading.EventWaitHandle]::TryOpenExisting($eventName, [ref] $readiness)) {
                try {
                    if ($readiness.WaitOne(0)) {
                        Write-Host "Fresh external observation: pid=$($identity.ProcessId); alive; readiness signaled."
                        return
                    }
                }
                finally { $readiness.Dispose() }
            }
            Start-Sleep -Milliseconds 50
        }
        throw 'Workload readiness was not observed within ten seconds.'
    }
    finally { $process.Dispose() }
}

try {
    $stateFile = New-Intent 'crash-gap'
    $initial = Read-State $stateFile
    $first = Start-Manager 'before-save' $stateFile -PauseBeforeLocatorSave
    Read-Until $first '^Action=start returned; locator NOT persisted;'
    $marker = $first.Lines[-1]
    Assert ($marker -match 'pid=(\d+); startTicks=(\d+); runId=([0-9a-f-]+);') `
        'Pause did not expose a locator for external observation and cleanup.'
    $orphan = [pscustomobject]@{
        ProcessId = [int] $Matches[1]
        StartTimeUtcTicks = [long] $Matches[2]
        RunId = $Matches[3]
    }

    Stop-Manager $first
    Assert-Starts $first 1
    $before = Read-State $stateFile
    Assert ($before.WorkloadId -eq $initial.WorkloadId -and $before.Desired -eq 'Running') `
        'Intent did not survive the killed manager.'
    Assert ($null -eq $before.Workload -and $before.LastObservation.State -eq 'Stopped') `
        'The test did not interrupt the intended pre-locator-save gap.'
    Copy-Item -LiteralPath $stateFile -Destination (Join-Path $evidence 'before-restart.json')
    Assert-ReadyWorkload $orphan
    $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($orphan.ProcessId)").CommandLine
    Assert ($commandLine -like "*$($orphan.RunId)*") 'Child command line did not carry its run ID.'
    Assert ($commandLine -notlike "*$($initial.WorkloadId)*") 'The child unexpectedly carried logical workload identity.'
    [pscustomobject]@{
        ObservedAt = [datetime]::UtcNow
        Identity = $orphan
        CommandLine = $commandLine
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $evidence 'external-orphan-observation.json')
    Write-Host 'After manager death: durable intent=Running; locator=null; saved observation=Stopped; original child is ready.'

    $second = Start-Manager 'after-restart' $stateFile
    Read-Until $second '^Converged:.*starts this manager=1;'
    Stop-Manager $second
    Assert-Starts $second 1
    Assert ($second.Lines -match 'Observation 1: fresh=Stopped') 'Restart did not exercise Observe(null).'
    $after = Read-State $stateFile
    Assert ($after.WorkloadId -eq $initial.WorkloadId -and $after.Desired -eq 'Running') `
        'Restart changed logical intent.'
    Assert ($after.Workload.ProcessId -ne $orphan.ProcessId -and $after.Workload.RunId -ne $orphan.RunId) `
        'The predicted duplicate was not created.'
    Assert ($after.LastObservation.State -eq 'Running') 'Second manager did not persist its convergence evidence.'
    Assert-ReadyWorkload $orphan
    Assert-ReadyWorkload $after.Workload
    Write-Host "LIMITATION REPRODUCED: two live ready children ($($orphan.ProcessId), $($after.Workload.ProcessId)); one locator; manager reported convergence."
}
finally {
    foreach ($session in $sessions) { Stop-Manager $session }
    foreach ($stateFile in $stateFiles) {
        if (Test-Path -LiteralPath $stateFile) { Stop-Workload (Read-State $stateFile) }
    }
    if ($null -ne $orphan) { Stop-Workload ([pscustomobject]@{ Workload = $orphan }) }
    foreach ($session in $sessions) { $session.Process.Dispose() }
}

Write-Host "Expected failure reproduced, not repaired. Captured evidence: $evidence"
