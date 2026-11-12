#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$assembly = [System.IO.Path]::ChangeExtension($executable, '.dll')
$evidence = (New-Item -ItemType Directory -Path (Join-Path $root ".state\day-04.1-$([guid]::NewGuid().ToString('N'))")).FullName
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
$children = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$events = [System.Collections.Generic.List[object]]::new()
$inspections = [System.Collections.Generic.List[object]]::new()
. "$PSScriptRoot\process-helpers.ps1"

function New-Gate {
    $name = "Local\ControlPlaneExperiment-Day41-$([guid]::NewGuid().ToString('N'))"
    $gate = [pscustomobject]@{
        Name = $name
        Handle = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $name)
    }
    $events.Add($gate)
    return $gate
}

function Start-Fleet(
    [string] $name, [string] $file, [string] $authorityFile, [long] $epoch, $gate,
    [switch] $PauseAfterFirstStart
) {
    $session = Start-Manager $name $file 600 -AuthorityEpoch $epoch -AuthorityFile $authorityFile `
        -PauseBeforeReadinessEvent $gate.Name -PauseBeforeLocatorSave:$PauseAfterFirstStart -CaptureError
    $session | Add-Member -NotePropertyName ErrorTask -NotePropertyValue $session.Process.StandardError.ReadToEndAsync()
    return $session
}

function Advance([string] $file, [long] $epoch) {
    $lines = @(& $executable grant $file $epoch)
    Assert ($LASTEXITCODE -eq 0) 'Grant command failed.'
    Assert ([System.IO.File]::ReadAllText($file) -ceq "$epoch") 'Wrong current authority.'
    foreach ($line in $lines) { Write-Host "[grant] $line" }
    return $lines
}

function Relinquish($session) {
    $session.Process.StandardInput.WriteLine('relinquish')
    $session.Process.StandardInput.Flush()
    Read-Until $session '^Authority relinquished:'
    Assert ($session.Process.WaitForExit(5000) -and $session.Process.ExitCode -eq 0) 'Clean manager exit failed.'
}

function Members([string] $line) {
    foreach ($match in [regex]::Matches($line, 'domain=([^,;]+),state=(Starting|Running),pid=(\d+),startTicks=(\d+),runId=([0-9a-f-]+)')) {
        [pscustomobject]@{
            Domain = $match.Groups[1].Value
            State = $match.Groups[2].Value
            ProcessId = [int] $match.Groups[3].Value
            StartTimeUtcTicks = [long] $match.Groups[4].Value
            RunId = $match.Groups[5].Value
        }
    }
}

function Latest-Observation($session) {
    return @($session.Lines | Where-Object { $_ -match '^Observation ' })[-1]
}

function Identity-Key($member) {
    return "$($member.ProcessId):$($member.StartTimeUtcTicks):$($member.RunId):$($member.Domain)"
}

function Assert-Retained($expected, $actual) {
    foreach ($member in $expected) {
        Assert (@($actual | Where-Object { (Identity-Key $_) -ceq (Identity-Key $member) }).Count -eq 1) `
            'An existing incarnation was not retained.'
    }
}

function Assert-Fleet([string] $workloadId, [object[]] $members) {
    $matching = @(Matching-Processes $workloadId)
    Assert ($matching.Count -eq $members.Count) 'External discovery found a different live cardinality.'
    foreach ($member in $members) {
        $children.Add($member)
        Assert-Live $member ($member.State -eq 'Running')
        $candidate = @($matching | Where-Object { $_.ProcessId -eq $member.ProcessId })
        Assert ($candidate.Count -eq 1) 'A logged member was not independently rediscoverable.'
        Assert ($candidate[0].SessionId -eq [System.Diagnostics.Process]::GetCurrentProcess().SessionId) 'Wrong session.'
        Assert ([math]::Floor($candidate[0].CreationDate.ToUniversalTime().Ticks / [decimal] 10) -eq `
            [math]::Floor($member.StartTimeUtcTicks / [decimal] 10)) 'WMI/native incarnation mismatch.'
        $launch = '(?:^|\s)"?' + [regex]::Escape($assembly) + '"?\s+--workload\s+' + `
            [regex]::Escape($workloadId) + '\s+' + [regex]::Escape($member.RunId) + '\s+\d+'
        if ($null -ne $member.Domain) { $launch += '\s+' + [regex]::Escape($member.Domain) }
        $launch += '\s*$'
        Assert ($candidate[0].CommandLine -match $launch) 'Logical identity, run ID, or launch shape changed.'
        $inspections.Add([ordered]@{
            At = [datetimeoffset]::UtcNow.ToString('O'); WorkloadId = $workloadId
            ProcessId = $member.ProcessId; VerifiedNativeStartTimeUtcTicks = $member.StartTimeUtcTicks
            WmiCreationUtc = $candidate[0].CreationDate.ToUniversalTime().ToString('O')
            RunId = $member.RunId; Domain = $member.Domain; VerifiedReady = $member.State -eq 'Running'
            CommandLine = $candidate[0].CommandLine
        })
    }
}

function Assert-Intent([string] $file, [byte[]] $original) {
    Assert ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file)) -ceq [Convert]::ToBase64String($original)) `
        'Reconciliation changed durable intent bytes.'
    $state = Read-State $file
    Assert ((($state.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'Desired,Replicas,WorkloadId' `
        -and $state.Replicas -eq 3) 'Durable intent contains more than logical identity, desired state, and cardinality.'
}

function Assert-Trace($session) {
    $observations = @($session.Lines | Where-Object { $_ -match '^Observation ' })
    foreach ($line in $observations) {
        Assert ($line -match 'desiredReplicas=3; runningCount=(\d+); startingCount=(\d+); liveCount=(\d+);') `
            'Missing set counts.'
        $running = [int] $Matches[1]; $starting = [int] $Matches[2]; $live = [int] $Matches[3]
        $members = @(Members $line)
        Assert ($live -eq $members.Count -and $live -eq $running + $starting -and $live -le 3 `
            -and @($members | Where-Object State -EQ 'Running').Count -eq $running `
            -and @($members | Where-Object State -EQ 'Starting').Count -eq $starting) 'Inconsistent live-set observation.'
        Assert (@($members.Domain | Sort-Object -Unique).Count -eq $members.Count `
            -and @($members | Where-Object { $_.Domain -notin @('domain-1','domain-2','domain-3') }).Count -eq 0) `
            'An accepted observation violated domain isolation.'
        $keys = @($members | ForEach-Object { Identity-Key $_ }) -join ','
        $sorted = @($members | Sort-Object StartTimeUtcTicks, ProcessId, RunId | ForEach-Object { Identity-Key $_ }) -join ','
        Assert ($keys -ceq $sorted) 'Set discovery was not deterministic.'
    }
    for ($index = 0; $index -lt $session.Lines.Count; $index++) {
        if ($session.Lines[$index] -notmatch '^Decision=start;') { continue }
        $previous = @($session.Lines | Select-Object -First $index | Where-Object { $_ -match '^Observation ' })[-1]
        Assert ($previous -match 'liveCount=([0-2]);') 'Start was decided without a creation deficit.'
        $occupied = @(Members $previous).Domain
        $missing = @('domain-1','domain-2','domain-3') | Where-Object { $_ -notin $occupied } | Select-Object -First 1
        Assert ($session.Lines[$index] -match 'domain=(domain-[1-3]);' -and $Matches[1] -ceq $missing) `
            'Start did not select the first unoccupied domain.'
    }
    $starts = @($session.Lines | Where-Object { $_ -match '^Action=start returned;' }).Count
    Assert (@($session.Lines | Where-Object { $_ -match '^Authority accepted: boundary=manager pre-check;' }).Count -eq $starts `
        -and @($session.Lines | Where-Object { $_ -match '^Authority accepted: boundary=process creation;' }).Count -eq $starts) `
        'A replica Start bypassed an authority boundary.'
}

function Assert-Convergence($session, [int] $starts) {
    Assert ($session.Lines[-1] -match "^Converged: two matching observations; starts this manager=$starts; replicas=3;") `
        'Missing convergence evidence.'
    $observations = @($session.Lines | Where-Object { $_ -match '^Observation ' })
    Assert ($observations.Count -ge 2) 'Convergence had fewer than two observations.'
    foreach ($line in $observations[-2,-1]) {
        Assert ($line -match 'runningCount=3; startingCount=0; liveCount=3;') 'Convergence included pending or absent members.'
        Assert-Retained @(Members $observations[-1]) @(Members $line)
    }
    Assert-Retained @(Members $observations[-1]) @(Members $session.Lines[-1])
    Assert-Starts $session $starts
    Assert-Trace $session
}

function Manager-Evidence($session) {
    $ticks = $session.Process.StartTime.ToUniversalTime().Ticks
    Assert ($session.Lines -match "Manager=$($session.Process.Id);.*managerStartTicks=$ticks; authorityEpoch=$($session.AuthorityEpoch)\.") `
        'Manager identity did not match native process evidence.'
    return [ordered]@{
        ProcessId = $session.Process.Id; StartTimeUtcTicks = $ticks; Epoch = $session.AuthorityEpoch
        Starts = @($session.Lines | Where-Object { $_ -match '^Action=start returned;' }).Count
        Lines = @($session.Lines)
    }
}

function Start-IdentifiedChild([string] $workloadId, [string] $domain, $gate) {
    $runId = [guid]::NewGuid()
    $info = [System.Diagnostics.ProcessStartInfo]::new('dotnet')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    [void] $info.Environment.Remove('CONTROL_PLANE_PAUSE_BEFORE_READINESS_EVENT')
    if ($null -ne $gate) { $info.Environment['CONTROL_PLANE_PAUSE_BEFORE_READINESS_EVENT'] = $gate.Name }
    foreach ($argument in @($assembly, '--workload', $workloadId, "$runId", '0')) { $info.ArgumentList.Add($argument) }
    if ($domain) { $info.ArgumentList.Add($domain) }
    $process = [System.Diagnostics.Process]::Start($info)
    try { $identity = Remember-Identity "pid=$($process.Id); startTicks=$($process.StartTime.ToUniversalTime().Ticks); runId=$runId" }
    finally { $process.Dispose() }
    $identity | Add-Member -NotePropertyName State -NotePropertyValue $(if ($null -eq $gate) { 'Running' } else { 'Starting' })
    $identity | Add-Member -NotePropertyName Domain -NotePropertyValue $(if ($domain) { $domain } else { $null })
    return $identity
}

function Assert-IsolationFailure($session, [object[]] $members, [string] $collision, [string] $unrecognized) {
    Assert ($session.Process.WaitForExit(15000) -and $session.Process.ExitCode -ne 0) 'Isolation violation was silently accepted.'
    foreach ($line in ($session.Process.StandardOutput.ReadToEnd() -split '\r?\n' | Where-Object { $_ })) {
        $session.Lines.Add($line)
    }
    $errorText = $session.ErrorTask.GetAwaiter().GetResult()
    Assert ($errorText -match 'InvalidOperationException: Domain isolation violation for workload' `
        -and $errorText -match "desiredReplicas=3; liveCount=$($members.Count)\. No Start issued\.") `
        'Domain isolation failure was not explicit.'
    foreach ($member in $members) {
        Assert ($errorText -match "(?<!\d)$($member.ProcessId)(?!\d)") 'Isolation error omitted a PID.'
        $domain = if ($null -eq $member.Domain) { '<none>' } else { $member.Domain }
        Assert ($errorText.Contains("domain=$domain,pids=")) 'Isolation error omitted an offending domain.'
    }
    Assert ($errorText.Contains("collisions=[$collision]") -and $errorText.Contains("unrecognized=[$unrecognized]")) `
        'Isolation error did not distinguish collision from unrecognized domain.'
    Assert-Starts $session 0
    Assert (-not ($session.Lines -match '^Decision=start;|^Converged:')) 'Invalid occupancy caused a Start decision or convergence.'
    return [regex]::Match($errorText, 'Domain isolation violation[^\r\n]+').Value
}

try {
    $defaultFile = New-Intent 'default-compatibility'
    $default = Read-State $defaultFile
    $newline = [Environment]::NewLine
    $expected = "{$newline  `"WorkloadId`": `"$($default.WorkloadId)`",$newline  `"Desired`": `"Running`"$newline}"
    Assert ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($defaultFile)) -ceq `
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($expected))) 'Default intent bytes changed.'
    foreach ($count in @('0', '-1')) {
        $invalidFile = Join-Path $evidence "invalid-$count.json"
        $errorText = & $executable intent $invalidFile --replicas $count 2>&1 | Out-String
        Assert ($LASTEXITCODE -ne 0 -and $errorText -match 'Replicas must be at least 1' `
            -and -not (Test-Path -LiteralPath $invalidFile)) 'Invalid cardinality was persisted.'
    }
    $invalidStoredFile = Join-Path $evidence 'invalid-stored.json'
    $stateFiles.Add($invalidStoredFile)
    [ordered]@{ WorkloadId = $default.WorkloadId; Desired = 'Running'; Replicas = 0 } |
        ConvertTo-Json | Set-Content -LiteralPath $invalidStoredFile
    $invalidStored = Start-Manager 'invalid-stored' $invalidStoredFile -CaptureError
    $invalidStored | Add-Member -NotePropertyName ErrorTask -NotePropertyValue $invalidStored.Process.StandardError.ReadToEndAsync()
    Assert ($invalidStored.Process.WaitForExit(15000) -and $invalidStored.Process.ExitCode -ne 0) `
        'An invalid stored cardinality was accepted.'
    Assert ($invalidStored.ErrorTask.GetAwaiter().GetResult() -match 'Replicas must be at least 1') `
        'Loaded intent bypassed cardinality validation.'

    $file = New-Intent 'fleet' -Replicas 3
    $intent = Read-State $file
    $originalBytes = [System.IO.File]::ReadAllBytes($file)
    $intentJson = [System.IO.File]::ReadAllText($file)
    $authorityFile = Join-Path $evidence 'fleet.epoch'
    $grant = @(Advance $authorityFile 1)
    $gate = New-Gate
    $manager = Start-Fleet 'fleet-manager' $file $authorityFile 1 $gate
    Read-Until $manager '^Action=none; waiting for startup evidence, not issuing another start\.$'
    $pending = Latest-Observation $manager
    Assert ($pending -match 'runningCount=0; startingCount=3; liveCount=3;') 'Cold fleet was not held at three Starting members.'
    Assert-Starts $manager 3
    Assert (-not $gate.Handle.WaitOne(0) -and -not ($manager.Lines -match '^Converged:')) 'Converged before readiness.'
    $pendingMembers = @(Members $pending)
    Assert (($pendingMembers.Domain -join ',') -ceq 'domain-1,domain-2,domain-3') 'Cold creation did not occupy distinct domains in order.'
    Assert-Fleet $intent.WorkloadId $pendingMembers
    Read-Until $manager '^Action=none; waiting for startup evidence, not issuing another start\.$'
    Assert-Starts $manager 3
    Assert (-not ($manager.Lines -match '^Converged:')) 'Pending occupancy was mistaken for convergence.'
    $releasedAt = [datetimeoffset]::UtcNow.ToString('O')
    Assert ($gate.Handle.Set()) 'Could not release fleet readiness.'
    Read-Until $manager '^Converged:.*starts this manager=3;'
    Assert-Convergence $manager 3
    $originalFleet = @(Members (Latest-Observation $manager))
    Assert-Retained $pendingMembers $originalFleet
    Assert-Fleet $intent.WorkloadId $originalFleet
    Assert-Intent $file $originalBytes
    $results.Add([ordered]@{
        Scenario = 'cold-three-domains'; WorkloadId = $intent.WorkloadId; IntentJson = $intentJson; Grant = $grant
        PendingObservation = $pending; ReadinessReleasedAt = $releasedAt
        Fleet = $originalFleet; Manager = Manager-Evidence $manager; IntentUnchanged = $true
    })

    $victim = @($originalFleet | Where-Object Domain -EQ 'domain-2')[0]
    $survivors = @($originalFleet | Where-Object ProcessId -NE $victim.ProcessId)
    $killedAt = [datetimeoffset]::UtcNow.ToString('O')
    Stop-Workload ([pscustomobject]@{ Workload = $victim })
    Read-Until $manager '^Converged:.*starts this manager=4;'
    Assert-Convergence $manager 4
    $deficit = @($manager.Lines | Where-Object { $_ -match 'runningCount=2; startingCount=0; liveCount=2;' })[-1]
    Assert ($null -ne $deficit) 'Did not freshly observe the single-member deficit.'
    $repairedFleet = @(Members (Latest-Observation $manager))
    Assert-Retained $survivors $repairedFleet
    Assert (@($repairedFleet | Where-Object RunId -NE $victim.RunId).Count -eq 3) 'Killed incarnation was retained.'
    $replacement = @($repairedFleet | Where-Object { $_.RunId -notin $originalFleet.RunId })
    Assert ($replacement.Count -eq 1 -and $replacement[0].Domain -ceq 'domain-2') 'Did not replace exactly the missing domain.'
    Assert-Fleet $intent.WorkloadId $repairedFleet
    Assert-Intent $file $originalBytes
    $results.Add([ordered]@{
        Scenario = 'single-domain-replacement'; WorkloadId = $intent.WorkloadId; IntentJson = $intentJson
        KilledAt = $killedAt; Victim = $victim; Survivors = $survivors; Replacement = $replacement[0]
        DeficitObservation = $deficit; Fleet = $repairedFleet; Manager = Manager-Evidence $manager; IntentUnchanged = $true
    })
    Relinquish $manager

    $handoffFile = New-Intent 'handoff' -Replicas 3
    $handoffIntent = Read-State $handoffFile
    $handoffBytes = [System.IO.File]::ReadAllBytes($handoffFile)
    $handoffAuthority = Join-Path $evidence 'handoff.epoch'
    $grant1 = @(Advance $handoffAuthority 1)
    $handoffGate = New-Gate
    $first = Start-Fleet 'handoff-A' $handoffFile $handoffAuthority 1 $handoffGate -PauseAfterFirstStart
    Read-Until $first '^Action=start returned; former pre-locator-save pause;'
    $adopted = Remember-Identity $first.Lines[-1]
    $adopted | Add-Member -NotePropertyName State -NotePropertyValue 'Starting'
    Assert ($first.Lines[-1] -match 'domain=(domain-1);') 'A did not create domain-1 first.'
    $adopted | Add-Member -NotePropertyName Domain -NotePropertyValue $Matches[1]
    Assert-Starts $first 1
    Assert-Fleet $handoffIntent.WorkloadId @($adopted)
    Assert-Intent $handoffFile $handoffBytes
    Stop-Process -Id $first.Process.Id -Force
    Assert ($first.Process.WaitForExit(5000)) 'Fault-paused A did not exit.'
    $grant2 = @(Advance $handoffAuthority 2)
    $second = Start-Fleet 'handoff-B' $handoffFile $handoffAuthority 2 $handoffGate
    Read-Until $second '^Observation 1: desiredReplicas=3; runningCount=0; startingCount=1; liveCount=1;'
    $adoption = Latest-Observation $second
    Assert-Retained @($adopted) @(Members $adoption)
    Read-Until $second '^Action=none; waiting for startup evidence, not issuing another start\.$'
    Assert-Starts $second 2
    $placedDomains = @($second.Lines | Where-Object { $_ -match '^Action=start returned;' } | ForEach-Object {
        Assert ($_ -match 'domain=(domain-[1-3]);') 'Missing domain in Start evidence.'
        $Matches[1]
    })
    Assert (($placedDomains -join ',') -ceq 'domain-2,domain-3') 'B recreated an occupied domain instead of the missing ones.'
    Assert (-not $handoffGate.Handle.WaitOne(0) -and -not ($second.Lines -match '^Converged:')) 'Handoff was not held during startup.'
    $handoffPending = Latest-Observation $second
    Assert ($handoffPending -match 'runningCount=0; startingCount=3; liveCount=3;') 'B did not fill only the deficit.'
    Assert-Fleet $handoffIntent.WorkloadId @(Members $handoffPending)
    $handoffReleasedAt = [datetimeoffset]::UtcNow.ToString('O')
    Assert ($handoffGate.Handle.Set()) 'Could not release handoff fleet readiness.'
    Read-Until $second '^Converged:.*starts this manager=2;'
    Assert-Convergence $second 2
    Assert-Trace $first
    $handoffFleet = @(Members (Latest-Observation $second))
    Assert-Retained @($adopted) $handoffFleet
    Assert-Fleet $handoffIntent.WorkloadId $handoffFleet
    Assert-Intent $handoffFile $handoffBytes
    Relinquish $second
    $results.Add([ordered]@{
        Scenario = 'fenced-partial-domain-handoff'; WorkloadId = $handoffIntent.WorkloadId
        IntentJson = [System.IO.File]::ReadAllText($handoffFile); Grant1 = $grant1; Grant2 = $grant2
        Adopted = $adopted; AdoptionObservation = $adoption; PendingObservation = $handoffPending
        ReadinessReleasedAt = $handoffReleasedAt; Fleet = $handoffFleet
        ManagerA = Manager-Evidence $first; ManagerB = Manager-Evidence $second
        StartsA = 1; StartsB = 2; IntentUnchanged = $true
    })

    $violations = [System.Collections.Generic.List[object]]::new()
    $isolationFile = New-Intent 'isolation' -Replicas 3
    $isolationIntent = Read-State $isolationFile
    $isolationBytes = [System.IO.File]::ReadAllBytes($isolationFile)
    $isolationAuthority = Join-Path $evidence 'isolation.epoch'
    [void] (Advance $isolationAuthority 1)
    $isolationGate = New-Gate
    $collisionFleet = @(
        (Start-IdentifiedChild $isolationIntent.WorkloadId 'domain-1')
        (Start-IdentifiedChild $isolationIntent.WorkloadId 'domain-1' $isolationGate)
        (Start-IdentifiedChild $isolationIntent.WorkloadId 'domain-2')
    )
    Assert-Fleet $isolationIntent.WorkloadId $collisionFleet
    $collision = Start-Fleet 'collision-manager' $isolationFile $isolationAuthority 1 $isolationGate
    $collisionError = Assert-IsolationFailure $collision $collisionFleet 'domain-1' ''
    Assert-Fleet $isolationIntent.WorkloadId $collisionFleet
    Assert-Intent $isolationFile $isolationBytes
    $violations.Add([ordered]@{
        Case = 'collision-with-domain-3-empty'; WorkloadId = $isolationIntent.WorkloadId
        Fleet = $collisionFleet; Manager = Manager-Evidence $collision; Error = $collisionError; ExitCode = $collision.Process.ExitCode
    })
    foreach ($member in $collisionFleet) { Stop-Workload ([pscustomobject]@{ Workload = $member }) }

    foreach ($unknown in @('domain-99', '<none>')) {
        $unknownDomain = if ($unknown -eq '<none>') { $null } else { $unknown }
        $unknownChild = Start-IdentifiedChild $isolationIntent.WorkloadId $unknownDomain $isolationGate
        Assert-Fleet $isolationIntent.WorkloadId @($unknownChild)
        $name = if ($unknown -eq '<none>') { 'missing-domain-manager' } else { 'unknown-domain-manager' }
        $unknownManager = Start-Fleet $name $isolationFile $isolationAuthority 1 $isolationGate
        $unknownError = Assert-IsolationFailure $unknownManager @($unknownChild) '' $unknown
        Assert-Fleet $isolationIntent.WorkloadId @($unknownChild)
        Assert-Intent $isolationFile $isolationBytes
        $violations.Add([ordered]@{
            Case = "unrecognized-$unknown"; WorkloadId = $isolationIntent.WorkloadId
            Fleet = @($unknownChild); Manager = Manager-Evidence $unknownManager
            Error = $unknownError; ExitCode = $unknownManager.Process.ExitCode
        })
        Stop-Workload ([pscustomobject]@{ Workload = $unknownChild })
    }

    $surplusGate = New-Gate
    $extra = Start-IdentifiedChild $intent.WorkloadId 'domain-1' $surplusGate
    $surplusFleet = @($repairedFleet) + @($extra)
    Assert-Fleet $intent.WorkloadId $surplusFleet
    $surplus = Start-Fleet 'surplus-manager' $file $authorityFile 1 $gate
    $surplusError = Assert-IsolationFailure $surplus $surplusFleet 'domain-1' ''
    Assert-Fleet $intent.WorkloadId $surplusFleet
    Assert-Intent $file $originalBytes
    Assert-Intent $handoffFile $handoffBytes
    Assert-Intent $isolationFile $isolationBytes
    $violations.Add([ordered]@{
        Case = 'excess-four-including-starting'; WorkloadId = $intent.WorkloadId
        Fleet = $surplusFleet; Manager = Manager-Evidence $surplus; Error = $surplusError; ExitCode = $surplus.Process.ExitCode
    })
    $results.Add([ordered]@{
        Scenario = 'domain-isolation-violations'; Cases = @($violations)
        IsolationIntentJson = [System.IO.File]::ReadAllText($isolationFile); FleetIntentJson = $intentJson
        InspectedAt = [datetimeoffset]::UtcNow.ToString('O'); IntentUnchanged = $true
    })
}
finally {
    foreach ($session in $sessions) {
        if (-not $session.Process.HasExited) { Stop-Process -Id $session.Process.Id -Force }
        Assert ($session.Process.WaitForExit(5000)) 'A manager did not exit.'
    }
    foreach ($child in $children) { Stop-Workload ([pscustomobject]@{ Workload = $child }) }
    foreach ($file in $stateFiles) {
        if (Test-Path -LiteralPath $file) { Stop-MatchingWorkloads (Read-State $file).WorkloadId }
    }
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

foreach ($name in @('fleet-manager', 'handoff-A', 'handoff-B')) {
    Assert ([string]::IsNullOrEmpty([System.IO.File]::ReadAllText((Join-Path $evidence "$name.log.stderr")))) `
        "$name failed unexpectedly."
}
[ordered]@{
    DefaultIntentBytesUnchanged = $true; InvalidCountsRejectedWithoutIntent = $true; InvalidStoredCountRejected = $true
    Scenarios = @($results); NativeInspections = @($inspections)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
Write-Host "PASS: Day 4.1 three distinct domains, domain-2-only replacement, fenced partial-domain handoff, collision with an empty domain, unknown/missing domains, and excess occupancy. Evidence: $evidence"
