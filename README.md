# Control Plane Experiment

Recently, I built a control-plane-driven system for a very different workload.

It coordinated distributed compute resources: reconciling desired state with running workloads, making placement decisions, publishing available capacity, and recovering as machines and workloads changed.

Once it was working, I started wondering which parts of the architecture were consequences of that particular problem and which parts were more general.

So I'm trying a small experiment.

I'm going to remove the original domain, keep the ideas that seem important, and implement the smallest real system I can that still forces those ideas to confront failure, recovery, and operational state.

I'm giving myself seven logical "days." They're checkpoints rather than calendar days.

I don't know yet what the final architecture will look like.

## Why not just use Kubernetes?

That's an obvious question.

If my goal were simply to run these workloads reliably, Kubernetes would be a reasonable answer. But the system this experiment came from already had a high-availability framework. Adding another orchestrator would have given me two systems with overlapping responsibilities for availability, recovery, and lifecycle.

That made the more interesting question: what was the smallest control plane I actually needed?

This experiment lets me ask that question again, without the original domain getting in the way.

## Running the experiment

A seven-day experiment exploring control planes, reconciliation, and the gap between intent and operational reality.

This is an experiment, not production software. The current model reconciles
one desired running workload with one or more child processes, observing readiness
separately from issuing a start. See the [Day 1 notebook](docs/day-01.md),
[Day 2.1 notebook](docs/day-02.1.md), [Day 2.2 notebook](docs/day-02.2.md),
and [Day 2.3 notebook](docs/day-02.3.md).
The [Day 2 reflection](docs/day-02.md) looks back across those three experiments.
The [Day 3.1 notebook](docs/day-03.1.md) tests clean authority movement without moving the workload.
The [Day 3.2 notebook](docs/day-03.2.md) reproduces a stale Start after declared authority moves.
The [Day 3.3 notebook](docs/day-03.3.md) tests authority enforcement at the local process-creation boundary.
The [Day 3 reflection](docs/day-03.md) looks back across those three experiments.
The [Day 4.1 notebook](docs/day-04.1.md) tests distinct logical execution domains and fresh occupancy discovery without persisted placement state.
The [Day 4.2 notebook](docs/day-04.2.md) tests subtractive reconciliation and incarnation-verified, authority-fenced Stop.
The [Day 4.3 notebook](docs/day-04.3.md) tests rediscoverable health loss and two-step replacement without a persisted repair workflow.
The [Day 4 reflection](docs/day-04.md) closes placement, removal, and repair as one investigation, and leaves Day 5 undecided at the physical-domain boundary.
The [Day 5.1 notebook](docs/day-05.1.md) projects management admission onto real Windows Failover Cluster ownership, without claiming stale-effect fencing.
The [experiment framing](docs/experiment-framing.md)
records rules introduced during Day 2.

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
`pwsh -NoLogo -NoProfile -File .\tests\all.ps1`.
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
