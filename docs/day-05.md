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
[5.4](day-05.4.md), [5.5](day-05.5.md) and [5.6](day-05.6.md). This
document explains why each step followed from the one before it.

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
        |  ...but, as a later review found, the harness rather than
        |  WFC still owned management lifetime and intent durability
        v
5.6  WFC hosts the manager as a cluster resource and carries
     current intent in its registry checkpoint
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

### 5.6: WFC owns management lifetime and carries intent

At the end of 5.5, this reflection declared Day 5 closed. A later review
found that the stop was premature in one respect. WFC owned management
*placement*, but the harness still owned management *lifetime*: it launched
and restarted the manager. An SMB share outside the cluster held the
PlatformStore. The claim that WFC provided management availability was only
partly exercised, so Day 5 was reopened.

[Day 5.6](day-05.6.md) (`98bdc72`) closed that gap without adding an HA
mechanism:

- The manager became a WFC Generic Application resource in the clustered role
  "VPS Management". WFC started it, terminated it on Offline, restarted it
  locally after a first failure, and failed it over after a repeated failure.
- Site intent (SiteId, Name, RootPath, Desired, DesiredReplicas, and no
  operational state) became a registry checkpoint of that resource, and WFC
  restored it to each new owner.
- Six WFC-created manager incarnations caused zero starts and zero stops of
  healthy realizations across management-only events.

The key evidence was that the checkpoint carried *current* intent, not just
the initial intent. After `DesiredReplicas` changed from 3 to 2, management
moved to Node-A. The new incarnation read 2 from the checkpoint and left the
two remaining realizations alone.

#### The fence finding

Hosting management in WFC made non-cooperative manager termination routine:
WFC Offline terminates the process. That exposed one real defect. A manager
was killed while the fence was replying to it, the connection reset, and the
fence process died. Safety held (`effects=withheld`), but liveness on that
domain was lost.

The interpretation is narrow. Management incarnations are disposable; failure
of an authority client must not destroy the execution-domain authority
boundary. The fix made the fence survive the loss of its requester's
transport. It does not make fences highly available. That remains a
different question.

## Failures of the apparatus versus failures of the architecture

Day 5 produced many failed runs, and most were not architectural. Day 5.5's
failed runs were PowerShell serialization and remoting problems in the test
scripts. During final regressions, a pwsh compatibility warning landed ahead
of JSON output and broke parsing in Day 5.3. Repeated deliberate ClusSvc
kills led WFC to quarantine Node-B. Day 5.6's first two runs failed on
harness defects: an empty value serialized as `{}`, and a missing registry
parent key. The details are in the notebooks.

Three failures were architectural, and this reflection is built around them:

- the stale Start in 5.2;
- the `Starting`-as-absent duplicate in 5.3;
- the fence dying with its client in 5.6.

Part of the discipline is telling the two kinds apart, and not promoting a
broken harness to a finding.

## The final decomposition

| Fact | Who owns the truth |
|---|---|
| Site identity, name, RootPath | Durable intent |
| Desired state (Running / Stopped / Removed), desired replica count | Durable intent |
| Durability and movement of that intent | WFC registry checkpoint of the management resource |
| Where management runs | WFC role ownership |
| Management process lifetime, restart, failover | WFC resource lifecycle (process liveness only) |
| Which management incarnation may mutate | Authority generation, held by each fence |
| Ordering of advance vs. irreversible effect | Execution-domain fence |
| Which execution domains are eligible | Configured topology |
| Current occupancy, Running nodes | Fresh observation |
| PID, native start time, RunId | The live incarnation, observed |
| Starting / Running / Degraded | Observation of readiness plus the per-incarnation Started witness |
| Which effect to take next | Reconciliation: one effect per pass from intent vs. observation |
| Whether a Stop hits the intended process | Incarnation verification at the fence |
| Host → site routing | The live realization's http.sys registration |
| DNS publication, content availability at RootPath | External (not built) |

The rule from [Day 2](day-02.md) held all the way through:

> Persist what the management plane knows because it owns it. Rediscover what
> it knows only because it observed it.

Several distinctions in this table are easy to collapse, and each was needed:

```text
configured topology       != observed occupancy
durable intent            != observed reality
WFC resource lifecycle    != mutation authority
management placement      != workload placement
generation                != workload lifetime
fencing                   != reconciliation correctness
management movement       != workload movement
```

### Topology

The eligible execution domains are configured topology: entries of the form
`name=host:port`. `DesiredReplicas=N` must satisfy
`1 <= N <= configured count`, and it means the first N configured domains.
This is deterministic placement over a configured set. It is not a
scheduler, and it is not derived from WFC membership (`Get-ClusterNode`).
The live evidence covers three domains. Topology tests cover sizes 1, 3 and
5 without a lab. The code does not encode three as a replica limit.

## Generation is not a lease on the workload

Days 5.4 to 5.6 repeatedly reported 0 starts and 0 stops after management
moved, even though each move advanced the generation. That can look
contradictory. If generation 8 supersedes generation 7, why does a
realization started under generation 7 keep running?

A generation is permission to perform a mutation. It is not a lease on the
reality that mutation created:

```text
gen 7 manager:  Start realization R           (accepted: gen 7 is current)
management moves; fences advance to gen 8
gen 8 manager:  observes R, Running, matches intent
                -> Converged; no effect
gen 7 manager:  any later Start/Stop           (rejected: gen 7 is stale)
```

> Advancing management authority invalidates stale mutations, not healthy
> reality created by an earlier valid authority.

The new authority adopts R by observation, not by re-issuing it. That
choice is not the only reasonable one.

## Alternatives considered

The invariant is:

> Authority must be enforced at the last boundary before a stale effect can
> become unsafe.

Where that boundary sits depends on what the realization knows.

**Chosen: opaque realization, fenced mutation.** The realization is an
ordinary native process that knows nothing about generations. Authority is
enforced in front of the effect:

```text
manager generation -> execution-domain fence -> Start/Stop
```

The advantages are that the workload needs no changes, and enforcement is
explicit and happens before the effect. The costs are one fence per execution
domain, no management effects while every fence cannot be established
(Day 5.4's 14 seconds), and a fence whose lifecycle matters (Day 5.6's
finding).

**Alternative: generation-aware realization adoption.** The realization, or
its local agent, accepts generations directly:

```text
gen 7 manager:  Ensure/Start(P, gen=7)
management moves
gen 8 manager:  Ensure(P, gen=8)  -> idempotently adopts the existing realization
gen 7 manager:  Ensure(P, gen=7)  -> rejected (monotonic generation acceptance)
```

That moves enforcement into the realization boundary. It needs:

- stable realization identity;
- canonical equivalence of parameters, so that "the same P" is decidable;
- idempotent Ensure;
- monotonic generation acceptance;
- defined semantics for a realization that existed before it was adopted.

Neither design is universally superior. This experiment chose opaque
mutation because its workloads were deliberately unaware of the control
plane. The lesson is the enforcement boundary, not the existence of a
separate fence process.

## What Day 5 established

Bounded to what was actually exercised:

> A movable Active/Passive management authority, hosted by Windows Failover
> Clustering and protected by per-execution-domain fencing generations,
> safely reconciled administrator-authored durable intent into Active/Active
> HTTP realizations across three Windows execution domains.
>
> WFC owned management placement, process lifetime and recovery, and carried
> current intent with the role. Management moves, restarts and failures did
> not cause healthy realizations to churn.
>
> Desired-replica changes, Suspend/Resume, selective repair and Remove
> converged from durable intent plus freshly observed reality.

## Lessons

1. Actions initiate transitions; observations establish convergence.
2. Persist intent; rediscover operational reality through stable logical and
   incarnation identity.
3. Make ambiguity explicit before inventing policy.
4. A decision valid when made is not permanent permission to perform its
   effect.
5. Management placement, mutation authority and effect fencing are different
   concerns.
6. Fencing protects authority; it does not make reconciliation decisions
   correct.
7. Reconciliation chooses the next justified effect from fresh observation,
   instead of persisting repair workflows.
8. Active/Passive management can reconcile Active/Active workload reality;
   management movement does not require workload movement.
9. Durable intent may need to outlive the resources whose absence it
   commands.

A corollary of 4 and 5, seen in 5.4: when safe mutation authority cannot be
established, reduced management availability is preferable to weakened
safety.

## Limitations and different questions

These bound the claim. They are not a backlog:

- **Manager health is process liveness.** WFC restarts or fails over the
  manager when its process exits. A hung manager would look healthy.
- **Intent is accessed through the owner.** Reads and writes go through the
  current owner while the role is Online. There is a single writer and no
  remote API.
- **Fences are experiment scaffolding.** They survive client loss, but they
  are not clustered, supervised, or highly available.
- **The domains share hardware.** Three VMs on one Hyper-V host are separate
  Windows execution domains, not independent physical failure domains.
- **Stronger failure models are different experiments:** network partitions,
  quorum loss, and complete semantics for "unreachable" versus "absent".

Also deliberately not built: DNS or a DNS publisher, load balancing, TLS,
content deployment, storage HA, a general scheduler, dynamic membership,
multi-workload orchestration, Linux, rolling upgrades, a general management
API, UI and packaging. An external discovery system, for example, could
consume the freshly observed set of Running nodes for a site. That would be
a downstream consumer of the boundary demonstrated here, not part of it.

## Why Day 5 stops here

The question was never "what features should this orchestrator have?" It
was whether a singleton, movable management authority is sufficient for
Active/Active workloads, and which mechanisms that claim actually requires.

Every mechanism in the system can be traced to a failure that earned it:

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
| WFC-hosted management lifetime, checkpointed intent | Day 5.6: the harness, not the substrate, owned management availability |
| Fence survives loss of its requester | Day 5.6: WFC Offline killed a manager mid-reply and the fence process died |

This reflection first ended after Day 5.5 with "Day 5 is closed. There is no
Day 5.6." That stop was premature. Day 5.6 was a review finding, not new
scope: the claim already said WFC provided management availability, and
the apparatus had not let WFC do it. Keeping that history visible is part of
the record.

The experiment now connects administrator-authored durable intent to useful
Active/Active service, through a management plane that participates in the
HA lifecycle of Windows Failover Clustering:

- WFC owns management placement, process lifetime and recovery, and carries
  current intent with the role.
- Authority generations and execution-domain fences prevent stale management
  effects.
- Fresh observation and reconciliation let healthy realizations outlive the
  management incarnations that created them.

The remaining questions are about stronger failure models, availability of
the supporting mechanisms, discovery and routing, storage, or
productization. They are different experiments, not missing proof for this
claim.

The method's last rule applies: stop when the evidence is sufficient for
the bounded claim. Day 5 is closed.
