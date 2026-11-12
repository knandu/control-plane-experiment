# Day 3

Day 2 ended by asking what the realization needed to expose so that management would not have to remember operational history.

Logical identity made a surviving realization rediscoverable. Durable intent no longer needed a saved locator or last observation.

Day 3 started with a different question:

> Can declared management authority move across manager processes without moving the workload?

I already expected management epochs and fencing to matter. That was experience from the earlier architecture, not a discovery this repository needed to pretend to make.

The useful question was how much of that experience this smaller experiment would actually require.

## Day 3.1: moving authority without moving the workload

In the recorded Day 3.1 run, managers 20560, 28312, and 30436 received epochs 1, 2, and 3.

All three converged on child 14420.

The child retained UTC process-start ticks `639300987343486756` and run ID `53dae204-f373-41f9-a9a3-49567dc24f60`. The Start counts were `1 / 0 / 0`.

The next manager needed the same durable intent, not its predecessor's locator or operation history. Fresh discovery recovered the relationship.

That worked during startup too. Child 31756 survived the epoch-1 manager's exit while still `Starting`. The epoch-2 manager adopted it, observed `Starting` and then `Running`, and converged. The Start counts were `1 / 0`.

Authority movement did not make the new manager merely a passive observer. After child 14420 was killed, manager 30436, still under epoch 3, observed `Stopped`, started replacement 10960, and converged again.

Four identities stayed separate:

```text
manager process identity
declared authority epoch
logical workload identity
workload incarnation identity
```

Changing the manager and declared authority did not require changing the logical workload or its surviving incarnation.

But there was an important limit.

The test sent `relinquish`, waited for the old manager to exit normally, and only then launched the next one.

That sequencing supplied exclusion. The epoch named the generation; it did not enforce the right to act.

Day 3.1, committed as `eff7397`, demonstrated continuity under a cooperative handoff. It did not demonstrate revocation.

## Day 3.2: make the stale effect happen

The framing rule mattered here:

> Make the problem appear before adding the solution.

I did not want to introduce fencing because the earlier architecture had it and then call a successful handoff evidence that it was necessary.

Day 3.2 kept manager A, PID 21080, alive under epoch 1.

A freshly observed `Stopped`, validly decided Start, and paused immediately before `Workload.Start`. There were still zero matching realizations.

The external test then declared epoch 2 and launched manager B, PID 23596.

B observed absence, started child 30880, observed `Starting` and then `Running`, and legitimately converged.

Only then did the test release A.

A did not rediscover reality or make a new decision. It continued its earlier decision and created ready child 27200.

There were now two independently verified ready realizations for the same logical workload.

Both managers subsequently exited `-532462766` with explicit two-realization ambiguity. B's earlier convergence was valid when reported, before the duplicate existed.

This was not Day 2.2 again.

Day 2.2 lost the recoverable relationship between intent and the surviving child. It created a second child and falsely converged because it could not correlate the first one.

Day 3.2 retained that relationship. Discovery correctly identified both children and refused to choose one.

But detecting the duplicate afterward did not prevent the stale side effect.

That distinction was the result of `a7665e7`, not an intermediate failure to hide:

> A decision can be valid when made and no longer be authorized when its effect is attempted.

The question had moved from whether authority could move to where authority needed to be enforced.

## Day 3.3: cover the check-to-effect interval

A manager-only recheck seemed like the smallest candidate.

But an unlocked check establishes authority only at the instant of the check. Preemption immediately afterward leaves the same problem, even if the check is moved into `Workload.Start` just before creation.

Raw Windows `Process.Start` accepts no application epoch to compare atomically.

Day 3.3 therefore made the external authority source participate in the ordering.

A separate scalar file records the current positive epoch. The foreground `grant` command advances it only to a strictly greater value.

Grant advancement and checked `Workload.Start` share a named local-session mutex, `Local\ControlPlaneExperiment-Authority-<sha256>`, derived from the authority-file path.

The creation boundary checks the offered epoch under that mutex and retains ownership through `Process.Start` and capture of the incarnation identity.

The two orderings mattered separately.

### The grant commits first

In the recorded run, A, PID 29616, passed its manager pre-check under epoch 1 and paused before the effect.

The source committed epoch 2. B, PID 28328, started child 33112 and converged.

Releasing A now produced `AuthorityRejectedException` at the `process creation` boundary: offered epoch 1, current epoch 2.

A exited nonzero with zero returned Starts. There was no second child to clean up.

B remained healthy on the same incarnation. Its fresh post-rejection observation still identified PID 33112, start ticks `639301057452627466`, and run ID `9653c132-06a0-44b7-92dc-aa837d2b43f2`.

When the test later killed that child, B, still under epoch 2, created replacement 10924 and converged.

The earlier manager check had been valid. It had not conferred a lasting right to create a process.

### Creation enters first

The second experiment paused A inside `Workload.Start`, after the boundary check but before `Process.Start`, while retaining the mutex.

The source requested epoch 2 and reported `Authority lock waiting`. Inspection still found epoch 1 in the file.

After release, A created child 30772. Its native process-start time was `18:42:36.8938928Z`; the newer grant committed afterward, at `18:42:36.9057461Z`.

Requesting authority had not made it current.

After A's cooperative exit, B under epoch 2 adopted that same child with zero additional Starts, observing `Starting` and then `Running`.

This was serialization, not Windows rejecting a stale creation call or cancellation of an already accepted operation.

The distinction made `c26c3a4` useful: an old attempt arriving after the grant is rejected, while an already accepted creation finishes before the grant can advance.

## What did not become workload state

Across the handoffs, stale rejection, and legitimate recovery, authoritative workload intent remained byte-for-byte unchanged:

```json
{
  "WorkloadId": "<logical workload id>",
  "Desired": "Running"
}
```

Authority ordering earned a durable representation in Day 3.3. It did not earn a field in workload intent.

The separate grant file belongs to the external source's protocol. In fenced mode, a manager cannot make its offered epoch current merely by presenting it; an ungranted future epoch is rejected too.

The child still carries no creator-epoch metadata. An incarnation accepted under the earlier authority can survive the handoff and become ready afterward.

I did not need a worker daemon, lease heartbeat, or a remembered Start history to demonstrate these results.

Intent, current authority, and freshly observed operational reality remained different kinds of truth.

## Keeping the evidence

This reflection does not replace the [Day 3.1](day-03.1.md), [Day 3.2](day-03.2.md), or [Day 3.3](day-03.3.md) notebooks.

The PIDs above belong to their recorded experiments, not one continuous run or the validation replay for this reflection.

The order in Git matters: clean movement in `eff7397`, the stale effect in `a7665e7`, and enforcement in `c26c3a4`.

`tests\all.ps1` preserves the original Day 1 behavior at `0ab3e5c`, the Day 2.1 cases and Day 2.2 failure at `ab24103`, and the Day 3.2 failure at `a7665e7`. It runs current Day 2.3, Day 3.1, and Day 3.3 alongside them.

A passing historical failure test means that the old failure was reproduced. It does not mean that the historical implementation was repaired.

I want the evidence for why the boundary was introduced to remain executable after introducing it.

## What Day 3 has not settled

The enforcement is cooperative, same-Windows-session ordering. Participants must use the same authority file and mutex protocol. Commands without the authority file retain the earlier unenforced mode.

This is not distributed consensus, hostile-caller isolation, or remote-node fencing.

A stalled creation inside the lock delays the next grant. That is a liveness cost of the tested safety boundary, not something a timeout has made disappear. Readiness is outside that lock.

Authority-source recovery after state loss, abandoned locks, and interrupted creation remain untested. The scalar file is not proof of a general durability or revocation contract.

Nor does a current epoch establish one manager per epoch. Two managers mistakenly given the same current epoch could both observe absence and decide Start. The mutex does not make discovery and creation one transaction.

Duplicate-realization arbitration and cleanup remain unresolved. Explicit ambiguity still does not select a winner.

There is no fenced Stop or removal operation. Test teardown is not such an operation.

Ongoing application health beyond initial readiness remains open. So does reconciliation for more than one desired replica (`replicas > 1`).

None of those questions is answered by closing this day.

## Where I ended up

I started Day 3 asking whether authority could move without moving the workload.

I ended it asking what makes an operation rejectable when the authority under which it was decided is no longer current at the side-effect boundary.

The earlier architectural instinct was that epochs and fencing would matter. The experiments made a narrower distinction concrete: declaring authority, observing reality, deciding an operation, and being allowed to perform its effect are not the same event.

Rediscovery recovered the relationship to a surviving realization. Cooperative exit supplied exclusion in the first handoff. A recorded grant and shared creation boundary then supplied the tested stale-Start rejection.

That is what logical Day 3 turned out to be.

This closes Day 3. It does not begin Day 3.4 or Day 4.
