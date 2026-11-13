# Day 5.3

## Question

Day 5.2 ended by asking how to order WFC authority movement against the
workload effect boundary. Before building anything, the question was
corrected:

> What is the smallest fencing mechanism that remains valid across both
> cooperative authority movement and uncooperative authority loss?

## Correction: the cooperative move path is not a safety foundation

Ordering `Process.Start` against WFC's cooperative ownership-move path is
insufficient as the fundamental safety mechanism because failover may follow
uncooperative authority loss.

A graceful move gives the old owner an Offline transition. A crashed manager,
a killed cluster service, or a dead node gives it nothing. Any design shaped
like this:

```text
old owner receives Offline -> releases lock/token -> new owner proceeds
```

fails in two ways when the old owner disappears. The new owner may wait for a
release that never comes. Or the old owner may later resume with local state
from its former ownership and act on it.

So two concepts that Day 5.2 left together must be separated:

- **WFC establishes where management authority resides.**
- **The fence establishes which authority incarnation may still mutate
  workload reality.**

Day 5.2 already showed that the first does not imply the second.

## Lifecycle finding (Offline/Online demoted)

The experiment group is resource-free (Day 5.1). It has no resources, so WFC
issues no resource Offline/Online callbacks during a move. Getting such a hook
would mean adding a Generic Script/Application resource, which is cluster
deployment machinery.

That hook was not built. A graceful Offline could later be a useful
*optimization*: the old owner could stop issuing effects promptly. It is not
needed for correctness. Case C below has the old owner's cluster service
killed, so no Offline could possibly run there, and safety held without it.

## Mechanism

```text
WFC ownership           -> who may advance the authority generation
authority generation    -> which incarnation may perform an effect
fence (one serial loop) -> orders "advance" against "effect"
```

`ClusterFenceExperiment` (about 130 lines) has two halves.

**Domain fence** (`fence-domain`) runs on the execution domain, Node-C. The
workload process is node-local, so its mutation boundary is on that node. The
fence is one TCP listener that serves one request at a time:

| Request | Behavior |
| --- | --- |
| `ADVANCE <node>` | The fence queries WFC locally. It accepts only if `<node>` is the current owner and the group is Online. It then mints `current + 1` with Day 3's `AuthorityGrant.Advance()`. |
| `OBSERVE <id>` | Fresh `Workload.Discover`. |
| `START <gen> <id>` | `AuthorityGrant(gen).WithCurrent("process creation", Workload.Start)`. Rejected unless `gen` is current. |

Because the loop is serial, an `ADVANCE` and a `START` can never interleave.
One of them wins first. This is the Day 3 rule (authority advancement and the
irreversible effect share one ordering point), now placed where the effect
actually happens.

**Fenced manager** (`experiment-fenced-start`) runs on whichever node WFC
names as owner:

1. Admission: the local node must be the WFC owner.
2. Send `ADVANCE`. This establishes a new incarnation (generation N+1).
3. Send `OBSERVE`. If the workload is absent (`Stopped`), decide Start.
4. Send `START <N+1>`.

After admission the manager makes no further WFC queries; the generation is
its only credential.

**Where the generation lives.** The generation is a file in the domain's
experiment directory, owned by the authority mechanism. It is not
`PlatformState`, which still holds only `WorkloadId` and `Desired`. The
experiment keeps these four things separate:

```text
workload intent (PlatformState) != management authority (WFC owner)
!= authority generation (domain fence file) != workload observation (Discover)
```

No workflow state is persisted: nothing like "Start pending", "owner failed",
or "retry required". A new owner recovers from WFC ownership, the current
generation, durable intent, and fresh discovery.

**Why a stale mint is harmless.** WFC is checked only when a generation is
minted. If ownership moves just after the check, the stale node mints
generation N. Any later owner's `ADVANCE` is serialized after it and mints
N+1, which immediately makes N stale at the boundary. Ownership checking
admits *who may advance*. Ordering is provided by the fence, not by the
check.

## Experiment

`tests\day-05.3.ps1` drives the Node-A/B/C lab through the external manifest
and pinned SSH/SCP. `tests\day-05.3-node.ps1` is the staged guest script. They
reuse the Day 5.2 staging pattern and witness-file pauses (no sleeps decide
ordering).

The test opens a temporary firewall rule for TCP 47053, limited to the local
subnet, on Node-C. Cleanup removes it, along with the group, processes and
staging. Each case uses a fresh workload ID and generation file. Each manager
is a cold process with no carried state.

Final run: `a4ce53ecf43440f883e3ed53d8481623` (November 13, 2026, UTC).

### Case B: authority advances first, stale effect rejected

| Time | Evidence |
| --- | --- |
| 20:41:55.050 | A: owner; fence mints generation 1. |
| 20:41:55.370 | A observes `Stopped`; decides Start; **paused** at `decision`. |
| 20:42:00 | WFC moves the group to Node-B. |
| 20:42:02.359 | Cold B manager: ownership check passes; fence advances 1 -> 2. |
| 20:42:02.445 | B `START 2` -> PID 1076. |
| 20:42:03.917 | A released: `START 1` -> `REJECTED ... offeredEpoch=1; currentEpoch=2`. |

There was one workload process. The Day 5.2 stale Start no longer happens.

### Case A: old effect wins first, then authority advances

| Time | Evidence |
| --- | --- |
| 20:42:15.307 | A: owner; generation 1. |
| 20:42:15.427 | Fence accepts A's `START 1`; paused **inside** the protected boundary. |
| 20:42:21 | WFC moves the group to Node-B (**move complete**). |
| 20:42:22.553 | Cold B manager admitted as owner; sends `ADVANCE`. |
| +3 s | Independent check: B has no reply; generation still 1; no child. |
| 20:42:32.431 | Inside released: A's Start completes, PID 4632. |
| 20:42:32.432 | Only now does the fence receive B's `ADVANCE`; it mints 2. |
| 20:42:32.484 | B observes `Starting` (PID 4632's incarnation) -> `Result=Converged`, no Start. |

There was one workload process and the final generation was 2.

WFC ownership had already moved while the generation-1 effect was in flight.
The effect was still legitimate, because the generation had not yet advanced.
**The decisive authority-transfer boundary is the generation advance at the
fence, not WFC move completion.**

### Case C: old authority disappears without cooperative release

Owners were restricted to Node-B and Node-C, so failover could not land on
Node-A, which hosts the core cluster group.

| Time | Evidence |
| --- | --- |
| 20:42:48.661 | B: owner; generation 1. |
| 20:42:48.760 | B observes `Stopped`; decides Start; paused (a "zombie" manager holding generation 1). |
| 20:42:54 | `ClusSvc` on Node-B killed (PID 3720). No Offline, relinquish, or cleanup was issued. |
| 20:42:56 | WFC fails the group over: owner Node-C, Online; Node-B `Down`. |
| 20:42:58.066 | Cold C manager: ownership check passes; fence advances 1 -> 2. **Nothing from generation 1 was needed.** |
| 20:42:58.110 | C `START 2` -> PID 4792. |
| 20:43:00.374 | Zombie B released: `START 1` -> `REJECTED ... offeredEpoch=1; currentEpoch=2`. |

There was one workload process. The new owner proceeded without the old owner
releasing anything. The old owner kept its local generation and its execution
capability, yet regained no permission.

Afterwards, cleanup restarted `ClusSvc` where needed (its recovery policy had
already restarted it after 15 s) and waited for all nodes to be `Up`. The core
cluster group stayed Online on Node-A. Unrelated groups and resources matched
the baseline. Experiment groups, firewall rules, processes and staging were
removed.

## A run that failed honestly

An earlier run (`988e558c…`) passed Case B. In Case A the fence ordered
correctly, but the manager then created a duplicate. B observed `Starting`:
A's child existed but was not yet ready. The manager treated anything other
than `Running` as absent, issued `START 2`, and gen 2 was legitimately
current, so the fence accepted it.

The fix was in the manager, not the fence: Start only on true absence
(`Stopped`). This is the Day 4 discovery semantics: `Starting` is an existing
realization.

**Fencing protects authority incarnations. It does not make a current
authority's decision correct.** Both are required.

A later run (`8ac75d37…`) failed only on a case-sensitive log assertion
(`NODE-B` vs `Node-B`). Its fence log showed the correct order.

## Finding

The three required orderings hold with one serial fence at the effect
boundary plus a WFC ownership check at generation mint:

1. **Effect first:** generation-1 Start completed, then generation 2 was
   minted. The new owner adopted the result.
2. **Advance first:** generation 2 was minted, then the generation-1 Start was
   rejected.
3. **Uncooperative loss:** the old owner's cluster service was killed, WFC
   failed over, and the new owner established generation 2 and proceeded. No
   cleanup from generation 1 was required, and the zombie was rejected.

WFC did not replace the authority-generation concept discovered in Day 3. It
supplied the concrete HA mechanism that determines who is entitled to advance
that generation.

## Relationship to Day 3

Day 3 found that authority placement and effect permission are distinct, and
that advancement and the effect boundary require a common ordering point.

Day 5.3 projects that onto a real HA substrate and the abstraction survives
unchanged. `AuthorityGrant` is reused as-is. What changed is:

- the source of the right to advance: WFC ownership instead of a declared
  epoch;
- the location of the ordering point: the execution domain, where the
  process effect occurs.

The change is a refinement, not a new mechanism.

## Complexity assessment

The mechanism added:

- one serial request loop;
- one generation file per domain;
- one ownership check at mint;
- a manager that sends three requests.

It did not need:

- leases or timeouts;
- a lock the old owner must release;
- a generalized fencing service;
- cluster resources or callbacks;
- shared storage;
- persisted workflow;
- changes to `PlatformState`.

The test harness is larger than the mechanism. That is expected for live
failure injection, and none of it is product machinery.

## Not established

- Fence availability: the domain fence is a single point. If Node-C is lost,
  the workload on it is lost too, so this is consistent with node-local
  effects, but it is not demonstrated.
- Multiple execution domains (one fence per domain).
- Automatic clustered manager deployment, quorum or partition behavior,
  full node-crash suites.
- Graceful Offline integration as an optimization.
- Cross-node active-active workload placement.

## Next question

With one fence per execution domain (Node-A, Node-B, Node-C), how does a
WFC-elected manager advance authority across several domains? Is a per-domain
generation sufficient, or does placement need its own ordering? This is not
implemented here.
