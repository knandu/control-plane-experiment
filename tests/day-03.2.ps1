#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$assembly = [System.IO.Path]::ChangeExtension($executable, '.dll')
$evidence = (New-Item -ItemType Directory -Path (Join-Path $root ".state\day-03.2-$([guid]::NewGuid().ToString('N'))")).FullName
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
$children = [System.Collections.Generic.List[object]]::new()
$remainingOutput = @{}
$exitCodes = @{}
. "$PSScriptRoot\process-helpers.ps1"

$eventName = "Local\ControlPlaneExperiment-BeforeStart-$([guid]::NewGuid().ToString('N'))"
$resume = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $eventName)

function Manager-Identity($session) {
    $ticks = $session.Process.StartTime.ToUniversalTime().Ticks
    Assert ($session.Lines -match "Manager=$($session.Process.Id);.*managerStartTicks=$ticks; authorityEpoch=$($session.AuthorityEpoch)\.") `
        'Manager identity and authority context were not independently reported.'
    return [pscustomobject]@{
        ProcessId = $session.Process.Id
        StartTimeUtcTicks = $ticks
        Epoch = $session.AuthorityEpoch
    }
}

function Assert-OldManagerPaused {
    Assert (-not $first.Process.HasExited) 'Old manager exited before release.'
    Assert (-not $resume.WaitOne(0)) 'The pre-effect gate was released too early.'
    Assert-Starts $first 0
    Assert (-not ($first.Lines -match '^Authority relinquished:|^Experiment resumed:')) `
        'Old manager relinquished or resumed before the authority move completed.'
}

function Assert-IntentUnchanged {
    Assert ([System.IO.File]::ReadAllText($stateFile) -ceq $intentJson) 'The experiment rewrote durable intent.'
    Assert ((((Read-State $stateFile).PSObject.Properties.Name | Sort-Object) -join ',') -eq 'Desired,WorkloadId') `
        'Authority metadata entered durable workload state.'
}

try {
    $stateFile = New-Intent 'stale-start'
    $intent = Read-State $stateFile
    $intentJson = [System.IO.File]::ReadAllText($stateFile)
    Assert (@(Matching-Processes $intent.WorkloadId).Count -eq 0) 'Initial reality was not empty.'
    $declaredEpoch = 1

    $first = Start-Manager 'old-A' $stateFile 1000 -AuthorityEpoch $declaredEpoch `
        -PauseBeforeStartEvent $eventName -CaptureError
    Read-Until $first '^Experiment paused: after Start decision; before process creation;'
    $identityA = Manager-Identity $first
    $observationA = @($first.Lines | Where-Object { $_ -match '^Observation ' })
    Assert ($observationA.Count -eq 1 -and $observationA[0] -match '^Observation 1: fresh=Stopped;') `
        'Old manager did not decide from its initial fresh absence observation.'
    $decisionA = @($first.Lines | Where-Object { $_ -match "^Decision=start;.*authorityEpoch=1; observation=1;" })
    Assert ($decisionA.Count -eq 1) 'No single epoch-1 Start decision was established.'
    $pause = $first.Lines[-1]
    Assert ($pause -like "*starts this manager=0; resumeEvent=$eventName;*") 'Wrong pre-effect pause.'
    Assert-OldManagerPaused
    Assert (@(Matching-Processes $intent.WorkloadId).Count -eq 0) 'A created a process before release.'
    Assert-IntentUnchanged

    $declaredEpoch = 2
    $authorityMovedAt = [datetimeoffset]::UtcNow
    Write-Host "External authority assignment: epoch=2; old manager remains paused; at=$($authorityMovedAt.ToString('O'))."
    $second = Start-Manager 'current-B' $stateFile 1000 -AuthorityEpoch $declaredEpoch -CaptureError
    Read-Until $second '^Converged:.*starts this manager=1;'
    $identityB = Manager-Identity $second
    $childB = Observed-Identity $second
    $remainingOutput[$second.Name] = $second.Process.StandardOutput.ReadToEndAsync()
    Assert-Starts $second 1
    Assert ($second.Lines -match '^Observation 1: fresh=Stopped;' `
        -and $second.Lines -match '^Decision=start;.*authorityEpoch=2; observation=1;' `
        -and $second.Lines -match 'fresh=Starting;' -and $second.Lines -match 'fresh=Running;') `
        'Current authority did not independently decide, start, and observe readiness.'
    Assert-Live $childB
    $before = @(Matching-Processes $intent.WorkloadId)
    Assert ($before.Count -eq 1 -and $before[0].ProcessId -eq $childB.ProcessId) 'B did not create exactly one realization.'
    Assert-OldManagerPaused
    Assert-IntentUnchanged

    $releasedAt = [datetimeoffset]::UtcNow
    Write-Host "External release: epoch=$declaredEpoch; B already converged; at=$($releasedAt.ToString('O'))."
    Assert ($resume.Set()) 'The experiment could not release the old decision.'
    Read-Until $first '^Experiment resumed: continuing decided Start without rediscovery;'
    $resumeMarker = $first.Lines[-1]
    Read-Until $first '^Action=start returned;'
    $childA = Remember-Identity $first.Lines[-1]
    $remainingOutput[$first.Name] = $first.Process.StandardOutput.ReadToEndAsync()
    Assert-Starts $first 1
    Assert ($childA.StartTimeUtcTicks -gt $releasedAt.UtcTicks `
        -and $childA.StartTimeUtcTicks -gt $authorityMovedAt.UtcTicks `
        -and $childA.RunId -ne $childB.RunId) 'No distinct effect occurred after authority movement and release.'
    $beforeEffect = $first.Lines | Select-Object -First ($first.Lines.Count - 1)
    Assert (@($beforeEffect | Where-Object { $_ -match '^Observation ' }).Count -eq 1 `
        -and @($beforeEffect | Where-Object { $_ -match '^Decision=start;' }).Count -eq 1) `
        'A rediscovered reality or made a new decision before its delayed effect.'
    foreach ($session in $sessions) {
        Assert ($session.Process.WaitForExit(15000) -and $session.Process.ExitCode -ne 0) `
            'A manager did not stop explicitly after the duplicate became discoverable.'
    }

    $after = @(Matching-Processes $intent.WorkloadId)
    Assert ($after.Count -eq 2) 'Expected exactly two matching live realizations.'
    foreach ($child in @($childB, $childA)) {
        Assert-Live $child
        $match = @($after | Where-Object { $_.ProcessId -eq $child.ProcessId })
        Assert ($match.Count -eq 1 -and $match[0].CommandLine -like "*--workload $($intent.WorkloadId) $($child.RunId) *") `
            'A resulting realization did not expose the expected logical and run identity.'
    }
    Assert ($declaredEpoch -eq 2) 'Declared current authority unexpectedly changed.'
    Assert-IntentUnchanged
}
finally {
    # Children inherit redirected writers; drain only after managers and children exit.
    foreach ($session in $sessions) {
        if (-not $session.Process.HasExited) { Stop-Process -Id $session.Process.Id -Force }
        Assert ($session.Process.WaitForExit(5000)) 'Manager did not exit during teardown.'
        $exitCodes[$session.Name] = $session.Process.ExitCode
    }
    foreach ($child in $children) { Stop-Workload ([pscustomobject]@{ Workload = $child }) }
    foreach ($file in $stateFiles) { Stop-MatchingWorkloads (Read-State $file).WorkloadId }
    foreach ($session in $sessions) {
        try {
            $remaining = if ($remainingOutput.ContainsKey($session.Name)) {
                $remainingOutput[$session.Name].GetAwaiter().GetResult()
            }
            else { $session.Process.StandardOutput.ReadToEnd() }
            foreach ($line in ($remaining -split '\r?\n' | Where-Object { $_ })) { $session.Lines.Add($line) }
            Stop-Manager $session
        }
        finally { $session.Process.Dispose() }
    }
    $resume.Dispose()
}

$ambiguities = [System.Collections.Generic.List[string]]::new()
foreach ($session in $sessions) {
    $errorText = Get-Content -Raw -LiteralPath ($session.Log + '.stderr')
    Assert ($errorText -match "Multiple live realizations of workload $($intent.WorkloadId): ([\d, ]+)\. No Start issued\.") `
        'A manager failed for something other than explicit duplicate ambiguity.'
    $ambiguousPids = @($Matches[1] -split ', ' | ForEach-Object { [int] $_ })
    Assert (-not (Compare-Object @($childA.ProcessId, $childB.ProcessId) $ambiguousPids)) `
        'Ambiguity reported the wrong realizations.'
    $ambiguities.Add([regex]::Match($errorText, 'Multiple live realizations[^\r\n]+').Value)
    Assert-Starts $session 1
    Assert (-not ($session.Lines -match '^Authority relinquished:')) 'A manager cooperatively relinquished.'
}
Assert (-not ($first.Lines -match '^Converged:')) 'Old authority falsely reported convergence.'
Assert (@($second.Lines | Where-Object { $_ -match '^Converged:' }).Count -eq 1) `
    'Current authority reported convergence again after the duplicate existed.'

$result = [ordered]@{
    WorkloadId = $intent.WorkloadId
    Desired = $intent.Desired
    DeclaredCurrentEpoch = $declaredEpoch
    AuthorityMovedAt = $authorityMovedAt
    ReleasedAt = $releasedAt
    ManagerA = @{
        Identity = $identityA; Observation = $observationA[0]; Decision = $decisionA[0]
        Pause = $pause; Resume = $resumeMarker; Starts = 1
        ConvergenceCount = 0; ExitCode = $exitCodes[$first.Name]; Ambiguity = $ambiguities[0]
    }
    ManagerB = @{
        Identity = $identityB; Starts = 1; ConvergedBeforeRelease = $true
        Observations = @($second.Lines | Where-Object { $_ -match '^Observation ' })
        Decision = @($second.Lines | Where-Object { $_ -match '^Decision=start;' })[0]
        ConvergenceCount = 1; ExitCode = $exitCodes[$second.Name]; Ambiguity = $ambiguities[1]
    }
    BeforeRelease = @{ OldManagerAlive = $true; OldManagerPaused = $true; LiveMatchingRealizations = $before.Count }
    Realizations = @(
        @{ CreatedByEpoch = 2; Identity = $childB; State = 'Running' }
        @{ CreatedByEpoch = 1; Identity = $childA; State = 'Running' }
    )
    TotalStarts = 2
    LiveMatchingRealizations = $after.Count
    ConvergenceAfterDuplicate = $false
    IntentUnchanged = $true
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
Write-Host ($result | ConvertTo-Json -Depth 6 -Compress)
Write-Host "LIMITATION REPRODUCED: epoch-1 decision executed after epoch 2 converged; ready duplicates $($childB.ProcessId), $($childA.ProcessId); both managers reported ambiguity."
Write-Host "PASS: Day 3.2 stale decided Start reproduced, not repaired. Evidence: $evidence"
