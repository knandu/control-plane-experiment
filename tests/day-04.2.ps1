#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$assembly = [System.IO.Path]::ChangeExtension($executable, '.dll')
$evidence = (New-Item -ItemType Directory -Path (Join-Path $root ".state\day-04.2-$([guid]::NewGuid().ToString('N'))")).FullName
$sessions = [System.Collections.Generic.List[object]]::new()
$stateFiles = [System.Collections.Generic.List[string]]::new()
$children = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$events = [System.Collections.Generic.List[object]]::new()
$inspections = [System.Collections.Generic.List[object]]::new()
$handles = [System.Collections.Generic.List[object]]::new()
. "$PSScriptRoot\process-helpers.ps1"

function Capture-Error($session) {
    $session | Add-Member -NotePropertyName ErrorTask -NotePropertyValue $session.Process.StandardError.ReadToEndAsync()
    $session | Add-Member -NotePropertyName StartTicks -NotePropertyValue $session.Process.StartTime.ToUniversalTime().Ticks
    return $session
}

function Start-Fleet(
    [string] $name, [string] $file, [string] $authorityFile, [long] $epoch = 1,
    [string] $beforeStop, [string] $afterStopCheck, $readinessGate
) {
    return Capture-Error (Start-Manager $name $file 600 -AuthorityEpoch $epoch -AuthorityFile $authorityFile `
        -PauseBeforeStopEvent $beforeStop -PauseAfterStopAuthorityCheckEvent $afterStopCheck `
        -PauseBeforeReadinessEvent $readinessGate.Name -CaptureError)
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

function Read-Exited($session, [bool] $success) {
    Assert ($session.Process.WaitForExit(15000)) "$($session.Name) did not exit."
    Assert (($session.Process.ExitCode -eq 0) -eq $success) "$($session.Name): unexpected exit code."
    foreach ($line in ($session.Process.StandardOutput.ReadToEnd() -split '\r?\n' | Where-Object { $_ })) {
        $session.Lines.Add($line)
    }
    return $session.ErrorTask.GetAwaiter().GetResult()
}

function Advance([string] $file, [long] $epoch) {
    $grant = Start-Grant "grant-$($sessions.Count)-$epoch" $file $epoch
    Assert ((Read-Exited $grant $true) -eq '') 'Successful grant wrote an error.'
    Assert ([System.IO.File]::ReadAllText($file) -ceq "$epoch") 'Wrong current grant.'
    return @($grant.Lines)
}

function New-Gate {
    $name = "Local\ControlPlaneExperiment-Day42-$([guid]::NewGuid().ToString('N'))"
    $gate = [pscustomobject]@{
        Name = $name
        Handle = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $name)
    }
    $events.Add($gate)
    return $gate
}

function Members([string] $line) {
    foreach ($match in [regex]::Matches($line, 'domain=([^,;]+),state=(Starting|Running),pid=(\d+),startTicks=(\d+),runId=([0-9a-f-]+)')) {
        [pscustomobject]@{
            Domain = $match.Groups[1].Value; State = $match.Groups[2].Value
            ProcessId = [int] $match.Groups[3].Value; StartTimeUtcTicks = [long] $match.Groups[4].Value
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

function Assert-Retained([object[]] $expected, [object[]] $actual) {
    foreach ($member in $expected) {
        Assert (@($actual | Where-Object { (Identity-Key $_) -ceq (Identity-Key $member) }).Count -eq 1) `
            'A surviving incarnation changed.'
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
        Assert ($candidate[0].CommandLine -match ($launch + '\s*$')) 'Launch identity or domain changed.'
        $inspections.Add([ordered]@{
            At = [datetimeoffset]::UtcNow.ToString('O'); WorkloadId = $workloadId
            ProcessId = $member.ProcessId; VerifiedNativeStartTimeUtcTicks = $member.StartTimeUtcTicks
            WmiCreationUtc = $candidate[0].CreationDate.ToUniversalTime().ToString('O')
            RunId = $member.RunId; Domain = $member.Domain; VerifiedReady = $member.State -eq 'Running'
            CommandLine = $candidate[0].CommandLine
        })
    }
}

function Assert-Absent($member) {
    try { $process = [System.Diagnostics.Process]::GetProcessById($member.ProcessId) }
    catch [System.ArgumentException] { return }
    try {
        Assert ($process.HasExited -or $process.StartTime.ToUniversalTime().Ticks -ne $member.StartTimeUtcTicks) `
            'The selected incarnation is still alive.'
    }
    finally { $process.Dispose() }
}

function Assert-Intent([string] $file, [byte[]] $bytes, [int] $replicas) {
    Assert ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file)) -ceq [Convert]::ToBase64String($bytes)) `
        'Reconciliation rewrote intent bytes.'
    $state = Read-State $file
    Assert ((($state.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'Desired,Replicas,WorkloadId' `
        -and $state.Replicas -eq $replicas) 'Operational state leaked into durable intent.'
}

function Update-Replicas([string] $file, [int] $replicas) {
    $before = Read-State $file
    & $executable intent $file --replicas $replicas | Out-Host
    Assert ($LASTEXITCODE -eq 0) 'Explicit intent update failed.'
    $after = Read-State $file
    Assert ($after.WorkloadId -ceq $before.WorkloadId -and $after.Desired -ceq $before.Desired `
        -and $after.Replicas -eq $replicas) 'Intent update replaced logical identity or desired state.'
    Assert (-not (Test-Path -LiteralPath ($file + '.tmp'))) 'Atomic update left a temporary file.'
}

function Assert-Operations($session, [int] $starts, [int] $stops) {
    Assert-Starts $session $starts
    Assert (@($session.Lines | Where-Object { $_ -match '^Process terminated:' }).Count -eq $stops) `
        "$($session.Name): wrong successful Stop count."
}

function Assert-Trace($session) {
    $lastObservation = $null
    $decided = @{}
    foreach ($line in $session.Lines) {
        if ($line -match '^Observation (\d+): desiredReplicas=(\d+); runningCount=(\d+); startingCount=(\d+); liveCount=(\d+);') {
            $number = [int] $Matches[1]; $desired = [int] $Matches[2]
            $running = [int] $Matches[3]; $starting = [int] $Matches[4]; $live = [int] $Matches[5]
            $members = @(Members $line)
            Assert ($live -eq $members.Count -and $live -eq $running + $starting `
                -and @($members | Where-Object State -EQ 'Running').Count -eq $running) 'Inconsistent set observation.'
            $ordered = @($members | Sort-Object StartTimeUtcTicks, ProcessId, RunId | ForEach-Object { Identity-Key $_ })
            Assert (($ordered -join ',') -ceq (($members | ForEach-Object { Identity-Key $_ }) -join ',')) `
                'Discovery order changed.'
            $lastObservation = @{ Number = $number; Desired = $desired; Members = $members }
        }
        if ($line -match '^Decision=(start|stop);') {
            $action = $Matches[1]
            Assert ($null -ne $lastObservation -and $line -match "observation=$($lastObservation.Number);") `
                'Decision did not follow its fresh observation.'
            Assert (-not $decided.ContainsKey($lastObservation.Number)) 'Two effects were decided in one pass.'
            $decided[$lastObservation.Number] = $action
            if ($action -eq 'start') {
                $target = @(1..$lastObservation.Desired | ForEach-Object { "domain-$_" })
                $observed = $lastObservation.Members
                Assert (@($observed | Where-Object Domain -NotIn $target).Count -eq 0 `
                    -and @($observed | Group-Object Domain | Where-Object Count -GT 1).Count -eq 0) `
                    'Start was selected before removing surplus or collisions.'
                $missing = $target | Where-Object { $_ -notin $observed.Domain } | Select-Object -First 1
                Assert ($missing -and $line.Contains("domain=$missing;")) 'Start did not fill the first missing domain.'
            }
        }
    }
    $starts = @($session.Lines | Where-Object { $_ -match '^Action=start returned;' }).Count
    $stops = @($session.Lines | Where-Object { $_ -match '^Process terminated:' }).Count
    Assert (@($session.Lines | Where-Object { $_ -match '^Authority accepted: boundary=process creation;' }).Count -eq $starts `
        -and @($session.Lines | Where-Object { $_ -match '^Authority accepted: boundary=process termination;' }).Count -eq $stops `
        -and @($session.Lines | Where-Object { $_ -match '^Authority accepted: boundary=manager pre-check;' }).Count -eq $decided.Count) `
        'A decision bypassed an authority boundary.'
}

function Assert-Convergence($session, [int] $replicas, [int] $starts, [int] $stops) {
    Assert ($session.Lines[-1] -match "^Converged: two matching observations; starts this manager=$starts; stops this manager=$stops; replicas=$replicas;") `
        'Missing convergence counters.'
    $observations = @($session.Lines | Where-Object { $_ -match '^Observation ' })
    foreach ($line in $observations[-2,-1]) {
        Assert ($line -match "runningCount=$replicas; startingCount=0; liveCount=$replicas;") 'Converged with missing or pending members.'
        $members = @(Members $line)
        Assert ((($members.Domain | Sort-Object) -join ',') -ceq ((1..$replicas | ForEach-Object { "domain-$_" }) -join ',')) `
            'Converged outside the target domains.'
        Assert-Retained @(Members $observations[-1]) $members
    }
    Assert-Operations $session $starts $stops
    Assert-Trace $session
}

function Relinquish($session, [int] $starts, [int] $stops) {
    $session.Process.StandardInput.WriteLine('relinquish')
    $session.Process.StandardInput.Flush()
    Read-Until $session '^Authority relinquished:'
    Assert ($session.Lines[-1].Contains("starts this manager=$starts; stops this manager=$stops;") `
        -and $session.Process.WaitForExit(5000) -and $session.Process.ExitCode -eq 0) 'Clean exit or relinquishment counters failed.'
}

function Manager-Evidence($session) {
    Assert ($session.Lines -match "Manager=$($session.Process.Id);.*managerStartTicks=$($session.StartTicks); authorityEpoch=$($session.AuthorityEpoch)\.") `
        'Manager identity was not independently verified.'
    return [ordered]@{
        ProcessId = $session.Process.Id; StartTimeUtcTicks = $session.StartTicks; Epoch = $session.AuthorityEpoch
        Starts = @($session.Lines | Where-Object { $_ -match '^Action=start returned;' }).Count
        Stops = @($session.Lines | Where-Object { $_ -match '^Process terminated:' }).Count
        Lines = @($session.Lines)
    }
}

function Start-IdentifiedChild([string] $workloadId, [string] $domain, $gate) {
    $runId = [guid]::NewGuid()
    $info = [System.Diagnostics.ProcessStartInfo]::new('dotnet')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    [void] $info.Environment.Remove('CONTROL_PLANE_PAUSE_BEFORE_READINESS_EVENT')
    if ($gate) { $info.Environment['CONTROL_PLANE_PAUSE_BEFORE_READINESS_EVENT'] = $gate.Name }
    foreach ($argument in @($assembly, '--workload', $workloadId, "$runId", '0')) { $info.ArgumentList.Add($argument) }
    if ($domain) { $info.ArgumentList.Add($domain) }
    $process = [System.Diagnostics.Process]::Start($info)
    try { $member = Remember-Identity "pid=$($process.Id); startTicks=$($process.StartTime.ToUniversalTime().Ticks); runId=$runId" }
    finally { $process.Dispose() }
    $member | Add-Member -NotePropertyName Domain -NotePropertyValue $(if ($domain) { $domain } else { $null })
    $member | Add-Member -NotePropertyName State -NotePropertyValue $(if ($gate) { 'Starting' } else { 'Running' })
    Assert-Live $member ($member.State -eq 'Running')
    return $member
}

function New-Fleet([string] $name) {
    $file = New-Intent $name -Replicas 3
    $state = Read-State $file
    $authorityFile = Join-Path $evidence "$name.epoch"
    [void] (Advance $authorityFile 1)
    $manager = Start-Fleet "$name-setup" $file $authorityFile
    Read-Until $manager '^Converged:'
    Assert-Convergence $manager 3 3 0
    $fleet = @(Members (Latest-Observation $manager))
    Assert-Fleet $state.WorkloadId $fleet
    Relinquish $manager 3 0
    return @{
        File = $file; WorkloadId = $state.WorkloadId; AuthorityFile = $authorityFile; Fleet = $fleet
        OriginalJson = [System.IO.File]::ReadAllText($file); Setup = Manager-Evidence $manager
    }
}

function Stamp([string] $line) {
    Assert ($line -match 'at=([^; ]+)\.$') 'Missing UTC timestamp.'
    return [datetimeoffset]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
}

try {
    $defaultFile = New-Intent 'default-compatibility'
    $default = Read-State $defaultFile
    $defaultBytes = [System.IO.File]::ReadAllBytes($defaultFile)
    $newline = [Environment]::NewLine
    $expected = "{$newline  `"WorkloadId`": `"$($default.WorkloadId)`",$newline  `"Desired`": `"Running`"$newline}"
    Assert ([Convert]::ToBase64String($defaultBytes) -ceq `
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($expected))) 'Default intent bytes changed.'
    $refusal = & $executable intent $defaultFile 2>&1 | Out-String
    Assert ($LASTEXITCODE -ne 0 -and $refusal -match 'Platform state already exists; intent will not overwrite it.' `
        -and [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($defaultFile)) -ceq `
        [Convert]::ToBase64String($defaultBytes)) 'Default intent overwrote existing state.'
    Update-Replicas $defaultFile 3
    $updatedBytes = [System.IO.File]::ReadAllBytes($defaultFile)
    $invalid = & $executable intent $defaultFile --replicas 0 2>&1 | Out-String
    Assert ($LASTEXITCODE -ne 0 -and $invalid -match 'Replicas must be at least 1') 'Invalid updated count was accepted.'
    Assert-Intent $defaultFile $updatedBytes 3
    $results.Add([ordered]@{
        Scenario = 'intent-update-compatibility'; WorkloadId = $default.WorkloadId
        DefaultJson = $expected; UpdatedJson = [System.IO.File]::ReadAllText($defaultFile)
        DefaultOverwriteRefused = $true; InvalidUpdatePreservedBytes = $true
    })

    $scale = New-Fleet 'scale-down'
    Update-Replicas $scale.File 2
    $scaleBytes = [System.IO.File]::ReadAllBytes($scale.File)
    $scaleVictim = @($scale.Fleet | Where-Object Domain -EQ 'domain-3')[0]
    $scaleSurvivors = @($scale.Fleet | Where-Object Domain -NE 'domain-3')
    $scaleManager = Start-Fleet 'scale-down-manager' $scale.File $scale.AuthorityFile
    Read-Until $scaleManager '^Converged:'
    Assert-Convergence $scaleManager 2 0 1
    $scaled = @(Members (Latest-Observation $scaleManager))
    Assert-Retained $scaleSurvivors $scaled
    Assert-Absent $scaleVictim
    Assert-Fleet $scale.WorkloadId $scaled
    Assert-Intent $scale.File $scaleBytes 2
    Relinquish $scaleManager 0 1
    $results.Add([ordered]@{
        Scenario = 'scale-down-three-to-two'; WorkloadId = $scale.WorkloadId; Setup = $scale.Setup
        BeforeJson = $scale.OriginalJson; AfterJson = [System.IO.File]::ReadAllText($scale.File)
        Victim = $scaleVictim; Survivors = $scaled; Manager = Manager-Evidence $scaleManager; IntentUnchanged = $true
    })

    $collisionFile = New-Intent 'collision' -Replicas 3
    $collisionIntent = Read-State $collisionFile
    $collisionBytes = [System.IO.File]::ReadAllBytes($collisionFile)
    $collisionAuthority = Join-Path $evidence 'collision.epoch'
    [void] (Advance $collisionAuthority 1)
    $pendingGate = New-Gate
    $duplicate = Start-IdentifiedChild $collisionIntent.WorkloadId 'domain-1' $pendingGate
    $keeper = Start-IdentifiedChild $collisionIntent.WorkloadId 'domain-1'
    $secondDomain = Start-IdentifiedChild $collisionIntent.WorkloadId 'domain-2'
    Assert ($duplicate.StartTimeUtcTicks -lt $keeper.StartTimeUtcTicks) 'Keeper preference was not tested against an older pending child.'
    Assert-Fleet $collisionIntent.WorkloadId @($duplicate, $keeper, $secondDomain)
    $replacementGate = New-Gate
    $collisionManager = Start-Fleet 'collision-manager' $collisionFile $collisionAuthority -readinessGate $replacementGate
    Read-Until $collisionManager '^Action=none; waiting for startup evidence'
    Assert-Operations $collisionManager 1 1
    $decisions = @($collisionManager.Lines | Where-Object { $_ -match '^Decision=' })
    Assert ($decisions.Count -eq 2 -and $decisions[0] -match "^Decision=stop;.*domain=domain-1; pid=$($duplicate.ProcessId);" `
        -and $decisions[1] -match '^Decision=start;.*domain=domain-3;') 'Collision was not removed before filling the missing domain.'
    Assert (-not ($collisionManager.Lines -match '^Converged:')) 'Converged before replacement readiness.'
    Assert-Absent $duplicate
    $pendingFleet = @(Members (Latest-Observation $collisionManager))
    Assert-Retained @($keeper, $secondDomain) $pendingFleet
    Assert-Fleet $collisionIntent.WorkloadId $pendingFleet
    $releasedAt = [datetimeoffset]::UtcNow.ToString('O')
    Assert ($replacementGate.Handle.Set()) 'Could not release replacement readiness.'
    Read-Until $collisionManager '^Converged:'
    Assert-Convergence $collisionManager 3 1 1
    $repaired = @(Members (Latest-Observation $collisionManager))
    Assert-Retained @($keeper, $secondDomain) $repaired
    Assert-Fleet $collisionIntent.WorkloadId $repaired
    Assert-Intent $collisionFile $collisionBytes 3
    Relinquish $collisionManager 1 1
    $results.Add([ordered]@{
        Scenario = 'collision-before-missing-domain'; WorkloadId = $collisionIntent.WorkloadId
        IntentJson = [System.IO.File]::ReadAllText($collisionFile); Victim = $duplicate; Keeper = $keeper
        PreservedDomain2 = $secondDomain; PendingFleet = $pendingFleet; ReadinessReleasedAt = $releasedAt
        Fleet = $repaired; Manager = Manager-Evidence $collisionManager; IntentUnchanged = $true
    })

    $stale = New-Fleet 'stale-stop'
    Update-Replicas $stale.File 2
    $staleBytes = [System.IO.File]::ReadAllBytes($stale.File)
    $staleVictim = @($stale.Fleet | Where-Object Domain -EQ 'domain-3')[0]
    $stopGate = New-Gate
    $staleA = Start-Fleet 'stale-stop-A' $stale.File $stale.AuthorityFile 1 $stopGate.Name
    Read-Until $staleA '^Experiment paused: after Stop decision; before process termination;'
    Assert ($staleA.Lines -match '^Authority accepted: boundary=manager pre-check; offeredEpoch=1; currentEpoch=1;' `
        -and $staleA.Lines[-1] -match 'stops this manager=0;') 'A did not pass its valid manager check before pausing.'
    Assert-Fleet $stale.WorkloadId $stale.Fleet
    $grant2 = @(Advance $stale.AuthorityFile 2)
    $staleReleased = [datetimeoffset]::UtcNow.ToString('O')
    Assert ($stopGate.Handle.Set()) 'Could not release stale Stop.'
    $staleError = Read-Exited $staleA $false
    Assert ($staleError -match 'AuthorityRejectedException: Authority rejected: boundary=process termination; offeredEpoch=1; currentEpoch=2') `
        'Stale Stop was not rejected at the termination boundary.'
    Assert-Operations $staleA 0 0
    Assert-Trace $staleA
    Assert (@($staleA.Lines | Where-Object { $_ -match '^Observation ' }).Count -eq 1 `
        -and -not ($staleA.Lines -match '^Converged:|^Action=stop returned;|^Authority relinquished:')) 'A reconsidered or falsely completed the stale decision.'
    $afterRejection = [datetimeoffset]::UtcNow.ToString('O')
    Assert-Fleet $stale.WorkloadId $stale.Fleet
    $staleB = Start-Fleet 'stale-stop-B' $stale.File $stale.AuthorityFile 2
    Read-Until $staleB '^Converged:'
    Assert-Convergence $staleB 2 0 1
    $staleSurvivors = @(Members (Latest-Observation $staleB))
    Assert-Retained @($stale.Fleet | Where-Object Domain -NE 'domain-3') $staleSurvivors
    Assert-Absent $staleVictim
    Assert-Fleet $stale.WorkloadId $staleSurvivors
    Assert-Intent $stale.File $staleBytes 2
    Relinquish $staleB 0 1
    $results.Add([ordered]@{
        Scenario = 'stale-stop-rejected'; WorkloadId = $stale.WorkloadId; Victim = $staleVictim
        IntentJson = [System.IO.File]::ReadAllText($stale.File); Grant2 = $grant2; ReleasedAt = $staleReleased
        RejectedAt = $afterRejection; VictimAliveAfterRejection = $true
        Rejection = [regex]::Match($staleError, 'Authority rejected:[^\r\n]+').Value
        ManagerA = Manager-Evidence $staleA; ManagerB = Manager-Evidence $staleB
        Survivors = $staleSurvivors; IntentUnchanged = $true
    })

    $locked = New-Fleet 'locked-stop'
    Update-Replicas $locked.File 2
    $lockedBytes = [System.IO.File]::ReadAllBytes($locked.File)
    $lockedVictim = @($locked.Fleet | Where-Object Domain -EQ 'domain-3')[0]
    $victimHandle = [System.Diagnostics.Process]::GetProcessById($lockedVictim.ProcessId)
    [void] $victimHandle.Handle
    $handles.Add($victimHandle)
    $lockedGate = New-Gate
    $lockedA = Start-Fleet 'locked-stop-A' $locked.File $locked.AuthorityFile 1 '' $lockedGate.Name
    Read-Until $lockedA '^Experiment paused: after boundary authority check; before Process.Kill;'
    Assert ($lockedA.Lines -match '^Authority accepted: boundary=process termination; offeredEpoch=1; currentEpoch=1;') `
        'A did not enter the actual locked termination boundary.'
    Assert-Operations $lockedA 0 0
    Assert-Fleet $locked.WorkloadId $locked.Fleet
    $pendingGrant = Start-Grant 'locked-stop-grant-2' $locked.AuthorityFile 2
    Read-Until $pendingGrant '^Authority lock waiting: offeredEpoch=2;'
    Assert (-not $pendingGrant.Process.HasExited -and -not $lockedA.Process.HasExited `
        -and -not $lockedGate.Handle.WaitOne(0) -and [System.IO.File]::ReadAllText($locked.AuthorityFile) -ceq '1') `
        'The new grant became current while termination was held.'
    Assert-Live $lockedVictim
    $lockedReleased = [datetimeoffset]::UtcNow
    Assert ($lockedGate.Handle.Set()) 'Could not release locked termination.'
    Read-Until $lockedA '^Action=stop returned;'
    Assert ($victimHandle.WaitForExit(5000)) 'Accepted Stop did not terminate the root process.'
    $nativeExitAt = [datetimeoffset] $victimHandle.ExitTime.ToUniversalTime()
    Assert ((Read-Exited $pendingGrant $true) -eq '') 'Pending grant failed.'
    $termination = @($lockedA.Lines | Where-Object { $_ -match '^Process terminated:' })[-1]
    $terminatedAt = Stamp $termination
    $committedAt = Stamp @($pendingGrant.Lines | Where-Object { $_ -match '^Authority advanced:' })[-1]
    Assert ($nativeExitAt -ge $lockedReleased -and $nativeExitAt -le $terminatedAt -and $terminatedAt -lt $committedAt) `
        'Native exit and successful termination were not ordered before grant advancement.'
    Assert ([System.IO.File]::ReadAllText($locked.AuthorityFile) -ceq '2') 'Grant 2 never became current.'
    Relinquish $lockedA 0 1
    Assert-Operations $lockedA 0 1
    Assert-Trace $lockedA
    $lockedB = Start-Fleet 'locked-stop-B' $locked.File $locked.AuthorityFile 2
    Read-Until $lockedB '^Converged:'
    Assert-Convergence $lockedB 2 0 0
    $lockedSurvivors = @(Members (Latest-Observation $lockedB))
    Assert-Retained @($locked.Fleet | Where-Object Domain -NE 'domain-3') $lockedSurvivors
    Assert-Absent $lockedVictim
    Assert-Fleet $locked.WorkloadId $lockedSurvivors
    Assert-Intent $locked.File $lockedBytes 2
    Relinquish $lockedB 0 0
    $results.Add([ordered]@{
        Scenario = 'termination-before-grant'; WorkloadId = $locked.WorkloadId; Victim = $lockedVictim
        IntentJson = [System.IO.File]::ReadAllText($locked.File); Grant2 = @($pendingGrant.Lines)
        EpochWhilePaused = 1; ReleasedAt = $lockedReleased; NativeExitAt = $nativeExitAt
        TerminatedAt = $terminatedAt; AuthorityMovedAt = $committedAt
        ManagerA = Manager-Evidence $lockedA; ManagerB = Manager-Evidence $lockedB
        Survivors = $lockedSurvivors; IntentUnchanged = $true
    })

    $priorityFile = New-Intent 'priority' -Replicas 2
    $priorityIntent = Read-State $priorityFile
    $priorityBytes = [System.IO.File]::ReadAllBytes($priorityFile)
    $priorityAuthority = Join-Path $evidence 'priority.epoch'
    [void] (Advance $priorityAuthority 1)
    $priorityGate = New-Gate
    $domain2 = Start-IdentifiedChild $priorityIntent.WorkloadId 'domain-2'
    $domain2Duplicate = Start-IdentifiedChild $priorityIntent.WorkloadId 'domain-2'
    $oldPending = Start-IdentifiedChild $priorityIntent.WorkloadId 'domain-1' $priorityGate
    $newPending = Start-IdentifiedChild $priorityIntent.WorkloadId 'domain-1' $priorityGate
    $oldReady = Start-IdentifiedChild $priorityIntent.WorkloadId 'domain-1'
    $newReady = Start-IdentifiedChild $priorityIntent.WorkloadId 'domain-1'
    $domain9 = Start-IdentifiedChild $priorityIntent.WorkloadId 'domain-9'
    $domain10Pending = Start-IdentifiedChild $priorityIntent.WorkloadId 'domain-10' $priorityGate
    $domain10Ready = Start-IdentifiedChild $priorityIntent.WorkloadId 'domain-10'
    $priorityFleet = @($domain2, $domain2Duplicate, $oldPending, $newPending, $oldReady, $newReady, $domain9, $domain10Pending, $domain10Ready)
    Assert-Fleet $priorityIntent.WorkloadId $priorityFleet
    $expectedVictims = @($domain10Pending, $domain10Ready, $domain9, $newPending, $oldPending, $newReady, $domain2Duplicate)
    $priority = Start-Fleet 'priority-manager' $priorityFile $priorityAuthority
    Read-Until $priority '^Converged:'
    Assert-Convergence $priority 2 0 7
    $actualVictims = @($priority.Lines | Where-Object { $_ -match '^Process terminated:' } | ForEach-Object {
        Assert ($_ -match '^Process terminated: pid=(\d+);') 'Stop omitted its native process identity.'
        [int] $Matches[1]
    })
    Assert (($actualVictims -join ',') -ceq ($expectedVictims.ProcessId -join ',')) 'Deterministic victim priority changed.'
    foreach ($member in $expectedVictims) { Assert-Absent $member }
    $prioritySurvivors = @(Members (Latest-Observation $priority))
    Assert-Retained @($oldReady, $domain2) $prioritySurvivors
    Assert-Fleet $priorityIntent.WorkloadId $prioritySurvivors
    Assert-Intent $priorityFile $priorityBytes 2
    Relinquish $priority 0 7
    $results.Add([ordered]@{
        Scenario = 'numeric-domain-and-victim-priority'; WorkloadId = $priorityIntent.WorkloadId
        InitialFleet = $priorityFleet; ExpectedVictims = $expectedVictims; ActualVictimPids = $actualVictims
        Survivors = $prioritySurvivors; Manager = Manager-Evidence $priority; IntentUnchanged = $true
    })

    $invalidFile = New-Intent 'invalid-domains' -Replicas 3
    $invalidIntent = Read-State $invalidFile
    $invalidBytes = [System.IO.File]::ReadAllBytes($invalidFile)
    $invalidAuthority = Join-Path $evidence 'invalid-domains.epoch'
    [void] (Advance $invalidAuthority 1)
    $invalidGate = New-Gate
    $invalidCases = [System.Collections.Generic.List[object]]::new()
    foreach ($label in @('<none>', 'worker-x', 'domain-0', 'domain-01')) {
        $domain = if ($label -eq '<none>') { $null } else { $label }
        $invalidChild = Start-IdentifiedChild $invalidIntent.WorkloadId $domain $invalidGate
        $invalidManager = Start-Fleet "invalid-domain-$($invalidCases.Count)" $invalidFile $invalidAuthority
        $errorText = Read-Exited $invalidManager $false
        Assert ($errorText -match 'Domain isolation violation for workload' `
            -and $errorText.Contains("unrecognized=[$label]") -and $errorText.Contains("pids=$($invalidChild.ProcessId)") `
            -and $errorText.Contains('No Stop issued.')) 'Malformed occupancy was not rejected explicitly.'
        Assert-Operations $invalidManager 0 0
        Assert (-not ($invalidManager.Lines -match '^Decision=|^Converged:')) 'Malformed metadata caused a side effect.'
        Assert-Fleet $invalidIntent.WorkloadId @($invalidChild)
        Assert-Intent $invalidFile $invalidBytes 3
        $invalidCases.Add([ordered]@{
            Domain = $label; Child = $invalidChild; Manager = Manager-Evidence $invalidManager
            Error = [regex]::Match($errorText, 'Domain isolation violation[^\r\n]+').Value
        })
        Stop-Workload ([pscustomobject]@{ Workload = $invalidChild })
    }
    $results.Add([ordered]@{ Scenario = 'unrecognized-domains-rejected'; Cases = @($invalidCases); IntentUnchanged = $true })

    $identityFile = New-Intent 'incarnation-check' -Replicas 2
    $identityIntent = Read-State $identityFile
    $identityChild = Start-IdentifiedChild $identityIntent.WorkloadId 'domain-1'
    $loaded = [System.Reflection.Assembly]::LoadFrom($assembly)
    $incarnationType = $loaded.GetType('WorkloadIncarnation', $true)
    $discoveredType = $loaded.GetType('DiscoveredWorkload', $true)
    $stateType = $loaded.GetType('WorkloadState', $true)
    $stopMethod = $loaded.GetType('Workload', $true).GetMethod('Stop', [System.Reflection.BindingFlags]'Public,Static')
    $wrongIncarnation = [Activator]::CreateInstance($incarnationType, [object[]]@(
        [int] $identityChild.ProcessId, [long] ($identityChild.StartTimeUtcTicks + 1), [guid] $identityChild.RunId))
    $forged = [Activator]::CreateInstance($discoveredType, [object[]]@(
        [Enum]::Parse($stateType, 'Running'), $wrongIncarnation, 'domain-1'))
    $writer = [System.IO.StringWriter]::new()
    $originalOutput = [Console]::Out
    try {
        [Console]::SetOut($writer)
        $terminated = $stopMethod.Invoke($null, [object[]]@($forged, $null))
    }
    finally { [Console]::SetOut($originalOutput) }
    $mismatch = $writer.ToString()
    $writer.Dispose()
    Assert (-not $terminated -and $mismatch.Contains('Termination skipped: reason=incarnation mismatch')) `
        'Stop trusted a PID without verifying its expected native start ticks.'
    Assert-Fleet $identityIntent.WorkloadId @($identityChild)
    Stop-Workload ([pscustomobject]@{ Workload = $identityChild })
    $absent = $stopMethod.Invoke($null, [object[]]@($forged, $null))
    Assert (-not $absent) 'An already-absent target counted as a terminated process.'
    $results.Add([ordered]@{
        Scenario = 'incarnation-mismatch-refused'; Child = $identityChild
        OfferedStartTimeUtcTicks = $identityChild.StartTimeUtcTicks + 1
        Mismatch = $mismatch.Trim(); WrongIncarnationStopped = $false; AbsentTargetStopped = $false
    })
}
finally {
    foreach ($session in $sessions) {
        if (-not $session.Process.HasExited) { Stop-Process -Id $session.Process.Id -Force }
        Assert ($session.Process.WaitForExit(5000)) 'A test process did not exit.'
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
    foreach ($handle in $handles) { $handle.Dispose() }
}

foreach ($session in $sessions) {
    if ($session.Name -eq 'stale-stop-A' -or $session.Name -like 'invalid-domain-*') { continue }
    Assert ([string]::IsNullOrEmpty([System.IO.File]::ReadAllText($session.Log + '.stderr'))) `
        "$($session.Name) failed unexpectedly."
}
[ordered]@{ Scenarios = @($results); NativeInspections = @($inspections) } |
    ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
Write-Host "PASS: Day 4.2 scale-down, collision-before-creation, stale Stop rejection, locked termination/grant ordering, deterministic victim priority, malformed-domain refusal, and native incarnation verification. Evidence: $evidence"
