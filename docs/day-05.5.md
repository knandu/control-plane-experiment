# Day 5.5

## Prior

Day 5.4 showed that one movable Active/Passive management authority, placed by
WFC, could safely reconcile an Active/Active workload across Node-A, Node-B,
and Node-C. Per-node fences ordered authority generations against irreversible
effects. Every manager incarnation rediscovered reality cold. Moving
management, cooperatively or through uncooperative ClusSvc loss, caused zero
workload churn. A lost realization was repaired selectively.

That workload was experiment-shaped: a WorkloadId, `Replicas=3`, and a process
that only reported readiness.

## Question

> Can the mechanisms already proven in Days 1–5.4 drive a real, declarative,
> administrator-authored service abstraction?
>
> "foobar.contoso.com should serve `\\server\path` with N replicas."

The chain under test:

```text
administrator-authored durable intent
    -> movable singleton management authority
    -> fresh observation
    -> fenced reconciliation
    -> useful Active/Active HTTP service
```

This is the final composition increment. No new HA mechanism is added unless
the experiment earns one. None was earned.

## Durable intent

One JSON document per site (`<SiteId>.json`) in a site store:

```json
{
  "SiteId": "351acdf3-683c-466a-a2c4-bd1777766243",
  "Name": "foobar.contoso.com",
  "RootPath": "\\\\LAB-DC\\vps-content-9192ac6f",
  "Desired": "Running",
  "DesiredReplicas": 3
}
```

- `Desired` is one of `Running`, `Stopped`, or `Removed`. `Removed` is a
  terminal tombstone (see Remove).
- `DesiredReplicas` is 1..3.
- `Name` must be a lower-case DNS host name. `RootPath` must be a UNC path.
- The store deserializes with `UnmappedMemberHandling.Disallow`. A document
  carrying any field other than these five is rejected rather than ignored.

The document never contains a PID, RunId, start time, health, node occupancy,
WFC owner, fencing generation, repair workflow, victim list, last observation,
or DNS data. PlatformState and the Day 4 intent contract are unchanged.

`RootPath` is legitimate intent: it says *what content* the site serves. It
does not say where, by which process, or whether it is healthy. The content
behind it is outside this control plane.

## Administrator surface

`tools\VPSSite.ps1` (PowerShell 7, dot-sourced) is a thin wrapper over
`ControlPlaneExperiment vps <verb> <store> ...`:

| Cmdlet | Effect on durable intent | Never does |
|---|---|---|
| `New-VPSSite -Name -RootPath -DesiredReplicas` | creates the document, `Desired=Running` | start a process |
| `Set-VPSSite -Name -DesiredReplicas` | changes `DesiredReplicas` | name a node or process to stop |
| `Suspend-VPSSite -Name` | `Desired=Stopped`; everything else kept | stop a process |
| `Resume-VPSSite -Name` | `Desired=Running` | restore remembered placement |
| `Remove-VPSSite -Name` | `Desired=Removed` (tombstone) | delete the document |
| `Get-VPSSite [-Fences]` | none: reads intent and freshly observes | persist what it saw |

Every mutation is refused once a site is `Removed`. All effects come from the
manager (`ControlPlaneExperiment vps-manage <store> <cluster> <group> <fence...>`),
which is the Day 5.4 manager generalized from a WorkloadId to a site.

`Get-VPSSite` returns, per site, the intent, `ObservedAt`, each observed
realization (node, domain, state, PID, start ticks, RunId), and `RunningNodes`.
`RunningNodes` is computed from the fences on each call. It is never written
anywhere. It is the answer a hypothetical external DNS or discovery consumer
would read.

## Placement

The Day 5.4 projection is kept:

```text
domain-1 -> Node-A    domain-2 -> Node-B    domain-3 -> Node-C
replicas=N -> domain-1..domain-N
```

This is an **experiment invariant, not a scheduler**. A realization in a domain
numbered above the required count is a `not-required-domain` surplus victim,
and Day 4's shared `DomainReconciliation.SelectVictim` chooses it. A missing
required domain gets one `START`.

The manager fences **every** eligible domain, not only the required ones,
because it may have to stop a surplus realization anywhere.

## HTTP realization and virtual-host routing

A realization is the existing workload process (`Workload.Start`) with two
more argv fields, the site name and the RootPath. It keeps every earned
identity property:

- the stable SiteId as workload id
- a fresh RunId per incarnation
- the execution domain in argv
- the native PID plus start time, so Day 4's `Stop` incarnation check still
  applies

**Front end.** Port 80 on each node is owned by **http.sys**, the kernel HTTP
listener already in Windows. Each realization registers exactly one URL prefix
with `HttpListener`:

```text
http://foobar.contoso.com:80/
```

http.sys dispatches each request on port 80 by its Host (HTTP/1.1) or
authority to the process that registered that host. The registration is
process-owned and non-durable. It appears when the realization's listener
starts and vanishes when the process exits or is killed. There is no URL ACL
reservation, no proxy process, and no front-end mapping table.

```text
client --(Host: foobar.contoso.com)--> Node-X:80 (http.sys)
     --> process registered for foobar.contoso.com on Node-X  (current local realization)
     --> file under RootPath
```

So the "node-local front end" is the minimum that already exists. Routing is
derived from current local reality: whatever process is alive and listening
for that host. No durable operational mapping was needed, so the stop
condition for one ("STOP and document") never arose.

A request for a host nobody registered is answered by http.sys itself with an
error status and never reaches a realization. The live run asserts a non-`200`
answer for `Host: other.contoso.com`.

Every response carries diagnostic headers:

- `X-VPS-Site: <name>;siteId=<id>`
- `X-VPS-Realization: node=..;domain=..;pid=..;runId=..`

The harness uses these to prove *which* incarnation served each request.

There is no load balancing, retry, affinity, caching, or TLS.

## Day 1 states

| State | Meaning for a site realization |
|---|---|
| Stopped | no process |
| Starting | process exists, but RootPath `index.html` is not yet readable or the listener is not yet registered; the *started* witness is not set |
| Running | listener registered, content readable, readiness set |
| Degraded | the *started* witness is set (startup completed once), but a 1 s health probe of RootPath now fails, so readiness is reset and requests get `503` |

The Day 4.3 startup-completed witness is reused unchanged: a named event set
only after the listener starts. A cold manager therefore still distinguishes
"never completed startup" (Starting) from "completed and later lost health"
(Degraded) without any persisted health observation.

## RootPath and the intent store in the lab

The harness, not the control plane, stages two SMB shares on Lab-DC for each
run:

- `\\LAB-DC\vps-content-<short>`: RootPath, containing `index.html` with a
  per-run marker.
- `\\LAB-DC\vps-intent-<short>`: the site store.

Both grant read access to the Node-A/B/C computer accounts. Fences and
managers run as LocalSystem scheduled tasks, so they reach the shares as the
machine account. Each share is created at setup and removed at cleanup.

This is not SMB provisioning or storage HA. It is the smallest equivalent of
"`\\server\path` is reachable from all eligible nodes". The intent store being
one DC share is a lab limitation. Its availability is not part of the claim.

## Remove

Deleting the document first would be unsafe. A manager that then found no
intent would have nothing telling it which realizations to stop, so they would
be orphaned. Remove is therefore a two-step lifecycle with the smallest
possible extra state: one more value of `Desired`.

1. `Remove-VPSSite` writes `Desired=Removed`. That is an absorbing tombstone:
   no admin verb may change it, and `RequiredReplicas` is 0, so no authority
   will ever choose `START` for it.
2. The next manager:
   - advances **all** domain fences to its new generation;
   - stops every observed realization with fenced, incarnation-checked
     `STOP`s;
   - freshly observes zero realizations on two consecutive passes;
   - then calls `DeleteTombstone`.

   `DeleteTombstone` deletes the file only if its current contents equal
   exactly the tombstone this manager reconciled.

Why this ordering is safe:

- **Intent exists while realizations remain.** The document disappears only
  after zero realizations were observed, so the stop work can always be
  re-derived.
- **No older authority can resurrect it.** Every fence is at the new
  generation before any observation. A superseded manager's `START` is
  rejected at the fence (Day 5.3). A newer manager reads `Removed` and starts
  nothing.
- **Interruption is harmless.** If the manager dies mid-removal, the tombstone
  remains, and any later manager resumes the same convergence from fresh
  observation.
- **Concurrent re-creation is not deleted by mistake.** The delete is
  conditional on exact content.

This did not need a general workflow or state machine. It was a finding about
ordering, not an architectural contradiction.

## Live run

Harness: `tests\day-05.5.ps1`, with `tests\day-05.5-node.ps1` and
`tests\day-05.5-dc.ps1` staged by pinned-key SSH/SCP. Remote side is
PowerShell 7.

Final evidence run: `.state\day-05.5-9192ac6fbe5440db98fde6b7ce5932da`.

- site `351acdf3-683c-466a-a2c4-bd1777766243`
- RootPath `\\LAB-DC\vps-content-9192ac6f`
- content marker `1706f38f44c440e3be6b53b336333710`

An earlier equivalent passing run under Windows PowerShell 5.1 is kept at
`.state\day-05.5-e6ff7704...`.

Baseline: no site intent, no realization, and no HTTP answer for the host on
any node.

| Exp | Admin action | WFC owner | Generation | Starts | Stops | HTTP 200 via |
|---|---|---|---|---|---|---|
| 1 | `New -DesiredReplicas 3` | Node-A | 1 | 3 | 0 | A, B, C |
| 2 | none (move) | Node-B | 2 | 0 | 0 | A, B, C |
| 3 | `Set -DesiredReplicas 2` | Node-B | 3 | 0 | 1 | A, B |
| 4a | `Suspend` | Node-B | 4 | 0 | 2 | none |
| 4b | `Resume` | Node-B | 5 | 2 | 0 | A, B |
| 5 | none (kill Node-B ClusSvc) | Node-C | 6 | 0 | 0 | A, B |
| 6 | none (kill Node-A realization) | Node-C | 7 | 1 | 0 | A, B |
| 7 | `Remove` | Node-C | 8 | 0 | 2 | none; intent gone |

### Experiment 1: administrator creates intent

`New-VPSSite -Name foobar.contoso.com -RootPath \\LAB-DC\vps-content-9192ac6f -DesiredReplicas 3`
wrote the five-field document. A manager on Node-A advanced all three fences
to generation 1, observed nothing, and started one realization per missing
required domain, waiting through Starting each time:

```text
domain-1 = Node-A pid=5772 startTicks=639302082342744000 runId=962c47b8-efe4-410b-bf75-3cc0c5401b39
domain-2 = Node-B pid=5184 startTicks=639302082347350062 runId=195af39f-efa4-41e8-9677-b3828a487747
domain-3 = Node-C pid=5804 startTicks=639302082351825678 runId=e3839216-4ab6-4c54-8b2e-8ae4befd4e55
```

The harness then sent `GET /` to `192.168.241.11/12/13:80` with
`Host: foobar.contoso.com`. The results:

- All three returned `200` with the RootPath marker.
- Each `X-VPS-Realization` named its own node and PID.
- `Host: other.contoso.com` was not served (non-`200` from http.sys).

`Get-VPSSite` reported `RunningNodes = [NODE-A, NODE-B, NODE-C]`, freshly
observed. No DNS was involved.

### Experiment 2: management movement, no service churn

WFC moved the group to Node-B. A cold Node-B manager established generation 2
everywhere and rediscovered all three realizations:

- `starts=0 stops=0`
- PID, start ticks, and RunId were identical to Experiment 1 for every domain.
- HTTP `200` via all three nodes.

Management moved; the service did not.

### Experiment 3: declarative scale-down

`Set-VPSSite -DesiredReplicas 2` changed one field of intent and named no node.
The Node-B manager (generation 3) observed three Running realizations against
required domains `domain-1,domain-2`. It chose one effect:

```text
Decision=Stop; reason=not-required-domain; domain=domain-3; pid=5804; runId=e3839216-...
```

Keepers unchanged:

- `domain-1` Node-A pid 5772 / run 962c47b8
- `domain-2` Node-B pid 5184 / run 195af39f

HTTP was `200` on A and B. Node-C no longer answered for the host because the
registration died with the process. Changed intent produced an observed
divergence, which produced one fenced effect and then convergence.

### Experiment 4: suspend and resume

`Suspend-VPSSite` changed only the document to `Desired=Stopped`.
`DesiredReplicas=2`, the RootPath, and the SiteId remained. The manager
(generation 4) stopped both realizations. Afterwards:

- zero realizations
- no HTTP answer on any node
- the document still present

`Resume-VPSSite` set `Desired=Running`. The manager (generation 5) had only
intent plus fresh observation of empty nodes. Nothing about previous
placement or repair existed anywhere. It started two new incarnations:

```text
domain-1 = Node-A pid=5508 startTicks=639302083348876635 runId=898ec004-1d79-4b57-9663-829baeabc351
domain-2 = Node-B pid=1660 startTicks=639302083352757916 runId=92a633fa-87af-4284-b729-7557f98cc798
```

Both became Running, and HTTP returned `200` via A and B.

### Experiment 5: uncooperative management failure

Preferred owners were set to Node-B,Node-C. Node-B's ClusSvc (PID 5628) was
killed at 17:12:46 local, with no offline, relinquish, or cleanup. WFC brought
the group Online on Node-C at 17:12:50. HTTP via Node-A and Node-B kept
returning `200` throughout. The Node-B realization does not depend on its
node's cluster service.

The cold Node-C manager reproduced Day 5.4's non-atomic establishment:

```text
Advance domain-1: round=1; reply=GENERATION 6
Advance domain-2: round=1; reply=ERROR Win32Exception: Cannot open cluster 'wfcluster'.
Advance domain-3: round=1; reply=GENERATION 6
Authority establishment: round=1; established=2/3; effects=withheld
... domain-2: Cannot open cluster / Cannot open authority group ...
Authority establishment: established=3/3; effects=permitted   (after ~14 s, 4 withheld rounds)
```

It then rediscovered both realizations with `starts=0 stops=0`. The identities
were unchanged: Node-A pid 5508 / run 898ec004 and Node-B pid 1660 / run
92a633fa. HTTP returned `200` via A and B.

This shows that useful-service continuity, not only process continuity, is
independent of management continuity. The ~14 s withheld window is the
documented Day 5.4 safety behavior and was not weakened.

### Experiment 6: repair after failover

The Node-A realization (PID 5508) was killed, and HTTP via Node-A stopped
answering. Intent was not touched. The Node-C manager (generation 7) observed
`domain-1` missing and made one fenced `START`:

```text
domain-1 = Node-A pid=4044 startTicks=639302084080845872 runId=2d2d32d6-bf78-4e96-9a3f-27853425bde4   (replaced)
domain-2 = Node-B pid=1660 runId=92a633fa-...                                                        (unchanged)
```

`starts=1 stops=0`. HTTP returned `200` via A and B.

### Experiment 7: Remove

`Remove-VPSSite` wrote `Desired=Removed`. A following `Resume-VPSSite` was
refused with `Removed is terminal`. The Node-C manager:

```text
Intent: {...,"Desired":"Removed","DesiredReplicas":2}; requiredReplicas=0; requiredDomains=[]
Authority establishment: round=1; established=3/3; effects=permitted        (generation 8)
Decision=Stop; reason=not-required-domain; domain=domain-2; pid=1660; runId=92a633fa-...
Decision=Stop; reason=not-required-domain; domain=domain-1; pid=4044; runId=2d2d32d6-...
Result=Converged; desired=Removed; required=0; starts=0; stops=2; realizations=[]
Result=Finalized; intentDeleted=True; siteId=351acdf3-...
```

Final state:

- the site store is empty
- no realization on any node
- no HTTP answer
- per-node generations 8/8/8

Cleanup then removed the group, fences, shares, and firewall rules. Unrelated
cluster groups and resources were byte-identical to the baseline.

## Failures

Every failure was reproduced and classified before it was changed. None was
architectural.

| Run | Symptom | Cause | Class |
|---|---|---|---|
| 1 | remote JSON shape wrong | Windows PowerShell 5.1 serialized an empty array as `{}` | harness |
| 2 | null where an array was expected | StrictMode empty-array function return became `$null` under 5.1 | harness |
| 4 | Inspect failed after moving to pwsh 7 | `FailoverClusters` loads only through WinPSCompat in pwsh 7, so objects come back deserialized: `OwnerNode` is a string, and piping groups into cluster cmdlets fails. Scripts now stringify and use `-Name` | harness/tooling |
| 5 | DC `After` was `null` | a function returning nothing for an empty store; wrapped in `@()` | harness |
| 3, 6 | **PASS** | | |

Two lab-environment events occurred during regression reruns after the switch
to PowerShell 7:

- **WFC node quarantine.** Day 5.3, Day 5.4, and Day 5.5 each deliberately
  kill ClusSvc on Node-B. Repeated such failures within an hour make
  WFC quarantine Node-B for two hours (event 1676). Later runs then failed
  their all-nodes-Up preconditions or cleanup. The quarantine was cleared with
  `Start-ClusterNode -Name Node-B -ClearQuarantine`, and the runs were spaced
  out. This is WFC working as designed, not a defect in the experiment.
- **Compat-layer warning in stdout.** With Node-B's ClusSvc down, the pwsh
  WinPSCompat proxy wrote a "running remotely" warning to the output stream
  ahead of a node script's JSON. All node scripts now set
  `$WarningPreference='SilentlyContinue'`. This is a harness issue.

Final regression evidence under pwsh 7 (all PASS):

| Run | Evidence |
|---|---|
| `dotnet build` | 0 warnings, 0 errors |
| `tests\all.ps1` | exit 0 (Day 1 – Day 5.1 local) |
| Day 5.1 live | `.state\day-05.1-4bec32e429414add81c9c20d4d557f73` |
| Day 5.2 live | `.state\day-05.2-87cecd351ec0482ea2c35f2f644057e5` |
| Day 5.3 live | `.state\day-05.3-63918a7ef4b94b8fad19ae88620b2091`. This is a rerun after the warning fix, about an hour after the previous ClusSvc kill. The failed attempt `ef9dda69…` is described above. |
| Day 5.4 live | `.state\day-05.4-f37dc164b5d041cdb630e9c5a1a450bd` |
| Day 5.5 live | `.state\day-05.5-9192ac6fbe5440db98fde6b7ce5932da` |

## PowerShell 7

All scripts now declare `#Requires -Version 7.0`, and harnesses invoke
`pwsh.exe`. PowerShell 7.7.0 was installed on Node-A/B/C and Lab-DC from the
signed release zip (hash and Authenticode verified) into
`C:\Program Files\PowerShell\7`.

Honest note: Windows Server's `FailoverClusters` module is not
Core-compatible. Under pwsh 7 its cmdlets execute in an implicit Windows
PowerShell 5.1 compatibility session. Loading it natively with
`-SkipEditionCheck` fails with a missing `EventDescriptor` type. The Day 5
scripts are therefore pwsh 7 scripts whose cluster calls are proxied.

## What is rediscovered, not persisted

Each of the following is obtained afresh by every manager pass and every
`Get-VPSSite`:

- PID, native start ticks, and RunId (from the fences)
- Starting, Running, or Degraded state (process presence plus the started and
  readiness witnesses)
- node occupancy and `RunningNodes`
- WFC owner (asked of WFC)
- HTTP routing (the live http.sys registration of a live process)

Authority generations live only in each fence's own generation file, owned by
the authority mechanism, never in intent. Domain-to-node mapping is on the
manager's command line.

Suspend followed by Resume proved this. Nothing operational survived between
them, and service was reconstructed purely from the document.

## Finding

### PROVEN (for this lab)

1. Administrator-authored site configuration (`Name`, `RootPath`, `Desired`,
   `DesiredReplicas`) was persisted as intent and nothing else.
2. The Day 5.4 manager, unchanged in its authority and fencing rules, realized
   that intent as useful HTTP replicas.
3. Each expected node served the virtual site on port 80 by Host, with content
   from RootPath, without DNS.
4. Management movement, cooperative and uncooperative, caused zero Starts and
   zero Stops, and every keeper incarnation was unchanged.
5. Changing `DesiredReplicas` declaratively produced exactly one fenced Stop of
   the not-required domain.
6. Suspend preserved intent and converged to zero; Resume rebuilt service from
   intent plus fresh observation.
7. The authority reached through uncooperative failover then repaired a lost
   realization selectively.
8. Remove converged realizations away before the intent disappeared.

The only new concepts needed beyond Day 5.4 were:

- a richer intent record
- an HTTP-serving realization
- one terminal `Desired` value for safe removal

No new HA, fencing, or authority mechanism was needed.

### NOT PROVEN

- The live Degraded path for HTTP (RootPath loss after startup). It is
  implemented and covered by the reused Day 4.3 witness, but it was not
  injected live.
- Collision handling with HTTP: two realizations for the same host on one
  node. http.sys would refuse the second registration, so that process would
  fail before setting its started witness. This was not exercised live.
- Availability of the intent store or the RootPath share.
- Everything listed under Day 5.4 NOT PROVEN still applies (shared physical
  host, no partition or quorum testing).

## Boundaries and non-goals

Deliberately outside Day 5.5:

- no DNS, DNS publisher, zones, registration, or TTL
- no load balancer or client routing policy
- no TLS or certificates
- no content deployment, SMB provisioning, storage HA, or filesystem replication
- no general scheduler (fixed N → domain-1..N)
- no multi-site or multi-workload platform (the manager refuses more than one site)
- no Linux
- no production packaging, front-end, or proxy
- no generalized management API

A hypothetical external DNS or discovery integration could consume the freshly
observed set of Running nodes for a VPS site (`Get-VPSSite` → `RunningNodes`)
and advertise them. That is a downstream consumer. It is not part of Day 5.5.

## Limitations

- All VMs share one Hyper-V host.
- Fences and realizations run as LocalSystem.
- The intent store is one SMB share on Lab-DC.
- Manager incarnations are launched by the harness on the current WFC owner;
  there is no manager service.
- Fence availability is not productionized. An unreachable fence withholds
  all effects (by design).
- HTTP serving is minimal: `GET`/`HEAD` of files under RootPath.

## Stop condition

| # | Condition | Evidence |
|---|---|---|
| 1 | intent persisted | Exp 1 document, five fields only |
| 2 | realized as HTTP replicas | Exp 1, 3 Running |
| 3 | per-node Host routing without DNS | Exp 1–6 direct-node requests; other host not served |
| 4 | move with zero churn | Exp 2, Exp 5 |
| 5 | declarative scale | Exp 3 |
| 6 | suspend keeps intent, zero reality | Exp 4a |
| 7 | resume from intent + observation | Exp 4b |
| 8 | uncooperative failover keeps service | Exp 5 |
| 9 | selective repair by new authority | Exp 6 |
| 10 | safe remove | Exp 7 |
| 11 | operational reality rediscovered | intent schema, Exp 4 |
| 12 | regressions pass | `dotnet build`, `tests\all.ps1`, Day 5.1–5.4 live under pwsh 7 |

**Met. Implementation stops here. There is no Day 5.6.**

## Final statement

An administrator declares the virtual HTTP service they want. Durable state
records that intent. A movable singleton management authority observes
reality, establishes fenced mutation authority, and reconciles the required
Active/Active realizations.

Management can move, restart, or fail without becoming part of workload
identity or causing unnecessary service churn.

DNS, client routing policy, content distribution, storage HA, and production
hosting concerns remain deliberately outside the demonstrated control-plane
boundary.
