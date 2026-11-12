# Day 3.3

## The question Day 3.2 earned

> Where must authority be enforced so that an operation validly decided under
> an older authority becomes rejectable after authority moves?

## Prior learning

I already expected an epoch to need enforcement. That is prior architectural
learning, not something this repository invented.

Day 3.2 supplied the concrete failure: a valid old Start decision remained
executable after a newer authority had created a ready realization.

## Before the change

The tree was clean on `main` at
`a7665e70817b9261467ab7caaf20919e78f63d4d`.

Workload intent was already only `WorkloadId` and `Desired`. Fresh discovery
could correlate surviving children with that intent. Neither property had
prevented Day 3.2's late, already-decided side effect.

## Candidate enforcement points before the change

`Program.cs` selects Start after fresh discovery. `Workload.Start` constructs
the child arguments and calls raw Windows `Process.Start`. The child later
signals readiness. None of those boundaries checked current authority.

A manager-only recheck would reject work already stale at that check. It
would not protect against preemption immediately afterward, including inside
`Workload.Start`. Moving an unlocked check closer to `Process.Start` merely
moves that interval. Windows process creation does not accept an application
epoch to compare atomically.

The smallest local mechanism I want to try is one scalar authority file,
separate from workload intent, and one named mutex shared by the external
grant command and the process-creation boundary. The source must participate:
calling a newer epoch current before acquiring that boundary would defeat
the ordering.

I will retain a manager pre-check and pause after it to test its limitation.
The actual enforcement will recheck under the mutex and retain it through
process creation. A second pause, after that boundary check, will test what
happens when a newer grant is requested while an accepted creation is
unfinished.

That was the proposed experiment before writing the implementation. The runs
below test it; they do not compare every possible enforcement mechanism.

## The smallest enforcement mechanism tried

The operator/test remains the authority source. It supplies positive `long`
epochs through a new foreground command:

```text
grant <authority-file> <epoch>
manage <state-file> [startup-delay-ms] --authority-epoch <epoch> --authority-file <authority-file>
```

`grant` does not elect a manager or allocate the next value. It records an
externally supplied value only if it is strictly greater than the existing
one. Missing authority state can be initialized; malformed or non-positive
recorded state fails explicitly.

The file contains only the decimal scalar, without a newline. A temporary
sibling is written and flushed, then moved over the grant file. This follows
the existing local file-write pattern without making authority a field in
`PlatformState` or a responsibility of `IPlatformStore`.

The named mutex is `Local\ControlPlaneExperiment-Authority-` followed by a
SHA-256 of the uppercased absolute authority-file path. Both grant advancement
and fenced Start use that same name in the current Windows session.

The manager pre-check acquires the mutex, compares its offered epoch with the
recorded grant, logs acceptance, and releases it. That acceptance is only a
check at that instant.

`Workload.Start` separately reacquires the mutex, requires exact equality with
the recorded epoch, and retains ownership through `Process.Start` and capture
of the returned PID and native start time. An older epoch throws
`AuthorityRejectedException` before calling the creation callback. An
ungranted future epoch is not accepted either.

This leaves two possible orders for cooperating participants:

1. The newer grant commits first. The old Start reaches the boundary later
   and is rejected.
2. The old Start enters the boundary first. A newer grant request waits until
   that accepted creation completes. The request is not yet a current grant.

The second case is serialization, not cancellation of an already accepted
operation. Raw Windows process creation still has no application-epoch
comparison. The source participates in the ordering instead.

There is no child epoch, readiness-time authorization, worker daemon, lease
heartbeat, election, placement model, or new package. Child arguments,
readiness, and logical-identity discovery are unchanged. Commands without
`--authority-file` retain the earlier unenforced mode for the earlier
experiments; the fenced experiment opts in explicitly.

## The executable experiment

`tests\day-03.3.ps1` uses two independent intent/grant pairs and named manual
reset events.

The first pause is the existing Day 3.2 gate, now after the manager pre-check
and before `Workload.Start`. The test waits for A's actual pause log and
verifies an unsignaled gate, a live manager, and zero matching processes.
It commits grant 2, waits for B's readiness and convergence, and only then
releases A.

The second gate is inside `Workload.Start`, after the locked authority check
and immediately before `Process.Start`:
`CONTROL_PLANE_PAUSE_AFTER_START_AUTHORITY_CHECK_EVENT`.
The advancing source first tries a nonblocking mutex acquisition. Its
`Authority lock waiting` message means acquisition actually failed, not
merely that the process was launched. The test waits for that message before
inspecting the still-recorded epoch 1 and releasing creation.

No sleep selects either race ordering. Readiness polling in the existing
process helpers remains observation, not the synchronization that places
the authority movement.

The test checks native process-start ticks, logical and run IDs in command
lines, readiness events, matching-process counts, Start counts, and manager
exit codes. Its post-rejection B observation must be timestamped after the
test has observed A's exit; an older buffered Running line is insufficient.

Rejected managers have explicit nonzero exits rather than silently dropping
the operation or pretending convergence. Manager/child output handles still
need care: the test drains stderr asynchronously, stops owned children
before waiting for inherited pipe writers to disappear, and then saves the
complete logs. Those logs and `results.json` are diagnostics, never inputs
to the runtime.

## Concrete run: the old decision is rejected

The evidence below comes from the **second complete fresh-shell
`tests\all.ps1` run**, on November 12, 2026, not from a focused rehearsal.
Its Day 3.3 directory was
`.state\day-03.3-0e0eae9bbf4349d7a14ea55f112cadda`.
All times below are UTC.

The durable intent was:

```json
{
  "WorkloadId": "ee4498e2-8c83-4fd4-bbcf-6719c346825e",
  "Desired": "Running"
}
```

The separate `stale-decision.epoch` was initialized to `1` at
`18:42:21.9902996Z`. Manager identities were independently checked against
their native process start times:

| Manager | Epoch | PID | UTC process-start ticks | Final exit |
|---|---|---|---|---|
| A | 1 | 29616 | 639301057443008682 | -532462766 |
| B | 2 | 28328 | 639301057448923522 | 0, after requested relinquishment |

A's log:

```text
Manager=29616; recovered workload=ee4498e2-8c83-4fd4-bbcf-6719c346825e; desired=Running; managerStartTicks=639301057443008682; authorityEpoch=1.
Observation 1: fresh=Stopped; workload=ee4498e2-8c83-4fd4-bbcf-6719c346825e; pid=; startTicks=; runId=; manager=29616; authorityEpoch=1; at=2026-11-12T18:42:24.6386402+00:00.
Decision=start; workload=ee4498e2-8c83-4fd4-bbcf-6719c346825e; manager=29616; authorityEpoch=1; observation=1; at=2026-11-12T18:42:24.6389839+00:00.
Authority accepted: boundary=manager pre-check; offeredEpoch=1; currentEpoch=1; at=2026-11-12T18:42:24.6408354+00:00.
Experiment paused: after Start decision; before process creation; starts this manager=0; resumeEvent=Local\ControlPlaneExperiment-Day33-1d806c6420184196b13b5f00debd34cd; at=2026-11-12T18:42:24.6409843+00:00.
```

At that gate there were zero matching realizations. A was alive and had
passed its manager-only check. Its absence observation and decision were
valid when made.

The external source then reported:

```text
Authority advance requested: offeredEpoch=2; at=2026-11-12T18:42:24.8645477+00:00.
Authority advanced: previousEpoch=1; currentEpoch=2; at=2026-11-12T18:42:24.8727699+00:00.
```

B observed `Stopped` at `18:42:25.2559350Z`, decided Start at
`18:42:25.2563080Z`, passed its manager pre-check at `18:42:25.2581354Z`,
and passed the process-creation check at `18:42:25.2599762Z`.

Selected B output:

```text
Manager=28328; recovered workload=ee4498e2-8c83-4fd4-bbcf-6719c346825e; desired=Running; managerStartTicks=639301057448923522; authorityEpoch=2.
Action=start returned; pid=33112; startTicks=639301057452627466; runId=9653c132-06a0-44b7-92dc-aa837d2b43f2; readiness not yet observed.
Observation 2: fresh=Starting; workload=ee4498e2-8c83-4fd4-bbcf-6719c346825e; pid=33112; startTicks=639301057452627466; runId=9653c132-06a0-44b7-92dc-aa837d2b43f2; manager=28328; authorityEpoch=2; at=2026-11-12T18:42:25.4604054+00:00.
Observation 8: fresh=Running; workload=ee4498e2-8c83-4fd4-bbcf-6719c346825e; pid=33112; startTicks=639301057452627466; runId=9653c132-06a0-44b7-92dc-aa837d2b43f2; manager=28328; authorityEpoch=2; at=2026-11-12T18:42:26.5946803+00:00.
Converged: two matching observations; starts this manager=1; pid=33112.
```

Observation 7 was already Running at `18:42:26.4016519Z`. External inspection
then found exactly B's one live ready incarnation. A was still paused alive.

The test released A at `18:42:26.7223436Z`. A continued the same decision:

```text
Experiment resumed: continuing decided Start without rediscovery; at=2026-11-12T18:42:26.7236467+00:00.
```

Its unhandled error was now:

```text
Authority rejected: boundary=process creation; offeredEpoch=1; currentEpoch=2; at=2026-11-12T18:42:26.7262250+00:00.
```

A exited `-532462766`. It had exactly one observation, one Start decision,
and zero returned Starts. It never accepted the process-creation boundary,
created a matching child, converged, or cooperatively relinquished.
This was rejection, not a second Start followed by duplicate cleanup.

B remained alive. Its fresh, post-rejection observation was:

```text
Observation 21: fresh=Running; workload=ee4498e2-8c83-4fd4-bbcf-6719c346825e; pid=33112; startTicks=639301057452627466; runId=9653c132-06a0-44b7-92dc-aa837d2b43f2; manager=28328; authorityEpoch=2; at=2026-11-12T18:42:29.0724853+00:00.
```

Independent inspection again found exactly that incarnation, alive and
ready. B did not encounter duplicate ambiguity. The recorded epoch remained
`2`, and intent bytes were unchanged.

This tests the limitation of the manager pre-check directly: it had passed
under 1, but did not make A's later operation current under 2. I did not build
a separate manager-only variant and claim a second duplicate reproduction.
Day 3.2 already preserves raw creation without enforcement; here the later
boundary is what rejects the resumed decision.

## Current authority can still recover

While B still held epoch 2, the test killed its verified original incarnation.
B freshly observed Stopped at `18:42:34.5662088Z` and decided another Start.
Its creation boundary accepted epoch 2 at `18:42:34.5668344Z`.

| Realization | PID | UTC process-start ticks | Run ID |
|---|---|---|---|
| Original B realization | 33112 | 639301057452627466 | 9653c132-06a0-44b7-92dc-aa837d2b43f2 |
| B's replacement | 10924 | 639301057545685633 | 17b6de0c-869b-4df3-8aa3-38209e9a4437 |

```text
Action=start returned; pid=10924; startTicks=639301057545685633; runId=17b6de0c-869b-4df3-8aa3-38209e9a4437; readiness not yet observed.
Observation 47: fresh=Running; workload=ee4498e2-8c83-4fd4-bbcf-6719c346825e; pid=10924; startTicks=639301057545685633; runId=17b6de0c-869b-4df3-8aa3-38209e9a4437; manager=28328; authorityEpoch=2; at=2026-11-12T18:42:35.8839890+00:00.
Converged: two matching observations; starts this manager=2; pid=10924.
Authority relinquished: epoch=2; manager=28328; starts this manager=2; workload left untouched.
```

Observation 46 was Running at `18:42:35.6949479Z`. Inspection found exactly
one ready replacement. B's two cumulative Starts were the legitimate
original and legitimate replacement, not a duplicate pair. It exited zero
only after the test requested relinquishment.

## The raw check-to-spawn interval

The second intent was `6074e781-9670-4388-ac61-7a108173ce80`, again with only
`Desired: Running`. Its independent `check-to-spawn.epoch` was initialized
to 1 at `18:42:36.3302895Z`.

| Manager | Epoch | PID | UTC process-start ticks | Final exit |
|---|---|---|---|---|
| A | 1 | 28152 | 639301057563395239 | 0, requested relinquishment |
| B | 2 | 20948 | 639301057570158623 | 0, requested relinquishment |

A observed Stopped at `18:42:36.6863247Z`, decided Start at
`18:42:36.6866768Z`, and passed its manager pre-check at `18:42:36.6885561Z`.
Inside `Workload.Start` it then logged:

```text
Authority accepted: boundary=process creation; offeredEpoch=1; currentEpoch=1; at=2026-11-12T18:42:36.6903920+00:00.
Experiment paused: after boundary authority check; before Process.Start; authorityEpoch=1; resumeEvent=Local\ControlPlaneExperiment-Day33-24914da6e3004ad995e2133f29bba695; at=2026-11-12T18:42:36.6908464+00:00.
```

There were still zero matching processes. This pause was after the actual
boundary check, not merely after the manager's earlier check.

The external epoch-2 source reported:

```text
Authority advance requested: offeredEpoch=2; at=2026-11-12T18:42:36.8821267+00:00.
Authority lock waiting: offeredEpoch=2; at=2026-11-12T18:42:36.8864717+00:00.
```

The test inspected the grant file: it still contained exactly `1`. A and
the source process were alive, and the gate was still unsignaled. Epoch 2
had been requested, not granted.

Release was recorded at `18:42:36.8908789Z`. A's output:

```text
Experiment resumed: locked process creation; at=2026-11-12T18:42:36.8909744+00:00.
Action=start returned; pid=30772; startTicks=639301057568938928; runId=5b53b7a0-d988-41c3-8342-5cec153bac37; readiness not yet observed.
```

That native start time is `18:42:36.8938928Z`. Only afterward did the source
report:

```text
Authority advanced: previousEpoch=1; currentEpoch=2; at=2026-11-12T18:42:36.9057461+00:00.
```

The committed grant was ordered after OS creation. A then cooperatively
exited with one Start, leaving its child untouched. B/epoch 2 adopted it:

```text
Observation 1: fresh=Starting; workload=6074e781-9670-4388-ac61-7a108173ce80; pid=30772; startTicks=639301057568938928; runId=5b53b7a0-d988-41c3-8342-5cec153bac37; manager=20948; authorityEpoch=2; at=2026-11-12T18:42:37.3718318+00:00.
Observation 6: fresh=Running; workload=6074e781-9670-4388-ac61-7a108173ce80; pid=30772; startTicks=639301057568938928; runId=5b53b7a0-d988-41c3-8342-5cec153bac37; manager=20948; authorityEpoch=2; at=2026-11-12T18:42:38.2824781+00:00.
Converged: two matching observations; starts this manager=0; pid=30772.
```

Observation 5 was Running at `18:42:38.0937570Z`. Exactly that one ready
incarnation existed. B issued zero Starts and later relinquished with exit
zero. Intent bytes were unchanged.

The old accepted creation was allowed to become ready after the handoff.
There is no attempt here to invalidate a surviving realization merely
because its creator used the earlier authority. This is compatible with
Day 3.1's continuity.

## Authority validation and state inspection

Before the first scenario's A was launched, a manager offering epoch 3 while
the recorded grant was 1 was rejected at the manager pre-check, with zero
children and zero Starts:

```text
Authority rejected: boundary=manager pre-check; offeredEpoch=3; currentEpoch=1; at=2026-11-12T18:42:22.3736092+00:00.
```

After the stale rejection, an external attempt to regress the current grant
from 2 to 1 failed:

```text
Authority rejected: boundary=grant; offeredEpoch=1; currentEpoch=2; at=2026-11-12T18:42:29.2752571+00:00.
```

Regranting 2 also failed as non-increasing. Granting 0 failed positive-epoch
validation. All were nonzero exits, not successful no-ops. The source file
remained `2` after those attempts.

Both intent files retained exactly their initial `WorkloadId` and `Desired`
properties. The test compares Base64 encodings of the actual byte arrays,
not parsed JSON equality or text with normalized line endings. Neither
handoff, stale rejection, nor legitimate recovery changed those bytes.
No operational observation, incarnation, or authority field was added to
workload intent.

## How this differs from Day 3.1 and Day 3.2

Day 3.1 obtained exclusion by waiting for clean manager exit. An epoch was
an identifier, not an enforced right.

Day 3.2 deliberately kept A alive and resumed its valid earlier decision
after B converged. The descriptive epoch did not prevent a second child;
later discovery correctly reported ambiguity.

Day 3.3 keeps that overlap in the first experiment. What changes is a
separate current-grant record and enforcement around the effect. A's old
decision now fails before creation; discovery does not have to repair a
duplicate afterward.

The second experiment distinguishes a requested handoff from a completed
one. The epoch file cannot advance during accepted creation because the
external source obeys the same boundary. This is stronger than an unlocked
last-moment check, but narrower than arbitrary revocation.

The old notebooks and `tests\day-03.2.ps1` were left untouched. The complete
runner exports `a7665e70817b9261467ab7caaf20919e78f63d4d` and reproduces
Day 3.2's failure there. It also retains the Day 1 `0ab3e5c` and Day 2.1/2.2
`ab24103` exports, then runs current Day 2.3, Day 3.1, and Day 3.3.

## What surprised me

The stale rejection itself was expected. I am not claiming to have discovered
fencing independently.

The useful distinction was between asking for authority and making it
current. Holding the local boundary closed the tested check-to-spawn
interval by delaying the grant, not by teaching Windows to reject a stale
process-creation call.

That let the first experiment reject the old decision while the second
preserved an already accepted child. Those are different outcomes, and
neither required putting creator authority into durable workload intent.

## What became uncomfortable

The source must cooperate. A command without the authority file, a direct
raw `Process.Start`, an out-of-protocol file writer, or a differently named
mutex can bypass this protection. The path must name the same file without
aliases, and participants must share the Windows session. This is not
authentication, hostile-process isolation, arbitrary remote-host fencing,
or distributed consensus.

There is a liveness price: a stalled accepted creation can hold up the next
grant. No timeout or lease secretly converts that unfinished creation into
a safely revoked operation. Readiness is outside the lock, so it does not
block grant movement.

The scalar survives ordinary process exit, but recovery of the authority
source after state loss, abandoned-lock behavior, interruption during
creation, and power-loss durability were not tested. No exception handler
converts such uncertainty into acceptance. Deleting the grant file destroys
the history needed to enforce monotonicity.

This also is not general single-realization exclusion. Two managers
incorrectly offered the same current epoch could both decide from absence;
the mutex does not make discovery and creation one transaction. Other side
effects have not been fenced. The successful cases do not establish an
answer to those separate questions.

## What I currently believe

**Prior:** authority generations can require enforcement at the operation
boundary, and an unlocked check can leave a check/effect interval.

**Observed:** A passed its manager check under 1, then was rejected at
creation under recorded 2. B retained its original incarnation, remained
healthy, and replaced a later killed child under 2. In the opposite ordering,
a grant request actually blocked behind the locked creation; its commit
followed the child's native start time. Both intent files stayed byte-for-byte
unchanged.

**Interpretation:** for this cooperative, same-session local process model,
the authority source and process-creation boundary can share a small
ordering mechanism. A manager-only acceptance is not a lasting right to
perform an effect. This is a demonstrated local boundary, not a final
universal authority contract.

## Validation and checkpoint

```powershell
dotnet build .\ControlPlaneExperiment.slnx
pwsh -NoLogo -NoProfile -File .\tests\day-03.3.ps1
pwsh -NoLogo -NoProfile -File .\tests\all.ps1
```

The build passed with **zero warnings and zero errors**. After adding precise
rejection timestamps, the focused test passed twice on the final code.
The complete suite then passed twice in separate fresh PowerShell shells.
An earlier focused rehearsal also passed; it is not the final evidence.

| Run on final code | Original B PID | Replacement PID | Serialized-creation PID | Stale A / B exit |
|---|---|---|---|---|
| Focused first pass | 22964 | 28524 | 30752 | -532462766 / 0 |
| Focused repeat | 31136 | 11404 | 5032 | -532462766 / 0 |
| First complete suite | 29236 | 3796 | 33716 | -532462766 / 0 |
| Fresh-shell complete repeat | 33112 | 10924 | 30772 | -532462766 / 0 |

Both complete runs preserved the historical Day 2.2 and Day 3.2 failures
while passing the current checks. No historical failure was redefined as
success under the new mechanism.

The full final Day 3.3 logs and result JSON were copied to session artifacts
before runtime cleanup. Nine newly created root `.state\day-*` directories
were inspected and removed. The runner removed its own two historical
scratch trees. The four pre-existing directories were preserved:

```text
day-02.1-0df68c90ae904b62aed616e988d86c65
day-02.1-4511ebcf25b141c9946070511267fa87
day-02.1-5b5b61f45a714a77bebf50bd166aa768
day-02.2-c54ab60795e140caa03ec662db850385
```

Independent process inspection found zero remaining experiment managers or
child `dotnet` processes. `git diff --check` passed. This checkpoint is one
commit on `main`, directly after `a7665e7`; nothing was pushed.

## Questions earned by this checkpoint

What must the authority source do if a process disappears during accepted
creation, or if its ordering history becomes unavailable?

When would delaying a grant behind unfinished creation be unacceptable,
requiring a different downstream enforcement contract?

What assumptions are needed about one manager per granted epoch, and what
would justify making discovery and creation one transaction?

These are questions left by Day 3.3, not permission to build their answers
into this checkpoint. I stop here without starting Day 3.4 or Day 4.
