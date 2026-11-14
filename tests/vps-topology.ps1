#Requires -Version 7.0
# Local regression: the VPS replica bound and desired-domain derivation come from the configured eligible
# execution-domain topology, not from a constant. Exercises topologies of size 1, 3 and 5 with arbitrary
# domain names. No cluster, no fences, no processes: validation and the pure decision function only.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $root 'src\ControlPlaneExperiment\bin\Debug\net10.0\ControlPlaneExperiment.exe'
$scratch = (New-Item -ItemType Directory -Path (Join-Path $root ".state\vps-topology-$([guid]::NewGuid().ToString('N'))")).FullName

function Invoke-Exe([string[]] $arguments) {
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
            $process.Kill(); [void] $process.WaitForExit(5000)
            throw "Command did not exit within 15 seconds: $($arguments -join ' ')."
        }
        [pscustomobject]@{ Code = $process.ExitCode; Out = $output.Result.Trim(); Err = $errorOutput.Result.Trim() }
    }
    finally { $process.Dispose() }
}
function Accept([string[]] $arguments) {
    $result = Invoke-Exe $arguments
    if ($result.Code -ne 0) { throw "Expected success: $($arguments -join ' '). $($result.Err)" }
    $result.Out
}
function Reject([string[]] $arguments, [string] $message) {
    $result = Invoke-Exe $arguments
    if ($result.Code -eq 0 -or $result.Err -notlike "*$message*" -or $result.Out -ne '') {
        throw "Expected refusal '$message': $($arguments -join ' '). exit=$($result.Code) out=$($result.Out) err=$($result.Err)"
    }
}
function Fingerprint([string] $store) {
    (Get-ChildItem -LiteralPath $store -File | Sort-Object Name | ForEach-Object { "$($_.Name)=$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) -join ';'
}
function Plan([string] $replicas, [string] $observed, [string[]] $domains) {
    Accept (@('vps-plan', $replicas, $observed) + $domains)
}
function Expect([string] $actual, [string] $fragment) {
    if (-not $actual.Contains($fragment)) { throw "Expected '$fragment' in: $actual" }
}

$topologies = [ordered]@{
    '1' = @('solo=127.0.0.1:47100')
    '3' = @('alpha=127.0.0.1:47101', 'beta=127.0.0.1:47102', 'gamma=127.0.0.1:47103')
    '5' = @('east-1=127.0.0.1:47111', 'east-2=127.0.0.1:47112', 'west.1=127.0.0.1:47113', 'west_2=127.0.0.1:47114', 'z9=127.0.0.1:47115')
}

try {
    foreach ($key in $topologies.Keys) {
        $size = [int] $key
        $domains = $topologies[$key]
        $names = @($domains | ForEach-Object { ($_ -split '=')[0] })
        $store = (New-Item -ItemType Directory -Path (Join-Path $scratch "store-$size")).FullName

        # Administrator intent is bounded by the configured topology size, and refusal does not mutate intent.
        Reject (@('vps', 'new', $store, "s$size.example.test", '\\content\site', '0') + $domains) 'at least 1'
        Reject (@('vps', 'new', $store, "s$size.example.test", '\\content\site', "$($size + 1)") + $domains) "between 1 and $size"
        if ((Fingerprint $store) -ne '') { throw "Refused New wrote intent for topology size $size." }
        Expect (Accept (@('vps', 'new', $store, "s$size.example.test", '\\content\site', "$size") + $domains)) "`"DesiredReplicas`":$size"
        $before = Fingerprint $store
        Reject (@('vps', 'set', $store, "s$size.example.test", "$($size + 1)") + $domains) "between 1 and $size"
        Reject (@('vps', 'set', $store, "s$size.example.test", '0') + $domains) 'at least 1'
        if ((Fingerprint $store) -cne $before) { throw "Refused Set mutated intent for topology size $size." }
        Expect (Accept (@('vps', 'set', $store, "s$size.example.test", '1') + $domains)) '"DesiredReplicas":1'

        # Desired domains are the first N configured domains, whatever they are named.
        foreach ($replicas in 1..$size) {
            $plan = Plan "$replicas" '-' $domains
            Expect $plan "eligibleCount=$size;"
            Expect $plan "requiredDomains=[$(($names | Select-Object -First $replicas) -join ',')];"
            Expect $plan "decision=Start; domain=$($names[0]); reason=required-domain-empty"
        }
        Reject (@('vps-plan', "$($size + 1)", '-') + $domains) "between 1 and $size"

        # Every configured domain Running at replicas=size is converged.
        $all = ($names | ForEach-Object { "${_}:Running" }) -join ','
        Expect (Plan "$size" $all $domains) 'decision=Converged;'
    }

    $five = $topologies['5']
    # Next Start fills the first empty required domain, even when it is not the first configured one.
    Expect (Plan '3' 'east-1:Running,west.1:Running' $five) 'decision=Start; domain=east-2; reason=required-domain-empty'
    # Surplus beyond N in a later configured position is stopped as not-required.
    Expect (Plan '2' 'east-1:Running,east-2:Running,west_2:Running' $five) 'decision=Stop; domain=west_2; reason=not-required-domain'
    # Starting in a required domain is awaited, not duplicated.
    Expect (Plan '2' 'east-1:Running,east-2:Starting' $five) 'decision=Wait;'
    # A collision in one required domain is resolved by Stop before anything else.
    Expect (Plan '2' 'east-1:Running,east-1:Running,east-2:Running' $five) 'decision=Stop; domain=east-1; reason=collision-or-degraded'
    # A realization claiming an unconfigured domain is a placement violation, not something to reconcile around.
    Reject (@('vps-plan', '2', 'east-1:Running,domain-4:Running') + $five) 'unconfigured domain'

    # Topology configuration itself is validated.
    $store = (New-Item -ItemType Directory -Path (Join-Path $scratch 'store-config')).FullName
    Reject @('vps', 'new', $store, 'c.example.test', '\\content\site', '1') 'At least one eligible execution domain'
    Reject @('vps', 'new', $store, 'c.example.test', '\\content\site', '1', '127.0.0.1:47100') 'must be name=host:port'
    Reject @('vps', 'new', $store, 'c.example.test', '\\content\site', '1', 'a=127.0.0.1:1', 'a=127.0.0.1:2') 'must be unique'
    Reject @('vps', 'new', $store, 'c.example.test', '\\content\site', '1', 'a=127.0.0.1:1', 'b=127.0.0.1:1') 'must be unique'
    if ((Fingerprint $store) -ne '') { throw 'Refused topology configuration wrote intent.' }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: VPS replica bound and desired-domain derivation follow configured topologies of size 1, 3 and 5.'
