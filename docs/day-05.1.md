# Day 5.1

## Question

Can a real Active/Passive HA substrate provide the movable singleton management
authority assumed by the earlier control-plane experiments?

Days 3 and 4 supplied epochs through an experimental external grant. This step
makes one part concrete: where management authority resides. It does not
simultaneously turn Day 4's workload domains into remote execution targets.

## Prior

Windows Failover Clustering appears capable of supplying singleton group
ownership that can move among nodes. That is a prior, not evidence that every
old operation is fenced after ownership moves.

## Pre-change findings

Inspected clean `main` at `7d25d36`, whose runtime remains Day 4.3 (`ba174e8`),
before changing the cluster or runtime.

`AuthorityGrant` serializes grant advancement and checked Start/Stop using a
`Local\` named mutex derived from the authority-file path. It holds that mutex
through native creation/incarnation capture or verified termination. The
manager pre-check releases it before the existing fault-injection gate.
The mechanism is cooperative and same-session, not a cross-node cluster fence.
It does not enforce one manager per epoch.

`PlatformState` contains only `WorkloadId`, `Desired`, and optional `Replicas`.
Management loads it once. Discovery, readiness, Started witnesses, and native
process identity are local-machine/current-session observations.

Read the external host-local manifest without copying it into the repository.
Pinned SSH execution on Node-A found:

- Windows Server 2025 Datacenter, build 26100.
- `wfcluster`, nodes Node-A, Node-B, Node-C all Up.
- Core `Cluster Group` Online on Node-A; `Available Storage` Offline on Node-A.
- No experiment-owned group.
- FailoverClusters `Add-ClusterGroup`, `Move-ClusterGroup`, and
  `Remove-ClusterGroup` available.
- No `dotnet` command on Node-A.

The lab's implementation repository was not inspected or modified.

## Bounded implementation

Use an empty, uniquely named `ControlPlaneExperiment-Day51-<run>` cluster
resource group as the ownership artifact. No resources, application service,
address, DNS name, or storage are added. Stable Online or Offline state is
accepted; ownership, not the existence of an application resource, is being
projected.

`ClusterAuthority` queries ownership through node-local native ClusAPI, verifies
the returned cluster name against the expected name, and obtains local
identity from the guest. `manage-cluster-observe` repeatedly gates entry into
local workload observation on current ownership and an Up local node.
It has no Start/Stop call path. The required `--effects-disabled` flag makes
that boundary visible; an admitted observation is not workload convergence.

The existing effectful manager and `AuthorityGrant` remain unchanged.
No cluster observer is passed off as a replacement effect fence.

### An assumption rejected by the first rehearsal

The initial harness required an empty group to be Offline. The first live
creation returned Online on Node-A, with zero resources in that group.
The harness failed before any manager probe, then removed the exact group
and all three guest staging directories. Core and unrelated cluster state
matched preflight. This run is not counted as a passing experiment.

The correction accepts either stable state, checks the guest's native
observation against the actual cluster snapshot, and still rejects Pending,
Failed, and PartialOnline for authority admission. No application resource
was added to make the earlier assumption true.

The second rehearsal admitted Node-A, then Node-B's `OpenCluster("wfcluster")`
failed with Win32 error 5 (Access Denied). Node-B's node-local PowerShell
inspection had succeeded. Named OpenCluster uses RPC, whereas null uses the
local cluster's LPC connection. The observer now explicitly uses the latter
and verifies the actual cluster name. No credentials, permissions, remote
management channel, or lab configuration were changed. The exact authentication
cause of the RPC failure was not established. Checked cleanup succeeded again;
this partial run is not a passing movement experiment.

## Environment and invocation

The external lab has its own repository and lifecycle. This repository consumes
only `C:\vm\labs\wfclab\environment.json` and its dedicated SSH/SCP identity and
known-host pins. The manifest is reloaded for every invocation because reset
rotates the credentials and host keys. No manifest, credentials, private key,
or known-host file is copied into source control.

The apparatus is `wfcluster` in `wfclab.test`: three Windows Server 2025
Datacenter guests, Node-A/B/C, at `192.168.241.11/12/13`, with a separate
AD/DNS guest and private cluster network. Guests have no configured Internet
route. Only cluster identity, node availability, core resource health, and
SSH execution were checked; lab construction was not repeated.

```powershell
dotnet build .\ControlPlaneExperiment.slnx
pwsh -NoLogo -NoProfile -File .\tests\day-05.1-local.ps1
pwsh -NoLogo -NoProfile -File .\tests\all.ps1
# Explicit integration invocation; not part of all.ps1:
pwsh -NoLogo -NoProfile -File .\tests\day-05.1.ps1
```

The host needs the .NET 10 SDK and OpenSSH clients. The harness publishes a
temporary self-contained Windows x64 build, rather than installing a runtime
or downloading anything inside the guests. It stages the node script and zip
with pinned SCP and invokes the file over pinned SSH. Normal user SSH
configuration is bypassed, not edited; WinRM, UAC elevation, RunAs, and lab
permission changes are not used.

The guest helper uses only its invocation's generated group and file names.
It refuses to reuse an existing group, move/remove a group with resources, or
delete staging while an experiment process remains. A cleanup error is a test
failure, not a passing result. Preflight refuses leftover Day 5.1 groups rather
than silently taking over another invocation's artifact.

## Experiments: first complete run

Run ID: `d81f620cc8b94677a3cec61f11524047`.
Group: `ControlPlaneExperiment-Day51-d81f620cc8b94677a3cec61f11524047`.
Full diagnostics were emitted to ignored `.state\day-05.1-<run>`.
Times in the table are the first guest authority observation, UTC.

### 1. Ownership determines admission

The helper executed `Add-ClusterGroup -Name <experiment-group>` on Node-A.
The group was created Online on Node-A, with zero resources.
It then ensured Node-A ownership with `Move-ClusterGroup -Node Node-A -Wait 30`
only if needed. No cluster core/infrastructure group was moved.

Each guest actually ran:

```text
ControlPlaneExperiment.exe manage-cluster-observe intent.json wfcluster <experiment-group> --effects-disabled 2
```

The executable obtains local node identity itself, opens the local cluster,
checks its name, and queries group ownership afresh for each pass. The host
does not supply an expected owner to the manager.

### 2. Movement to Node-B, without rebuilding state

On Node-A, the helper executed
`Get-ClusterGroup <experiment-group> | Move-ClusterGroup -Node Node-B -Wait 30`.
The resulting snapshot showed Online ownership on Node-B. All three guests
ran the same management command again, without updating their intent files
or reading predecessor logs.

### 3. Repeated movement to Node-C

The same action targeted Node-C. A new snapshot and actual execution on all
three guests established the third placement, not an A/B special case.

| Cluster owner | Guest / manager PID | Native manager start ticks | First observation UTC | Authoritative / admission |
|---|---|---|---|---|
| Node-A | Node-A / 3476 | 639301878009906911 | 17:30:01.9584727Z | true / admitted |
| Node-A | Node-B / 2236 | 639301878045574669 | 17:30:05.5117183Z | false / skipped |
| Node-A | Node-C / 5008 | 639301878080040723 | 17:30:09.1163142Z | false / skipped |
| Node-B | Node-A / 6056 | 639301878145884750 | 17:30:14.7659064Z | false / skipped |
| Node-B | Node-B / 5868 | 639301878169501787 | 17:30:17.1227449Z | true / admitted |
| Node-B | Node-C / 3196 | 639301878198257841 | 17:30:20.0058814Z | false / skipped |
| Node-C | Node-A / 500 | 639301878244390598 | 17:30:24.6233583Z | false / skipped |
| Node-C | Node-B / 3912 | 639301878268012966 | 17:30:26.9813918Z | false / skipped |
| Node-C | Node-C / 5636 | 639301878293516007 | 17:30:29.5254422Z | true / admitted |

All observations above occurred on November 13, 2026. Node names scope the
native PID identities; a PID alone is not a cluster-wide identity.

### 4. Non-owner refusal is in the management path

The six non-owner invocations each produced two ownership observations and
two explicit skips:

```text
admission=skipped; reason=not-current-owner-or-not-stable; reconciliationAttempted=false; effects=disabled; starts=0; stops=0.
```

They did not call workload discovery. The operator did not have to avoid
invoking the wrong node.

### 5. Owner admission is observable, but bounded

The three owner invocations each entered two passes of existing local
workload discovery and reported:

```text
admission=admitted; reconciliationAttempted=true; workload=8fb74bf8-b0f4-4f34-af34-8a01f7be5883; desiredReplicas=3; liveCount=0; runningCount=0; startingCount=0; degradedCount=0; scope=local-observation-only; effects=disabled; starts=0; stops=0.
```

There were no workload children, no Start/Stop decisions, and no claimed
workload convergence. This is entry into the observation portion of
reconciliation, not an effectful cluster deployment.

### 6. Movement does not mutate application intent

The host created intent once and staged identical test copies on all three
nodes **before** moving authority:

```json
{
  "WorkloadId": "8fb74bf8-b0f4-4f34-af34-8a01f7be5883",
  "Desired": "Running",
  "Replicas": 3
}
```

Every guest invocation checked the bytes before and after management.
All 18 hashes, plus the host's final hash, matched the initial SHA-256:

```text
0445A626BA6277D25B951F8252A30F273D7C83257D07F88BC8AA5793D2802774
```

Property names remained exactly `WorkloadId,Desired,Replicas`.
No owner, authority locator, manager identity, observation, occupancy, health,
or repair metadata entered `PlatformState`. Cluster group configuration
belongs to the HA substrate, not the application intent store.

These are identical pre-staged local copies, **not** a newly demonstrated
distributed durable intent store. Mutable intent propagation, store recovery,
and shared storage are outside this checkpoint.

## Clean repeat

The second complete fresh-shell invocation reloaded the manifest and confirmed
that no Day 5.1 group remained before creating a new one:
`ControlPlaneExperiment-Day51-016b181e44c64cc384b725955c6bbc79`.

| Action | Observed owner / state | Snapshot UTC, November 13, 2026 |
|---|---|---|
| Create | Node-A / Online | 17:31:44.0083356Z |
| Ensure A ownership | Node-A / Online | 17:31:46.1860832Z |
| Move A -> B | Node-B / Online | 17:31:58.0575268Z |
| Move B -> C | Node-C / Online | 17:32:07.6101702Z |
| Remove exact group | Absent | 17:32:17.4269677Z |

All three guests again executed two passes at each placement: six admitted
owner passes, twelve skipped non-owner passes, zero Starts, zero Stops.
The three admitted managers in that repeat were:

| Owner | PID | Native manager start ticks | First authority observation UTC |
|---|---|---|---|
| Node-A | 5756 | 639301879083074719 | 17:31:49.2114735Z |
| Node-B | 3132 | 639301879224190243 | 17:32:02.5811562Z |
| Node-C | 5564 | 639301879346725405 | 17:32:14.8439480Z |

Its logical workload was `74a436cf-0787-4131-8dc3-e21349e7aa76`.
The original, before/after guest, and final host intent hash was:

```text
F89609170F237A25F514414EF5220860276C027EE306E0FF51E74C015BEA5D20
```

Across both complete runs, the evidence contains 18 guest manager invocations,
36 fresh ownership observations, 12 admitted local observation passes, and
24 explicit skips. Both runs removed the exact group and reported zero
remaining experiment processes on each guest, with staging removed.

## Cleanup and validation

The first complete run removed its group at `17:30:32.0560192Z`; the repeat
removed its group at `17:32:17.4269677Z`. Each cleanup snapshot found
Node-A/B/C Up, the core group Online on Node-A, and the same unrelated group
and resource names, owners, and states as preflight. The helper also inspected
process executable paths before deleting each exact run directory, zip, and
staged script. It did not kill any infrastructure process or remove any
resource from another group.

An independent pinned-SSH inspection at `17:35:31.9894904Z` again found
all three nodes Up, only `Available Storage` and `Cluster Group` in the normal
group inventory, and `Cluster IP Address`, `Cluster Name`, and the existing
`User Manager` resource Online. No Day 5.1 group remained.

One local validation rehearsal hit the new negative-command test's ten-second
exit limit. A diagnostic replay returned the expected explicit rejection, and
the four guard checks passed on replay. The new helper now uses the same
15-second exit bound as the repository's existing authority tests and includes
the rejected arguments in timeout errors. The exact cause of the one delay
was not established; that aborted run, in which the full suite had not started,
is not counted as a passing validation.

Final validation on the completed source:

| Check | Result |
|---|---|
| Current `dotnet build` | Passed; zero warnings, zero errors |
| Focused Day 5.1 local guards | Passed; invalid mode, counts 0/101, missing intent, unchanged bytes |
| Focused existing Day 3.3 and Day 4.3 | Passed; original effect fences and health repair preserved |
| Full `tests\all.ps1`, fresh shell | Passed, including historical failures and new local guards; all five builds zero warnings/errors |
| Day 5.1 live integration, two complete fresh-shell runs | Passed; 36 checks across A/B/C ownership, checked cleanup both times |
| Explicit absent-manifest invocation | Failed as expected before lab access, with the absent-manifest diagnostic |
| Independent post-cleanup cluster inspection | Passed; all nodes Up, infrastructure Online, no experiment group |

`tests\all.ps1` never invokes the external integration script. The lab can be
unavailable without making the existing local suite unusable.
`AuthorityGrant.cs`, `Workload.cs`, `PlatformStore.cs`, prior notebooks, prior
scenario scripts, and historical source pins were not changed.
Existing `Program.cs` gained only dispatch/usage for the separately named observer.
No new package or `PlatformState` field was required.

After validation, diagnostics were copied and hash-verified outside the
repository before removing 11 exact task-owned host runtime directories.
The four pre-existing `.state` directories were preserved. No repository
experiment process remained at cleanup. Build outputs remain ordinary ignored
build outputs; no lab manifest, key, pins, payload, or runtime state is staged.

The API contracts consulted were Microsoft's `OpenCluster`,
`GetClusterInformation`, and `GetClusterGroupState` references:

```text
https://learn.microsoft.com/en-us/windows/win32/api/clusapi/nf-clusapi-opencluster
https://learn.microsoft.com/en-us/windows/win32/api/clusapi/nf-clusapi-getclusterinformation
https://learn.microsoft.com/en-us/windows/win32/api/clusapi/nf-clusapi-getclustergroupstate
```

## Why this construct

An empty cluster group was sufficient to answer who owns this experimental
authority. A Generic Application/Service/Script resource, address, network name,
or shared disk would have introduced a lifecycle or availability claim that
the question did not require. None was added.

Ownership changes are real Windows Failover Cluster operations. The managers
are explicitly invoked on guests, not launched or supervised by a clustered
application resource. This tests movable placement of authority and guarded
entry, not automatic manager restart or crash-triggered failover.

## Findings and limits

**Established:** Windows Failover Clustering supplied the movable singleton
node placement of management authority assumed by the experiment. After
each stable A -> B -> C movement, only that owner admitted the observation
portion of reconciliation; the other guests skipped it. Authority movement
did not rewrite application intent.

**Not established:** cluster ownership alone safely fences every stale effect
from a former owner. The observation can become stale immediately after it is
returned. Local node state and group ownership are not one transactional
snapshot; no query is treated as a lease or retained effect permission.

There is deliberately no effectful cluster-backed manager in Day 5.1.
The required `--effects-disabled` flag is not an opt-in to a stronger mode:
there is no enabled variant. The earlier effectful `manage` command still
requires its original single-manager protocol and optional experimental
`AuthorityGrant`. It is not made cluster-safe by this command's existence.

Nor does one owner node imply one process on that node: two managers launched
there could both be admitted. Manager process supervision/exclusion, actual
node failure, partitions, remote workload discovery/effects, health repair
across machines, and role recovery policy were not tested. Day 4 domains
remain logical labels; none was mapped onto a cluster node.

## Next question: Day 5.2

> When cluster ownership moves after an old manager has made a decision but
> before it performs the effect, what prevents the former owner from
> executing the stale operation?

Day 5.1 leaves that question open. It adds no cross-node effect fence,
publication, scheduler, service recovery mechanism, or deployment framework.
