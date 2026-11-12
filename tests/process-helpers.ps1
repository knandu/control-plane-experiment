function Assert($condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Start-Manager(
    [string] $name,
    [string] $stateFile,
    [int] $delay = 500,
    [switch] $PauseBeforeLocatorSave,
    [switch] $CaptureError
) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $CaptureError
    [void] $info.Environment.Remove('CONTROL_PLANE_PAUSE_BEFORE_LOCATOR_SAVE')
    if ($PauseBeforeLocatorSave) {
        $info.Environment['CONTROL_PLANE_PAUSE_BEFORE_LOCATOR_SAVE'] = '1'
    }
    foreach ($argument in @('manage', $stateFile, "$delay")) {
        $info.ArgumentList.Add($argument)
    }
    $session = [pscustomobject]@{
        Name = $name
        Process = [System.Diagnostics.Process]::Start($info)
        Lines = [System.Collections.Generic.List[string]]::new()
        Log = Join-Path $evidence "$name.log"
        CaptureError = $CaptureError
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
