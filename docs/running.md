# Running the experiment

This is reference material moved out of the [README](../README.md). Each
notebook also records its own prerequisites, validation and cleanup.

## Local model

The early local model reconciles one desired workload with one or more child
processes on a single machine. Days 5.1–5.6 run against an external
three-node WFC lab.
With the .NET 10 SDK installed, run these commands from the repository root:

```powershell
dotnet build .\ControlPlaneExperiment.slnx
dotnet run --project .\src\ControlPlaneExperiment --no-build -- intent .\.state\platform.json
dotnet run --project .\src\ControlPlaneExperiment --no-build -- manage .\.state\platform.json
```

Run default `intent` only once, with no manager running. Run exactly one manager
at a time. On Windows, it observes every 100 ms and keeps running after convergence;
stop it and repeat only the `manage` command to test recovery. Manager exit
deliberately leaves the child running. The Day 2.1 notebook includes validation
and explicit cleanup commands.

Use `intent <state-file> --replicas <count>` to request an active-active workload
with a positive replica count, for example `intent .\.state\fleet.json --replicas 3`.
Omitting `--replicas` keeps the original one-replica intent bytes, launch arguments,
and ambiguity behavior. For larger counts, the available logical domains are
`domain-1` through `domain-N`. A child exposes its domain in its launch arguments;
fresh discovery reconstructs occupancy without persisting assignments.
Starting children already occupy their domains. Convergence requires one ready
child in each domain across two observations.

An explicit `intent <existing-state-file> --replicas <count>` updates only the
count, preserving logical workload identity and desired state. Stop or
relinquish the manager first, update intent, then run `manage` again: managers
load intent once, not continuously. Default `intent` still refuses overwrite.
For counts greater than one, management removes out-of-range numbered domains
before resolving target-domain collisions, and removes collisions before
creating in missing domains. Each observation permits at most one Stop or
one Start. Missing or malformed domain labels still fail explicitly.
Effective count one retains its original ambiguity behavior; this is not a
multi-domain scale-down-to-one protocol. Domains remain logical labels on one
Windows machine, not physical fault isolation or remote-node placement.

Each child also owns a volatile startup-completed event. An unready child is
`Starting` before that event is set and `Degraded` afterward, even to a manager
that never saw it ready. After surplus and collisions, multi-domain management
stops the first degraded target domain; a subsequent observation rediscovers
the gap and starts its replacement. A genuinely Starting replacement occupies
its domain and is left alone. No health history or repair state enters intent.

Day 3.3 adds a separate, opt-in authority record. The external operator supplies
each strictly increasing positive epoch; managers cannot grant themselves one:

```powershell
dotnet run --project .\src\ControlPlaneExperiment --no-build -- grant .\.state\authority.epoch 1
dotnet run --project .\src\ControlPlaneExperiment --no-build -- manage .\.state\platform.json --authority-epoch 1 --authority-file .\.state\authority.epoch
```

In this mode, grant advancement and checked process creation share a local
Windows-session mutex. Day 4.2 uses the same boundary for Stop, verifying the
selected incarnation's native start ticks before termination. A stale Start or
Stop fails explicitly; a grant requested during an accepted effect waits until
that effect completes. All participants must use
the same authority file and protocol. Commands without `--authority-file`
retain the earlier, unenforced single-manager behavior.

Run the complete experiment, including pinned historical failures, with
`pwsh -NoLogo -NoProfile -File .\tests\all.ps1`. It includes
`tests\vps-topology.ps1`, which checks VPS replica bounds and domain derivation
against configured topologies of 1, 3 and 5 domains without a lab.
Day 4.1 is replayed at `c11d024` to preserve its pre-remediation isolation failures;
the current Day 4.2 test exercises their bounded remediation, and the current
Day 4.3 test exercises health loss, replacement handoffs, and health priority.

## External Day 5.1 integration experiment

The local suite includes Day 5.1 argument guards but does not require a cluster.
Run the live experiment explicitly from the Hyper-V host with the external lab
already available:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\day-05.1.ps1
```

Each invocation reloads `C:\vm\labs\wfclab\environment.json` and uses only its
dedicated SSH identity and host pins. The script does not construct or repair
the lab. It stages a temporary self-contained build on the three nodes, moves
an empty experiment-owned cluster group A -> B -> C, checks guest-side
authority/admission and unchanged intent, and removes its group and guest
staging. Evidence stays under ignored `.state\day-05.1-<run>`.

The guest command is
`manage-cluster-observe <state-file> <cluster> <group> --effects-disabled [observations]`.
Only the observed owner enters local workload observation. Start and Stop are
disabled even for the owner: this proves authority placement/admission, not
cross-node workload placement or stale-operation fencing.

## Later live experiments (Day 5.2–5.6)

The later live harnesses follow the same pattern. They run from the Hyper-V
host against the existing lab, and keep evidence under ignored
`.state\day-05.N-<run>`:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\day-05.2.ps1
pwsh -NoLogo -NoProfile -File .\tests\day-05.3.ps1
pwsh -NoLogo -NoProfile -File .\tests\day-05.4.ps1
pwsh -NoLogo -NoProfile -File .\tests\day-05.5.ps1
pwsh -NoLogo -NoProfile -File .\tests\day-05.6-probe.ps1
pwsh -NoLogo -NoProfile -File .\tests\day-05.6.ps1
```

All require PowerShell 7 on the host and nodes. The Day 5.6 node-side scripts
use Windows PowerShell 5.1, which the FailoverClusters module needs. Day
5.3–5.5 deliberately kill the cluster service on a node. Space repeated runs
so that WFC does not quarantine that node. The prerequisites and cleanup for
each run are in its notebook. The administrative surface (`New-`, `Set-`,
`Suspend-`, `Resume-`, `Remove-` and `Get-VPSSite`) is in
`tools\VPSSite.ps1`. In Day 5.6 it runs on the current owner of "VPS
Management".
