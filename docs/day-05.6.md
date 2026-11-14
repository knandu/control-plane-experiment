# Day 5.6

## Why Day 5 was reopened

Day 5.5 originally appeared to complete the experiment, and
[Day 5](day-05.md) was written as closed.

A later share-readiness review found one remaining artificial boundary in the
concrete WFC projection:

```text
WFC owned management placement,

but:

the external harness still owned management lifetime
and PlatformStore durability.
```

In Days 5.1–5.5 the "VPS Management" group was an empty ownership group. The
harness launched the manager with SSH and a scheduled task on whichever node
WFC named as owner. It also restarted the manager after a move or failure.
Durable intent lived in an SMB share on the DC, outside the cluster. WFC
decided *where* management could run. It did not run, monitor, restart or fail
over management, and it knew nothing about the intent that management
reconciled.

So the claim "WFC provides the availability of the management plane" was only
partly true. Day 5.6 reopens Day 5 to test whether those responsibilities can
be honestly projected onto Windows Failover Clustering. This was not planned.
It was found after the stopping decision.

## Question

> Does the management plane actually participate in the HA health and
> durability model of the substrate we claim provides its availability?

Concretely:

```text
"VPS Management" owns a real WFC resource that runs the manager.
WFC starts, monitors, restarts and fails over that manager.
The administrator's intent is carried with the role by WFC.
No harness supervises, restarts or reconstructs management.
```

Every Day 5.3–5.5 separation must survive:

```text
configuration           != observation
durable intent          != operational reality
WFC lifecycle           != mutation authority
authority generation    != effect ordering
management movement     != workload movement
```

## WFC resource choice

The manager is the process of a built-in **Generic Application** resource named
`VPS Manager`, in the group `VPS Management`.

```text
Group     VPS Management     (FailoverThreshold=4294967295, FailoverPeriod=6: defaults)
Resource  VPS Manager        type Generic Application
          CommandLine        "<dir>\ControlPlaneExperiment.exe" vps-serve
                             "wfc-checkpoint:wfcluster:VPS Management:HKLM\SOFTWARE\ControlPlaneExperiment\Day56-<run>"
                             wfcluster "VPS Management" "<dir>\manager.log"
                             domain-1=192.168.241.11:47055 domain-2=...12:47055 domain-3=...13:47055
          CurrentDirectory   <dir>
          Policy             RestartAction=2 RestartThreshold=1 RestartPeriod=600000
                             RestartDelay=500 PendingTimeout=180000 (all defaults)
          Registry checkpoint SOFTWARE\ControlPlaneExperiment\Day56-<run>
```

The eligible domains are passed as configured topology on the command line.
They are not derived from `Get-ClusterNode`.

The alternatives were weaker for this purpose:

- **Generic Service** would require installing and registering a Windows
  service on every node. That is packaging infrastructure the spec excludes,
  and it adds nothing the question needs.
- **Generic Script** relies on VBScript entry points, which Windows is
  deprecating.
- **A custom resource DLL** would be production WFC infrastructure, and no
  evidence forced it.

Generic Application provides what the question requires: WFC launches the
process, holds its handle, treats process exit as resource failure, applies
restart/failover policy, and supports registry checkpoints. Default policy
was kept, so nothing was tuned to make the result look better.

## Health and lifecycle semantics

These are the actual semantics observed, not assumptions:

- **Who starts management.** WFC. Every manager incarnation's parent process is
  `rhs.exe` (the Resource Hosting Subsystem). The harness asserted this in
  every experiment, and the harness never launched a manager.
- **Health signal.** Process liveness. The Generic Application resource DLL
  monitors the process it launched. If the process exits, the resource goes
  Failed. `LooksAlive`/`IsAlive` stay at type defaults. This is a meaningful
  but coarse signal: a manager that hangs while still alive looks healthy to
  WFC (see Limitations).
- **Online.** The resource reports Online once the process is started. The
  group can be briefly `Pending` while the manager is already running, so the
  manager's admission loop waits for the group to be `Online` on its own node
  before it requests authority.
- **Offline** (move, resource restart, cleanup) terminates the process. This is
  not a cooperative shutdown, so the old manager does not get to relinquish
  anything. That is acceptable only because safety never depended on
  relinquishment. The new incarnation's ADVANCE through every fence is what
  retires the old one (Day 5.3).
- **Failure policy.** With `RestartThreshold=1` and `RestartPeriod=600000`, the
  first failure within ten minutes is restarted on the same node. A second
  failure within the period fails the group over to another node.
- **Manager faults.** `vps-serve` never exits on convergence. Any unexpected
  fault (store refused, authority not established within three minutes,
  effect bound exceeded, and so on) is logged as `Fault:` and exits with code
  1. WFC then sees a resource failure. The harness does not.

## Checkpoint mechanism

`PlatformStore` site intent for Day 5.6 is `RegistrySiteStore`:

- Store spec: `wfc-checkpoint:<cluster>:<group>:HKLM\SOFTWARE\ControlPlaneExperiment\<key>`.
- One `REG_SZ` value per site, named by `SiteId`, containing exactly the Day 5.5
  intent JSON: `SiteId`, `Name`, `RootPath`, `Desired`, `DesiredReplicas`.
  Parsing still uses `UnmappedMemberHandling.Disallow`, so an operational
  field written there would be rejected.
- The key is registered with `Add-ClusterCheckpoint -RegistryCheckpoint` on
  the `VPS Manager` resource.
- Every read, write and tombstone delete first checks that the local node is
  the WFC owner, the group is `Online` and the node is `Up`. A write is
  confirmed with the same check afterwards.
- The store sets and deletes **values** only. It never deletes or recreates
  the key.

The administrator cmdlets (`tools\VPSSite.ps1`) are unchanged in shape. They
select the store through `VPS_STORE`, so in Day 5.6 they must run on the
current owner. The manager re-reads intent on every pass, so a change takes
effect without a restart.

Nothing else is checkpointed. Generations live in each fence's own file.
Occupancy, PIDs, RunIds, health and the owner are observed fresh by every
incarnation.

## Checkpoint semantics (probe)

Before using a checkpoint for intent, `tests\day-05.6-probe.ps1` measured how
it actually behaves. It used a throwaway Generic Application running
`PING.EXE -t` with a checkpointed key.

Run 1 (`.state\day-05.6-probe-58e6a6b0…`) was **confounded**. Its "write"
used `New-Item -Force`, which deletes and recreates the key, and after that
captured writes stopped following the role. That looked like "checkpoints
don't replicate". It was the probe destroying the key that WFC was watching.
The run was discarded, not interpreted.

Run 2 (`.state\day-05.6-probe-d3946600…`, value-only writes) established:

| Probe | Observed |
|---|---|
| Non-owner before any move | Key absent. Checkpoint data is not replicated live to other nodes. |
| Owner writes v1, role moves A → B | B reads v1. The destination receives the latest owner state on Online. |
| Non-owner writes locally, then the role arrives there | The local write is overwritten by the checkpoint. |
| Owner writes while the resource is Offline | Lost. The next Online restores the last captured value. |
| Kill #1 | Local restart in about 0.6 s (new PID); value retained. |
| Kill #2 within RestartPeriod | Group failed over A → B; value retained. |
| Delete and recreate the key on the owner, write v6, then move | Destination read stale v5. Capture silently stopped. |

Consequences, encoded in `RegistrySiteStore`:

1. Intent is current **only on the owner while the role is Online**. A copy on
   any other node is not intent.
2. A write while Offline is silently lost, so it is refused instead.
3. The key must never be recreated while checkpointed. The harness creates it
   empty before `Add-ClusterCheckpoint`, and nothing deletes it until cleanup.

## Fence protocol: unchanged in kind

The per-domain fences are the Day 5.4/5.5 fences, unchanged in protocol.
`ADVANCE` is accepted only from the node that WFC currently names as owner of
an Online group. `START`, `STOP` and `OBSERVE` carry the generation or identity
exactly as before. Each manager incarnation establishes a new generation on
**every** configured domain before any effect (`EstablishAuthority`).

## Live experiments

Final run: `.state\day-05.6-aa79ff20a65748ddaec274b1bf86a532`.

Topology:

- Three configured execution domains: Node-A/B/C.
- `RootPath` is the UNC content share `\\LAB-DC\vps-content-aa79ff20`.
- Intent is in the role's checkpoint. There is no intent share.
- Each node's fence runs as a SYSTEM scheduled task. That is experiment
  apparatus, not management.

Each experiment is measured from a mark. The harness counts, across all three
nodes:

- fence `START`/`STOP` requests;
- manager `Decision` lines.

It also requires:

- exactly one manager process, on the owner only, with parent `rhs.exe`;
- convergence logged by that manager after it reached a stable state;
- generations newer than before for each new incarnation;
- the owner-local intent equal to what the administrator wrote;
- HTTP checks on all nodes with `Host: foobar.contoso.com`.

| # | Event | WFC action | Manager | Fence starts / stops | Result |
|---|---|---|---|---|---|
| 1 | `New-VPSSite … -DesiredReplicas 3` on Node-A | none | 5336 on A | 3 / 0 | domain-1/2/3 Running and serving; generations 1 |
| 2 | `Move-ClusterGroup` A → B | Offline A, Online B | 5848 on B | **0 / 0** | identical PID/startTicks/RunId on all three; generations 2 |
| 3 | `Stop-`/`Start-ClusterResource` on B | restart in place | 5548 on B | **0 / 0** | identities unchanged; generations 3 |
| 4a | kill manager 5548 | Failed → Online on B in about 0.7 s (**local restart**) | 5468 on B | **0 / 0** | identities unchanged; generations 4 |
| 4b | kill manager 5468 (second failure within period) | **failover B → C**, Online in under 1 s | 5560 on C | **0 / 0** | identities unchanged; generations 5 |
| 5 | kill domain-1 realization (PID 1180 on A) | none | 5560 on C | 1 / 0 | only domain-1 restarted (new PID 4788); domain-2/3 unchanged |
| 6a | `Set-VPSSite -DesiredReplicas 2` on C | none | 5560 on C | 0 / 1 | only domain-3 stopped; administrator named no node |
| 6b | `Move-ClusterGroup` C → A | Offline C, Online A | 3244 on A | **0 / 0** | A's local intent reads `DesiredReplicas=2`; generations 6 |
| close | `Remove-VPSSite` on A | none | 3244 on A | 0 / 2 | converged to zero, `Result=Finalized`, tombstone value deleted, key present and empty, `Get-VPSSite` empty |

### Keeper identities across all management-only events (2, 3, 4a, 4b, 6b)

```text
domain-1  Node-A  pid=1180  runId=49103f19-…   (until it was deliberately killed in 5)
domain-2  Node-B  pid=1440  runId=a566589e-…
domain-3  Node-C  pid=1012  runId=1b6159a1-…   (until 6a stopped it)
```

Six distinct management incarnations ran on three nodes (5336, 5848, 5548,
5468, 5560, 3244), and WFC created all of them. None of them started or stopped a healthy realization. Every one of
them re-established authority and observed reality cold, without reading any
operational state from a predecessor.

### Updated intent followed the role

In 6a the administrator changed intent on Node-C, the owner at the time. In
6b WFC moved the role to Node-A. Node-A's manager, started by WFC, read
`DesiredReplicas=2` from its local checkpointed key and converged with 0
starts and 0 stops. The harness copied no intent at any point. The DC holds
only the content share.

## Failed attempts

Four live runs; three failed. They are classified below.

| Run | Failure | Class |
|---|---|---|
| `56d4a8e6…` | Inspect reported a residual "VPS Management" on a clean cluster. Under Windows PowerShell 5.1, `Management=$(if($group){…})` with no group serializes as `{}`, not `null`. The original error was then masked by a cleanup error. | Harness. The snapshot now emits an explicit `$null`, and the driver records `primary-error.txt` before cleanup. |
| `bed2427a…` | `New-Item` for the checkpointed key failed because its parent key had been removed by an earlier cleanup. Cleanup then removed the half-created group cleanly. | Harness. Create the parent if missing; still create the checkpointed key exactly once, without `-Force`. |
| `c09f7397…` | Experiment 1 passed. In Experiment 2, the Node-B manager could not establish authority: `Advance domain-2 … UNREACHABLE … actively refused`, `established=2/3; effects=withheld`. Node-B's fence had **exited** with an unhandled `IOException` in `writer.WriteLine(reply)`: *"An existing connection was forcibly closed by the remote host."* | **Lifecycle/fence coupling: an architectural finding.** See below. |
| `aa79ff20…` | — | PASS |

### Finding: non-cooperative management termination exposed fence fragility

WFC's `Offline` terminated the Node-A manager in the middle of an `OBSERVE`
exchange. The fence had already computed the reply. Its write to the dead
socket threw, the exception escaped the serial accept loop, and the domain-2
fence process died.

This never happened in Days 5.3–5.5. There, a manager was always either
allowed to finish, or lost its node's cluster service while its connections
stayed up. Hosting management in WFC made non-cooperative manager termination
**routine**: every move, resource restart and failover now does it.

Safety held. The new manager refused all effects at `established=2/3`
(`effects=withheld`), exactly as Day 5.4 requires. But the system had lost
liveness on that domain until someone restarted the fence. A fence that dies
when a requester dies makes the fence's availability depend on the requester
behaving cooperatively. That is the coupling the spec names "lifecycle/fence
coupling".

The fix is narrow. In `ClusterFenceExperiment.ServeDomain`, each connection is
handled in its own `try`. An `IOException` from the transport is logged as
`Domain transport lost: request=…; reply=…` and the fence continues. If an
effect had been applied, it stands. The reply is lost, but the next owner's
fresh observation rediscovers the effect. That is the Day 2 rule, applied to
the fence's own transport.

The final run exercised the fix live. At the Experiment 2 move, Node-A's fence
logged:

```text
Domain request: OBSERVE 9a2b8f06-…               05:25:59.2459
Domain reply:   OBSERVED domain-1 NODE-A Running|…|1180|…
Domain transport lost: request=OBSERVE …; error=An existing connection was forcibly closed by the remote host.
Domain request: ADVANCE NODE-B                    05:25:59.4524
Advance ownership check: requester=NODE-B; owner=Node-B; group=Online
```

The fence survived and accepted the new owner's ADVANCE 0.2 s later. This
fence change does not alter the protocol or any safety rule. The fence is
still experimental apparatus, not a production fence (see Limitations).

The interpretation: management incarnations are disposable, but the failure
of an authority client must not destroy the execution-domain authority
boundary. This is not a claim that fences are highly available. That remains
a different question.

## Regressions

- `tests\all.ps1` (Days 1–5 local, including the topology-generalization
  tests) passed after the fence change.
- The live Day 5.5 harness was rerun after the `Manage` refactor and fence
  change, and passed: `.state\day-05.5-6501a1351e8d4a27878eff7af0057a26`. The
  file-backed store, scale, suspend/resume, ClusSvc kill, repair and remove
  all behaved as before.

## Findings

1. **WFC can own management lifetime, not just placement.** Moves, resource
   restarts, local restart after failure and failover after repeated failure
   all happened under WFC policy. Each produced exactly one new manager, with
   parent `rhs.exe`, on the owner, and no harness involvement.
2. **The checkpoint carries intent with the role, under narrow rules.** The
   latest owner-written intent reached every destination. Intent is current
   only on the owner while Online. Off-owner or offline writes are lost, and
   recreating the key silently breaks capture. The store enforces the first
   two and avoids the third.
3. **WFC lifecycle is still not mutation authority.** WFC decides which
   process runs. Each new incarnation still had to ADVANCE every fence before
   acting. Offline is non-cooperative, and safety does not depend on it being
   anything else.
4. **Non-cooperative lifecycle exposed a fence availability flaw.** It was
   fixed by making the fence tolerate requester death. That is liveness, not
   safety, and it was the only code change the live run forced.
5. **Management movement remained independent of workload movement.**
   Management-only events produced zero fence starts or stops.

## Limitations

- **Health is process liveness.** A hung but alive manager is "Online" to WFC.
  An application-level `IsAlive` would need a custom resource or script, which
  was not built.
- **Intent is readable and writable only on the owner while Online.** The
  administrator cmdlets must run there. There is no remote management API.
- **Admin TOCTOU window.** The store checks ownership before and after a
  write. A move that completes between those checks and the next capture
  could lose that one write. The administrator sees the refusal or can reread.
  This was not exercised.
- **The checkpointed key must never be recreated.** That rule is enforced by
  convention in the store and harness, not by WFC.
- **Effect rejection is handled by exiting.** A manager that cannot establish
  authority within three minutes, or that sees a store refusal, exits nonzero
  and leaves recovery to WFC policy. Repeated failure therefore depends on
  that policy, and on fences being reachable.
- **The fences are still experiment apparatus**: SYSTEM scheduled tasks
  started by the harness, not clustered resources. Their own availability and
  supervision remain out of scope, as in Day 5.4/5.5.
- **Three execution domains, live.** The demonstrator was exercised live with
  three Windows execution domains, but the reconciliation implementation does
  not encode three as an architectural replica limit. The eligible domain set
  is configured topology passed on the resource command line, not WFC
  membership.
- **One shared Hyper-V host.** These are separate Windows execution domains,
  not independent physical failure domains.
- **No reboot or ClusSvc kill in Day 5.6.** Resource restart, move, and
  failure/failover established the checkpoint and lifecycle semantics being
  claimed. Day 5.3/5.5 evidence for uncooperative ClusSvc loss stands for the
  unchanged authority mechanism.

## What is now proven (for this lab)

> The "VPS Management" WFC role contains a real Generic Application resource
> that is the VPS manager. WFC starts it, monitors its process, terminates it
> on Offline, restarts it locally after a first failure and fails it over
> after a repeated failure. The administrator's durable site intent is a
> registry checkpoint of that resource. It reaches each new owner by WFC
> checkpoint restore, without harness copying. Each WFC-created manager
> incarnation establishes mutation authority through per-domain generation
> fences without cooperation from its predecessor. Across one move, one
> resource restart, one local restart, one failover and one move after an
> intent change, it caused zero starts and zero stops of healthy realizations.
> It still repaired a lost realization selectively, rescaled declaratively and
> removed the site.

## What remains outside scope

DNS, load balancing, TLS, content deployment, storage HA, SMB provisioning, a
scheduler, dynamic eligible-domain membership, clustered or supervised fences,
application-level health checks, network-partition and quorum research,
independent physical failure domains, rolling upgrades, a management API or
UI, Linux, and production packaging.

## Final architecture

```text
Administrator (on the owner)
      |
      v
checkpointed durable intent      HKLM\SOFTWARE\ControlPlaneExperiment\<key>, REG_SZ per SiteId
      |
      v
WFC "VPS Management" role        Generic Application "VPS Manager"
      |
      +-- management placement
      +-- management lifetime
      +-- management health/recovery (process liveness; restart, then failover)
      |
      v
authority generation             ADVANCE on every configured domain, owner-checked
      |
      v
per-execution-domain fences      order generation vs. Start/Stop; tolerate requester death
      |
      v
fresh observation + reconciliation
      |
      v
configured execution domains     domain-1..N from configuration, not cluster membership
      |
      v
Active/Active HTTP realizations
```

## Stop decision

The question this step reopened Day 5 for is answered. WFC owns management
placement, process lifetime and recovery, and carries current intent with
the role. The remaining limitations above (health depth, a remote
administration surface, fence supervision) are different questions, not
missing proof for the thesis.

How this step fits the whole of Day 5, the alternatives considered, and the
final stopping argument are in the [Day 5 reflection](day-05.md#why-day-5-stops-here).
