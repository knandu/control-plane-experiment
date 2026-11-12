#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$assembly = [System.IO.Path]::ChangeExtension($executable, '.dll')
$evidence = (New-Item -ItemType Directory -Path (Join-Path $root ".state\day-02.3-$([guid]::NewGuid().ToString('N'))")).FullName
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
$children = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$staleReadiness = $null
. "$PSScriptRoot\process-helpers.ps1"

function Start-IdentifiedChild([string] $workloadId, [int] $delay = 0) {
    $runId = [guid]::NewGuid()
    $info = [System.Diagnostics.ProcessStartInfo]::new('dotnet')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    foreach ($argument in @($assembly, '--workload', $workloadId, "$runId", "$delay")) {
        $info.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        return Remember-Identity "pid=$($process.Id); startTicks=$($process.StartTime.ToUniversalTime().Ticks); runId=$runId"
    }
    finally { $process.Dispose() }
}

function Record-Result([string] $scenario, [string] $workloadId, $identity, [int] $starts, [string] $outcome) {
    $result = [pscustomobject]@{
        Scenario = $scenario
        WorkloadId = $workloadId
        Identity = $identity
        Starts = $starts
        Outcome = $outcome
    }
    $results.Add($result)
    Write-Host ($result | ConvertTo-Json -Depth 4 -Compress)
}

try {
    $stateFile = New-Intent 'interrupted-creation'
    $intent = Read-State $stateFile
    $intentJson = [System.IO.File]::ReadAllText($stateFile)
    $first = Start-Manager 'before-save' $stateFile -PauseBeforeLocatorSave
    Read-Until $first '^Action=start returned; former pre-locator-save pause;'
    $survivor = Remember-Identity $first.Lines[-1]
    Stop-Manager $first
    Assert-Starts $first 1
    $before = Read-State $stateFile
    Assert (($before.PSObject.Properties.Name | Sort-Object) -join ',' -eq 'Desired,WorkloadId') `
        'Authoritative state contains more than intent.'
    Assert ($before.Desired -eq 'Running' -and $before.WorkloadId -eq $intent.WorkloadId) 'Intent changed.'
    Copy-Item -LiteralPath $stateFile -Destination (Join-Path $evidence 'crash-state.json')
    Assert-Live $survivor
    $processes = @(Matching-Processes $intent.WorkloadId)
    Assert ($processes.Count -eq 1 -and $processes[0].ProcessId -eq $survivor.ProcessId) 'Wrong surviving realization.'
    Write-Host "Fresh external launch metadata: $($processes[0].CommandLine)"
    $second = Start-Manager 'after-crash' $stateFile
    Read-Until $second '^Converged:.*starts this manager=0;'
    Stop-Manager $second
    Assert-Starts $second 0
    $adopted = Observed-Identity $second
    Assert ($adopted.ProcessId -eq $survivor.ProcessId -and $adopted.RunId -eq $survivor.RunId `
        -and $adopted.StartTimeUtcTicks -eq $survivor.StartTimeUtcTicks) 'Did not adopt the same incarnation.'
    Assert (@(Matching-Processes $intent.WorkloadId).Count -eq 1) 'Duplicate created.'
    Assert ([System.IO.File]::ReadAllText($stateFile) -ceq $intentJson) 'Reconciliation rewrote durable state.'
    Record-Result 'interrupted-creation' $intent.WorkloadId $survivor 1 'First manager: 1 Start; restarted manager: 0; one ready child; no duplicate.'

    $intentOnly = [ordered]@{ WorkloadId = $intent.WorkloadId; Desired = $intent.Desired }
    $intentOnly | ConvertTo-Json | Set-Content -LiteralPath $stateFile
    $withoutFields = Read-State $stateFile
    Assert ($withoutFields.PSObject.Properties.Name -notcontains 'Workload' `
        -and $withoutFields.PSObject.Properties.Name -notcontains 'LastObservation') 'Fields were not omitted.'
    $withoutLocator = Start-Manager 'no-locator-or-observation' $stateFile
    Read-Until $withoutLocator '^Converged:.*starts this manager=0;'
    Stop-Manager $withoutLocator
    Assert-Starts $withoutLocator 0
    $rediscovered = Observed-Identity $withoutLocator
    Assert ($rediscovered.ProcessId -eq $survivor.ProcessId -and $rediscovered.RunId -eq $survivor.RunId) `
        'Control depended on a persisted field.'
    Record-Result 'absent-fields' $intent.WorkloadId $rediscovered 0 'Both locator and observation omitted; same incarnation observed ready.'

    $unrelatedId = [guid]::NewGuid().ToString()
    $unrelated = Start-IdentifiedChild $unrelatedId
    Assert-Live $unrelated
    Write-Host "Unrelated ready seed: workload=$unrelatedId; pid=$($unrelated.ProcessId); startTicks=$($unrelated.StartTimeUtcTicks); runId=$($unrelated.RunId)."
    $falseEvidence = [ordered]@{
        WorkloadId = $intent.WorkloadId
        Desired = $intent.Desired
        Workload = $unrelated
        LastObservation = @{ State = 'Stopped'; At = '2000-01-01T00:00:00+00:00' }
    }
    $falseEvidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile
    $contradiction = Start-Manager 'contradictory-history' $stateFile
    Read-Until $contradiction '^Converged:.*starts this manager=0;'
    Stop-Manager $contradiction
    Assert-Starts $contradiction 0
    $fresh = Observed-Identity $contradiction
    Assert ($fresh.ProcessId -eq $survivor.ProcessId) 'Saved locator or Stopped observation overruled reality.'
    Record-Result 'contradictory-history' $intent.WorkloadId $fresh 0 'Unrelated saved locator and saved Stopped ignored; actual matching child adopted.'

    $staleEventName = "Local\ControlPlaneExperiment-$(([guid] $survivor.RunId).ToString('N'))"
    $staleReadiness = [Threading.EventWaitHandle]::OpenExisting($staleEventName)
    $falseEvidence.Workload = $survivor
    $falseEvidence.LastObservation.State = 'Running'
    $falseEvidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile
    Stop-Workload ([pscustomobject]@{ Workload = $survivor })
    Assert ($staleReadiness.WaitOne(0)) 'Test did not retain stale readiness evidence.'
    Assert (@(Matching-Processes $intent.WorkloadId).Count -eq 0) 'Killed workload is still live.'
    $replacementManager = Start-Manager 'after-child-death' $stateFile
    Read-Until $replacementManager '^Converged:.*starts this manager=1;'
    Stop-Manager $replacementManager
    Assert-Starts $replacementManager 1
    Assert ($replacementManager.Lines -match '^Observation 1: fresh=Stopped;') 'Fresh observation accepted stale evidence.'
    $replacement = Observed-Identity $replacementManager
    Assert ($replacement.RunId -ne $survivor.RunId) 'No new incarnation was created.'
    Assert-Live $replacement
    Assert (@(Matching-Processes $intent.WorkloadId).Count -eq 1) 'Expected exactly one replacement.'
    Record-Result 'killed-while-absent' $intent.WorkloadId $replacement 1 'Saved Running and still-signaled old event rejected; exactly one replacement.'

    $otherFile = New-Intent 'unrelated-process'
    $otherIntent = Read-State $otherFile
    $otherManager = Start-Manager 'unrelated-process' $otherFile
    Read-Until $otherManager '^Converged:.*starts this manager=1;'
    Stop-Manager $otherManager
    Assert-Starts $otherManager 1
    $otherChild = Observed-Identity $otherManager
    Assert ($otherChild.ProcessId -ne $unrelated.ProcessId -and $otherChild.ProcessId -ne $replacement.ProcessId) `
        'Adopted a similar process with another logical ID.'
    Assert-Live $unrelated
    Assert-Live $replacement
    Assert-Live $otherChild
    Record-Result 'unrelated-process' $otherIntent.WorkloadId $otherChild 1 "Other logical IDs ignored, including ready PID $($unrelated.ProcessId)."

    $pendingFile = New-Intent 'restart-during-startup'
    $pendingIntent = Read-State $pendingFile
    $pendingFirst = Start-Manager 'starting-before-restart' $pendingFile 5000
    Read-Until $pendingFirst '^Observation 2: fresh=Starting;'
    Stop-Manager $pendingFirst
    Assert-Starts $pendingFirst 1
    $pendingChild = Observed-Identity $pendingFirst
    $pendingSecond = Start-Manager 'starting-after-restart' $pendingFile
    Read-Until $pendingSecond '^Converged:.*starts this manager=0;'
    Stop-Manager $pendingSecond
    Assert-Starts $pendingSecond 0
    $pendingAdopted = Observed-Identity $pendingSecond
    Assert ($pendingAdopted.ProcessId -eq $pendingChild.ProcessId -and $pendingAdopted.RunId -eq $pendingChild.RunId) `
        'Restart during startup did not preserve the incarnation.'
    Assert ($pendingSecond.Lines -match '^Observation 1: fresh=Starting;') 'Did not restart during startup.'
    Assert-Live $pendingAdopted
    Assert (@(Matching-Processes $pendingIntent.WorkloadId).Count -eq 1) 'Restart during startup created a duplicate.'
    Record-Result 'restart-during-startup' $pendingIntent.WorkloadId $pendingAdopted 1 `
        'First manager: 1 Start; restart observed Starting then Running; 0 additional Starts; same incarnation.'

    $hungFile = New-Intent 'never-ready'
    $hungIntent = Read-State $hungFile
    $hungChild = Start-IdentifiedChild $hungIntent.WorkloadId -1
    Assert-Live $hungChild $false
    $hungManager = Start-Manager 'never-ready' $hungFile
    Read-Until $hungManager '^Observation 3: fresh=Starting;'
    Stop-Manager $hungManager
    Assert-Starts $hungManager 0
    Assert (-not ($hungManager.Lines -match '^Converged:')) 'Identity was mistaken for readiness.'
    Assert-Live $hungChild $false
    Record-Result 'never-ready' $hungIntent.WorkloadId $hungChild 0 'Alive, identifiable, readiness unsignaled; three Starting observations, no Start or convergence; bounded test stopped manager.'

    $ambiguousFile = New-Intent 'multiple-matches'
    $ambiguousIntent = Read-State $ambiguousFile
    $ambiguousOne = Start-IdentifiedChild $ambiguousIntent.WorkloadId
    $ambiguousTwo = Start-IdentifiedChild $ambiguousIntent.WorkloadId
    Assert-Live $ambiguousOne
    Assert-Live $ambiguousTwo
    $ambiguousManager = Start-Manager 'multiple-matches' $ambiguousFile -CaptureError
    Assert ($ambiguousManager.Process.WaitForExit(15000)) 'Ambiguous discovery did not stop explicitly.'
    $stdout = $ambiguousManager.Process.StandardOutput.ReadToEnd()
    foreach ($line in ($stdout -split '\r?\n' | Where-Object { $_ })) { $ambiguousManager.Lines.Add($line) }
    Stop-Manager $ambiguousManager
    $errorText = Get-Content -Raw -LiteralPath ($ambiguousManager.Log + '.stderr')
    Assert ($ambiguousManager.Process.ExitCode -ne 0 -and $errorText -match 'Multiple live realizations') `
        'Ambiguity was silently accepted.'
    Assert-Starts $ambiguousManager 0
    Assert (@(Matching-Processes $ambiguousIntent.WorkloadId).Count -eq 2) 'Ambiguity created or removed a child.'
    Record-Result 'multiple-matches' $ambiguousIntent.WorkloadId @($ambiguousOne, $ambiguousTwo) 0 `
        'Explicit error; neither arbitrary adoption nor third Start; no remediation.'

    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
    Write-Host "PASS: all Day 2.3 scenarios. Evidence: $evidence"
}
finally {
    foreach ($session in $sessions) { Stop-Manager $session }
    foreach ($identity in $children) { Stop-Workload ([pscustomobject]@{ Workload = $identity }) }
    # Include any newly created child if an assertion failed before its observation was collected.
    foreach ($stateFile in $stateFiles) {
        if (Test-Path -LiteralPath $stateFile) {
            $state = Read-State $stateFile
            Stop-MatchingWorkloads $state.WorkloadId
        }
    }
    if ($null -ne $staleReadiness) { $staleReadiness.Dispose() }
    foreach ($session in $sessions) { $session.Process.Dispose() }
}
