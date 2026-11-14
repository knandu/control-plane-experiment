# Control Plane Experiment

> **Active/Active workloads do not require an Active/Active control plane.**

This repository tests that claim. A single, movable management authority
(Active/Passive) safely reconciled multiple simultaneously serving workload
realizations (Active/Active) across three Windows Failover Cluster nodes. It
did so through management moves, uncooperative management failure, scaling,
suspend/resume, repair and removal, and none of these disturbed healthy
service realizations.

The experiment is complete. It ended at Day 5.5.

## What this is, and what it is not

This is an **architecture demonstrator**, not a prototype. A prototype is an
early version of a product. This is the smallest real system I could build
that forces one architectural claim to confront crashes, stale authority,
failover and operational state, and it keeps the failures that shaped it.
Every mechanism in it exists because an earlier experiment failed without it.

It is not production software, not an orchestrator, and not a hosting
platform.

## Where it came from

I had built a control-plane-driven system for a very different workload. It
coordinated distributed compute resources: reconciling desired state with
running workloads, making placement decisions, publishing available capacity,
and recovering as machines and workloads changed.

Once it was working, I wondered which parts of the architecture were
consequences of that particular problem and which were more general. So I
removed the original domain, kept the ideas that seemed important, and built
the smallest real system that still forced those ideas to meet failure,
recovery and operational state. I planned up to seven logical "days" as
checkpoints, not calendar days. The question was answered in five.

### Why not just use Kubernetes?

If the goal were simply to run these workloads reliably, Kubernetes would be
a reasonable answer. But the original system already sat on a
high-availability framework. Adding another orchestrator would have created
two systems with overlapping responsibility for availability, recovery and
lifecycle. The more interesting question was: what is the smallest control
plane I actually need on top of an HA substrate I already have?

## The final demonstration

An administrator declares a virtual HTTP site:

```powershell
New-VPSSite -Name foobar.contoso.com -RootPath \\server\path -DesiredReplicas 3
```

Durable state records only that intent: identity, name, RootPath, desired
state and desired replica count. A singleton manager, placed by Windows
Failover Clustering (WFC), establishes a fenced mutation generation on every
node. It then observes reality fresh and starts one HTTP realization per
required node. Each node's port 80 serves `Host: foobar.contoso.com` from
RootPath.

With that running, the following were demonstrated live:

- Management moved: 0 starts, 0 stops.
- `DesiredReplicas` was declaratively reduced to 2: exactly one realization
  was stopped.
- Suspend/Resume rebuilt the service from intent alone.
- The cluster service was killed under the manager: the service continued,
  with 0 starts and 0 stops.
- One replica was killed: one fenced Start repaired it, and the peer was
  untouched.
- Remove converged reality to zero before the intent disappeared.

There is no DNS. Each node was addressed directly with an explicit `Host`
header. See [Day 5.5](docs/day-05.5.md).

The eligible execution domains are configured topology, not WFC membership,
and `DesiredReplicas` is bounded by their configured count. The demonstrator
was exercised live with three Windows execution domains, but the
reconciliation implementation does not encode three as an architectural
replica limit.

## The arc

Each day was earned by the failure, or missing proof, of the one before it.

| Day | Question | What it established |
|---|---|---|
| [1](docs/day-01.md) | What is the smallest honest reconciler? | Start returned ≠ Running. Observation is separate from action; convergence needs repeated matching observation. |
| [2](docs/day-02.md) | What must survive the manager? | A crash between Start and save created an orphan plus a duplicate. Persist **intent**; **rediscover** reality from identity the workload itself exposes. |
| [3](docs/day-03.md) | Can authority move without moving the workload? | Yes, but a stale manager executed an earlier valid decision. Authority must be **fenced at the effect boundary**, not only checked at decision time. |
| [4](docs/day-04.md) | Can one manager reconcile Active/Active replicas? | Occupancy, surplus and repair are all rediscovered. One effect per pass; incarnation-verified Stop; a startup witness distinguishes Starting from Degraded. |
| [5](docs/day-05.md) | What happens on a real HA substrate? | WFC gives placement but not fencing. Generation fences separate ownership from mutation authority, compose per node across Active/Active execution, and drive declarative service intent. |

Day 5 in five steps:

- [5.1](docs/day-05.1.md): WFC provides singleton placement.
- [5.2](docs/day-05.2.md): placement is not fencing, and an ownership recheck
  narrows the race without closing it.
- [5.3](docs/day-05.3.md): generation fencing that does not depend on the old
  owner's cooperation.
- [5.4](docs/day-05.4.md): per-node fences under Active/Active execution, with
  zero churn on management movement.
- [5.5](docs/day-05.5.md): declarative VPS site intent becomes a useful HTTP
  service.

## Who owns which truth

| Fact | Source of truth |
|---|---|
| Site identity, name, RootPath, desired state, desired replicas | Durable intent |
| Which node may establish management authority | WFC ownership |
| Which management incarnation may mutate | Authority generation, held per node by the fence |
| Ordering of generation advance vs. Start/Stop | Per-node execution-domain fence |
| Where realizations run, which are Running | Fresh observation |
| PID, native start time, RunId | The live incarnation |
| Starting vs. Running vs. Degraded | Readiness plus a per-incarnation startup witness |
| Which effect to take next | Reconciliation, one effect per pass |
| DNS, content storage | Outside the boundary |

> Persist what the management plane knows because it owns it. Rediscover what
> it knows only because it observed it.

## The bounded claim

> A movable Active/Passive management authority, placed by Windows Failover
> Clustering and protected by per-execution-domain fencing generations,
> safely reconciled administrator-authored declarative intent into
> Active/Active HTTP service realizations across three Windows execution
> domains. Management ownership moved and failed without causing healthy
> service realizations to churn.

The nodes are separate Windows execution domains: three VMs on one shared
Hyper-V host. They are not independent physical failure domains.

There is one recorded cost. When a fence could not confirm the new owner
because a node's cluster service was down, the manager withheld all effects
for about 14 seconds (`established=2/3`). That is reduced management
availability by design, not weakened safety. The experimental fence is not a
production availability design.

## Non-goals

These were not built, and nothing in the claim depends on them:

- DNS or a DNS publisher, load balancing, TLS
- Content deployment, storage HA, SMB provisioning
- A general scheduler, dynamic membership, multi-workload orchestration
- Network-partition or quorum research beyond what was exercised
- Production fence supervision, rolling upgrades, a management API, UI
- Linux, production packaging

An external DNS or discovery system could consume the freshly observed set
of Running nodes for a site. That would be a downstream consumer, not part of
this experiment.

## Why it stops here

The question was never which features an orchestrator should have. It was
whether a singleton management authority is enough for Active/Active
workloads, and which mechanisms that requires. After Day 5.5:

- every mechanism traces to a failure that earned it;
- the final composition needed no new HA mechanism;
- any next step (DNS, storage, scheduling, fence availability) would test a
  product, not this thesis.

Continuing would turn evidence into accumulation. The full stopping argument
is in the [Day 5 reflection](docs/day-05.md).

## A side effect: a teaching case

Because each mechanism was introduced only after its absence was reproduced,
the history reads as a sequence of small, concrete distributed-systems
lessons:

- observation versus action;
- intent versus observed state;
- crash windows;
- stale authority;
- fencing tokens;
- incarnation identity;
- the difference between placement and fencing.

The commits and notebooks can be followed in order for that purpose. This
was not the goal, but it turned out to be useful.

## How this was built

The architectural viewpoint, priors and stopping decisions are mine. They
come from experience building the original system. I defined each
experiment, often with help from planning and review agents. AI
implementation agents wrote the code, ran the harnesses, reported the
evidence and drafted much of the documentation. I interpreted each result
before choosing the next question.

AI assistance made it cheap to run a long sequence of small, falsifiable
experiments, including deliberately reproducing failures, that I would not
otherwise have had time for. It did not supply the thesis or decide what
counted as evidence. The method is recorded in the
[experiment framing](docs/experiment-framing.md).

## Documents

- Day 1: [notebook](docs/day-01.md)
- Day 2:
  - [2.1](docs/day-02.1.md): separate durable intent from manager lifetime
  - [2.2](docs/day-02.2.md): reproduce the start-before-save crash gap
  - [2.3](docs/day-02.3.md): rediscover workload identity
  - [reflection](docs/day-02.md)
- Day 3:
  - [3.1](docs/day-03.1.md): move authority without moving the workload
  - [3.2](docs/day-03.2.md): stale Start after authority moves
  - [3.3](docs/day-03.3.md): enforce authority at process creation
  - [reflection](docs/day-03.md)
- Day 4:
  - [4.1](docs/day-04.1.md): logical execution domains
  - [4.2](docs/day-04.2.md): incarnation-verified, fenced Stop
  - [4.3](docs/day-04.3.md): health loss and replacement
  - [reflection](docs/day-04.md)
- Day 5:
  - [5.1](docs/day-05.1.md): WFC placement
  - [5.2](docs/day-05.2.md): stale Start across WFC movement
  - [5.3](docs/day-05.3.md): generation fencing
  - [5.4](docs/day-05.4.md): Active/Active across cluster nodes
  - [5.5](docs/day-05.5.md): declarative VPS site intent
  - [reflection and conclusion](docs/day-05.md)
- [Experiment framing](docs/experiment-framing.md): rules introduced along the way

## Running the experiment

The early local model reconciles one desired workload with one or more child
processes on a single machine. Days 5.1–5.5 run against an external
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

## Later live experiments (Day 5.2–5.5)

The later live harnesses follow the same pattern. They run from the Hyper-V
host against the existing lab, and keep evidence under ignored
`.state\day-05.N-<run>`:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\day-05.2.ps1
pwsh -NoLogo -NoProfile -File .\tests\day-05.3.ps1
pwsh -NoLogo -NoProfile -File .\tests\day-05.4.ps1
pwsh -NoLogo -NoProfile -File .\tests\day-05.5.ps1
```

All require PowerShell 7 on the host and nodes. Day 5.3–5.5 deliberately
kill the cluster service on a node. Space repeated runs so that WFC does not
quarantine that node. The prerequisites and cleanup for each run are in its
notebook. The Day 5.5 administrative surface (`New-`, `Set-`, `Suspend-`,
`Resume-`, `Remove-` and `Get-VPSSite`) is in `tools\VPSSite.ps1`.
