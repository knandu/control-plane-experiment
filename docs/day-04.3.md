# Day 4.3

## The question Day 4.2 left open

> If a live realization loses readiness after startup, can a new authority
> distinguish it from one still warming up, and finish its replacement without
> remembering a repair workflow?

Day 4.2 could remove numbered surplus and colliding incarnations. A single
unready occupant was different: it still occupied the right domain, but the
readiness bit alone could not say whether startup was incomplete or health had
been lost. Waiting was legitimate for one case and insufficient for the other.

## Prior learning

I expected the realization to need some evidence that startup had completed.
I did not expect that evidence to require a manager's saved observation history.
I also expected replacement to be two ordinary reconciliation decisions, not
one larger operation whose progress needed its own durable record.

Those are priors, not conclusions. In particular, killing every unready process
would repeatedly destroy genuine startups. Remembering that a previous manager
once saw Running would not help a cold authority that had never observed it.

## Before the change

The tree was clean on `main` at
`9352cd59fdae07e77aa68bcbfeda7845fa7076b0`.

Intent already held only `WorkloadId`, `Desired`, and optional `Replicas`.
Fresh discovery recovered domain occupancy and native process incarnations.
Day 4.2 already selected victims deterministically and fenced termination
against the separate authority grant. Those mechanisms remain in place.

The missing distinction was operational health after initial readiness.
An unset readiness event previously meant Starting, even after a ready child
lost that signal while remaining alive.

## The smallest change tried

### Put the startup witness in the live incarnation

Each child holds two initially unsignaled manual-reset kernel events for its
lifetime:

```text
Local\ControlPlaneExperiment-<runId:N>          readiness
Local\ControlPlaneExperiment-Started-<runId:N>  startup completed
```

After its startup delay and optional readiness gate, the child sets Started
and then readiness. The test can subsequently reset readiness without resetting
Started or terminating the child.

After the existing native incarnation checks, observation interprets the live
evidence as follows:

| Readiness | Started | Observation |
|---|---|---|
| Signaled | Either | Running |
| Unsignaled | Missing or unsignaled | Starting |
| Unsignaled | Signaled | Degraded |

This is not an absence of memory everywhere. Started is a volatile,
per-incarnation startup witness owned by the realization, not persisted health
history owned by management. A replacement manager can open it without ever
having observed that child Running. It does not survive the child as an intent
field, a last-known health record, or a repair instruction.

No field was added to `PlatformState`. Neither `PlatformStore.cs` nor
`AuthorityGrant.cs` changed. Existing single-replica launch arguments, logs,
intent bytes, and duplicate ambiguity remain compatible; the multi-domain
repair policy is not a new single-replica repair protocol.

### Reconcile health without adding a replacement operation

For multi-domain workloads the decision order is now:

```text
missing/malformed domain       -> explicit failure; no effect
numbered surplus               -> Stop one surplus incarnation
target-domain collision        -> Stop one non-keeper
single-occupant Degraded target -> Stop the first such domain numerically
clean occupancy deficit        -> Start in the first missing domain
Starting occupancy             -> wait
all target domains Running     -> count a matching observation
```

Every pass still permits at most one Stop or one Start. A successful degraded
Stop does not create its replacement in the same pass. The next fresh
observation sees a missing domain; normal deficit reconciliation starts there.
The new Starting incarnation occupies that domain while readiness is withheld.
Convergence still requires two consecutive observations with every target
domain Running.

Collision keepers prefer Running, then Starting, then Degraded. Ties still use
earliest native start ticks, lowest PID, and ascending RunId. Surplus victims
and collision non-keepers prefer Degraded, then Starting, then Running, with
newest ticks, highest PID, and descending RunId as tie-breakers. Highest numbered
surplus still precedes lower surplus and all target-domain repair.

Stop continues to verify PID and native start ticks at the authority-fenced
termination boundary. Health repair reuses that boundary, its existing test
gates, and its successful-operation counters. It does not introduce a new
authority source or persist the selected victim.

### Where endpoint publication would fit

There is deliberately no DNS implementation or external publication service.
A downstream publisher would derive its eligible set from fresh discovery and
the same in-scope domain/keeper policy: publish only Running target-domain
keepers, exclude numbered surplus and duplicate non-keepers, and immediately
withhold Starting and Degraded incarnations from that computed set **before**
replacement. A returned Start is not publication evidence.

In particular, domain-2 should stop contributing an eligible endpoint as soon
as it is observed Degraded, not only after its Stop completes. Its replacement
becomes eligible only after it is observed Running. Healthy peer keepers remain
eligible throughout this experiment's repair.

That is an architectural attachment point, not a claim that external DNS caches
can be invalidated instantly. Real publication would need an endpoint/address
model, its own authority-fenced effect boundary, failure/retry behavior, and
TTL/cache semantics. None of those are exercised by local process identities
and kernel events, so adding a DNS client here would hide rather than test them.

## Executable experiment design

`tests\day-04.3.ps1` uses real Windows processes, native UTC start ticks,
WMI launch metadata, and independently opened readiness/Started handles.
Manual-reset gates hold the relevant boundaries; elapsed time alone is not
proof that a replacement is Starting or that a stale Stop was rejected.

The four main scenarios exercise ongoing repair, a cold mixed-health authority,
stale Stop followed by an interrupted replacement, and a collision whose
Starting keeper is younger than its Degraded victim. A fifth focused probe
checks the complete Degraded/Starting/Running victim order in both surplus and
target-domain collisions.

Every scenario checks unchanged intent bytes and the three-property schema.
Trace checks enforce at most one decision per observation, authority acceptance
at the appropriate boundaries, and actual creation/termination counts. Pending
readiness is held across two no-action observations, and independent native
checks verify retained peers rather than relying only on manager logs.

Two harness mistakes are excluded from the measured evidence below. An initial
draft reached its PASS line without invoking the scenarios; the corrected
entry point requires all five results, six readiness resets, and native
inspections. A later run completed the scenarios but failed teardown when an
old child's PID had been reused by another incarnation. Cleanup now explicitly
logs and skips obsolete native identities before calling the unchanged strict
cleanup helper. Replacement assertions require a new RunId and later native
start ticks, not a necessarily different PID. The failed run's 13 remaining
children were removed only after checking their workload, assembly, RunId, and
native ticks against that run's evidence. Validation restarts after these fixes.

## Final measured run

The measurements below are from the second complete run on November 13, 2026:
`.state\day-04.3-4c50b3755bb343dc9b6c946b9c8cfb61`.
Its 41 evidence files were archived outside the repository and hash-verified
before cleanup. `results.json` contains five scenarios, six readiness-reset
records, and 60 independent native/health inspections. These are diagnostics,
not inputs read by management.

All timestamps below are UTC. Native `StartTimeUtcTicks` values are preserved
as exact 64-bit integers, not rounded floating-point values.

| Manager | Epoch | PID | Native start ticks | Successful Starts / Stops |
|---|---:|---:|---:|---:|
| Ongoing health | 1 | 16488 | 639301750264242829 | 4 / 1 |
| Cold mixed health | 2 | 13796 | 639301750310908707 | 1 / 1 |
| Stale A | 1 | 13972 | 639301750338662136 | 0 / 0 |
| Interrupted B | 2 | 21996 | 639301750362672179 | 0 / 1 |
| Replacement C | 3 | 32396 | 639301750371333678 | 1 / 0 |
| Collision | 1 | 8696 | 639301750398161062 | 0 / 1 |
| Priority probe | 1 | 27336 | 639301750430192697 | 0 / 5 |

### 1. Ongoing health loss, with healthy peers retained

Workload: `684b1b96-fa86-4d33-95c0-42e08c0a7e14`.
The same epoch-1 manager first converged three domains, then observed and
repaired domain-2's lost readiness.

| Role | Domain | PID | Native start ticks | RunId |
|---|---|---:|---:|---|
| Retained | domain-1 | 18340 | 639301750267827550 | `23add2bf-653c-4cc7-8ffb-a4bceb117aea` |
| Running, then Degraded and stopped | domain-2 | 27640 | 639301750269879169 | `06433d3b-7a2d-49ae-8468-3d637d01d285` |
| Retained | domain-3 | 22344 | 639301750271920950 | `e7a63fde-13d8-42bc-83ee-c880c2eb0bad` |
| Replacement, initially Starting | domain-2 | 25372 | 639301750288400340 | `1565ed8d-d865-43b1-8366-8f56a889c5da` |

The harness recorded its readiness-reset request at
`2026-11-13T13:57:08.5083410+00:00`. Observation 10 selected Stop at
`2026-11-13T13:57:08.5337117+00:00`; native termination completed at
`2026-11-13T13:57:08.6652886+00:00`. Observation 11, not observation 10,
selected the missing domain's Start at `2026-11-13T13:57:08.8379540+00:00`.

Two no-action observations retained the genuine Starting replacement with no
additional Stop or Start. The readiness gate was released at
`2026-11-13T13:57:09.3492230+00:00`. Observations 15 and 16 were all Running at
`2026-11-13T13:57:09.5945514+00:00` and
`2026-11-13T13:57:09.7841242+00:00`.

The repair delta was **one Stop and one Start**. Lifetime counters were four
Starts and one Stop because this manager also created the initial three
children. Domain-1 and domain-3 retained all three identity fields exactly.

### 2. A cold authority distinguishes all three live states

Workload: `39a4e43c-d8ab-451d-a033-e6d1cfc7bdbf`.
The harness prepared these children without a running manager. Epoch 2 became
current at `2026-11-13T13:57:11.0813621+00:00`, before the new manager launched.

| Prepared role | Domain | PID | Native start ticks | RunId |
|---|---|---:|---:|---|
| Running, retained | domain-1 | 22060 | 639301750304285166 | `92c2b669-8f96-45f7-9c96-cfbbfc81e0f4` |
| Degraded, stopped | domain-2 | 15300 | 639301750305627384 | `9ec0f68a-4103-48a7-bc60-8d7f8d71e965` |
| Starting, retained | domain-3 | 5104 | 639301750307078392 | `5a4c4310-4704-4f2d-9f26-e1bc04ea71de` |
| Starting replacement | domain-2 | 30012 | 639301750317979796 | `07699073-64b3-4584-ac55-a032ea59ba43` |

Independent event inspections before management confirmed the distinction:

| UTC inspection | PID | State | Readiness | Started |
|---|---:|---|---|---|
| `2026-11-13T13:57:10.9374175+00:00` | 22060 | Running | True | True |
| `2026-11-13T13:57:10.9449594+00:00` | 15300 | Degraded | False | True |
| `2026-11-13T13:57:10.9527529+00:00` | 5104 | Starting | False | False |

The manager's **first** observation at
`2026-11-13T13:57:11.4687675+00:00` classified one Running, one Starting,
and one Degraded realization. It stopped only PID 15300, completing termination
at `2026-11-13T13:57:11.6038744+00:00`, then selected domain-2 creation on
observation 2 at `2026-11-13T13:57:11.7930407+00:00`.

Both domain-2's replacement and the original domain-3 remained Starting across
two no-action passes. Domain-3's gate was released first at
`2026-11-13T13:57:12.2748693+00:00`; the replacement's gate followed at
`2026-11-13T13:57:12.4590718+00:00`. All-ready observations 6 and 7 occurred at
`2026-11-13T13:57:12.5460484+00:00` and
`2026-11-13T13:57:12.7296082+00:00`. Counts were one Start and one Stop;
the original domain-1 and domain-3 incarnations survived unchanged.

### 3. Stale removal and an interrupted replacement

Workload: `337d968a-2ff9-475b-bcdb-2a6c56622f19`.

| Role | Domain | PID | Native start ticks | RunId |
|---|---|---:|---:|---|
| Retained | domain-1 | 3780 | 639301750333641951 | `5b67ae81-530c-4ef3-b2d6-18a6c2888e8e` |
| Degraded victim | domain-2 | 20252 | 639301750334967081 | `91732658-e69c-4ca3-847f-be6ed134e649` |
| Retained | domain-3 | 16332 | 639301750336245493 | `1df1e767-3849-4790-a30a-c244a087b920` |
| C's replacement | domain-2 | 5884 | 639301750375179196 | `ef45d22a-7e8c-4778-a128-fd4359d17e87` |

A passed its epoch-1 manager pre-check and paused before Stop. Epoch 2 became
current at `2026-11-13T13:57:14.3653253+00:00`. After release, A failed explicitly:

```text
Authority rejected: boundary=process termination; offeredEpoch=1; currentEpoch=2; at=2026-11-13T13:57:14.3746975+00:00.
```

Independent native/event checks still found the same degraded incarnation
alive at `2026-11-13T13:57:16.2653889+00:00`. A created and terminated nothing.

B, under epoch 2, completed that victim's Stop at
`2026-11-13T13:57:16.6799545+00:00`. Its next observation found only the two
healthy peers and selected domain-2 Start at
`2026-11-13T13:57:16.8770864+00:00`. The existing before-Start gate held it
**before process creation**. I terminated that verified manager incarnation;
its exit was confirmed at `2026-11-13T13:57:16.9902280+00:00`.
B had one Start decision, but **zero actual Starts and one Stop**.

Epoch 3 became current at `2026-11-13T13:57:17.1240652+00:00`.
C's first observation at `2026-11-13T13:57:17.5110446+00:00` found two Running
children and a missing domain-2, not a saved replacement step. It selected Start
at `2026-11-13T13:57:17.5117259+00:00`, waited through two Starting no-action
passes, and converged on observations 5 and 6 at
`2026-11-13T13:57:18.2905724+00:00` and
`2026-11-13T13:57:18.4788236+00:00`.
C performed one Start and zero Stops; both original healthy peers survived.

### 4. A younger Starting keeper beats an older Degraded occupant

Workload: `ac696227-8bb9-49b5-875c-7f52c4adf982`.

| Initial role | Domain | PID | Native start ticks | RunId |
|---|---|---:|---:|---|
| Older Degraded victim | domain-1 | 15032 | 639301750391359502 | `f993f117-51db-4477-9380-b7211e4c5fa9` |
| Younger Starting keeper | domain-1 | 26188 | 639301750392659109 | `2ea7d2ae-015e-4003-ba93-a67855096486` |
| Running peer | domain-2 | 14564 | 639301750394236311 | `db002b16-a1f0-46fe-bba2-e6fd501432ad` |
| Running peer | domain-3 | 6804 | 639301750395660999 | `3dcd68a2-dfe6-4faa-8f09-4df9a87fb0bb` |

Observation 1 at `2026-11-13T13:57:20.1945342+00:00` found four live children,
including the collision. Only the Degraded child was terminated, at
`2026-11-13T13:57:20.2296693+00:00`. The Starting keeper remained unchanged
through two no-action observations. After its gate release at
`2026-11-13T13:57:20.7164104+00:00`, observations 4 and 5 were all Running at
`2026-11-13T13:57:20.8061030+00:00` and
`2026-11-13T13:57:20.9942652+00:00`. The result was zero Starts and one Stop.

### Additional probe: complete victim priority

Workload: `27c4b3fb-463f-4d13-9480-20821a9e5ac2`, desired count two.
The initial set had three surplus domain-3 occupants, three colliding domain-1
occupants, and one healthy domain-2 peer.

| Initial state | Domain | PID | Native start ticks | RunId |
|---|---|---:|---:|---|
| Degraded | domain-3 | 20816 | 639301750416257953 | `a04e793a-968e-4bb5-a8b3-add825f849d8` |
| Starting | domain-3 | 13832 | 639301750417702432 | `478bbe42-64c9-4455-bc29-5dcda417aedb` |
| Running | domain-3 | 18508 | 639301750419120566 | `48b68a63-c1d6-4cf1-aa92-0c752dcc0b5b` |
| Degraded | domain-1 | 1616 | 639301750421179093 | `8debf5ff-e793-4c18-94dc-a8419db5aa14` |
| Starting | domain-1 | 29412 | 639301750423085194 | `ae572982-8b9c-4f55-83a3-6e0d9f8976c4` |
| Running keeper | domain-1 | 9940 | 639301750425004477 | `5aa89a81-6e7b-4b20-9e92-2f76d9858b50` |
| Running peer | domain-2 | 2672 | 639301750427038631 | `1035da54-d828-49f7-bc9c-d3cda15b8eb7` |

Observations 1 through 5 stopped PIDs **20816, 13832, 18508, 1616, 29412**,
in exactly that order. This independently checks surplus before collisions,
Degraded before Starting before Running among victims, and Running as keeper
even when it is younger. The last termination completed at
`2026-11-13T13:57:24.3124472+00:00`. Observations 6 and 7 were all Running at
`2026-11-13T13:57:24.5048680+00:00` and
`2026-11-13T13:57:24.6958518+00:00`: zero Starts, five Stops.

## Validation and cleanup

All runs below used fresh `pwsh -NoLogo -NoProfile -File` processes and the
corrected final-code harness. Failed or vacuous earlier drafts do not count.

| Validation | Result / Day 4.3 evidence suffix |
|---|---|
| Focused suite, first | Passed; `850048f7193f4a87bad8a5ceedf3ce73` |
| Focused suite, repeat | Passed; `68a6603ad5ae47f8a6199a2e71eeee6c` |
| Complete suite, first | Passed; `1b13cb32236c46929f84dfe123ed6ec0` |
| Complete suite, repeat | Passed; `4c50b3755bb343dc9b6c946b9c8cfb61` |

All five builds in each complete run reported **zero warnings and zero errors**.
The runner preserves every existing pinned checkpoint, including Day 4.1 at
`c11d024`, and runs Day 4.2 unchanged against the current tree before Day 4.3.
Historical single-replica intent, ambiguity, handoff, and fencing tests passed.

After archiving and hash-checking all 41 final evidence files, I removed the
25 inspected task-created state directories. The four pre-existing Day 2
directories were preserved. A native process inventory found zero remaining
experiment processes. No dependencies or container environment were added,
and nothing was pushed.

## What surprised me

The cold-manager case was more useful than merely watching one manager remember
a Running-to-Degraded transition. Its first observation had to distinguish
Running, genuinely Starting, and previously started but unready children at
once. That made the location of the evidence observable.

The interruption between removal and creation also did not leave a special
kind of incomplete work. After B stopped domain-2 and exited before creation,
C found an ordinary missing domain. No one had to reconstruct B's intention
from its log or advance a saved replacement step.

The collision test needed age and health to disagree. Keeping a younger
Starting child over an older Degraded one showed that the new health ordering,
not the old age tie-breaker, made the choice.

The test cleanup also encountered real PID reuse. The native-incarnation rule
was not only a property of the production Stop: diagnostic cleanup needed to
respect obsolete addresses too.

## What remains uncomfortable

Readiness loss is injected by resetting a kernel event. This is not a real
application health probe, a diagnosis of the fault, or proof that process
replacement repairs application data. Started records startup completion, not
continuous liveness or an explanation of the lost signal.

The two events and process enumeration are not an atomic health snapshot.
Sequential event publication and observation can straddle a transition, and
health can change after victim selection. The existing effect fence verifies
authority and native incarnation, not a transactional health precondition.
This checkpoint does not add debounce, hysteresis, startup deadlines, backoff,
or a continuously flapping-health policy.

The same-session, cooperative authority boundary and logical domains retain
Day 4.2's limits. They are not independent machines, consensus, a distributed
failure detector, graceful draining, or a proof of application replication
safety. A publisher would introduce another independently failing effect;
the architectural attachment point above does not implement that protocol.

There is deliberately no promise that an already decided Stop becomes the
right application action merely because its epoch and process identity are
still valid. Nor does an operation counter survive a manager crash as durable
truth. Recovery here comes from the next discovered set, not those counters.

## What I currently believe

**Prior:** distinguishing never-ready from no-longer-ready needs evidence, but
that evidence need not be a manager's persisted observation history.

**Observed:** a cold authority classified all three live states on its first
pass, preserved genuine startup, and replaced only the degraded domain.
Stale authority could not terminate the degraded incarnation. A later authority
recovered the Stop-to-Start gap from absence alone, while healthy peers kept
their exact native identities.

**Interpretation:** this bounded replacement needs a discoverable
per-incarnation startup witness plus the already-earned removal and creation
boundaries, not a durable repair workflow. That does not make the health
sampling or replacement policy a general distributed health protocol.

## Questions earned

What would make a health signal trustworthy and timely on a remote worker,
rather than a cooperative same-session event?

When would transient health loss require withholding publication without
immediately replacing the process?

Which application-level readiness, draining, and publication acknowledgments
would force a richer state model than this two-pass local replacement?
