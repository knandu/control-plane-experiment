# Day 5.2

## Question

When cluster ownership moves after an old manager decides but before its
effect, what prevents that former owner from executing the stale operation?

## Prior

Day 5.1 showed that Windows Failover Clustering (WFC) ownership of a
resource-free experiment group can supply movable singleton management
placement. It did not show that ownership automatically fences an
already-admitted manager's later effects.

## Experiment

`ClusterStartExperiment` (`experiment-cluster-start`) is a bounded, test-only
manager for one Running intent:

1. Observe WFC ownership of the experiment group (Day 5.1 `ClusterAuthority`);
   refuse if not owner.
2. Freshly discover the workload (existing `Workload.Discover`).
3. Missing -> decide Start.
4. Optional explicit pause (`decision`, or `recheck` after a second ownership
   query).
5. Existing `Workload.Start`; freshly observe Running; report current owner.

Pauses are explicit witness files: the manager writes `<stage>.reached` and
waits for the host to write `<stage>.release`. Ordering is chosen by
witnesses, not sleeps. `tests\day-05.2.ps1` drives the Node-A/B/C lab
through the external manifest and dedicated pinned SSH/SCP only. It stages a
temporary self-contained payload (with a private `dotnet` host so the
unchanged `Workload.Start` can launch), creates one resource-free group,
moves it with `Move-ClusterGroup`, and removes the group, staging, and
processes afterward. Nothing is installed on the guests.

## Result 1: former owner executes stale Start

Run `c0c850e48d5b4ec6894d5c2f50e52850` (November 13, 2026, UTC):

| Time | Evidence |
| --- | --- |
| 18:52:06.860 | Baseline: A admitted as owner; Start PID 5664; Running. No movement. |
| 18:52:12.690 | A admitted: local NODE-A, owner Node-A, authoritative. |
| 18:52:12.802 | A discovers Stopped. |
| 18:52:12.803 | A decides Start. |
| 18:52:12.804 | A paused at `decision`; independent inspection: no child. |
| 18:52:18 | `Move-ClusterGroup` completed; cluster snapshot: owner Node-B, Online. |
| 18:52:19.278 | Only then A released. |
| 18:52:19.290 | A Start: PID 4204, start ticks `639301927392826580`, run `4501aee9-f94b-40d6-a6ba-02d590375f26`. |
| 18:52:19.554 | A observes Running; observed owner **Node-B**. |
| 18:52:25.385 | Separate cold manager on B admitted as owner, discovers its own missing workload, starts it. |

```text
WFC owner = A
A admitted -> Missing -> decides Start -> PAUSED
WFC owner -> B (verified)
A resumes -> A starts the workload while owner = B
```

## Result 2: recheck before Start does not close the race

Run `0677398d6dee4633be5cef70c0bb3412` repeated Result 1 and added a case that
queries ownership again immediately before Start, then pauses:

| Time | Evidence |
| --- | --- |
| 18:57:04.171 | A admitted as owner. |
| 18:57:04.289 | A decides Start. |
| 18:57:04.291 | Recheck: local NODE-A, owner Node-A, authoritative=True. |
| 18:57:04.293 | A paused **after** the successful recheck. |
| | WFC moved to Node-B; snapshot verified. |
| 18:57:11.765 | A released. |
| 18:57:11.779 | A Start: PID 2460, run `6bc9e82d-c94a-49cc-91cf-97ba530976a6`. |
| 18:57:12.058 | Running; observed owner **Node-B**. |

The same run also reproduced Result 1 again (stale PID 5216).

The pause only widens the interval between check and effect that exists
without it. A recheck narrows the race but does not order the check against
movement.

Both runs: nodes stayed Up, the core cluster group stayed Online, unrelated
groups/resources were unchanged, and experiment groups, staging, and
processes were removed. Durable intent (`WorkloadId`, `Desired`) was
unchanged; `PlatformState` was not modified.

## Answer

Nothing inherent in the ownership observation the manager performs prevents
it.

- WFC provides movable singleton ownership.
- A former owner retains ordinary execution capability after ownership moves.
- Therefore, an effect authorized while the manager was owner can execute
  after it ceases to be owner.
- Rechecking ownership just before the effect narrows the race but does not
  close it, because ownership can move between the recheck and the effect.

## Relationship to Day 3

Day 3 experimentally derived the principle that an earlier valid decision is
not a permanent right to perform its effect.

Day 5.2 independently reproduces the same problem with Windows Failover
Clustering as the real authority-placement substrate. The abstraction
survives: concrete movable ownership answers *who may decide*, not *whether
an already-made decision may still take effect*.

## Not established

- The correct WFC-integrated fencing mechanism.
- Whether WFC Offline/Online transitions can participate in such a fence.
- That an ownership query plus `Process.Start` can ever be made sufficiently
  safe without additional ordering.
- Cross-node active-active workload placement.
- Automatic manager-process failover.

## Next question

Day 5.3: What is the smallest mechanism that orders WFC authority movement
against the workload effect boundary so that either:

- the old authority performs the effect before authority moves, or
- authority moves first and the old effect is rejected,

but never:

- authority moves and the old authority subsequently performs its stale
  effect?

WFC's Offline/Online transitions during a group move are a promising
hypothesis to investigate, not a predetermined solution. Day 5.3 should
determine whether those transitions expose a sufficiently strong ordering
point, or whether an additional application-level fencing generation/token
is still needed.
