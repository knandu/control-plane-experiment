# Day 2

Day 2 took longer to understand than Day 1.

I came into it with a strong architectural instinct: intent should survive the lifetime of the process currently managing it.

That led naturally to durable platform state.

At first, I persisted more than intent.

I also persisted an incarnation locator and the last observation.

For the restarts I tested, it worked.

A new manager could restart, recover state about what its predecessor had created, freshly observe the workload, and continue reconciliation without immediately starting another one.

But that result turned out to be the beginning of Day 2 rather than the end.

## Day 2.1: what should survive the manager?

Day 2.1 separated manager lifetime from workload lifetime.

The manager could disappear while the workload continued running.

A new manager could recover durable intent, observe the workload through the saved locator, and continue reconciliation.

One experiment was particularly useful.

The saved state said the workload was `Running`.

While management was down, the workload was killed.

When management restarted, fresh observation said `Stopped`, and the system started a replacement.

That made one distinction concrete:

> Persisted observation is not current operational truth.

An observation records what I saw.

It does not establish what is true now.

That result made me question how much operational state belonged in durable platform state at all.

It did not yet show that the locator was unnecessary. The successful restart cases depended on that locator having been saved.

## The experiment itself needed correction

This was also the point where the methodology became uncomfortable.

I introduced `IPlatformStore` because durable management state existed in the architecture that led to this experiment and I expected something like it to survive simplification.

That wasn't necessarily wrong.

Intent really does need somewhere to survive the lifetime of the process currently managing it.

But I noticed how easy it would be to keep reconstructing concepts from an architecture I already knew and then call the result an experiment.

That is why [experiment-framing.md](experiment-framing.md) appeared during Day 2 rather than at the beginning of the repository.

I ended up adopting two useful rules:

> An architectural prior can influence the question I ask. It doesn't automatically earn an implementation.

And:

> When ambiguity appears, record it before resolving it.

That changed what I did next.

## Day 2.2: make the ambiguity happen

Day 2.1 contained an uncomfortable crash gap:

```text
observe no workload
        |
        v
start workload
        |
        v
workload exists
        |
        v
manager dies
        |
        v
save incarnation locator
```

The last step never happens.

I didn't want to resolve this only in the notebook. Day 2.2 deliberately stopped the manager at that boundary.

It had successfully created child 4960. After the manager was killed, that child remained alive and ready.

Durable intent still said `Running`, but the saved locator was null. The saved observation said `Stopped`.

The replacement manager could not correlate the existing child with the logical workload. With no locator, it observed `Stopped`, started child 15772, and eventually reported convergence.

Both children were independently verified alive and ready.

This wasn't lost intent, and it wasn't failed process creation.

The intent survived. The realization survived. The relationship between them did not survive in a form the replacement manager could recover.

That failure is part of the result, not an awkward intermediate version to hide.

## Day 2.3: can reality expose the missing relationship?

The next question was whether a new manager could recover that relationship without remembering that its predecessor had successfully issued a Start.

First, I inspected an equivalent orphan under the old implementation. Process discovery could find it and observe readiness, but its launch arguments exposed an incarnation run ID, not the logical workload ID.

Finding a process was not the same as knowing which desired thing it belonged to.

Day 2.3 then put the logical workload GUID into the child launch arguments, alongside a separate incarnation run GUID.

The logical identity accompanies process creation. There is no later manager-side step that first records, "this existing process belongs to workload W." Putting that association into a separate post-creation save would recreate the gap Day 2.2 had just exposed.

A later manager can inspect the realization itself to recover the association.

The implementation uses Windows WMI enumeration, constrained to the current session and exact assembly path, followed by process-incarnation and readiness checks. That is the mechanism I tested, not a general discovery architecture.

The more interesting distinction is:

```text
logical workload identity != process-incarnation identity != operational state
```

Logical identity answers: what desired thing is this realization associated with?

Incarnation identity answers: which particular realization am I observing? Here that means PID, process creation/start time, and run ID.

Operational state answers: what is true about that realization now? Here that means freshly observed existence and readiness.

## Trying to make rediscovery uncomfortable

In the recorded final Day 2.3 run, child 23080 survived the interrupted-creation scenario. The first manager issued one Start. Recovery management rediscovered and adopted the ready child with zero Starts. No duplicate was created.

With both the persisted locator and last observation absent, management still adopted that same incarnation with zero Starts.

An unrelated saved locator and a saved `Stopped` observation did not override the live matching realization either.

Then child 23080 was killed while management was absent. The old saved `Running` evidence was still present, and the test deliberately kept its old readiness event signaled through a retained handle. Neither established that the process still existed. Fresh observation found absence, and exactly one replacement, 30756, was created.

A ready but unrelated process, 32544, was not adopted. Management created exactly one realization for the desired logical workload, 29972.

Restart during startup also preserved the relationship. Child 10920 survived; the first manager issued one Start, the restarted manager issued zero additional Starts, and fresh observations progressed from `Starting` to `Running`.

Child 33068 made another distinction visible. It was identifiable and alive but never became ready. The bounded test observed three `Starting` results, no additional Start, and no convergence before stopping the manager.

Identity was not readiness. Process existence was not successful realization.

Finally, two ready processes, 29196 and 5776, exposed the same logical workload identity. Management issued zero Starts and reported explicit ambiguity. It did not arbitrarily choose one.

Rediscovery had recovered a relationship. It had not solved what to do when that relationship was not unique.

## What actually needed to remain durable?

I did not remove the persisted operational fields first and then declare the smaller schema sufficient.

Day 2.3 initially retained them while testing rediscovery, their absence, and contradictory saved evidence. Only after those experiments were the incarnation locator and last observation removed from authoritative durable state.

The final state has this conceptual shape:

```json
{
  "WorkloadId": "<logical workload id>",
  "Desired": "Running"
}
```

It records management truth: what should be true.

It does not try to preserve the management plane's current model of operational reality.

The manager freshly rediscovers the logical identity exposed by live realizations, PID, process start/creation time, incarnation run ID, existence, and readiness. It no longer saves an incarnation locator or an observation during reconciliation.

Timestamped observations are still useful diagnostic evidence. They are not authoritative state. Handles, loop counters, and process-local bookkeeping remain transient.

Neither persisted operational field was required for correctness in the scenarios tested here. That is narrower than claiming operational metadata can never deserve a durable role.

## Keeping the evidence

This reflection does not replace the [Day 2.1](day-02.1.md), [Day 2.2](day-02.2.md), or [Day 2.3](day-02.3.md) notebooks.

The Git history still shows the order in which the questions developed: durable state in `0a372f8`, framing introduced in `500b566` and refined in `98a2901`, the reproduced crash gap in `ab24103`, and rediscovery in `4889b6b`.

The complete test runner preserves that history too. It runs the original Day 1 real-process behavior against pinned source at `0ab3e5c`. It runs the four historical Day 2.1 cases and the Day 2.2 failure reproduction against the source checkpoint at `ab24103`. Day 2.3 tests the current implementation.

At Day 2.3 completion, the historical Day 2.2 replay still produced two independently verified ready children, 13000 and 13092.

A passing historical failure test means that the old duplicate-realization bug was reproduced. It does not mean that architectural checkpoint was repaired.

I want both results to remain visible: the failure really existed, and the later change addressed the tested recovery case.

## What Day 2 has not settled

Multiple matching realizations remain unresolved. So do cleanup semantics and identity reuse.

An identifiable workload can remain `Starting`. The never-ready test was bounded; it did not establish a policy for that condition. The existing 100-pending-observation limit is still an exception, not a remediation strategy.

Readiness is not ongoing health, and observation is not atomic.

Discovery remains limited to this local Windows/session/assembly-path model. Remote or distributed discovery has not been tested. The file store demonstrates process-restart durability here, not a general distributed durability guarantee.

Single management authority is still assumed, not enforced. Authority movement, stale management authority, fencing, and adoption across authority generations remain outside this result.

None of those boundaries is resolved by closing the notebook.

## Where I ended up

I started Day 2 asking what management needed to remember.

I ended it asking what the realization needed to expose so that management would not have to remember it.

Durable intent survived. The durable model of operational reality became smaller, but only after an experiment showed why the original recovery path failed and another tested an alternative.

That is what logical Day 2 turned out to be.

This closes Day 2. It does not begin Day 3.
