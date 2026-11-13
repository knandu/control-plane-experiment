# Day 5.4

## Question

> Can one movable Active/Passive management authority safely reconcile an
> Active/Active workload across Node-A, Node-B, and Node-C as real execution
> domains?

Day 4 answered this against simulated execution domains on one machine. Day
5.3 showed that WFC can decide *who* may advance an authority generation, and
that a fence at the execution domain decides *which* generation may still
mutate it. Day 5.4 combines the two with Replicas=3.

## Projection

The mapping is fixed for the experiment and supplied on the manager's command
line. It is not persisted.

```text
Day 4 domain-1 -> Node-A   (192.168.241.11)
Day 4 domain-2 -> Node-B   (192.168.241.12)
Day 4 domain-3 -> Node-C   (192.168.241.13)
```

Each node runs one small fence process
(`fence-execution-domain <cluster> <group> <port> <generation-file> <gates> domain-K`).
The fence is the only thing that touches that node's workload processes. It
starts the realization with argv domain `domain-K`, so each realization records
its domain exactly as in Day 4.

Management location is independent of workload placement. The manager
(`experiment-active-active`) runs on whichever node WFC names as owner of the
resource-free experiment group. Across the run, management lived on Node-A,
then Node-B, then Node-C. The three realizations stayed on their own nodes
throughout.

```text
                    WFC group owner (one of A/B/C)
                         manager
            ┌──────────────┼──────────────┐
         fence A        fence B        fence C
       domain-1 proc  domain-2 proc  domain-3 proc
```

## Authority

Two separate things are established:

- **WFC determines who may establish management authority.** The manager
  passes WFC admission (`IsAuthoritative`: it is the stable owner). Each fence
  re-checks with its local WFC that the requester is the current owner of an
  Online group before it mints a new generation (Day 5.3's `ADVANCE`).
- **Each node's fence determines which authority generation may mutate that
  node's workload reality.** `START` and `STOP` carry the generation and run
  inside `AuthorityGrant.WithCurrent`, so a superseded generation is rejected
  at the mutation boundary, serially with `ADVANCE`.

Establishment across the three nodes is **not atomic**. There is no global
generation and no coordinator. The manager sends `ADVANCE` to each fence and
holds three independent generations. The rule chosen and tested here:

> A manager incarnation issues no `OBSERVE`, `START`, or `STOP` until every
> targeted fence has accepted its `ADVANCE`. Until then it retries every 2 s
> (up to 3 minutes) and logs `established=k/3; effects=withheld`.

The intermediate state is real and was observed (Experiment 4). While the new
manager holds generations on some fences but not others, a still-running
previous manager would remain current on the fences not yet advanced. Safety
does not need atomicity across nodes. It needs one current generation **per
node** at each mutation boundary, and each fence provides that on its own. What
the rule adds is that the new manager acts only once it controls every domain
it may need to mutate.

Generation answers "may this authority incarnation mutate?" The
`STOP <gen> <pid> <startTicks> <runId>` request also keeps Day 4's incarnation
check (`Workload.Stop` verifies PID and start ticks): "is this still the exact
process we decided on?" The two checks stay separate.

Each manager invocation is one authority incarnation. It advances, rediscovers,
reconciles to convergence (two consecutive all-Running passes), and exits. The
next invocation starts cold. That makes every experiment a fresh
rediscovery (Day 2).

## Live run

One complete run, `.state\day-05.4-ff26ea1be59f498a94a9f2150e270167`, workload
`2c3c8d31-d8f3-46aa-b61b-00335adacea9`, cluster `wfcluster`. All five
experiments ran in sequence against the same three long-lived fences.

| Exp | Owner | Generations (d1,d2,d3) | Starts | Stops |
|---|---|---|---|---|
| 1 | Node-A | 1,1,1 | 3 | 0 |
| 2 | Node-B (moved) | 2,2,2 | 0 | 0 |
| 3 | Node-B | 3,3,3 | 1 | 0 |
| 4 | Node-C (failover) | 4,4,4 | 0 | 0 |
| 5 | Node-C | 5,5,5 | 1 | 0 |

## Experiment 1

Initial convergence: empty platform, Node-A owner, Replicas=3.

The manager advanced all three fences to generation 1, observed no
realizations, and issued one `START` per pass to the first missing domain.
Each domain then waited through Starting until Running. It converged after
three starts:

```text
domain-1 = Node-A pid=1560 startTicks=639302029728296276 runId=d25167a9-8ee2-4d13-b09f-bdb5596c50e7
domain-2 = Node-B pid=4048 startTicks=639302029732528466 runId=e9395ce5-9e3d-496a-b81b-da655cd89e80
domain-3 = Node-C pid=228  startTicks=639302029736548260 runId=cf5b84fe-c9d3-4b2a-8ba8-c38cba196dc4
```

These are three distinct machines, PIDs, start ticks, and RunIds. Each node's
own process listing showed exactly one realization.

## Experiment 2

Management authority moved; no workload churn.

WFC moved the group from Node-A to Node-B (`Move-ClusterGroup`). A cold
manager on Node-B advanced every fence to generation 2. It rediscovered the
three realizations from the fences and converged:

```text
starts=0 stops=0
domain-1 = Node-A pid=1560 startTicks=639302029728296276 runId=d25167a9-...
domain-2 = Node-B pid=4048 startTicks=639302029732528466 runId=e9395ce5-...
domain-3 = Node-C pid=228  startTicks=639302029736548260 runId=cf5b84fe-...
```

All three identities are byte-identical to Experiment 1. The harness asserts
equality of PID, start ticks, and RunId per domain.

This is the central result. Management moved between machines, and the
workload did not notice. Nothing about management placement is encoded in the
workload. Nothing about workload placement is encoded in management state.

## Experiment 3

Single-domain loss and isolated replacement. Owner is Node-B.

The realization on Node-C (PID 228) was killed with `Stop-Process`. Neither the
manager nor the fence took part. A Node-B manager advanced to generation 3 and
observed only domain-1 and domain-2. It decided `Start domain-3` and received
`STARTED domain=domain-3; pid=4524`:

```text
starts=1 stops=0
domain-1 = Node-A pid=1560 (unchanged)
domain-2 = Node-B pid=4048 (unchanged)
domain-3 = Node-C pid=4524 startTicks=639302029923988924 runId=891bdd98-...   (replaced)
```

Healthy peers kept identical identities. Only the lost domain was repaired,
and it was repaired on its own node.

## Experiment 4

Uncooperative management failover while workloads keep running.

Preferred owners were set to Node-B,Node-C. Node-B's `ClusSvc` process was
killed (`Stop-Process -Force`). No Offline, relinquish, or cleanup ran. WFC
reported the group Online on Node-C about 2 s later, with Node-B Down.

A cold Node-C manager then logged:

```text
Advance domain-1: round=1; reply=GENERATION 4
Advance domain-2: round=1; reply=ERROR Win32Exception: Cannot open cluster 'wfcluster'.
Advance domain-3: round=1; reply=GENERATION 4
Authority establishment: round=1; established=2/3; effects=withheld
... rounds 2-6: domain-2 ERROR Cannot open cluster
... round 7:   domain-2 ERROR Cannot open authority group
Advance domain-2: round=8; reply=GENERATION 4
Authority establishment: round=8; established=3/3; effects=permitted
starts=0 stops=0  (all three identities unchanged from Experiment 3)
```

Two things happened.

- **The workload survived management loss.** Node-B's realization (PID 4048)
  kept running through the death of its own node's cluster service. All three
  realizations were adopted with zero effects.
- **Non-atomic establishment was visible.** Node-B's fence verifies ownership
  through its local cluster service, which was down. For about 14 s the new
  manager held generation 4 on domain-1 and domain-3 and nothing on domain-2,
  and it withheld every effect. When Node-B's ClusSvc came back, the fence
  verified the new owner and minted generation 4. No cleanup action from the
  old authority was needed.

This is a real limit of the chosen fence design. A domain fence can advance
only when its own node can confirm WFC ownership. A node that cannot reach the
cluster cannot be advanced, so the new manager cannot act anywhere until that
node recovers. The design chose safety (no effects) over availability on the
healthy domains. Whether it should instead act on the advanced subset is a
policy question this experiment did not need to answer.

## Experiment 5

Repair by the new manager after failover. Owner is Node-C.

The Node-A realization (PID 1560) was killed. A Node-C manager advanced to
generation 5 everywhere and started only domain-1:

```text
starts=1 stops=0
domain-1 = Node-A pid=5444 startTicks=639302030217476734 runId=197dc7f7-...   (replaced)
domain-2 = Node-B pid=4048 (unchanged since Experiment 1)
domain-3 = Node-C pid=4524 (unchanged since Experiment 3)
```

The manager repaired a domain on a different machine from where it runs,
under a management owner that was reached through uncooperative failover.
Final per-node generations: Node-A 5, Node-B 5, Node-C 5.

## State

PlatformState was not changed. The one intent document was created once by
`intent <file> --replicas 3` and copied identically to every node as a
stand-in for shared intent storage. It contains only:

```text
WorkloadId, Desired=Running, Replicas=3   (existing Day 4 contract)
```

Not persisted in PlatformState or anywhere else by the manager:

- domain-to-node placement (manager command line)
- current WFC owner (asked of WFC)
- authority generation (each fence's own file, owned by the authority mechanism)
- PID, start ticks, RunId, health (rediscovered from fences each pass)
- start-pending, failover, or repair workflow

Each manager reconstructed `domain -> node -> state + incarnation` purely from
the three fences.

## Reconciliation

Day 4's victim ordering (surplus, then collision non-keeper, then Degraded)
was extracted unchanged into `DomainReconciliation.SelectVictim` and is now
shared by the local Day 4 manager and the Day 5.4 projection. Day 4's local
suite still passes. Added for the projection:

- A realization whose recorded domain differs from the node it runs on fails
  explicitly (`Domain placement violation`) with no effect. This is Day 4's
  invalid-domain rule applied to placement.
- Missing domain: `START` to that domain's fence. Starting: wait. Converged
  after two consecutive all-Running passes.
- A `REJECTED` effect means this incarnation has been superseded on that
  domain. The manager stops managing rather than retrying.

The live experiments exercised Start, wait, adopt, and replace. `STOP`
(Degraded, surplus, or collision) is wired to the fence with Day 4's
incarnation check, but no live experiment produced a victim. Its behavior is
covered only by the shared selection logic and Day 4's local tests. The
optional Degraded and collision demonstrations were skipped. Readiness events
are per-session (`Local\`), so remote Degraded injection was not nearly free.

## Findings

### PROVEN (for this lab)

- A singleton Active/Passive management authority, placed by WFC, reconciled an
  Active/Active workload with one realization on each of three separate Windows
  execution domains (Node-A, Node-B, Node-C).
- Management authority moved, both cooperatively and through uncooperative
  ClusSvc loss, with zero Starts, zero Stops, and identical PID, start ticks,
  and RunId on every realization.
- The loss of one realization was repaired on its own node, from fresh
  rediscovery, without touching healthy peers. This held before and after
  failover.
- Per-node fences composed. Each domain had exactly one current generation, and
  the new owner established its generation on every node without any action
  from the previous owner.
- Workload intent stayed exactly the Day 4 contract. Placement, ownership,
  generation, and observation lived elsewhere or were rediscovered.

### NOT PROVEN

- Independent failure domains. The three VMs share one physical Hyper-V host,
  so they are separate Windows execution domains, not independent hosts.
- Behavior under network partition, quorum loss, or full node power loss. Only
  a ClusSvc process kill was injected.
- Live STOP paths (Degraded, surplus, collision) on the cluster.
- Availability of the fence itself. If a fence is unreachable or cannot see its
  cluster, that domain blocks establishment. Experiment 4 showed this but did
  not solve it.
- Any atomicity of authority across nodes. None exists, and none was needed for
  per-domain safety.

## Relationship to Days 1–4

- **Day 1:** wait for observed convergence. The manager declares success only
  after two consecutive all-Running observations, never after issuing Start.
- **Day 2:** rediscover operational reality. Every manager incarnation starts
  cold and rebuilds `domain -> incarnation` from the nodes.
- **Day 3:** fence effects across authority generations. The same
  `AuthorityGrant` is used, now with one per execution node.
- **Day 4:** reconcile distribution and health per domain. The same victim
  ordering is used, now literally shared code, with domains bound to machines.
- **Day 5:** project authority and domains onto real clustered machines. WFC
  supplies who may advance; fences supply which generation may mutate; the
  nodes supply reality.

Nothing new was invented for Day 5.4 beyond letting three Day 5.3 fences
observe, start, and stop locally, and letting one manager address them.

## Limitations

These bound the claim; they do not invalidate it.

- All VMs share one physical Hyper-V host.
- Lab networking is controlled (one subnet, firewall opened per run).
- SSH is experimental transport. The fence uses a plain TCP line protocol.
- Fence availability is not productionized: no restart, supervision, or auth.
- No partition or quorum analysis.
- No load balancing or DNS publication.
- No shared storage. Intent is an identical copied file.
- No production workload. The realization is the experiment's own process.
- No generalized scheduler. Placement is a fixed one-domain-per-node map.
- No automatic manager service packaging. Each manager incarnation is launched
  by the harness on the current owner.

## Next question

Has the original architectural thesis now been demonstrated strongly enough to
stop the implementation arc?

**Yes, for the bounded claim.** The thesis was that intent, management
authority, authority generation, and observation are separate concerns. Under
that separation, a movable singleton manager can safely drive a distributed
workload. Days 1–4 built the pieces locally. Day 5 projected them onto WFC and
three real nodes. Day 5.4 exercised the full composition: converge, move,
repair, uncooperative failover, and repair again, with no workload churn caused
by management movement.

The next work should be reflection, not mechanism:

- `docs\day-05.md`: the Day 5 reflection.
- The overall experiment conclusion and README framing.
