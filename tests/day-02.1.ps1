#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$evidence = Join-Path $root ".state\day-02.1-$([guid]::NewGuid().ToString('N'))"
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
New-Item -ItemType Directory -Path $evidence | Out-Null

function Assert($condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Start-Manager([string] $name, [string] $stateFile, [int] $delay = 500) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    foreach ($argument in @('manage', $stateFile, "$delay")) {
        $info.ArgumentList.Add($argument)
    }
    $session = [pscustomobject]@{
        Name = $name
        Process = [System.Diagnostics.Process]::Start($info)
        Lines = [System.Collections.Generic.List[string]]::new()
        Log = Join-Path $evidence "$name.log"
    }
    $sessions.Add($session)
    return $session
}

function Read-Until($session, [string] $pattern) {
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while ([datetime]::UtcNow -lt $deadline) {
        $read = $session.Process.StandardOutput.ReadLineAsync()
        Assert ($read.Wait(10000)) "Timed out reading $($session.Name)."
        $line = $read.GetAwaiter().GetResult()
        Assert ($null -ne $line) "$($session.Name) exited before '$pattern'."
        $session.Lines.Add($line)
        if ($line -notmatch '^Observation (?:[2-9]|[1-9][0-9]+):|^Action=none;') {
            Write-Host "[$($session.Name)] $line"
        }
        if ($line -match $pattern) { return }
    }
    throw "$($session.Name) never produced '$pattern'."
}

function Stop-Manager($session) {
    if (-not $session.Process.HasExited) {
        Stop-Process -Id $session.Process.Id -Force
    }
    Assert ($session.Process.WaitForExit(5000)) "Manager $($session.Name) did not exit."
    [System.IO.File]::WriteAllLines($session.Log, $session.Lines)
}

function Read-State([string] $stateFile) {
    return Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
}

function Stop-Workload($state) {
    if ($null -eq $state.Workload) { return }
    try {
        $child = [System.Diagnostics.Process]::GetProcessById($state.Workload.ProcessId)
    }
    catch [System.ArgumentException] { return }
    try {
        Assert ($child.StartTime.ToUniversalTime().Ticks -eq $state.Workload.StartTimeUtcTicks) `
            'Refusing cleanup: PID now identifies a different process.'
        Stop-Process -Id $child.Id -Force
        Assert ($child.WaitForExit(5000)) 'Workload did not exit during cleanup.'
    }
    finally { $child.Dispose() }
}

function New-Intent([string] $name) {
    $stateFile = Join-Path $evidence "$name.json"
    $stateFiles.Add($stateFile)
    & $executable intent $stateFile | Out-Host
    Assert ($LASTEXITCODE -eq 0) 'Intent command failed.'
    $state = Read-State $stateFile
    Assert ($state.Desired -eq 'Running' -and $null -eq $state.Workload `
        -and $null -eq $state.LastObservation) 'Initial durable state was not intent alone.'
    return $stateFile
}

function Assert-Starts($session, [int] $expected) {
    $actual = @($session.Lines | Where-Object { $_ -match '^Action=start returned;' }).Count
    Assert ($actual -eq $expected) "$($session.Name): expected $expected starts, got $actual."
}

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
