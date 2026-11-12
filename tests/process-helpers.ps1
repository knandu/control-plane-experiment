function Assert($condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Start-Manager(
    [string] $name,
    [string] $stateFile,
    [int] $delay = 500,
    [switch] $PauseBeforeLocatorSave,
    [switch] $CaptureError,
    [Nullable[long]] $AuthorityEpoch,
    [string] $PauseBeforeStartEvent,
    [string] $AuthorityFile,
    [string] $PauseAfterStartAuthorityCheckEvent,
    [string] $PauseBeforeReadinessEvent
) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $CaptureError
    $info.RedirectStandardInput = $null -ne $AuthorityEpoch
    [void] $info.Environment.Remove('CONTROL_PLANE_PAUSE_BEFORE_LOCATOR_SAVE')
    [void] $info.Environment.Remove('CONTROL_PLANE_PAUSE_BEFORE_START_EVENT')
    [void] $info.Environment.Remove('CONTROL_PLANE_PAUSE_AFTER_START_AUTHORITY_CHECK_EVENT')
    [void] $info.Environment.Remove('CONTROL_PLANE_PAUSE_BEFORE_READINESS_EVENT')
    if ($PauseBeforeStartEvent) {
        $info.Environment['CONTROL_PLANE_PAUSE_BEFORE_START_EVENT'] = $PauseBeforeStartEvent
    }
    if ($PauseAfterStartAuthorityCheckEvent) {
        $info.Environment['CONTROL_PLANE_PAUSE_AFTER_START_AUTHORITY_CHECK_EVENT'] = $PauseAfterStartAuthorityCheckEvent
    }
    if ($PauseBeforeReadinessEvent) {
        $info.Environment['CONTROL_PLANE_PAUSE_BEFORE_READINESS_EVENT'] = $PauseBeforeReadinessEvent
    }
    if ($PauseBeforeLocatorSave) {
        $info.Environment['CONTROL_PLANE_PAUSE_BEFORE_LOCATOR_SAVE'] = '1'
    }
    foreach ($argument in @('manage', $stateFile, "$delay")) {
        $info.ArgumentList.Add($argument)
    }
    if ($null -ne $AuthorityEpoch) {
        $info.ArgumentList.Add('--authority-epoch')
        $info.ArgumentList.Add("$AuthorityEpoch")
    }
    if ($AuthorityFile) {
        $info.ArgumentList.Add('--authority-file')
        $info.ArgumentList.Add($AuthorityFile)
    }
    $session = [pscustomobject]@{
        Name = $name
        Process = [System.Diagnostics.Process]::Start($info)
        Lines = [System.Collections.Generic.List[string]]::new()
        Log = Join-Path $evidence "$name.log"
        CaptureError = $CaptureError
        AuthorityEpoch = $AuthorityEpoch
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
    if ($session.CaptureError) {
        [System.IO.File]::AppendAllText($session.Log + '.stderr', $session.Process.StandardError.ReadToEnd())
    }
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

function New-Intent([string] $name, [Nullable[int]] $Replicas) {
    $stateFile = Join-Path $evidence "$name.json"
    $stateFiles.Add($stateFile)
    $arguments = @('intent', $stateFile)
    if ($null -ne $Replicas) { $arguments += @('--replicas', "$Replicas") }
    & $executable @arguments | Out-Host
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

function Remember-Identity([string] $line) {
    Assert ($line -match 'pid=(\d+); startTicks=(\d+); runId=([0-9a-f-]+)') 'Missing incarnation in live evidence.'
    $identity = [pscustomobject]@{
        ProcessId = [int] $Matches[1]
        StartTimeUtcTicks = [long] $Matches[2]
        RunId = $Matches[3]
    }
    $children.Add($identity)
    return $identity
}

function Observed-Identity($session) {
    $line = @($session.Lines | Where-Object { $_ -match '^Observation .*fresh=(Running|Starting);' })[-1]
    return Remember-Identity $line
}

function Matching-Processes([string] $workloadId) {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'dotnet.exe'" |
        Where-Object { $_.CommandLine -like "*$assembly*--workload $workloadId *" })
}

function Assert-Live($identity, [bool] $ready = $true) {
    $process = [System.Diagnostics.Process]::GetProcessById($identity.ProcessId)
    try {
        Assert ($process.StartTime.ToUniversalTime().Ticks -eq $identity.StartTimeUtcTicks) 'Wrong incarnation.'
        $eventName = "Local\ControlPlaneExperiment-$(([guid] $identity.RunId).ToString('N'))"
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while ([datetime]::UtcNow -lt $deadline) {
            Assert (-not $process.HasExited) 'Expected child exited.'
            $handle = $null
            if ([Threading.EventWaitHandle]::TryOpenExisting($eventName, [ref] $handle)) {
                try {
                    if ($handle.WaitOne(0) -eq $ready) { return }
                }
                finally { $handle.Dispose() }
            }
            Start-Sleep -Milliseconds 50
        }
        throw "Expected readiness=$ready was not observed."
    }
    finally { $process.Dispose() }
}

function Stop-MatchingWorkloads([string] $workloadId) {
    foreach ($process in @(Matching-Processes $workloadId)) {
        $child = [System.Diagnostics.Process]::GetProcessById($process.ProcessId)
        try {
            Stop-Workload ([pscustomobject]@{ Workload = [pscustomobject]@{
                ProcessId = $child.Id
                StartTimeUtcTicks = $child.StartTime.ToUniversalTime().Ticks
            } })
        }
        finally { $child.Dispose() }
    }
}
