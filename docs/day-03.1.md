# Day 3.1

## The prior I'm bringing in

The earlier architecture used a management epoch. Moving authority advanced
that epoch, distinguishing work associated with an older authority from work
under the current one.

I already know that an epoch can represent authority movement. This repository
is not independently inventing that idea.

The question is how much that established learning needs to mean here. I do
not want to reconstruct the earlier mechanism merely because I know it.
This checkpoint tries only a clean handoff, not stale-authority execution.

## The question

> Can management authority move while the existing workload stays where it is
> and continues satisfying intent?

And:

> Is authority identity independent from realization identity?

## Before the change

The logical Day 2 close was `8d6c326`. The tree was clean on `main`.

The manager already reported its PID, loaded durable intent, and rediscovered
live realizations by logical workload identity. It did not represent authority
explicitly. One manager was a precondition, not an enforced property.

Day 2 had already tested replacing the management process. It had not named a
change in authority separately from that process replacement.

I expected the existing discovery mechanism might be enough for adoption.
That expectation did not justify adding authority metadata to the child or
the durable workload record before trying the handoff.

## The smallest authority model

An operator, represented by the sequential process test, explicitly assigns
a positive `long` epoch:

```text
manage <state-file> [startup-delay-ms] --authority-epoch <epoch>
```

The experiment assigns 1, then 2, then 3. A separate startup experiment
uses its own 1-to-2 sequence. The manager does not allocate these values,
compare them with a stored current epoch, or decide who wins.

Management process identity is the OS PID plus UTC process-start ticks.
Authority identity is the separately supplied epoch. Neither is derived from
the other, and neither becomes the workload's logical or incarnation identity.

In explicit authority mode, one line on stdin, `relinquish`, asks the manager
to finish its current reconciliation pass and exit normally at the next loop
boundary. It reports relinquishment and leaves the workload alive.
Unexpected input or EOF is an explicit error, not a successful handoff.

The test waits for both the relinquishment message and exit code zero before
granting the next epoch. It refuses to launch the next manager while any
previous test manager is still alive. No competing authority is exercised.

The `Authority acquired` log means an explicit experimental assignment.
It is not proof of election, exclusion, or a right enforced at a side-effect
boundary. Positive-integer input validation is not epoch-freshness validation.
Nothing checks the epoch at `Workload.Start`.

Omitting the flag preserves the Day 2 mode: authority is logged as `implicit`,
and no stdin relinquishment channel is enabled.

### Where the state lives

The current grant belongs to the operator/test's sequential protocol. The
manager holds its assigned epoch only in process-local memory, received as a
launch argument. No durable authority-state file was introduced.

That was sufficient because this experiment supplies the next assignment
externally and waits for clean exit. It does not test recovery of the authority
source or guarantee monotonicity after that source loses its own history.

Durable workload intent remains exactly `WorkloadId` and `Desired`.
The tests compare its bytes across handoffs and replacement. No authority
field was added to `PlatformState` or `IPlatformStore`.

Logs and test `results.json` contain epochs as diagnostic evidence. No manager
reads them as a current-authority record, journal, or recovery hint.

The child's launch arguments and readiness mechanism are unchanged. In
particular, no creator epoch accompanies the workload incarnation.

## Experiment: epoch 1

The following identities are from the first complete fresh-shell suite on
November 12, 2026, not the earlier focused rehearsal.

Durable intent:

```json
{
  "WorkloadId": "4b0de37e-3660-49a6-881d-b48a89668b75",
  "Desired": "Running"
}
```

Manager A was PID **20560**, start ticks `639300987340240900`, assigned
epoch **1**.

It freshly observed `Stopped`, issued exactly **one Start**, observed
`Starting`, then observed `Running` twice and reported convergence.
The test used a 1000 ms startup delay to expose startup.

The resulting incarnation was:

| Field | Observed value |
|---|---|
| PID | 14420 |
| UTC process-start ticks | 639300987343486756 |
| Run ID | 53dae204-f373-41f9-a9a3-49567dc24f60 |

A accepted `relinquish` and exited with code zero. Independent process and
readiness checks confirmed that this same child remained alive and ready.

## Experiment: epoch 1 -> epoch 2

Only after A exited, the test assigned epoch **2** to Manager B, PID
**28312**, start ticks `639300987359324087`.

B received the same state-file path, not a locator or predecessor log.
It loaded the same intent and used fresh process enumeration. Its first
observation was:

```text
Observation 1: fresh=Running; workload=4b0de37e-3660-49a6-881d-b48a89668b75; pid=14420; startTicks=639300987343486756; runId=53dae204-f373-41f9-a9a3-49567dc24f60; manager=28312; authorityEpoch=2; at=2026-11-12T16:45:36.2682127+00:00.
```

PID, process-start ticks, and run ID were unchanged. B observed `Running`
twice, converged with **zero Starts**, then relinquished and exited normally.
External checks still found the same ready child and exactly one matching
realization. Intent remained byte-for-byte unchanged.

Moving authority had not required moving or recreating this workload.

## Repeated handoff

After B exited, Manager C, PID **30436**, start ticks
`639300987366923626`, received epoch **3**.

C also freshly observed the same ready incarnation on its first observation
and converged with **zero Starts**.

| Epoch | Manager PID | Realization PID | Starts at healthy convergence |
|---|---|---|---|
| 1 | 20560 | 14420 | 1 |
| 2 | 28312 | 14420 | 0 |
| 3 | 30436 | 14420 | 0 |

Across both handoffs, the realization retained the exact start ticks and run
ID recorded above. The manager process and assigned authority changed;
the logical workload, durable intent, and workload incarnation did not.

## Handoff during startup

A separate bounded run used logical workload
`58bc0817-8a26-4f5b-ab65-3ad2767b11ba` and a 5000 ms child startup delay.

| Authority | Manager PID | Manager UTC start ticks | Starts |
|---|---|---|---|
| Epoch 1 | 30032 | 639300987385291929 | 1 |
| Epoch 2 | 16232 | 639300987391751323 | 0 |

The first manager observed absence, created child **31756**, and observed
`Starting` before cleanly relinquishing and exiting.

That child's start ticks were `639300987388510318`; its run ID was
`ce70fd12-e0db-48e1-922d-ffab03a0e95f`. External inspection after the exit
confirmed that it was alive with readiness unsignaled.

The epoch-2 manager freshly observed `Starting` on observation 1 for that
same PID/start-time/run-ID combination. It did not issue another Start.
It later observed `Running` and converged at observation 28. Exactly one
matching realization existed, and the intent file was unchanged.

No timeout, remediation policy, or artificial workload restart was needed.

## Failure after handoff

In the ready-workload sequence, I kept C running under epoch 3 after its
healthy convergence. Then the test killed the verified incarnation **14420**.
There was no additional authority move.

The same manager **30436**, still under epoch **3**, freshly observed
`Stopped` at observation 3 and issued exactly **one replacement Start**.
It observed startup and readiness and converged again.

The replacement was PID **10960**, start ticks `639300987373695605`,
run ID `0cd7f91b-14c7-4014-9bad-65637d6faf62`.

The desired workload ID and JSON bytes remained unchanged. There was exactly
one matching live realization. C then relinquished and exited normally.

The newer authority was not limited to passively observing its predecessor's
child. The existing reconciliation behavior could satisfy intent after that
child disappeared. No new health-monitoring mechanism was added.

## What surprised me

The straightforward handoffs worked as expected. There was no adoption
failure or architectural surprise to manufacture.

The startup handoff and replacement also followed the existing discovery
and reconciliation paths.

## What became uncomfortable

The epoch makes the declared authority transition visible, but does not make
the declaration true by enforcement. Clean exit and the sequential external
grant protocol are doing the exclusion work in this experiment.

The current grant is not workload intent. Putting it into `PlatformState`
would have conflated two different management-owned facts without this
experiment demonstrating a need for that persistence.

Conversely, an external epoch assignment is not an explanation of how a real
authority source recovers, preserves ordering, or transfers responsibility.
Its transient representation here should not be mistaken for that result.

The adopted child did not need to know its creator's epoch in these runs.
Adding one now would anticipate a different experiment rather than explain
the observed clean handoff.

Relinquishment is cooperative and checked between passes. It neither revokes
an uncooperative manager nor fences a side effect already decided under an
older authority. Those paths were not exercised.

Multiple matching realizations remain ambiguous. No newest-epoch winner
rule was added; the existing explicit error remains.

## What I currently believe

**Observed:** with serial manual grants and normal manager exit, epochs
1 -> 2 -> 3 accepted the same healthy local workload incarnation. A new
authority also adopted a Starting incarnation, and the current epoch-3
manager replaced an absent incarnation exactly once.

**Interpretation:** management process identity, declared authority identity,
logical workload identity, and workload incarnation identity can remain
separate in this simplified model. Durable intent spanned the grants without
being rewritten.

The epoch was not needed to choose which realization to adopt; Day 2's
logical-identity discovery still did that work. This checkpoint makes
responsibility movement explicit. It does not establish that epochs are
necessary for benign adoption, or that authority correctness is solved.

I left `experiment-framing.md` unchanged. Its existing treatment of priors
already allowed this bounded use of established learning; this run did not
reveal a new methodological rule.

## Validation and checkpoint

```powershell
dotnet build .\ControlPlaneExperiment.slnx
pwsh -NoLogo -NoProfile -File .\tests\day-03.1.ps1
pwsh -NoLogo -NoProfile -File .\tests\all.ps1
```

The focused real-process run passed, followed by two complete-suite runs
from separate fresh shells, each running Day 3.1 again. The second complete
run validated the final source. Current and pinned historical builds had
zero warnings and zero errors.

The full suite retained the original Day 1 baseline, four Day 2.1 cases,
Day 2.2's expected duplicate, and all eight current Day 2.3 cases. In this
replay, historical Day 2.2 independently verified ready duplicate PIDs
**6248** and **3852**. Current Day 2.3 still rejected two matching
realizations, **32600** and **29816**, with zero Starts and explicit ambiguity.

Common observation and verified test-cleanup functions were moved from
Day 2.3 into the existing process-test helper for reuse. Its scenario
assertions and historical source pins were not changed.

There are no new packages, cluster APIs, WSFC dependencies, authority-store
fields, worker journals, stale-epoch checks, or epoch checks at Start.
The workload implementation and two-field durable schema are unchanged.
No originating-system names, code, or configuration were introduced.

Test teardown stopped only identified managers and workload incarnations,
checking workload start times before termination. Independent process
enumeration found no remaining experiment managers or children. After
capturing this notebook, the five newly created runtime-evidence directories
were removed; all four pre-existing ignored directories were preserved.

## Questions earned by this checkpoint

- What happens if an old manager does not stop acting after authority moves?
- What would make an authority grant enforceable rather than declared?
- What happens to a side effect already decided under an older authority?
- Where must epoch ordering live if the authority source itself restarts?

These are questions, not a selection or implementation of Day 3.2.
This checkpoint stops at Day 3.1.
