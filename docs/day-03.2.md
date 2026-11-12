# Day 3.2

## The crack Day 3.1 left open

Day 3.1 moved declared authority from epoch 1 to 2 to 3 while the same
workload incarnation survived. Each old manager cooperatively relinquished
and exited before the next manager acted.

The epoch named the authority generation. Clean process sequencing provided
exclusion. This experiment removes that sequencing assumption, not the
existing discovery mechanism.

## Prior learning

The earlier architecture used management epochs. Stale authority is not a
new concept to me, and this repository is not pretending to invent epochs.
The question is what this smaller model's epoch accomplishes without
enforcement, before reconstructing any earlier fencing design.

## The question

> What happens when a manager executes a decision made under an old authority
> epoch after authority has moved?

My hypothesis before running it: a manager-local epoch is descriptive rather
than protective if the old manager can still execute the side effect.

## Before the experiment

Inspected the clean `main` checkpoint `eff7397`, before changing runtime
behavior:

1. `Program.cs` constructs `FilePlatformStore` and calls `Load` once per
   manager lifetime. `PlatformState` contains only `WorkloadId` and `Desired`.
2. Each loop calls `Workload.Discover(state.WorkloadId)`. This enumerates
   current-session Windows `dotnet.exe` processes, requires the exact assembly
   path and logical identity, validates incarnation identity, and observes
   existence/readiness.
3. If observed state differs from desired Running and is `Stopped`, the
   manager takes the Start branch. That is the decision.
4. The next statement calls `Workload.Start(state.WorkloadId, startupDelayMs)`.
   It generates a run GUID, constructs child launch arguments, and calls
   `Process.Start`. That call creates the process.
5. The manager increments its Start count after the call returns. The existing
   former-pre-locator-save fault injection is later still; it cannot expose
   an old decision waiting to create a process.

There was no queue or stored decision object between the branch and creation.
The decision is embodied by the executing control flow and its local intent,
observation, and startup-delay values.

The assigned epoch is available in `Program.cs` as a nullable positive
`long`, parsed once from launch arguments and used in diagnostic output.
The manager has no current-authority source to consult. Cooperative stdin
relinquishment is checked only at loop boundaries.

Neither `Workload.Start` nor `Process.Start` receives an epoch. Child launch
arguments expose logical identity and run identity, not authority. The
passive store does not validate authority, and reconciliation does not write
to it. The child only supplies readiness; it performs no authority validation.

The smallest meaningful pause point is inside the already-selected Start
branch, immediately before calling `Workload.Start`. Resuming there must not
repeat discovery, reconsider the decision, or check an epoch.

## Fault injection

I added a diagnostic `Decision=start` line in that branch and one opt-in gate:

```text
CONTROL_PLANE_PAUSE_BEFORE_START_EVENT=<existing named event>
```

The test creates a uniquely named local Windows manual-reset event, initially
unsignaled. Only A receives its name. A opens the event, reports the
post-decision/pre-creation pause, and waits. Opening a nonexistent event fails
explicitly. With the environment variable absent, there is no gate.

The stdout pause marker establishes that A selected Start from its fresh
absence observation. The still-unsignaled event prevents it from reaching
`Workload.Start`. The test independently checks that A remains alive, its
Start count is zero, and no matching realization exists.

The event stays unsignaled throughout B's reconciliation. Only after B
converges and external inspection finds its single ready child does the test
signal it. A continues directly to the existing call, without rediscovery,
current-epoch validation, cancellation, or another decision.

This is experimental synchronization, not an authority lock or production
operation queue. It widens one existing interval without changing the order
of observation, decision, and effect. The child's startup delay exposes
Starting; sleeps are not used to order the authority move or release.

The normal test launcher clears the new environment variable unless the test
explicitly supplies it. The older post-creation fault injection is unchanged.

## Manager A / epoch 1

The concrete evidence below comes from the second complete-suite run on
November 12, 2026. All process-start values are UTC .NET ticks.

Durable intent, unchanged throughout:

```json
{
  "WorkloadId": "a3bb9bb6-6daa-4a19-9087-4d30271f89d4",
  "Desired": "Running"
}
```

A was PID **21080**, start ticks `639301005683330252`, epoch **1**.
There were initially zero matching processes.

A's only observation before creation was `Stopped`, at
`17:16:08.6545014Z`. It selected Start while the test's declared current epoch
was still 1:

```text
Decision=start; workload=a3bb9bb6-6daa-4a19-9087-4d30271f89d4; manager=21080; authorityEpoch=1; observation=1; at=2026-11-12T17:16:08.6549488+00:00.
Experiment paused: after Start decision; before process creation; starts this manager=0; resumeEvent=Local\ControlPlaneExperiment-BeforeStart-67299da84ac34ecf82f952464654d295; at=2026-11-12T17:16:08.6551177+00:00.
```

Before moving authority, the test independently verified the unsignaled gate,
the same live manager, zero returned Starts, zero matching processes, and
byte-for-byte unchanged intent.

The decision was valid when made. Nothing was running for that logical
workload, and epoch 1 was still the externally assigned authority.

## Authority movement

The test changed its declared current epoch from **1 to 2**, recorded at
`2026-11-12T17:16:08.7637584+00:00`, and launched B with
`--authority-epoch 2` against the same intent file.

A was not sent `relinquish`, killed, or allowed to exit during this move.
Its event remained unsignaled. After B converged, the test checked again
that the same A was alive and had issued zero Starts.

The harness is still the simple external authority source. This deliberately
does not use Day 3.1's test rule requiring prior manager exit. There is no
runtime exclusion check to bypass and no election, lease, or cluster service.
Epoch 2 is current by the test's explicit assignment, not by a newly
implemented authority protocol.

## Manager B / epoch 2

B was PID **23596**, start ticks `639301005687682785`, epoch **2**.

Its first observation was freshly `Stopped`, at `17:16:09.0930651Z`.
It selected Start under epoch 2 and issued exactly **one Start**.

| B's realization | Observed value |
|---|---|
| Logical workload | a3bb9bb6-6daa-4a19-9087-4d30271f89d4 |
| PID | 30880 |
| UTC process-start ticks | 639301005690966122 |
| Run ID | 0aa3b96e-2384-4934-b319-b415be0d585d |

Observations 2 through 7 were `Starting`. Observations 8 and 9 were `Running`;
the second was timestamped `17:16:10.5285655Z`. B then reported:

```text
Converged: two matching observations; starts this manager=1; pid=30880.
```

Before release, external inspection verified exactly one matching live
realization, with that PID/start-time/run-ID combination and signaled
readiness. Durable intent was unchanged. Declared current authority was 2,
while A remained alive behind its unsignaled pre-effect gate.

## Resume Manager A

The test recorded release at `2026-11-12T17:16:10.6412897+00:00` and signaled
the event. A continued:

```text
Experiment resumed: continuing decided Start without rediscovery; at=2026-11-12T17:16:10.6430236+00:00.
Action=start returned; pid=27200; startTicks=639301005706463209; runId=b9ebf3e2-64b4-4d2c-a484-6cdb345577ba; readiness not yet observed.
```

There was still only one observation and one decision in A's output before
this effect. It did not make a new epoch-1 decision after B's assignment.
It completed its earlier decision. The new child's process-start ticks were
later than both the external authority change and the recorded release.

External inspection then found exactly these two matching live realizations:

| Created by | PID | UTC process-start ticks | Run ID | Fresh readiness |
|---|---|---|---|---|
| B / epoch 2 | 30880 | 639301005690966122 | 0aa3b96e-2384-4934-b319-b415be0d585d | Signaled |
| A / epoch 1 | 27200 | 639301005706463209 | b9ebf3e2-64b4-4d2c-a484-6cdb345577ba | Signaled |

Both command lines exposed the same logical workload ID from the intent.
The test checked each actual process start time and readiness event.
There were **two Starts in total**, one per manager, while declared authority
remained epoch 2.

On subsequent discovery, both managers exited nonzero with the existing
explicit ambiguity:

```text
Multiple live realizations of workload a3bb9bb6-6daa-4a19-9087-4d30271f89d4: 30880, 27200. No Start issued.
```

Both exit codes were `-532462766`. The last sentence describes the failed
discovery pass: it does not mean the earlier Starts were prevented.

A never reported convergence. B reported it once, before release, when its
single realization was ready. Neither reported convergence after the
duplicate existed. Later ambiguity detected the damage; it did not prevent
the stale effect or select a winner.

Both children remained alive and ready after their managers exited, until
explicit test teardown. No production cleanup or arbitration was added.

## How this differs from Day 2.2

Day 2.2 lost the recoverable relationship between surviving intent and a
surviving child. The replacement manager had neither its locator nor a
logical-identity discovery path, so it started another realization and
reported convergence while both were ready.

Here, the relationship was never missing. Both managers loaded the same
intent, and both children exposed its logical identity. B correctly observed
absence and then its own realization. A's earlier absence observation was
also valid when it decided.

The duplicate happened because that already-decided side effect remained
executable after authority moved and B acted. The existing discovery mechanism
subsequently correlated both realizations and reported ambiguity correctly.

This is a stale-authority/unenforced-side-effect failure, not the old
discovery/correlation failure.

## What the epoch actually did

Epoch 1 stopped being current in the external test's assignment. Epoch 2 was
explicitly assigned to B while A stayed alive. A still knew only its own
launch-time value, 1; it had no current-authority source, notification, or
comparison that could tell it about 2.

| Boundary or role | What happened |
|---|---|
| Authority identifier | A's logs said 1; B's said 2. |
| Ordering value | The test externally supplied 1 then 2; no component enforced monotonic assignment or persisted its history. |
| Diagnostic context | Fresh observations and Start decisions identified the manager and its assigned epoch. |
| Manager decision | Assigning 2 did not revoke A's earlier decision. |
| Start/process creation | Neither received or validated an epoch. |
| Durable store | Both loaded the same intent; no creation-time store call rejected anything. |
| Child/readiness boundary | Neither validated management authority. Both children became ready. |
| Enforcement | None was demonstrated. The stale Start succeeded. |

The epoch was descriptive here. Clean cooperative exit in Day 3.1 prevented
this overlap; the epoch itself did not supply that protection. Day 3.1 still
holds for its benign, serial sequence.

## What surprised me

The prediction was confirmed. I am not claiming stale authority was a new
discovery or manufacturing surprise.

The value was making the ordering concrete: A's decision was valid when
made, B converged under the newer assignment, and A's delayed effect still
created another ready realization.

## What became uncomfortable

- Where would authority need to be revalidated for this old decision to become
  rejectable? No such validation was tried here.
- Would a manager-only check suffice, or merely leave another check/effect
  interval? This run does not answer that.
- Does the side-effect or downstream realization boundary eventually need
  authority context? The current child has none; no worker abstraction or
  speculative epoch field was added.
- Where would authority ordering survive a restart of its external source?
  The test's transient assignments do not establish durable ordering.
- Two ready realizations can share logical identity. Explicit ambiguity is
  honest, but still supplies neither winner selection nor cleanup semantics.

Fresh discovery is useful but not atomic with process creation. Detecting a
duplicate on the next pass is different from preventing one.

## What I currently believe

**Prior:** epochs can distinguish authority generations, and stale authority
can require enforcement. That knowledge came into this experiment.

**Observed:** with overlapping local manager lifetimes, an epoch-1 decision
created a second ready realization after epoch 2 had been assigned and had
already converged. The intent file was unchanged. Both managers subsequently
reported ambiguity.

**Interpretation:** declaring a newer epoch does not, in this implementation,
revoke previously decided work. Logical-identity rediscovery addressed the
tested Day 2 recovery gap, not this stale side effect.

This does not establish a final fencing contract, the right enforcement
location, a need for a particular durable authority schema, or that epochs
alone are sufficient.

I reread `experiment-framing.md` afterward. Its existing instruction to make
the failure appear before adding the solution already fits this checkpoint.
The expected technical result did not produce a new methodological lesson,
so I left that document unchanged.

## Validation and checkpoint

```powershell
dotnet build .\ControlPlaneExperiment.slnx
pwsh -NoLogo -NoProfile -File .\tests\day-03.2.ps1
pwsh -NoLogo -NoProfile -File .\tests\all.ps1
```

The current build passed with zero warnings and zero errors. The focused
experiment passed twice, including after test-output/handle cleanup was
tightened. The complete historical/current suite then passed twice in
separate fresh shells, each reproducing Day 3.2 again.

| Run | Ready duplicate PIDs | Starts A / B | Outcome |
|---|---|---|---|
| First focused run | 1984, 23396 | 1 / 1 | Both managers: explicit ambiguity |
| Focused final harness | 8272, 12148 | 1 / 1 | Both managers: explicit ambiguity |
| First complete suite | 24452, 31720 | 1 / 1 | Both managers: explicit ambiguity |
| Fresh-shell complete repeat | 30880, 27200 | 1 / 1 | Both managers: explicit ambiguity |

All current and pinned historical builds had zero warnings/errors. The
complete suite retained the original Day 1 baseline, four Day 2.1 cases,
Day 2.2's pinned duplicate, all eight current Day 2.3 cases, and all Day 3.1
clean handoff/startup/replacement checks.

In the final suite, historical Day 2.2 still independently verified ready
duplicate PIDs **14464** and **19480**. That is its original expected failure,
not a repaired historical snapshot.

The new test asserts that A stays alive behind the unsignaled gate until B
converges, verifies both incarnations and readiness, and checks both actual
ambiguity errors. It drains B's later stdout asynchronously so output
buffering cannot accidentally exclude the stale effect. Teardown drains
inherited output/error writers only after managers and children have exited.

Cleanup terminates only identified test processes, verifies workload start
times before killing a PID, and discovers any remaining children of the
owned logical intent on failure. Independent enumeration found no experiment
managers or children after both complete runs. After recording this notebook,
all eight task-created runtime-evidence directories were removed; the four
pre-existing ignored directories were preserved. Historical exports were
removed by the suite runner.

The implementation delta is one diagnostic decision line and one
disabled-by-default pre-creation gate. The workload implementation, passive
store, durable schema, dependencies, prior notebooks, historical source pins,
and earlier scenario assertions are unchanged.

No epoch enforcement, fencing, stale-operation rejection, rediscovery on
release, authority polling, or repair was added. No originating-system names,
code, configuration, or new architecture were introduced. There was no stale
Stop experiment: the controller has no Stop/removal operation, and teardown
is not one.

## Question earned by this experiment

> Where must authority be enforced so that an operation validly decided under
> an older authority becomes rejectable after authority moves?

That question is not answered here. This checkpoint stops after Day 3.2.
It does not select a final authority contract, implement a repair, or begin
Day 3.3.
