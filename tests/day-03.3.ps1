#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$assembly = [System.IO.Path]::ChangeExtension($executable, '.dll')
$evidence = (New-Item -ItemType Directory -Path (Join-Path $root ".state\day-03.3-$([guid]::NewGuid().ToString('N'))")).FullName
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
$children = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$events = [System.Collections.Generic.List[object]]::new()
. "$PSScriptRoot\process-helpers.ps1"

function Capture-Error($session) {
    $session | Add-Member -NotePropertyName ErrorTask -NotePropertyValue $session.Process.StandardError.ReadToEndAsync()
    return $session
}

function Start-Grant([string] $name, [string] $file, [long] $epoch) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @('grant', $file, "$epoch")) { $info.ArgumentList.Add($argument) }
    $session = [pscustomobject]@{
        Name = $name; Process = [System.Diagnostics.Process]::Start($info)
        Lines = [System.Collections.Generic.List[string]]::new()
        Log = Join-Path $evidence "$name.log"; CaptureError = $true; AuthorityEpoch = $epoch
    }
    $sessions.Add($session)
    return Capture-Error $session
}

function Start-Fenced(
    [string] $name, [string] $file, [string] $authorityFile, [long] $epoch,
    [string] $beforeStart, [string] $afterBoundaryCheck
) {
    return Capture-Error (Start-Manager $name $file 1000 -AuthorityEpoch $epoch -AuthorityFile $authorityFile `
        -PauseBeforeStartEvent $beforeStart -PauseAfterStartAuthorityCheckEvent $afterBoundaryCheck -CaptureError)
}

function Read-Exited($session, [bool] $success) {
    Assert ($session.Process.WaitForExit(15000)) "$($session.Name) did not exit."
    Assert (($session.Process.ExitCode -eq 0) -eq $success) "$($session.Name): unexpected exit code."
    foreach ($line in ($session.Process.StandardOutput.ReadToEnd() -split '\r?\n' | Where-Object { $_ })) {
        $session.Lines.Add($line)
    }
    $errorText = $session.ErrorTask.GetAwaiter().GetResult()
    return $errorText
}

function Advance([string] $name, [string] $file, [long] $epoch) {
    $session = Start-Grant $name $file $epoch
    Assert ((Read-Exited $session $true) -eq '') 'Successful grant wrote an error.'
    Assert ($session.Lines -match "^Authority advanced:.*currentEpoch=$epoch;") 'Grant was not committed.'
    Assert ([System.IO.File]::ReadAllText($file) -ceq "$epoch") 'Wrong recorded grant.'
    return $session
}

function New-Gate {
    $name = "Local\ControlPlaneExperiment-Day33-$([guid]::NewGuid().ToString('N'))"
    $handle = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $name)
    $gate = [pscustomobject]@{ Name = $name; Handle = $handle }
    $events.Add($gate)
    return $gate
}

function Assert-Intent([string] $file, [byte[]] $original) {
    Assert ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file)) -ceq [Convert]::ToBase64String($original)) `
        'Authority activity changed workload intent bytes.'
    Assert ((((Read-State $file).PSObject.Properties.Name | Sort-Object) -join ',') -eq 'Desired,WorkloadId') `
        'Authority state leaked into workload intent.'
}

function Assert-Same($expected, $actual) {
    Assert ($expected.ProcessId -eq $actual.ProcessId -and $expected.StartTimeUtcTicks -eq $actual.StartTimeUtcTicks `
        -and $expected.RunId -eq $actual.RunId) 'The original incarnation changed.'
}

function Assert-Only([string] $workloadId, $identity) {
    Assert-Live $identity
    $matching = @(Matching-Processes $workloadId)
    Assert ($matching.Count -eq 1 -and $matching[0].ProcessId -eq $identity.ProcessId `
        -and $matching[0].CommandLine -like "*--workload $workloadId $($identity.RunId) *") `
        'Expected exactly the original matching ready incarnation.'
}

function Relinquish($session) {
    $session.Process.StandardInput.WriteLine('relinquish')
    $session.Process.StandardInput.Flush()
    Read-Until $session '^Authority relinquished:'
    Assert ($session.Process.WaitForExit(5000) -and $session.Process.ExitCode -eq 0) 'Clean manager exit failed.'
}

function Stamp([string] $line) {
    Assert ($line -match 'at=([^; ]+)\.$') 'Missing timestamp.'
    return [datetimeoffset]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
}

function Manager-Evidence($session) {
    $ticks = $session.Process.StartTime.ToUniversalTime().Ticks
    Assert ($session.Lines -match "Manager=$($session.Process.Id);.*managerStartTicks=$ticks; authorityEpoch=$($session.AuthorityEpoch)\.") `
        'Manager identity was not independently checked.'
    return @{
        ProcessId = $session.Process.Id; StartTimeUtcTicks = $ticks; Epoch = $session.AuthorityEpoch
        ExitCode = $session.Process.ExitCode; Lines = @($session.Lines)
    }
}

try {
    $file = New-Intent 'stale-decision'
    $intent = Read-State $file
    $originalJson = [System.IO.File]::ReadAllText($file)
    $originalBytes = [System.IO.File]::ReadAllBytes($file)
    $authorityFile = Join-Path $evidence 'stale-decision.epoch'
    $grant1 = Advance 'grant-1' $authorityFile 1

    $future = Start-Fenced 'ungranted-3' $file $authorityFile 3
    Assert ($future.Process.WaitForExit(15000)) 'Future-epoch manager did not exit.'
    Assert (@(Matching-Processes $intent.WorkloadId).Count -eq 0) 'An ungranted future epoch created a child.'
    $futureError = Read-Exited $future $false
    Assert ($futureError -match 'Authority rejected: boundary=manager pre-check; offeredEpoch=3; currentEpoch=1') `
        'An ungranted future epoch was not rejected explicitly.'
    Assert-Starts $future 0

    $gate = New-Gate
    $first = Start-Fenced 'stale-A' $file $authorityFile 1 $gate.Name
    Read-Until $first '^Experiment paused: after Start decision; before process creation;'
    Assert ($first.Lines -match '^Observation 1: fresh=Stopped;' `
        -and $first.Lines -match '^Decision=start;.*authorityEpoch=1; observation=1;' `
        -and $first.Lines -match '^Authority accepted: boundary=manager pre-check; offeredEpoch=1; currentEpoch=1;') `
        'A did not validly decide and pass its manager pre-check under epoch 1.'
    Assert (-not $first.Process.HasExited -and -not $gate.Handle.WaitOne(0)) 'A was not held before the effect.'
    Assert-Starts $first 0
    Assert (@(Matching-Processes $intent.WorkloadId).Count -eq 0) 'A created a process before release.'
    Assert-Intent $file $originalBytes

    $grant2 = Advance 'grant-2' $authorityFile 2
    $movedAt = Stamp @($grant2.Lines | Where-Object { $_ -match '^Authority advanced:' })[-1]
    $second = Start-Fenced 'current-B' $file $authorityFile 2
    Read-Until $second '^Converged:.*starts this manager=1;'
    $original = Observed-Identity $second
    Assert ($second.Lines -match '^Observation 1: fresh=Stopped;' -and $second.Lines -match 'fresh=Starting;' `
        -and $second.Lines -match 'fresh=Running;') 'B did not observe absence, startup, and readiness.'
    Assert-Only $intent.WorkloadId $original
    Assert (-not $first.Process.HasExited -and -not $gate.Handle.WaitOne(0)) 'A did not survive the authority move.'
    Assert-Intent $file $originalBytes

    $releasedAt = [datetimeoffset]::UtcNow
    Assert ($gate.Handle.Set()) 'Could not release the old decision.'
    Assert ($first.Process.WaitForExit(15000)) 'Stale A did not exit.'
    Assert-Only $intent.WorkloadId $original
    $rejection = Read-Exited $first $false
    Assert ($rejection -match 'Authority rejected: boundary=process creation; offeredEpoch=1; currentEpoch=2') `
        'The process-creation boundary did not reject stale authority.'
    Assert ($first.Lines -match '^Experiment resumed: continuing decided Start without rediscovery;') 'No resume evidence.'
    Assert (@($first.Lines | Where-Object { $_ -match '^Observation ' }).Count -eq 1 `
        -and @($first.Lines | Where-Object { $_ -match '^Decision=start;' }).Count -eq 1) 'A reconsidered its old decision.'
    Assert-Starts $first 0
    Assert (-not ($first.Lines -match '^Authority accepted: boundary=process creation;')) 'Stale creation was accepted.'
    Assert (-not ($first.Lines -match '^Converged:|^Authority relinquished:')) 'A falsely converged or relinquished.'

    $afterRejection = [datetimeoffset]::UtcNow
    do {
        Read-Until $second '^Observation .*fresh=Running;'
    } while ((Stamp $second.Lines[-1]) -le $afterRejection)
    $postRejection = $second.Lines[-1]
    Assert-Same $original (Observed-Identity $second)
    Assert (-not $second.Process.HasExited) 'B failed after stale A was rejected.'
    Assert-Only $intent.WorkloadId $original

    $recordedGrant = [System.IO.File]::ReadAllText($authorityFile)
    $lower = Start-Grant 'reject-lower-grant' $authorityFile 1
    $lowerError = Read-Exited $lower $false
    Assert ($lowerError -match 'Authority rejected: boundary=grant; offeredEpoch=1; currentEpoch=2') 'Grant order regressed.'
    $equal = Start-Grant 'reject-equal-grant' $authorityFile 2
    Assert ((Read-Exited $equal $false) -match 'Authority rejected: boundary=grant; offeredEpoch=2; currentEpoch=2') `
        'The authority source accepted a non-increasing grant.'
    $zero = Start-Grant 'reject-zero-grant' $authorityFile 0
    Assert ((Read-Exited $zero $false) -match 'Use a positive authority epoch') 'A non-positive grant was accepted.'
    Assert ([System.IO.File]::ReadAllText($authorityFile) -ceq $recordedGrant) 'Rejected grants changed authority state.'
    Assert-Intent $file $originalBytes

    Stop-Workload ([pscustomobject]@{ Workload = $original })
    Read-Until $second '^Converged:.*starts this manager=2;'
    $replacement = Observed-Identity $second
    Assert ($replacement.RunId -ne $original.RunId) 'Current authority did not replace the killed realization.'
    Assert-Only $intent.WorkloadId $replacement
    Assert-Starts $second 2
    Assert-Intent $file $originalBytes
    Relinquish $second
    $results.Add([ordered]@{
        Scenario = 'stale-decision-rejected'; WorkloadId = $intent.WorkloadId; IntentJson = $originalJson
        AuthorityFile = $authorityFile; RecordedEpoch = $recordedGrant
        Grant1 = @($grant1.Lines); Grant2 = @($grant2.Lines); AuthorityMovedAt = $movedAt; ReleasedAt = $releasedAt
        ManagerA = Manager-Evidence $first; ManagerB = Manager-Evidence $second
        Rejection = [regex]::Match($rejection, 'Authority rejected:[^\r\n]+').Value
        UngrantedFuture = [regex]::Match($futureError, 'Authority rejected:[^\r\n]+').Value
        LowerGrant = [regex]::Match($lowerError, 'Authority rejected:[^\r\n]+').Value
        Original = $original; AfterRejectionObservation = $postRejection; Replacement = $replacement
        StaleStarts = 0; CurrentStarts = 2; MatchingAfterRejection = 1; IntentUnchanged = $true
    })

    $gapFile = New-Intent 'check-to-spawn'
    $gapIntent = Read-State $gapFile
    $gapJson = [System.IO.File]::ReadAllText($gapFile)
    $gapBytes = [System.IO.File]::ReadAllBytes($gapFile)
    $gapAuthority = Join-Path $evidence 'check-to-spawn.epoch'
    [void] (Advance 'gap-grant-1' $gapAuthority 1)
    $gapGate = New-Gate
    $gapA = Start-Fenced 'gap-A' $gapFile $gapAuthority 1 '' $gapGate.Name
    Read-Until $gapA '^Experiment paused: after boundary authority check; before Process.Start;'
    Assert ($gapA.Lines -match '^Authority accepted: boundary=process creation; offeredEpoch=1; currentEpoch=1;') `
        'A did not enter the actual locked creation boundary.'
    Assert-Starts $gapA 0
    Assert (@(Matching-Processes $gapIntent.WorkloadId).Count -eq 0) 'The boundary pause was after creation.'

    $pendingGrant = Start-Grant 'gap-grant-2' $gapAuthority 2
    Read-Until $pendingGrant '^Authority lock waiting: offeredEpoch=2;'
    Assert (-not $pendingGrant.Process.HasExited -and -not $gapA.Process.HasExited `
        -and -not $gapGate.Handle.WaitOne(0)) 'The critical-section experiment was not held.'
    Assert ([System.IO.File]::ReadAllText($gapAuthority) -ceq '1') 'Epoch 2 became current inside the old creation boundary.'
    Assert-Intent $gapFile $gapBytes
    $gapReleasedAt = [datetimeoffset]::UtcNow
    Assert ($gapGate.Handle.Set()) 'Could not release locked creation.'
    Read-Until $gapA '^Action=start returned;'
    $gapChild = Remember-Identity $gapA.Lines[-1]
    Assert ((Read-Exited $pendingGrant $true) -eq '') 'The pending grant failed.'
    $committedAt = Stamp @($pendingGrant.Lines | Where-Object { $_ -match '^Authority advanced:' })[-1]
    Assert ($gapChild.StartTimeUtcTicks -gt $gapReleasedAt.UtcTicks `
        -and $gapChild.StartTimeUtcTicks -lt $committedAt.UtcTicks) 'Grant completion was not ordered after OS creation.'
    Assert ([System.IO.File]::ReadAllText($gapAuthority) -ceq '2') 'The pending grant never became current.'
    Relinquish $gapA

    $gapB = Start-Fenced 'gap-B' $gapFile $gapAuthority 2
    Read-Until $gapB '^Converged:.*starts this manager=0;'
    Assert-Same $gapChild (Observed-Identity $gapB)
    Assert-Only $gapIntent.WorkloadId $gapChild
    Assert-Intent $gapFile $gapBytes
    Assert-Starts $gapA 1
    Assert-Starts $gapB 0
    Relinquish $gapB
    $results.Add([ordered]@{
        Scenario = 'check-to-spawn-serialized'; WorkloadId = $gapIntent.WorkloadId; IntentJson = $gapJson
        ManagerA = Manager-Evidence $gapA; ManagerB = Manager-Evidence $gapB
        Grant2 = @($pendingGrant.Lines); ReleasedAt = $gapReleasedAt; AuthorityMovedAt = $committedAt
        EpochWhileCreationPaused = 1; RecordedEpoch = [System.IO.File]::ReadAllText($gapAuthority)
        Realization = $gapChild; StartsA = 1; StartsB = 0; Matching = 1; IntentUnchanged = $true
    })
}
finally {
    foreach ($session in $sessions) {
        if (-not $session.Process.HasExited) { Stop-Process -Id $session.Process.Id -Force }
        Assert ($session.Process.WaitForExit(5000)) 'A test process did not exit.'
    }
    foreach ($child in $children) { Stop-Workload ([pscustomobject]@{ Workload = $child }) }
    foreach ($file in $stateFiles) { Stop-MatchingWorkloads (Read-State $file).WorkloadId }
    foreach ($session in $sessions) {
        try {
            foreach ($line in ($session.Process.StandardOutput.ReadToEnd() -split '\r?\n' | Where-Object { $_ })) {
                $session.Lines.Add($line)
            }
            [System.IO.File]::WriteAllText($session.Log + '.stderr', $session.ErrorTask.GetAwaiter().GetResult())
            Stop-Manager $session
        }
        finally { $session.Process.Dispose() }
    }
    foreach ($gate in $events) { $gate.Handle.Dispose() }
}

foreach ($name in @('current-B', 'gap-A', 'gap-B')) {
    Assert ([string]::IsNullOrEmpty([System.IO.File]::ReadAllText((Join-Path $evidence "$name.log.stderr")))) `
        "$name failed instead of remaining healthy."
}
$results | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
Write-Host ($results | ConvertTo-Json -Depth 7 -Compress)
Write-Host "PASS: stale Start rejected after a passed manager check; current authority replaced its child; check-to-spawn serialized with grant advancement. Evidence: $evidence"
