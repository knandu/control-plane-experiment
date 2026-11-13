#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$assembly = [System.IO.Path]::ChangeExtension($executable, '.dll')
$evidence = (New-Item -ItemType Directory -Path (Join-Path $root ".state\day-04.3-$([guid]::NewGuid().ToString('N'))")).FullName
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
$children = [System.Collections.Generic.List[object]]::new()
$events = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$inspections = [System.Collections.Generic.List[object]]::new()
$healthLosses = [System.Collections.Generic.List[object]]::new()
. "$PSScriptRoot\process-helpers.ps1"

function Capture-Error($session) {
    $session | Add-Member -NotePropertyName ErrorTask -NotePropertyValue $session.Process.StandardError.ReadToEndAsync()
    $session | Add-Member -NotePropertyName StartTicks -NotePropertyValue $session.Process.StartTime.ToUniversalTime().Ticks
    return $session
}

function Start-Fleet(
    [string] $name, $case, [long] $epoch = 1, $readinessGate, $beforeStop, $beforeStart
) {
    return Capture-Error (Start-Manager $name $case.File 600 -CaptureError `
        -AuthorityEpoch $epoch -AuthorityFile $case.AuthorityFile `
        -PauseBeforeReadinessEvent $readinessGate.Name -PauseBeforeStopEvent $beforeStop.Name `
        -PauseBeforeStartEvent $beforeStart.Name)
}

function Advance($case, [long] $epoch) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($arg in @('grant', $case.AuthorityFile, "$epoch")) { $info.ArgumentList.Add($arg) }
    $session = [pscustomobject]@{
        Name = "grant-$($sessions.Count)-$epoch"; Process = [System.Diagnostics.Process]::Start($info)
        Lines = [System.Collections.Generic.List[string]]::new()
        Log = Join-Path $evidence "grant-$($sessions.Count)-$epoch.log"; CaptureError = $true
    }
    $sessions.Add($session)
    $session = Capture-Error $session
    Assert ((Read-Exited $session $true) -eq '') 'Grant failed.'
    Assert ([System.IO.File]::ReadAllText($case.AuthorityFile) -ceq "$epoch") 'Wrong grant.'
    return @($session.Lines)
}

function Read-Exited($session, [bool] $success) {
    Assert ($session.Process.WaitForExit(15000)) "$($session.Name) did not exit."
    Assert (($session.Process.ExitCode -eq 0) -eq $success) "$($session.Name) had the wrong exit code."
    foreach ($line in ($session.Process.StandardOutput.ReadToEnd() -split '\r?\n' | Where-Object { $_ })) {
        $session.Lines.Add($line)
    }
    return $session.ErrorTask.GetAwaiter().GetResult()
}

function New-Case([string] $name, [int] $replicas = 3) {
    $file = New-Intent $name -Replicas $replicas
    $case = @{
        File = $file; WorkloadId = (Read-State $file).WorkloadId; Replicas = $replicas
        Bytes = [System.IO.File]::ReadAllBytes($file); AuthorityFile = Join-Path $evidence "$name.epoch"
    }
    [void] (Advance $case 1)
    return $case
}

function New-Gate {
    $name = "Local\ControlPlaneExperiment-Day43-$([guid]::NewGuid().ToString('N'))"
    $gate = [pscustomobject]@{
        Name = $name; Handle = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $name)
    }
    $events.Add($gate)
    return $gate
}

function Release($gate) {
    $at = [datetimeoffset]::UtcNow.ToString('O')
    Assert ($gate.Handle.Set()) 'Could not release event gate.'
    return $at
}

function Members([string] $line) {
    foreach ($match in [regex]::Matches($line, 'domain=([^,;]+),state=(Starting|Running|Degraded),pid=(\d+),startTicks=(\d+),runId=([0-9a-f-]+)')) {
        [pscustomobject]@{
            Domain = $match.Groups[1].Value; State = $match.Groups[2].Value
            ProcessId = [int] $match.Groups[3].Value; StartTimeUtcTicks = [long] $match.Groups[4].Value
            RunId = $match.Groups[5].Value
        }
    }
}

function Latest($session) {
    return @($session.Lines | Where-Object { $_ -match '^Observation ' })[-1]
}

function Identity-Key($member) {
    return "$($member.ProcessId):$($member.StartTimeUtcTicks):$($member.RunId):$($member.Domain)"
}

function Assert-Retained([object[]] $expected, [object[]] $actual) {
    foreach ($member in $expected) {
        Assert (@($actual | Where-Object { (Identity-Key $_) -ceq (Identity-Key $member) }).Count -eq 1) 'Survivor identity changed.'
    }
}

function Event-Signaled([string] $name) {
    $handle = $null
    Assert ([Threading.EventWaitHandle]::TryOpenExisting($name, [ref] $handle)) "Missing live event: $name"
    try { return $handle.WaitOne(0) }
    finally { $handle.Dispose() }
}

function Assert-Fleet($case, [object[]] $members) {
    $matching = @(Matching-Processes $case.WorkloadId)
    Assert ($matching.Count -eq $members.Count) 'Independent live cardinality differs.'
    foreach ($member in $members) {
        $children.Add($member)
        Assert-Live $member ($member.State -eq 'Running')
        $candidate = @($matching | Where-Object ProcessId -EQ $member.ProcessId)
        Assert ($candidate.Count -eq 1) 'Live member not rediscoverable.'
        Assert ($candidate[0].SessionId -eq [System.Diagnostics.Process]::GetCurrentProcess().SessionId) 'Wrong session.'
        Assert ([math]::Floor($candidate[0].CreationDate.ToUniversalTime().Ticks / [decimal] 10) -eq `
            [math]::Floor($member.StartTimeUtcTicks / [decimal] 10)) 'Native/WMI incarnation mismatch.'
        $launch = '(?:^|\s)"?' + [regex]::Escape($assembly) + '"?\s+--workload\s+' + `
            [regex]::Escape($case.WorkloadId) + '\s+' + [regex]::Escape($member.RunId) + '\s+\d+\s+' + `
            [regex]::Escape($member.Domain) + '\s*$'
        Assert ($candidate[0].CommandLine -match $launch) 'Launch workload, run, or domain mismatch.'
        $suffix = ([guid] $member.RunId).ToString('N')
        $ready = Event-Signaled "Local\ControlPlaneExperiment-$suffix"
        $started = Event-Signaled "Local\ControlPlaneExperiment-Started-$suffix"
        Assert ($ready -eq ($member.State -eq 'Running') -and $started -eq ($member.State -ne 'Starting')) `
            'Independent live health evidence differs from the observed state.'
        $inspections.Add([ordered]@{
            At = [datetimeoffset]::UtcNow.ToString('O'); WorkloadId = $case.WorkloadId
            ProcessId = $member.ProcessId; NativeStartTimeUtcTicks = $member.StartTimeUtcTicks
            RunId = $member.RunId; Domain = $member.Domain; State = $member.State
            Readiness = $ready; Started = $started
            WmiCreationUtc = $candidate[0].CreationDate.ToUniversalTime().ToString('O')
            CommandLine = $candidate[0].CommandLine
        })
    }
}

function Test-HealthReconciliation {
        $ongoing = New-Case 'ongoing-health'
        $replacementGate = New-Gate
        [void] (Release $replacementGate)
        $stopGate = New-Gate
        $manager = Start-Fleet 'ongoing-manager' $ongoing -readinessGate $replacementGate -beforeStop $stopGate
        Read-Until $manager '^Converged:'
        Assert-Convergence $manager 3 3 0
        $initial = @(Members (Latest $manager))
        $initialSnapshot = @($initial | Select-Object *)
        Assert-Fleet $ongoing $initial
        Assert ($replacementGate.Handle.Reset()) 'Could not hold future replacement readiness.'
        $victim = @($initial | Where-Object Domain -EQ 'domain-2')[0]
        $peers = @($initial | Where-Object Domain -NE 'domain-2')
        $degradedAt = Lose-Readiness $victim
        Read-Until $manager '^Experiment paused: after Stop decision; before process termination;'
        Assert ((Latest $manager) -match 'runningCount=2; startingCount=0; liveCount=3; degradedCount=1;') 'Health loss was not observed.'
        Assert-Fleet $ongoing @(Members (Latest $manager))
        [void] (Release $stopGate)
        $pending = @(Assert-Waiting $manager $ongoing $peers 4 1)
        Assert (@($manager.Lines | Where-Object { $_ -match '^Converged:' }).Count -eq 1) 'Re-converged before replacement readiness.'
        Assert-Absent $victim
        $replacement = @($pending | Where-Object Domain -EQ 'domain-2')[0]
        Assert ($replacement.RunId -ne $victim.RunId -and $replacement.StartTimeUtcTicks -gt $victim.StartTimeUtcTicks) `
            'Replacement reused the old incarnation.'
        $stopDecision = @($manager.Lines | Where-Object { $_ -match '^Decision=stop;' })[0]
        $startDecision = @($manager.Lines | Where-Object { $_ -match '^Decision=start;.*domain=domain-2;' })[-1]
        Assert ($stopDecision -match 'observation=(\d+);') 'Stop omitted observation.'
        $stopPass = [int] $Matches[1]
        Assert ($startDecision -match "domain=domain-2; observation=$($stopPass + 1);" `
            -and $stopDecision.Contains("pid=$($victim.ProcessId);")) 'Repair was not Stop then Start on consecutive observations.'
        $releasedAt = Release $replacementGate
        Read-Until $manager '^Converged:'
        Assert-Convergence $manager 3 4 1
        $repaired = @(Members (Latest $manager))
        Assert-Retained ($peers + @($replacement)) $repaired
        Assert-Fleet $ongoing $repaired
        Assert-Intent $ongoing
        Relinquish $manager 4 1
        $results.Add([ordered]@{
            Scenario = 'ongoing-health-loss'; WorkloadId = $ongoing.WorkloadId; OriginalFleet = $initialSnapshot
            DegradedAt = $degradedAt; Victim = $victim; Replacement = $replacement; PendingFleet = $pending
            ReadinessReleasedAt = $releasedAt; Fleet = $repaired; RepairStarts = 1; RepairStops = 1
            Manager = Manager-Evidence $manager; IntentUnchanged = $true
        })

        $cold = New-Case 'cold-mixed-health'
        $originalGate = New-Gate
        $domain1 = Seed $cold 'domain-1'
        $domain2 = Seed $cold 'domain-2'
        $domain3 = Seed $cold 'domain-3' $originalGate
        $coldDegradedAt = Lose-Readiness $domain2
        $coldFleet = @($domain1, $domain2, $domain3)
        Assert-Fleet $cold $coldFleet
        $coldGrant2 = @(Advance $cold 2)
        $coldReplacementGate = New-Gate
        $coldStopGate = New-Gate
        $coldManager = Start-Fleet 'cold-manager' $cold 2 -readinessGate $coldReplacementGate -beforeStop $coldStopGate
        Read-Until $coldManager '^Experiment paused: after Stop decision; before process termination;'
        $first = @($coldManager.Lines | Where-Object { $_ -match '^Observation ' })[0]
        Assert ($first -match '^Observation 1:.*runningCount=1; startingCount=1; liveCount=3; degradedCount=1;') `
            'Cold management needed remembered health to classify its first observation.'
        Assert-Fleet $cold @(Members $first)
        Assert (@($coldManager.Lines | Where-Object { $_ -match '^Decision=stop;' })[0].Contains("domain=domain-2; pid=$($domain2.ProcessId);")) `
            'Cold management selected the genuinely Starting child.'
        [void] (Release $coldStopGate)
        $coldPending = @(Assert-Waiting $coldManager $cold @($domain1, $domain3) 1 1)
        Assert (@($coldPending | Where-Object State -EQ 'Starting').Count -eq 2) 'Both original and replacement startups were not pending.'
        Assert (-not ($coldManager.Lines -match '^Converged:')) 'Cold manager converged before readiness.'
        Assert-Absent $domain2
        $coldReplacement = @($coldPending | Where-Object Domain -EQ 'domain-2')[0]
        $originalReleasedAt = Release $originalGate
        Read-Until $coldManager '^Observation .*runningCount=2; startingCount=1; liveCount=3; degradedCount=0;'
        Assert-Operations $coldManager 1 1
        Assert-Fleet $cold @(Members (Latest $coldManager))
        $coldReleasedAt = Release $coldReplacementGate
        Read-Until $coldManager '^Converged:'
        Assert-Convergence $coldManager 3 1 1
        $coldFinal = @(Members (Latest $coldManager))
        Assert-Retained @($domain1, $domain3, $coldReplacement) $coldFinal
        Assert-Fleet $cold $coldFinal
        Assert-Intent $cold
        Relinquish $coldManager 1 1
        $results.Add([ordered]@{
            Scenario = 'cold-mixed-health'; WorkloadId = $cold.WorkloadId; PreparedFleet = $coldFleet
            DegradedAt = $coldDegradedAt; Grant2 = $coldGrant2; PendingFleet = $coldPending
            OriginalReadinessReleasedAt = $originalReleasedAt; ReplacementReadinessReleasedAt = $coldReleasedAt
            Replacement = $coldReplacement; Fleet = $coldFinal; Manager = Manager-Evidence $coldManager; IntentUnchanged = $true
        })

        $handoff = New-Case 'interrupted-repair'
        $handoffFleet = @(1..3 | ForEach-Object { Seed $handoff "domain-$_" })
        $handoffVictim = @($handoffFleet | Where-Object Domain -EQ 'domain-2')[0]
        $handoffPeers = @($handoffFleet | Where-Object Domain -NE 'domain-2')
        $handoffDegradedAt = Lose-Readiness $handoffVictim
        Assert-Fleet $handoff $handoffFleet
        $staleGate = New-Gate
        $a = Start-Fleet 'stale-health-A' $handoff 1 -beforeStop $staleGate
        Read-Until $a '^Experiment paused: after Stop decision; before process termination;'
        Assert ($a.Lines -match '^Authority accepted: boundary=manager pre-check; offeredEpoch=1; currentEpoch=1;') 'A never passed the valid pre-check.'
        $grant2 = @(Advance $handoff 2)
        $staleReleasedAt = Release $staleGate
        $errorText = Read-Exited $a $false
        Assert ($errorText -match 'AuthorityRejectedException: Authority rejected: boundary=process termination; offeredEpoch=1; currentEpoch=2') `
            'Stale Stop was not rejected at process termination.'
        Assert-Operations $a 0 0
        Assert-Trace $a
        Assert (@($a.Lines | Where-Object { $_ -match '^Observation ' }).Count -eq 1 `
            -and -not ($a.Lines -match '^Action=stop returned;|^Converged:')) 'A reconsidered or completed the stale Stop.'
        Assert-Fleet $handoff $handoffFleet
        $aliveAfterRejectionAt = [datetimeoffset]::UtcNow.ToString('O')
        $betweenGate = New-Gate
        $b = Start-Fleet 'interrupted-health-B' $handoff 2 -beforeStart $betweenGate
        Read-Until $b '^Experiment paused: after Start decision; before process creation;'
        Assert-Operations $b 0 1
        Assert-Trace $b
        Assert-Absent $handoffVictim
        $missing = @(Members (Latest $b))
        Assert ($missing.Count -eq 2 -and @($missing | Where-Object Domain -EQ 'domain-2').Count -eq 0) 'Stopped domain was not freshly absent.'
        Assert-Retained $handoffPeers $missing
        Assert-Fleet $handoff $missing
        Assert-Intent $handoff
        Assert ($b.Process.StartTime.ToUniversalTime().Ticks -eq $b.StartTicks) 'Wrong B incarnation.'
        Stop-Process -Id $b.Process.Id -Force
        Assert ($b.Process.WaitForExit(5000)) 'B did not exit before epoch 3.'
        $bExitedAt = [datetimeoffset]::UtcNow.ToString('O')
        $grant3 = @(Advance $handoff 3)
        $handoffReadyGate = New-Gate
        $c = Start-Fleet 'replacement-health-C' $handoff 3 -readinessGate $handoffReadyGate
        $handoffPending = @(Assert-Waiting $c $handoff $handoffPeers 1 0)
        $cFirst = @($c.Lines | Where-Object { $_ -match '^Observation ' })[0]
        Assert ($cFirst -match '^Observation 1:.*runningCount=2; startingCount=0; liveCount=2; degradedCount=0;' `
            -and $c.Lines -match '^Decision=start;.*domain=domain-2; observation=1;') 'C did not independently reconstruct the missing domain.'
        $handoffReplacement = @($handoffPending | Where-Object Domain -EQ 'domain-2')[0]
        $handoffReleasedAt = Release $handoffReadyGate
        Read-Until $c '^Converged:'
        Assert-Convergence $c 3 1 0
        $handoffFinal = @(Members (Latest $c))
        Assert-Retained ($handoffPeers + @($handoffReplacement)) $handoffFinal
        Assert-Fleet $handoff $handoffFinal
        Assert-Intent $handoff
        Relinquish $c 1 0
        $results.Add([ordered]@{
            Scenario = 'stale-stop-and-interrupted-replacement'; WorkloadId = $handoff.WorkloadId
            OriginalFleet = $handoffFleet; Victim = $handoffVictim; DegradedAt = $handoffDegradedAt
            Grant2 = $grant2; StaleReleasedAt = $staleReleasedAt; AliveAfterRejectionAt = $aliveAfterRejectionAt
            Rejection = [regex]::Match($errorText, 'Authority rejected:[^\r\n]+').Value
            MissingFleet = $missing; ManagerBExitedAt = $bExitedAt; Grant3 = $grant3
            PendingFleet = $handoffPending; ReadinessReleasedAt = $handoffReleasedAt
            Replacement = $handoffReplacement; Fleet = $handoffFinal
            ManagerA = Manager-Evidence $a; ManagerB = Manager-Evidence $b; ManagerC = Manager-Evidence $c
            IntentUnchanged = $true
        })

        $collision = New-Case 'degraded-collision'
        $collisionVictim = Seed $collision 'domain-1'
        [void] (Lose-Readiness $collisionVictim)
        $keeperGate = New-Gate
        $keeper = Seed $collision 'domain-1' $keeperGate
        $healthy = @(Seed $collision 'domain-2'; Seed $collision 'domain-3')
        Assert ($collisionVictim.StartTimeUtcTicks -lt $keeper.StartTimeUtcTicks) 'Health preference was not distinguished from earliest-age preference.'
        Assert-Fleet $collision (@($collisionVictim, $keeper) + $healthy)
        $collisionManager = Start-Fleet 'collision-health-manager' $collision
        $collisionPending = @(Assert-Waiting $collisionManager $collision (@($keeper) + $healthy) 0 1)
        Assert-Absent $collisionVictim
        Assert (-not ($collisionManager.Lines -match '^Converged:') `
            -and @($collisionManager.Lines | Where-Object { $_ -match '^Decision=stop;' })[0].Contains("pid=$($collisionVictim.ProcessId);")) `
            'Collision did not preserve the genuinely Starting keeper.'
        $keeperReleasedAt = Release $keeperGate
        Read-Until $collisionManager '^Converged:'
        Assert-Convergence $collisionManager 3 0 1
        $collisionFinal = @(Members (Latest $collisionManager))
        Assert-Retained (@($keeper) + $healthy) $collisionFinal
        Assert-Fleet $collision $collisionFinal
        Assert-Intent $collision
        Relinquish $collisionManager 0 1
        $results.Add([ordered]@{
            Scenario = 'starting-kept-over-degraded'; WorkloadId = $collision.WorkloadId; Victim = $collisionVictim
            Keeper = $keeper; HealthyPeers = $healthy; PendingFleet = $collisionPending
            ReadinessReleasedAt = $keeperReleasedAt; Fleet = $collisionFinal
            Manager = Manager-Evidence $collisionManager; IntentUnchanged = $true
        })

        $priority = New-Case 'health-priority' 2
        $priorityGate = New-Gate
        $surplusDegraded = Seed $priority 'domain-3'
        [void] (Lose-Readiness $surplusDegraded)
        $surplusStarting = Seed $priority 'domain-3' $priorityGate
        $surplusRunning = Seed $priority 'domain-3'
        $targetDegraded = Seed $priority 'domain-1'
        [void] (Lose-Readiness $targetDegraded)
        $targetStarting = Seed $priority 'domain-1' $priorityGate
        $targetRunning = Seed $priority 'domain-1'
        $domain2Running = Seed $priority 'domain-2'
        $priorityFleet = @($surplusDegraded, $surplusStarting, $surplusRunning, $targetDegraded, $targetStarting, $targetRunning, $domain2Running)
        Assert-Fleet $priority $priorityFleet
        $priorityManager = Start-Fleet 'priority-health-manager' $priority
        Read-Until $priorityManager '^Converged:'
        Assert-Convergence $priorityManager 2 0 5
        $expectedVictims = @($surplusDegraded, $surplusStarting, $surplusRunning, $targetDegraded, $targetStarting)
        $actualVictims = @($priorityManager.Lines | Where-Object { $_ -match '^Process terminated:' } | ForEach-Object {
            Assert ($_ -match '^Process terminated: pid=(\d+);') 'Stop omitted native identity.'
            [int] $Matches[1]
        })
        Assert (($actualVictims -join ',') -ceq ($expectedVictims.ProcessId -join ',')) 'Surplus or collision health priority changed.'
        foreach ($member in $expectedVictims) { Assert-Absent $member }
        $priorityFinal = @(Members (Latest $priorityManager))
        Assert-Retained @($targetRunning, $domain2Running) $priorityFinal
        Assert-Fleet $priority $priorityFinal
        Assert-Intent $priority
        Relinquish $priorityManager 0 5
        $results.Add([ordered]@{
            Scenario = 'surplus-and-collision-health-order'; WorkloadId = $priority.WorkloadId
            InitialFleet = $priorityFleet; Victims = $expectedVictims; ActualVictimPids = $actualVictims
            Fleet = $priorityFinal; Manager = Manager-Evidence $priorityManager; IntentUnchanged = $true
        })
}

function Lose-Readiness($member) {
    Assert-Live $member
    $suffix = ([guid] $member.RunId).ToString('N')
    Assert (Event-Signaled "Local\ControlPlaneExperiment-Started-$suffix") 'Child never finished startup.'
    $handle = [Threading.EventWaitHandle]::OpenExisting("Local\ControlPlaneExperiment-$suffix")
    try {
        $at = [datetimeoffset]::UtcNow.ToString('O')
        Assert ($handle.Reset()) 'Could not reset readiness.'
    }
    finally { $handle.Dispose() }
    $member.State = 'Degraded'
    $healthLosses.Add([ordered]@{ At = $at; Member = $member })
    return $at
}

function Seed($case, [string] $domain, $gate) {
    $info = [System.Diagnostics.ProcessStartInfo]::new('dotnet')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    [void] $info.Environment.Remove('CONTROL_PLANE_PAUSE_BEFORE_READINESS_EVENT')
    if ($gate) { $info.Environment['CONTROL_PLANE_PAUSE_BEFORE_READINESS_EVENT'] = $gate.Name }
    $run = [guid]::NewGuid()
    foreach ($arg in @($assembly, '--workload', $case.WorkloadId, "$run", '0', $domain)) { $info.ArgumentList.Add($arg) }
    $process = [System.Diagnostics.Process]::Start($info)
    try { $member = Remember-Identity "pid=$($process.Id); startTicks=$($process.StartTime.ToUniversalTime().Ticks); runId=$run" }
    finally { $process.Dispose() }
    $member | Add-Member -NotePropertyName Domain -NotePropertyValue $domain
    $member | Add-Member -NotePropertyName State -NotePropertyValue $(if ($gate) { 'Starting' } else { 'Running' })
    Assert-Live $member ($member.State -eq 'Running')
    return $member
}

function Assert-Absent($member) {
    try { $process = [System.Diagnostics.Process]::GetProcessById($member.ProcessId) }
    catch [System.ArgumentException] { return }
    try {
        Assert ($process.HasExited -or $process.StartTime.ToUniversalTime().Ticks -ne $member.StartTimeUtcTicks) 'Victim is still alive.'
    }
    finally { $process.Dispose() }
}

function Assert-Intent($case) {
    Assert ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($case.File)) -ceq [Convert]::ToBase64String($case.Bytes)) `
        'Health reconciliation rewrote durable intent.'
    Assert ((((Read-State $case.File).PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'Desired,Replicas,WorkloadId') `
        'Operational health or repair state leaked into intent.'
}

function Assert-Operations($session, [int] $starts, [int] $stops) {
    Assert-Starts $session $starts
    Assert (@($session.Lines | Where-Object { $_ -match '^Process terminated:' }).Count -eq $stops) 'Wrong native Stop count.'
}

function Assert-Trace($session) {
    $observed = $null
    $decided = @{}
    foreach ($line in $session.Lines) {
        if ($line -match '^Observation (\d+): desiredReplicas=(\d+); runningCount=(\d+); startingCount=(\d+); liveCount=(\d+); degradedCount=(\d+);') {
            $number = [int] $Matches[1]; $desired = [int] $Matches[2]
            $running = [int] $Matches[3]; $starting = [int] $Matches[4]
            $live = [int] $Matches[5]; $degraded = [int] $Matches[6]
            $members = @(Members $line)
            Assert ($members.Count -eq $live -and $live -eq $running + $starting + $degraded `
                -and @($members | Where-Object State -EQ 'Running').Count -eq $running `
                -and @($members | Where-Object State -EQ 'Starting').Count -eq $starting `
                -and @($members | Where-Object State -EQ 'Degraded').Count -eq $degraded) 'Incorrect health counts.'
            $ordered = @($members | Sort-Object StartTimeUtcTicks, ProcessId, RunId | ForEach-Object { Identity-Key $_ })
            Assert (($ordered -join ',') -ceq (($members | ForEach-Object { Identity-Key $_ }) -join ',')) 'Discovery sort changed.'
            $observed = @{ Number = $number; Desired = $desired; Members = $members }
        }
        if ($line -match '^Decision=(start|stop);') {
            $action = $Matches[1]
            Assert ($observed -and $line.Contains("observation=$($observed.Number);") `
                -and -not $decided.ContainsKey($observed.Number)) 'Decision lacks a fresh pass or two effects share a pass.'
            $decided[$observed.Number] = $action
            if ($action -eq 'start') {
                $target = @(1..$observed.Desired | ForEach-Object { "domain-$_" })
                Assert (@($observed.Members | Where-Object { $_.Domain -notin $target -or $_.State -eq 'Degraded' }).Count -eq 0 `
                    -and @($observed.Members | Group-Object Domain | Where-Object Count -GT 1).Count -eq 0) 'Creation preceded remediation.'
                $missing = $target | Where-Object { $_ -notin $observed.Members.Domain } | Select-Object -First 1
                Assert ($missing -and $line.Contains("domain=$missing;")) 'Creation did not target the first missing domain.'
            }
        }
    }
    Assert (@($session.Lines | Where-Object { $_ -match '^Authority accepted: boundary=manager pre-check;' }).Count -eq $decided.Count) `
        'A decision bypassed the manager check.'
    Assert (@($session.Lines | Where-Object { $_ -match '^Authority accepted: boundary=process creation;' }).Count -eq `
        @($session.Lines | Where-Object { $_ -match '^Action=start returned;' }).Count) 'Start bypassed the effect fence.'
    Assert (@($session.Lines | Where-Object { $_ -match '^Authority accepted: boundary=process termination;' }).Count -eq `
        @($session.Lines | Where-Object { $_ -match '^Process terminated:' }).Count) 'Stop bypassed the effect fence.'
}

function Assert-Convergence($session, [int] $replicas, [int] $starts, [int] $stops) {
    Assert ($session.Lines[-1] -match "^Converged: two matching observations; starts this manager=$starts; stops this manager=$stops; replicas=$replicas;") `
        'Missing convergence counters.'
    $observations = @($session.Lines | Where-Object { $_ -match '^Observation ' })
    foreach ($line in $observations[-2,-1]) {
        Assert ($line.Contains("runningCount=$replicas; startingCount=0; liveCount=$replicas; degradedCount=0;")) 'Converged with unhealthy members.'
        $members = @(Members $line)
        Assert ((($members.Domain | Sort-Object) -join ',') -ceq ((1..$replicas | ForEach-Object { "domain-$_" }) -join ',')) 'Wrong converged domains.'
        Assert-Retained @(Members $observations[-1]) $members
    }
    Assert-Operations $session $starts $stops
    Assert-Trace $session
}

function Relinquish($session, [int] $starts, [int] $stops) {
    $session.Process.StandardInput.WriteLine('relinquish')
    $session.Process.StandardInput.Flush()
    Read-Until $session '^Authority relinquished:'
    Assert ($session.Process.WaitForExit(5000) -and $session.Process.ExitCode -eq 0 `
        -and $session.Lines[-1].Contains("starts this manager=$starts; stops this manager=$stops;")) 'Relinquishment failed.'
}

function Manager-Evidence($session) {
    Assert ($session.Lines -match "Manager=$($session.Process.Id);.*managerStartTicks=$($session.StartTicks); authorityEpoch=$($session.AuthorityEpoch)\.") `
        'Manager native identity was not verified.'
    return [ordered]@{
        ProcessId = $session.Process.Id; StartTimeUtcTicks = $session.StartTicks; Epoch = $session.AuthorityEpoch
        Starts = @($session.Lines | Where-Object { $_ -match '^Action=start returned;' }).Count
        Stops = @($session.Lines | Where-Object { $_ -match '^Process terminated:' }).Count
        Lines = @($session.Lines)
    }
}

function Assert-Waiting($session, $case, [object[]] $retained, [int] $starts, [int] $stops) {
    foreach ($pass in 1..2) { Read-Until $session '^Action=none; waiting for startup evidence' }
    Assert-Operations $session $starts $stops
    $pending = @(Members (Latest $session))
    Assert (@($pending | Where-Object State -EQ 'Starting').Count -gt 0 `
        -and @($pending | Where-Object State -EQ 'Degraded').Count -eq 0) 'Not genuinely waiting for initial readiness.'
    Assert-Retained $retained $pending
    Assert-Fleet $case $pending
    return $pending
}

try {
    Test-HealthReconciliation
    Assert ($results.Count -eq 5 -and $healthLosses.Count -eq 6 -and $inspections.Count -gt 0) `
        'The health experiments did not all execute.'
}
finally {
    foreach ($session in $sessions) {
        if (-not $session.Process.HasExited) { Stop-Process -Id $session.Process.Id -Force }
        Assert ($session.Process.WaitForExit(5000)) 'Test session did not exit.'
    }
    foreach ($child in $children) {
        try { $process = [System.Diagnostics.Process]::GetProcessById($child.ProcessId) }
        catch [System.ArgumentException] { continue }
        try {
            $actualTicks = $process.StartTime.ToUniversalTime().Ticks
            if ($actualTicks -ne $child.StartTimeUtcTicks) {
                Write-Host "Cleanup skipped obsolete incarnation: pid=$($child.ProcessId); expectedTicks=$($child.StartTimeUtcTicks); actualTicks=$actualTicks."
                continue
            }
            Stop-Workload ([pscustomobject]@{ Workload = $child })
        }
        finally { $process.Dispose() }
    }
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

foreach ($session in $sessions) {
    if ($session.Name -eq 'stale-health-A') { continue }
    Assert ([string]::IsNullOrEmpty([System.IO.File]::ReadAllText($session.Log + '.stderr'))) "$($session.Name) failed unexpectedly."
}
[ordered]@{ Scenarios = @($results); HealthLosses = @($healthLosses); NativeInspections = @($inspections) } |
    ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
Write-Host "PASS: Day 4.3 ongoing health loss, cold mixed-health discovery, stale degraded Stop rejection, interrupted replacement handoff, and health-prioritized collisions/surplus. Evidence: $evidence"
