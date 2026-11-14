# Day 5

Day 4 ended at a boundary I had not crossed. Its execution domains were
logical labels on one Windows machine, and its authority epochs were
advanced by hand. The reconciliation model worked, but every substrate
underneath it was a local stand-in.

Day 5 asked:

> What happens when the abstract authority and reconciliation model developed
> in Days 1–4 is projected onto a real high-availability substrate?

The substrate was Windows Failover Clustering (WFC) on three Windows Server
VMs, Node-A/B/C. They share one physical Hyper-V host. Throughout this
document they are separate Windows execution domains, not independent
physical failure domains.

This reflection is not another test log. The detailed evidence, run IDs,
PIDs and failed runs live in the individual notebooks:
[5.1](day-05.1.md), [5.2](day-05.2.md), [5.3](day-05.3.md),
[5.4](day-05.4.md) and [5.5](day-05.5.md). This document explains why each
step followed from the one before it.

## What I brought into the day

My strongest prior from the original system was that an existing HA
framework should decide where a single management authority runs. I did not
believe the control plane needed to become Active/Active itself in order to
manage Active/Active workloads.

That prior is the repository's thesis:

> Active/Active workloads do not require an Active/Active control plane.

Days 1–4 had earned pieces of it locally. Day 5 had to find out whether a
real HA substrate would supply the missing piece or quietly break the model.

## The progression

Each step below was earned by the failure, or missing proof, of the step
before it.

```text
5.1  WFC gave placement
        |  ...but placement was not fencing
        v
5.2  closer ownership checks narrowed the race
        |  ...but did not remove it
        v
5.3  generation fencing separated ownership from mutation authority
        |  ...but only for one execution domain
        v
5.4  per-domain fences composed the model across Active/Active execution
        |  ...but the workload was still experiment-shaped
        v
5.5  declarative VPS intent realized and maintained a useful,
     administrator-authored service
```

### 5.1: WFC gives placement

[Day 5.1](day-05.1.md) (`b17803a`) replaced Day 3's hand-advanced epoch with
ownership of a resource-free, experiment-owned WFC group. As the group moved
A → B → C, exactly one manager was admitted at each step.

That is a real result: WFC can decide where singleton management authority
lives. The notebook was careful about what it did not prove. Effects were
disabled, so nothing showed that a former owner could no longer change
workload reality.

### 5.2: Ownership is not effect fencing

[Day 5.2](day-05.2.md) (`ea3c40b`) made the problem happen before solving
it, following the [framing rule](experiment-framing.md). A manager observed
itself as owner, decided Start, and paused. WFC moved ownership to Node-B.
When the old manager resumed, it started the workload anyway.

Rechecking ownership immediately before Start narrowed the race but did not
close it. The manager paused after a successful recheck, ownership moved, and
the stale Start still happened. A check is not ordered against the effect
that follows it.

This was Day 3.2 again, reproduced on a real substrate:

> A valid decision is not a lasting permission to act.

WFC answers "who owns management authority?" It does not revoke the
execution capability of a manager it has already admitted. That gap is not a
WFC defect; it is a different question.

### 5.3: Fence authority incarnations, not owners

[Day 5.3](day-05.3.md) (`064eb1e`) began with a correction made before any
code was written. The obvious design was to order the old owner's effects
against WFC's graceful move: Offline, release, then the new owner proceeds.
But failover can follow an uncooperative loss. A killed cluster service or a
dead node receives no Offline and releases nothing. Safety could not depend
on the old owner's cooperation.

That separated three concepts that 5.2 had left tangled together:

| Concept | Answers |
|---|---|
| WFC ownership | Which node may establish or advance management authority? |
| Authority generation | Which authority incarnation may still mutate workload reality? |
| Execution-domain fence | What orders generation advancement against irreversible effects? |

The fence is one serial loop on the node where the effect happens. It mints a
new generation only for the current WFC owner, and it runs Start under the
current generation. Because the loop is serial, `ADVANCE` and `START` cannot
interleave. Three live cases passed:

- **Advance first.** The newer generation advanced, and the stale Start was
  rejected.
- **Effect first.** The stale Start had already entered the boundary. The
  newer generation waited, the effect completed, and the new manager adopted
  the resulting workload instead of duplicating it.
- **Uncooperative loss.** ClusSvc was killed, WFC moved ownership, and the new
  manager advanced without any action from the old owner. The old manager's
  later request was rejected.

The important interpretation is that WFC ownership movement is not the
instant at which mutation authority moves. **Mutation authority moves when
the fence advances the generation.**

One failed run is worth keeping. The fence ordered everything correctly, but
the manager treated `Starting` as absent and created a duplicate under a
legitimately current generation. The fix was in reconciliation, not the
fence. Day 4 had already said `Starting` occupies its domain.

> Fencing protects authority incarnations. It does not make a current
> authority's decision correct.

### 5.4: Compose Active/Passive management with Active/Active workload

[Day 5.4](day-05.4.md) (`baf5325`) placed one fence on each node, mapping
domain-1/2/3 to Node-A/B/C. One movable manager had to establish its
generation on every fence before it could observe or act. Establishment is not
atomic across nodes and does not need to be. Each node's fence keeps one
current generation at its own mutation boundary. The added rule is that a
manager acts only once it controls every domain it may need to touch.

The live results were the thesis made concrete:

- First convergence: 3 starts, one realization per node.
- **Management moved A → B: 0 starts, 0 stops, all three incarnations
  unchanged. Management moved; the workload did not.**
- A Node-C realization was killed; only domain-3 was restarted.
- ClusSvc was killed on Node-B, and WFC moved authority to Node-C.
- After failover, a Node-A realization was killed; only domain-1 was repaired.

#### The availability finding

The failover case produced the most informative result of the day. Node-B's
fence asks its local cluster service who the owner is, and that service was
down. For about 14 seconds the new manager held its generation on only two
of three fences. It logged `established=2/3; effects=withheld` and did
nothing. When Node-B's ClusSvc came back, the fence confirmed the new owner
and the manager rediscovered all three workloads: 0 starts, 0 stops.

That delay is not inefficiency to be tuned away. It is the design stating
its priority:

```text
inability to establish safe mutation authority
    -> reduced management availability
not
    -> weakened fencing safety
```

During those 14 seconds the workloads kept serving; only management was
paused. This experimental fence is explicitly **not** a production
availability design. A real system would need fence supervision, bounded
waits, and a policy for a domain that never answers. Those questions were not
part of this experiment.

### 5.5: Intent becomes a useful service

At the end of 5.4 the reconciler was correct but the workload was still an
experiment-shaped child process. The remaining question was whether the same
mechanisms could drive something an administrator would actually declare.

[Day 5.5](day-05.5.md) (`f588023`) introduced declarative VPS site intent:

```text
SiteId           stable identity
Name             foobar.contoso.com
RootPath         \\server\path
Desired          Running | Stopped | Removed
DesiredReplicas  N
```

Nothing operational is in it: no PID, RunId, health, node occupancy, WFC
owner, generation or repair state. A realization is an HTTP service. On each
node, Windows' built-in HTTP listener (http.sys) on port 80 routes a request
carrying `Host: foobar.contoso.com` to that node's realization, which serves
RootPath. Requests for other hosts are not served. There is no DNS; each node
was addressed directly with an explicit Host header.

Seven live experiments composed everything above:

| Experiment | Result |
|---|---|
| Create intent, 3 replicas | 3 starts; Node-A/B/C all served the site |
| Move management | 0 starts, 0 stops; service and incarnations unchanged |
| `DesiredReplicas` 3 → 2 | Reconciliation stopped only Node-C; the administrator never named a node |
| Suspend / Resume | Suspend preserved intent at zero replicas; Resume rebuilt two from intent plus fresh observation |
| Uncooperative failover | 0 starts, 0 stops; useful service continued |
| Kill one replica | One fenced Start; the peer kept its exact incarnation |
| Remove | Converged to zero realizations, then deleted the intent |

Management movement and failure left the useful service untouched, not just
the processes. Suspend/Resume showed the Day 2 rule working end to end:
nothing about placement survived Suspend, and nothing needed to.

The demonstrator was exercised live with three Windows execution domains, but
the reconciliation implementation does not encode three as an architectural
replica limit. The eligible domain set is configured topology (not WFC
membership), and `DesiredReplicas` is bounded by its configured count.

#### The Remove finding

Remove was the last design problem, and it was earned the same way as the
others. The naive reading is "delete the site record." But then a restarted
or newly failed-over manager would find no intent, and nothing would say that
the running replicas must go. The declaration that commands absence would
have vanished before the absence existed.

The smallest correct lifecycle was:

```text
Desired = Removed      durable, terminal intent; further admin changes refused
    -> reconcile reality to absence under established fences
    -> observe zero realizations twice
    -> delete the intent only if it is unchanged
```

**The durable declaration always outlives the operational reality whose
absence it commands.** This is not a general lifecycle framework. It is one
terminal value of `Desired` plus a conditional delete, and that was all the
problem required.

## Failures of the apparatus versus failures of the architecture

Day 5 produced many failed runs. Most were not architectural. Day 5.5's
failed runs were PowerShell serialization and remoting problems in the test
scripts. During final regressions, a pwsh compatibility warning landed ahead
of JSON output and broke parsing in Day 5.3. Repeated deliberate ClusSvc
kills also led WFC to quarantine Node-B. After the earlier kills aged out,
Day 5.3 passed again, including the stale-manager rejection.

Two failures were architectural, and they are the ones this reflection is
built around: the stale Start in 5.2, and the `Starting`-as-absent duplicate
in 5.3. Part of the discipline is telling the two kinds apart, and not
promoting a broken harness to a finding.

## The final decomposition

| Fact | Who owns the truth |
|---|---|
| Site identity, name | Durable intent |
| RootPath | Durable intent |
| Desired state (Running / Stopped / Removed) | Durable intent |
| Desired replica count | Durable intent |
| Which node may establish management authority | WFC ownership |
| Which management incarnation may mutate | Authority generation, held by each fence |
| Ordering of advance vs. irreversible effect | Execution-domain fence |
| Current node occupancy, Running nodes | Fresh observation |
| PID, native start time, RunId | The live incarnation, observed |
| Starting / Running / Degraded | Observation of readiness plus the per-incarnation Started witness |
| Which effect to take next | Reconciliation: one effect per pass from intent vs. observation |
| Whether a Stop hits the intended process | Incarnation verification at the fence |
| Host → site routing | The live realization's http.sys registration |
| DNS publication | External consumer (not built) |
| Content availability at RootPath | External dependency (not built) |

The rule from [Day 2](day-02.md) held all the way through:

> Persist what the management plane knows because it owns it. Rediscover what
> it knows only because it observed it.

## What Day 5 established

Bounded to what was actually exercised:

> A movable Active/Passive management authority, placed by Windows Failover
> Clustering and protected by per-execution-domain fencing generations,
> safely reconciled administrator-authored declarative intent into
> Active/Active HTTP service realizations across three Windows execution
> domains.
>
> Management ownership moved and failed without causing healthy service
> realizations to churn.
>
> Desired-replica changes, Suspend/Resume, selective repair and Remove
> converged from durable intent plus freshly observed reality.

It does **not** establish independent physical failure domains,
production-grade fencing or fence availability, partition tolerance beyond
the killed-ClusSvc cases tested, production HA, general scheduling, or a
VPS platform.

## What was deliberately not built

DNS integration or a DNS publisher, a load balancer, TLS and certificates,
content deployment, storage HA, SMB provisioning, filesystem replication, a
general scheduler, dynamic cluster membership, multi-workload orchestration,
Linux support, production fence supervision, network-partition or quorum
research beyond what was exercised, rolling upgrades, a general management
API, UI, and production packaging.

These are legitimate future experiments or product concerns. None of them is
missing proof for the thesis. An external DNS or discovery integration, for
example, could consume the freshly observed set of Running nodes for a site
and advertise them. That would be a downstream consumer of the boundary
demonstrated here, not part of it.

## Why this is where implementation stops

The question was never "what features should this orchestrator have?" It
was whether a singleton, movable management authority is sufficient for
Active/Active workloads, and which mechanisms that claim actually requires.

After Day 5.5 every mechanism in the system can be traced to a failure that
earned it:

| Mechanism | Earned by |
|---|---|
| Observation separate from action | Day 1: Start returned ≠ Running |
| Durable intent, rediscovered reality, exposed workload identity | Day 2.2: crash after Start created an unrecoverable orphan and a duplicate |
| Effect-boundary authority fence | Day 3.2: stale authority executed an earlier valid decision |
| One-effect reconciliation, incarnation-verified Stop, Started witness | Day 4: collisions, surplus, Starting vs. Degraded |
| WFC placement | Day 5.1: a real substrate for singleton placement |
| Generation fencing independent of owner cooperation | Day 5.2 stale Start under WFC; Day 5.3 uncooperative loss |
| Per-domain fences, establish-all-before-acting | Day 5.4: Active/Active across real nodes |
| `Removed` as terminal intent | Day 5.5: deleting intent first would lose the command to remove |

The last experiment composed those mechanisms into a useful,
administrator-facing service, and it did so without adding a new HA
mechanism. Nothing failed in a way that earned one. A next step would no
longer test the thesis. It would test a product: DNS, storage, scheduling,
fence availability. Those are different questions with their own
experiments.

Continuing would turn evidence into accumulation. Stopping here is part of
the result.

Day 5 is closed. There is no Day 5.6, and the experiment is concluded.
