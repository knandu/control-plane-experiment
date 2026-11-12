#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$assembly = [System.IO.Path]::ChangeExtension($executable, '.dll')
$evidence = (New-Item -ItemType Directory -Path (Join-Path $root ".state\day-03.1-$([guid]::NewGuid().ToString('N'))")).FullName
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
$children = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
. "$PSScriptRoot\process-helpers.ps1"

function Grant-Authority([string] $name, [string] $stateFile, [long] $epoch, [int] $delay = 500) {
    Assert (@($sessions | Where-Object { -not $_.Process.HasExited }).Count -eq 0) `
        'The previous manager must exit before the next manual grant.'
    $session = Start-Manager $name $stateFile $delay -AuthorityEpoch $epoch
    Read-Until $session "^Authority acquired: epoch=$epoch; manager=$($session.Process.Id);"
    $ticks = $session.Process.StartTime.ToUniversalTime().Ticks
    Assert ($session.Lines -match "managerStartTicks=$ticks; authorityEpoch=$epoch\.") `
        'Manager process identity and authority were not reported separately.'
    return $session
}

function Relinquish-Authority($session) {
    $session.Process.StandardInput.WriteLine('relinquish')
    $session.Process.StandardInput.Flush()
    Read-Until $session "^Authority relinquished: epoch=$($session.AuthorityEpoch); manager=$($session.Process.Id);"
    Assert ($session.Process.WaitForExit(5000) -and $session.Process.ExitCode -eq 0) `
        'Cooperative relinquishment did not exit successfully.'
    $session.Process.StandardInput.Close()
    Stop-Manager $session
}

function Assert-SameIncarnation($expected, $actual) {
    Assert ($expected.ProcessId -eq $actual.ProcessId `
        -and $expected.StartTimeUtcTicks -eq $actual.StartTimeUtcTicks `
        -and $expected.RunId -eq $actual.RunId) 'Authority movement changed workload incarnation.'
}

function Assert-IntentUnchanged([string] $stateFile, [string] $original) {
    Assert ([System.IO.File]::ReadAllText($stateFile) -ceq $original) 'Authority movement rewrote workload intent.'
    $state = Read-State $stateFile
    Assert ((($state.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'Desired,WorkloadId') `
        'Authority metadata leaked into durable intent.'
    Assert (@(Matching-Processes $state.WorkloadId).Count -eq 1) 'Expected exactly one matching realization.'
}

function Record-AuthorityResult(
    [string] $scenario, [string] $workloadId, $session, $identity, [int] $starts, [int] $fromLine = 0
) {
    Assert-Starts $session $starts
    $observations = @($session.Lines | Select-Object -Skip $fromLine | Where-Object { $_ -match '^Observation ' })
    Assert ($observations.Count -gt 0) 'No fresh observations.'
    foreach ($line in $observations) {
        Assert ($line -match "workload=$workloadId;.*manager=$($session.Process.Id); authorityEpoch=$($session.AuthorityEpoch);") `
            'Observation lacks its logical workload, manager, or authority context.'
    }
    $result = [pscustomobject]@{
        Scenario = $scenario
        WorkloadId = $workloadId
        Manager = @{
            ProcessId = $session.Process.Id
            StartTimeUtcTicks = $session.Process.StartTime.ToUniversalTime().Ticks
        }
        AuthorityEpoch = $session.AuthorityEpoch
        Incarnation = $identity
        Starts = $starts
        ObservedStates = @($observations | ForEach-Object {
            Assert ($_ -match 'fresh=(\w+);') 'Observation lacks a state.'
            $Matches[1]
        })
        FirstObservation = $observations[0]
        LastObservation = $observations[-1]
        Converged = [bool] ($session.Lines | Select-Object -Skip $fromLine |
            Where-Object { $_ -match "^Converged:.*starts this manager=$starts;" })
    }
    $results.Add($result)
    Write-Host ($result | ConvertTo-Json -Depth 4 -Compress)
}

try {
    $stateFile = New-Intent 'ready-handoffs'
    $intent = Read-State $stateFile
    $intentJson = [System.IO.File]::ReadAllText($stateFile)

    $first = Grant-Authority 'ready-A' $stateFile 1 1000
    Read-Until $first '^Converged:.*starts this manager=1;'
    $original = Observed-Identity $first
    Assert ($first.Lines -match 'fresh=Stopped;' -and $first.Lines -match 'fresh=Starting;' `
        -and $first.Lines -match 'fresh=Running;') 'Baseline did not expose absence, startup, and readiness.'
    Relinquish-Authority $first
    Assert-Live $original
    Record-AuthorityResult 'epoch-1-baseline' $intent.WorkloadId $first $original 1

    $second = Grant-Authority 'ready-B' $stateFile 2
    Read-Until $second '^Converged:.*starts this manager=0;'
    $adopted = Observed-Identity $second
    Assert-SameIncarnation $original $adopted
    Assert ($second.Lines -match '^Observation 1: fresh=Running;') 'New authority did not freshly observe readiness.'
    Relinquish-Authority $second
    Assert-Live $adopted
    Assert-IntentUnchanged $stateFile $intentJson
    Record-AuthorityResult 'epoch-1-to-2' $intent.WorkloadId $second $adopted 0

    $third = Grant-Authority 'ready-C' $stateFile 3
    Read-Until $third '^Converged:.*starts this manager=0;'
    $repeated = Observed-Identity $third
    Assert-SameIncarnation $original $repeated
    Assert ($third.Lines -match '^Observation 1: fresh=Running;') 'Repeated handoff did not freshly observe readiness.'
    Assert-Live $repeated
    Assert-IntentUnchanged $stateFile $intentJson
    Record-AuthorityResult 'epoch-2-to-3' $intent.WorkloadId $third $repeated 0

    $beforeFailure = $third.Lines.Count
    Stop-Workload ([pscustomobject]@{ Workload = $original })
    Read-Until $third '^Converged:.*starts this manager=1;'
    $replacement = Observed-Identity $third
    Assert ($replacement.RunId -ne $original.RunId) 'Current authority did not create a replacement incarnation.'
    Assert-Live $replacement
    Assert-IntentUnchanged $stateFile $intentJson
    Record-AuthorityResult 'failure-under-epoch-3' $intent.WorkloadId $third $replacement 1 $beforeFailure
    Assert ($results[-1].ObservedStates -contains 'Stopped') 'Current authority did not freshly observe absence.'
    Relinquish-Authority $third
    Stop-Workload ([pscustomobject]@{ Workload = $replacement })

    $pendingFile = New-Intent 'startup-handoff'
    $pendingIntent = Read-State $pendingFile
    $pendingJson = [System.IO.File]::ReadAllText($pendingFile)
    $pendingFirst = Grant-Authority 'starting-A' $pendingFile 1 5000
    Read-Until $pendingFirst '^Observation 2: fresh=Starting;'
    $pending = Observed-Identity $pendingFirst
    Relinquish-Authority $pendingFirst
    Assert-Live $pending $false
    Record-AuthorityResult 'startup-epoch-1' $pendingIntent.WorkloadId $pendingFirst $pending 1

    $pendingSecond = Grant-Authority 'starting-B' $pendingFile 2
    Read-Until $pendingSecond '^Converged:.*starts this manager=0;'
    $ready = Observed-Identity $pendingSecond
    Assert-SameIncarnation $pending $ready
    Assert ($pendingSecond.Lines -match '^Observation 1: fresh=Starting;') 'Handoff did not occur during startup.'
    Assert-Live $ready
    Assert-IntentUnchanged $pendingFile $pendingJson
    Relinquish-Authority $pendingSecond
    Record-AuthorityResult 'startup-epoch-1-to-2' $pendingIntent.WorkloadId $pendingSecond $ready 0

    Assert (@($sessions | ForEach-Object { "$($_.Process.Id):$($_.Process.StartTime.ToUniversalTime().Ticks)" } |
        Sort-Object -Unique).Count -eq $sessions.Count) 'A manager process identity was reused.'
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
    Write-Host "PASS: Day 3.1 baseline, two clean handoffs, current-authority replacement, and startup handoff. Evidence: $evidence"
}
finally {
    foreach ($session in $sessions) { Stop-Manager $session }
    foreach ($identity in $children) { Stop-Workload ([pscustomobject]@{ Workload = $identity }) }
    foreach ($stateFile in $stateFiles) {
        if (Test-Path -LiteralPath $stateFile) { Stop-MatchingWorkloads (Read-State $stateFile).WorkloadId }
    }
    foreach ($session in $sessions) { $session.Process.Dispose() }
}
