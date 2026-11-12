# Day 2.3

## The question Day 2.2 earned

Intent and the workload survived, but their relationship did not. What is the
smallest observable logical identity that lets a fresh manager recover that
relationship without remembering a successful Start?

## What reality exposed before the change

Recorded before implementing new identity or discovery:

The original PID 4960 was cleaned up in Day 2.2, so I created one equivalent
interrupted-save child with the unchanged Day 2.2 implementation. Manager 28400
created PID 25416 and was killed before saving its locator. Durable intent was
`c4d76faf-5d5d-4ac8-9e0f-a0c43b2eac99`; the saved locator was null.

A fresh OS process enumeration found PID 25416. Its start time was
`639300957374894259` UTC ticks and its run ID was
`fb355f57-fdd5-4556-8479-6003e49f5f03`. Its readiness event was signaled.
Its live command-line arguments ended with:

```text
--workload fb355f57-fdd5-4556-8479-6003e49f5f03 500
```

They did not contain the logical workload ID. The old manager's
`Observe(null)` also never enumerated processes. So finding a process was
possible, but the current observer neither discovered unknown incarnations
nor had observable logical identity with which to correlate this one.
The test knew the relationship from watching the predecessor; a new manager
did not. No additional durable state was used for this inspection.

## What I expected

Hypothesis, recorded before implementing the change: perhaps putting the
logical workload ID in process-visible launch arguments will let a manager
enumerate, correlate, and adopt a live incarnation without a saved locator.
At that point I had not demonstrated that this was enough, or that it made
any stored field unnecessary.

## The smallest identity mechanism I tried

The child launch now includes the durable logical workload ID:

```text
dotnet <this assembly> --workload <logical-workload-id> <run-id> <startup-delay-ms>
```

The logical ID answers which desired thing this process realizes. The
separate run ID, PID, and process start time identify its current incarnation.
The transient C# locator value is now named `WorkloadIncarnation`, not
`WorkloadIdentity`.

The manager directly queries Windows `Win32_Process` through the
`System.Management` 10.0.0 package. Each observation enumerates `dotnet.exe`
in the manager's Windows session, parses its live command line using
`CommandLineToArgvW`, and requires this exact assembly path, child-mode
argument shape, and logical workload GUID. There is no general discovery
interface or workload registry.

For a candidate, it opens the process, checks it has not exited, obtains its
actual start time, and compares that with WMI's creation time at WMI's
microsecond precision. This prevents attaching old enumerated launch
metadata to a reused PID. It then rechecks the incarnation and reads the
existing child-held `Local\ControlPlaneExperiment-<run-id-without-hyphens>`
readiness event. Missing or unsignaled readiness means Starting, not Running.
More than one live match is an explicit error, not an arbitrary selection.
Inspection errors fail explicitly rather than being converted to absence.

These are launch arguments supplied as part of OS process creation, not a
manager-written file after creation. They remain observable if the manager
dies before recording anything and even before the child executes its
startup code. They name the logical workload, not the manager or the Start
operation. The event is still only readiness evidence; it does not supply
the logical relationship.

## Repeating the crash

The original pause flag remains disabled by default:
`CONTROL_PLANE_PAUSE_BEFORE_LOCATOR_SAVE=1`. In the final implementation it
pauses immediately after creation at the former save boundary; there is no
locator save afterward. Its log calls this the "former pre-locator-save
pause." The earlier retained-field run is recorded below, so this is not
claiming a save existed after it was removed.

The final fresh-shell complete-suite run on November 12, 2026:

1. Started with a new state file containing Running intent for
   `2a5be304-4b6b-4b6e-a8ed-552eb4c3c4d5`.
2. Manager 10364 freshly observed no matching process and issued one Start.
3. It returned PID 23080, start ticks `639300968007368928`, run ID
   `b90e9777-eb09-4ee7-ac10-40aaecd7c6ae`, then paused.
4. The test terminated manager 10364 before the old locator-save position.
   The durable file still contained only intent.
5. External inspection independently verified that 23080 was alive, its
   command line exposed that logical workload ID, and its readiness was
   signaled.
6. Fresh manager 9384 enumerated that same PID/start time/run ID, observed
   Running, and converged after two observations with zero Starts.
7. External enumeration found exactly one matching process. Across both
   managers there was one Start and no duplicate. Reconciliation left the
   original intent JSON byte-for-byte unchanged.

The first successful run with the old durable fields still present is also
recorded below. Recovery did not depend on first removing those fields.

## Challenging the identity

The same complete-suite run exercised these cases. "Starts" counts manager
operations; test-seeded children are identified separately.

| Case | Fresh evidence and result |
|---|---|
| Existing interrupted-creation child | PID 23080, ready; restart Starts = 0; one matching process |
| Both saved fields absent | Same PID 23080 and run ID, ready; Starts = 0 |
| Contradictory saved evidence | Saved locator pointed at another ready workload; saved state said Stopped; fresh matching PID 23080 adopted; Starts = 0 |
| Child killed while management absent | Old saved Running and even a retained signaled old event did not count as existence; first observation Stopped; exactly one replacement, PID 30756 |
| Unrelated process | Ready PID 32544 ran the same assembly and child mode with a different logical GUID; it was not adopted or killed; desired workload `24c9e36f-af4e-4370-a688-852fd51d6ab3` got one new child, PID 29972 |
| Restart during startup | Workload `06e6eb59-c102-49f0-a6de-ddf849de84ed`, PID 10920; first manager Starts = 1; fresh manager observed Starting then Running on the same incarnation; additional Starts = 0 |
| Never ready | Test seeded PID 33068 for `9e6d5b9e-7f5e-44cf-9669-2c927d3d236e`, using the child's existing `Task.Delay(-1)` behavior; three fresh Starting observations, zero Starts, no convergence |
| Multiple matching children | Test seeded ready PIDs 29196 and 5776 for `4c476da9-2462-45da-bb51-9a04ed9c20a6`; manager failed explicitly, issued zero Starts, and neither selected nor removed a child |

Further incarnation details from that run:

| PID | UTC start ticks | Run ID |
|---|---|---|
| 30756 | 639300968037190260 | c4768c4d-c2b5-4658-9914-9adddd4dca2a |
| 32544 | 639300968026518469 | 24027151-cc62-4e7d-b50a-7f57dc96e1dc |
| 29972 | 639300968052678918 | 974127cb-9841-44e2-adcc-6d5bd1bb884a |
| 10920 | 639300968066850371 | d290420f-c341-4e38-becc-f28258db6be9 |
| 33068 | 639300968122307550 | 22ed52fd-447d-4e2e-9781-e9b76a458589 |
| 29196 | 639300968132439881 | 49efde29-fd28-4149-bdda-2bdcd70ec8ee |
| 5776 | 639300968132519904 | 56dee806-1a1a-4c2c-83b0-3c699ce0b757 |

The unrelated seed's logical ID was
`8b1d9dbe-724a-4010-85c6-62b396db568a`. The locator in the contradictory
history case pointed to that seed, not to the desired workload.

The never-ready test was deliberately bounded: stop management after three
observations and inspect the still-live, unsignaled child. The existing
100-pending-observation exception remains unchanged; this run stopped before
it. No timeout or remediation policy was added, and there is no answer here
to what management should do with an indefinitely Starting workload.

## What still needs to be durable?

The first successful post-change run retained the Day 2.1 four-field state
shape. For workload `39863225-35a8-4555-aa2a-ebf30b1b713c`, manager 32312
created PID 2448, start ticks `639300962036269531`, run ID
`3608b540-f93f-4bfb-9257-f2f478a003c9`, then was killed before saving its
locator. Manager 9396 adopted that same ready incarnation with zero Starts.

Only then did the test rewrite its JSON to contain just WorkloadId and
Desired, omitting both locator and observation fields entirely. Manager 8528
rediscovered the same ready PID with zero Starts. A further restart supplied
a saved locator for unrelated ready PID 14452 and a false saved Stopped
observation: manager 14052 still found PID 2448 and issued zero Starts.

With management down, the test killed 2448, saved the old locator and a
Running observation, and deliberately kept an open handle to its signaled
readiness event. Manager 31520 freshly observed Stopped and issued exactly
one Start: PID 23460, start ticks `639300962068796110`, run ID
`c039e872-1f3b-4b89-bb37-add35e6a47c8`. Neither historical state nor the
still-signaled old event proved that the old process existed.

These are results from before removing either field from PlatformState.
They justify attempting the intent-only simplification, not a claim that
all runtime identity problems are solved.

After those experiments, I removed both `Workload` and `LastObservation`
from authoritative PlatformState, including PID, start ticks, run ID, saved
state, and saved observation time. `IPlatformStore` remains the same passive
Load/Save boundary. Only the intent command saves; reconciliation does not
write operational observations back to it.

The resulting C# state is exactly:

```csharp
sealed record PlatformState(Guid WorkloadId, WorkloadState Desired);
```

A manually inspected durable file, captured at the interrupted-creation
boundary in an intent-only run, was exactly:

```json
{
  "WorkloadId": "2a5be304-4b6b-4b6e-a8ed-552eb4c3c4d5",
  "Desired": "Running"
}
```

WorkloadId must survive because management owns which logical thing it
intends to run; replacing it would change the relationship being requested.
Desired must survive because a live process cannot tell a new manager
whether management still wants it. There are no remaining diagnostic or
incarnation fields in this record.

The distinction after this experiment:

- **Durable management truth:** logical workload ID and desired Running.
- **Diagnostic/history:** timestamped console observations, operation counts,
  test logs, and these notebooks; none is read to make control decisions.
- **Fresh operational observation:** current process enumeration and launch
  arguments, matching logical GUID, PID, process creation/start time, run
  ID, process existence, and readiness-event state.
- **Process-local transient state:** the current discovered incarnation,
  opened handles, observation/convergence counters, and this manager's
  Start count.

No separate category of durable management metadata was needed in this
checkpoint. The PID/start-time/run-ID value is still useful for observing
an incarnation and safe test cleanup, but correctness no longer requires
persisting it. A saved observation was not needed for any control decision.
Timestamped fresh evidence was kept in logs rather than deleted.

Old extra JSON properties are ignored by deserialization, not consulted.
This is not a migration framework: management does not automatically
rewrite historical files to strip their extra fields. Newly created state
serializes only the two fields above.

## What surprised me

The first post-change harness run blocked, rather than producing an
architectural result. I had added stderr capture to management tests, and a
surviving child inherited the pipe's writer; draining it waited for the child
even after the manager was dead. I stopped only that verified experimental
child and restricted stderr capture to the ambiguity test, which issues no
Start. Subsequent runs passed.

There was no demonstrated need for another durable field after adding
observable logical identity. That is a result, not a claim that I had no
prior preference for rediscovery.

## What became uncomfortable

An observable logical GUID does not establish exclusive realization.
The two-match experiment really was ambiguous. Failing explicitly avoids
pretending to converge, but chooses neither adoption nor cleanup semantics.

Readiness can remain signaled after death if someone holds a handle. A
readiness event alone is not existence, logical identity, or current health.
The existing readiness signal is still one-time startup evidence, not a
health protocol.

Discovery is deliberately local: same Windows session, readable WMI
metadata, and exact assembly path. Moving the executable or authority into
another session is not covered. The new dependency is concrete Windows WMI,
not a portable or general identity model. Enumeration and inspection are
also not one atomic snapshot.

The unrelated processes stayed alive until test teardown. There is still
no intent-deletion cleanup policy, identity-reuse policy, or decision for
multiple matches. GUIDs in launch arguments are correlation metadata, not
authentication. None of these experiments enforce the single-authority
assumption or examine stale authority.

## What I currently believe

**Observed:** with one manager, readable local launch metadata, and this
cooperative child, a fresh manager recovered the relationship lost in Day
2.2 without knowing the predecessor's Start history. It adopted both ready
and starting incarnations, rejected stale readiness after process death,
and distinguished another logical workload. Removing the saved locator and
observation did not break those control decisions.

**Interpretation:** making this workload rediscoverable eliminated a need
to make this manager remember more. Intent remains durable; the relationship
to a particular realization can be reconstructed from current reality in
the tested scope. This does not establish a complete identity model.

I reread `experiment-framing.md` after the experiments. Its existing
"Prefer rediscovery over operation history" already frames the question;
these results tested that rule rather than discovering a new methodology.
I left it unchanged.

## Validation and checkpoint

Run the complete suite from a fresh PowerShell 7 shell:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\all.ps1
```

It builds the entire current solution, exports the unmodified Day 1 source
at `0ab3e5c` and Day 2.2 source at `ab24103` into temporary directories, builds
them, runs the Day 1 real-process baseline and all four existing Day 2.1
tests, reproduces Day 2.2's duplicate, and runs all eight current Day 2.3
cases. Historical tests retain their original contracts: the saved-field
assertions and expected duplicate are not falsely applied to repaired code.
The original Day 2.1/2.2 scripts and the old commits remain unchanged.

The complete suite passed twice in separate fresh shells. Current and
historical builds had zero warnings and zero errors. In the final run the
historical failure still produced two independently ready children, PIDs
13000 and 13092, while the current code adopted 23080 without another Start.

Test cleanup uses known incarnations and checks process start times before
killing a PID. Historical snapshots are removed by the runner. Runtime
evidence lives only in ignored per-run directories until inspection and
notebook capture; it is not operational identity storage. Unlike the old
Day 2.1 state-file cleanup example, current teardown cannot recover a PID
from durable state: it must use fresh discovery or an already verified
test incarnation.

After notebook capture, all six Day 2.3 run/inspection directories were
removed, including the incomplete harness run. A final independent process
enumeration found zero experiment managers or children. Earlier checkpoints'
pre-existing ignored evidence was left untouched.

Changes are confined to the identity/discovery code, intent-only state,
test support, this notebook, and the README notebook link. No prior notebook
or framing text was rewritten; no original-system names, code, or
configuration were added.

## Questions for the next checkpoint

- What should one authority do when multiple live incarnations expose one
  logical ID?
- What cleanup belongs to intent removal or identity reuse, rather than
  test teardown?
- What should management do when logical identity is clear but readiness
  never arrives?
- Which parts of the demonstrated correlation survive a change of
  executable location or Windows session?

These are questions earned here, not a selection of Day 2.4. Stop at Day 2.3.
