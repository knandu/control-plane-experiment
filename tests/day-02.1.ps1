#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$evidence = Join-Path $root ".state\day-02.1-$([guid]::NewGuid().ToString('N'))"
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
New-Item -ItemType Directory -Path $evidence | Out-Null

. "$PSScriptRoot\process-helpers.ps1"

try {
    $baselineFile = New-Intent 'baseline'
    $baseline = Start-Manager 'baseline' $baselineFile
    Read-Until $baseline '^Converged:.*starts this manager=1;'
    Stop-Manager $baseline
    Assert-Starts $baseline 1
    Assert ($baseline.Lines -match 'fresh=Stopped') 'Baseline did not observe absence.'
    Assert ($baseline.Lines -match 'fresh=Starting') 'Baseline did not observe pending startup.'
    Assert ($baseline.Lines -match 'fresh=Running') 'Baseline did not observe readiness.'
    $baselineState = Read-State $baselineFile
    Assert ($baselineState.LastObservation.State -eq 'Running') 'Running observation was not durable.'
    Stop-Workload $baselineState
    Write-Host 'PASS: clean baseline; one start, independent startup observation, durable Running evidence.'

    foreach ($scenario in @('ready-restart', 'pending-restart', 'stale-observation')) {
        $stateFile = New-Intent $scenario
        $delay = if ($scenario -eq 'pending-restart') { 3000 } else { 500 }
        $first = Start-Manager "$scenario-first" $stateFile $delay
        if ($scenario -eq 'pending-restart') {
            Read-Until $first 'fresh=Starting'
        }
        else {
            Read-Until $first '^Converged:.*starts this manager=1;'
        }
        Stop-Manager $first
        Assert-Starts $first 1
        $before = Read-State $stateFile
        Copy-Item -LiteralPath $stateFile -Destination (Join-Path $evidence "$scenario-before.json")
        if ($scenario -eq 'stale-observation') {
            Stop-Workload $before
            Assert ((Read-State $stateFile).LastObservation.State -eq 'Running') `
                'Expected deliberately stale Running evidence.'
        }

        $second = Start-Manager "$scenario-second" $stateFile
        $expectedStarts = if ($scenario -eq 'stale-observation') { 1 } else { 0 }
        Read-Until $second "^Converged:.*starts this manager=$expectedStarts;"
        Stop-Manager $second
        Assert-Starts $second $expectedStarts
        $after = Read-State $stateFile
        Assert ($before.WorkloadId -eq $after.WorkloadId) 'Logical workload identity changed on restart.'
        Assert ($before.Desired -eq $after.Desired) 'Intent changed on restart.'
        Assert ($after.LastObservation.At -gt $before.LastObservation.At) 'No newer observation was persisted.'
        if ($scenario -eq 'stale-observation') {
            Assert ($second.Lines -match 'Saved observation=Running; not current truth.') 'Missing stale evidence.'
            Assert ($second.Lines -match 'Observation 1: fresh=Stopped') 'Saved Running was trusted as truth.'
            Assert ($before.Workload.RunId -ne $after.Workload.RunId) 'A replacement incarnation was not recorded.'
        }
        else {
            Assert ($before.Workload.ProcessId -eq $after.Workload.ProcessId `
                -and $before.Workload.StartTimeUtcTicks -eq $after.Workload.StartTimeUtcTicks `
                -and $before.Workload.RunId -eq $after.Workload.RunId) 'Restart replaced the existing workload.'
            if ($scenario -eq 'pending-restart') {
                Assert ($before.LastObservation.State -eq 'Starting') 'First manager did not stop during startup.'
                Assert ($second.Lines -match 'Observation 1: fresh=Starting') 'Second manager missed pending startup.'
            }
        }
        Stop-Workload $after
        Write-Host "PASS: $scenario; same intent; second-manager starts=$expectedStarts."
    }
}
finally {
    foreach ($session in $sessions) { Stop-Manager $session }
    foreach ($stateFile in $stateFiles) {
        if (Test-Path -LiteralPath $stateFile) { Stop-Workload (Read-State $stateFile) }
    }
    foreach ($session in $sessions) { $session.Process.Dispose() }
}

Write-Host "All four process experiments passed. Logs and JSON evidence: $evidence"
