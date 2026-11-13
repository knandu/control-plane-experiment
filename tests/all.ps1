#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

& dotnet build (Join-Path $root 'ControlPlaneExperiment.slnx')
if ($LASTEXITCODE -ne 0) { throw 'Current solution build failed.' }

$scratch = (New-Item -ItemType Directory -Path (Join-Path $root ".state\historical-$([guid]::NewGuid().ToString('N'))")).FullName

function Export-Checkpoint([string] $commit, [string] $name) {
    $archive = Join-Path $scratch "$name.zip"
    $destination = Join-Path $scratch $name
    & git -C $root archive --format=zip "--output=$archive" $commit
    if ($LASTEXITCODE -ne 0) { throw "Cannot export historical checkpoint $commit." }
    Expand-Archive -LiteralPath $archive -DestinationPath $destination
    & dotnet build (Join-Path $destination 'ControlPlaneExperiment.slnx') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Historical build failed: $commit." }
    return $destination
}

try {
    # Historical contracts include saved observations and the intentionally broken crash recovery.
    $dayOne = Export-Checkpoint '0ab3e5ca5106e81c4d71f19f8b9c0fd4d398af58' 'day-01'
    $baseline = & (Join-Path $dayOne 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Day 1 real-process baseline failed.' }
    $baseline | Out-Host
    if (-not ($baseline -match '^Converged:.*start operations=1\.') `
        -or -not ($baseline -match '^Observation .*observed=Starting') `
        -or -not ($baseline -match '^Cleanup: owned child process has exited\.')) {
        throw 'Day 1 did not demonstrate pending startup, one Start, convergence, and cleanup.'
    }

    $dayTwo = Export-Checkpoint 'ab2410343f2c79251b3ba801a3ecd1a09bee7355' 'day-02.2'
    & pwsh -NoLogo -NoProfile -File (Join-Path $dayTwo 'tests\day-02.1.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Historical Day 2.1 tests failed.' }
    & pwsh -NoLogo -NoProfile -File (Join-Path $dayTwo 'tests\day-02.2.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Historical Day 2.2 failure reproduction failed.' }

    & pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'day-02.3.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Current Day 2.3 tests failed.' }

    & pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'day-03.1.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Current Day 3.1 tests failed.' }

    $dayThreeTwo = Export-Checkpoint 'a7665e70817b9261467ab7caaf20919e78f63d4d' 'day-03.2'
    & pwsh -NoLogo -NoProfile -File (Join-Path $dayThreeTwo 'tests\day-03.2.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Historical Day 3.2 failure reproduction failed.' }

    & pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'day-03.3.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Current Day 3.3 authority enforcement failed.' }

    $dayFourOne = Export-Checkpoint 'c11d024ef6bb2f3e79546ae3a93bfd48261c1f7c' 'day-04.1'
    & pwsh -NoLogo -NoProfile -File (Join-Path $dayFourOne 'tests\day-04.1.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Historical Day 4.1 isolation failure reproduction failed.' }

    & pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'day-04.2.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Current Day 4.2 subtractive reconciliation failed.' }

    & pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'day-04.3.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Current Day 4.3 ongoing health reconciliation failed.' }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}

Write-Host 'PASS: Day 1 baseline, four Day 2.1 scenarios, preserved Day 2.2 failure, eight current Day 2.3 scenarios, Day 3.1 clean handoffs, pinned Day 3.2 failure, current Day 3.3 authority enforcement, pinned Day 4.1 isolation failures, current Day 4.2 subtractive reconciliation, and current Day 4.3 ongoing health reconciliation.'
