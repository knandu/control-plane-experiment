#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$scratch = (New-Item -ItemType Directory -Path (Join-Path $root ".state\day-05.1-local-$([guid]::NewGuid().ToString('N'))")).FullName

function Reject([string[]] $arguments, [string] $message) {
    $info = [Diagnostics.ProcessStartInfo]::new($executable)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill();
            [void] $process.WaitForExit(5000)
            throw "Rejected command did not exit within 15 seconds: $($arguments -join ' ')."
        }
        if ($process.ExitCode -eq 0 -or $errorOutput.Result -notlike "*$message*" -or $output.Result -ne '') {
            throw "Expected explicit rejection before cluster access: $message. $($errorOutput.Result)"
        }
    }
    finally { $process.Dispose() }
}

try {
    $state = Join-Path $scratch 'intent.json'
    & $executable intent $state --replicas 3 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Intent command failed.' }
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($state))
    Reject @('manage-cluster-observe', $state, 'unused', 'unused', '--allow-effects') 'requires --effects-disabled'
    foreach ($count in @('0', '101')) {
        Reject @('manage-cluster-observe', $state, 'unused', 'unused', '--effects-disabled', $count) 'between 1 and 100'
    }
    Reject @('manage-cluster-observe', (Join-Path $scratch 'absent.json'), 'unused', 'unused', '--effects-disabled') 'No durable intent exists'
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($state)) -cne $before) { throw 'Rejected probe mutated intent.' }
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
Write-Host 'PASS: Day 5.1 local fail-closed argument and missing-intent checks; no lab required.'
