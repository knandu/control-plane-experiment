# Day 2.1

## What I'm bringing into this experiment

The single-management-authority model and the idea of durable, eventually
cluster-visible platform state come from the original architecture. They are
hypotheses being re-tested here, not discoveries made by this repository.
For this checkpoint there is one manager, by assumption, not by election or
enforcement. A local file is not a cluster-visible store.

## The question

Can durable intent survive management-process lifetime while reconciliation
remains the responsibility of a single authority?

Before implementation, I expect a workload locator to need persistence, but
not the manager's process handle, readiness-read task, or loop counters. I do
not yet know whether a remembered start operation will be needed. A saved
observation should be evidence of an earlier observation, not current truth.

## What I changed

Kept one executable and added one passive JSON file store. Its whole boundary:

```csharp
interface IPlatformStore
{
    PlatformState? Load();
    void Save(PlatformState state);
}
```

`Load` returns null for an absent file; malformed state fails, rather than
resetting intent. `Save` writes and flushes a sibling temporary file, then
replaces the state file. This is a local process-restart experiment, not a
power-loss or shared-filesystem durability claim.

Durable `PlatformState` contains:

- `WorkloadId`: identity of the one logical workload.
- `Desired`: currently only `Running` is supported.
- `Workload`: locator for an incarnation: PID, UTC process-start ticks, and
  a random run ID. PID alone would not distinguish PID reuse.
- `LastObservation`: state and UTC timestamp of the last observation.

The `intent <state-file>` command records initial intent while no manager is
running; it refuses to overwrite an existing record. `manage <state-file>`
loads that state and runs the single reconciliation loop until terminated.
Intent is read once per manager lifetime; live intent editing is not supported.

The manager opens the identified process again on each observation and checks
its start time. Readiness is a Windows named event held by the child, named
with its run ID. The event is a readiness signal, not an authority lock. The
child does not read or write platform state or interpret global intent.
No manager-owned pipe needs to survive. No worker-directive model was added.

Process handles, event handles, loop counters, and the per-manager start count
remain transient. No operation ledger is restored. Manager exit deliberately
does not kill the child. After two matching observations it reports convergence
but continues observing. Startup still has a 100-pending-observation bound.
The optional startup-delay argument only exposes the pending period.

## Experiments

Built the full solution with SDK 10.0.404 / `net10.0`: zero warnings and errors.
There was no existing test suite. Added `tests/day-02.1.ps1`, a dependency-free
PowerShell 7 process test, not a simulated store or workload. All four scenarios
passed, then passed again from a fresh PowerShell shell. No experiment children
remained after cleanup. It force-terminates only the known manager PID, not its process tree,
before starting a fresh manager. It explicitly cleans up identified children
after each scenario and leaves captured logs and JSON in ignored `.state`.

| Run | Actual observations and actions |
| --- | --- |
| Clean baseline | Manager 14612 observed `Stopped`, issued one start for PID 24992, observed `Starting`, then `Running`, and persisted Running evidence. |
| Restart after readiness | Managers 21932 then 21020 used child PID 14392 with identical start ticks and run ID. Second manager freshly observed `Running`; zero starts. |
| Restart while pending | With a 3000 ms child delay, manager 11908 persisted `Starting` and was killed. Manager 10536 freshly observed `Starting` for the same PID 10328; observation 27 was `Running`, and 28 confirmed it. Zero starts in the second manager. |
| Saved observation made stale | After manager 33220 stopped, killed its ready child PID 15244 without changing saved `Running`. Manager 26492 read that evidence, freshly observed `Stopped`, started PID 19680, then converged. Same logical workload ID, new incarnation. |

This restart-after-readiness snapshot is actual saved state before restart:

```json
{
  "WorkloadId": "b8e34d39-3501-4799-90aa-f947432cfa77",
  "Desired": "Running",
  "Workload": {
    "ProcessId": 14392,
    "StartTimeUtcTicks": 639300910839487254,
    "RunId": "174d73a9-f172-49e8-9320-07d282727420"
  },
  "LastObservation": {
    "State": "Running",
    "At": "2026-11-12T14:38:04.722792+00:00"
  }
}
```

After restart, the locator and intent were unchanged; observation time advanced
to `2026-11-12T14:38:05.0525424+00:00`. Selected second-manager output:

```text
Saved observation=Running; not current truth.
Observation 1: fresh=Running; evidence persisted.
Converged: two matching observations; starts this manager=0; pid=14392.
```

The stale-observation run instead produced:

```text
Saved observation=Running; not current truth.
Observation 1: fresh=Stopped; evidence persisted.
Action=start returned; locator persisted; pid=19680; readiness not yet observed.
Converged: two matching observations; starts this manager=1; pid=19680.
```

These are separate steps: `intent` saves intent, process start returns,
the locator is saved, a later observation checks process/event reality and
saves evidence, then two matching observations report convergence. The JSON
is a snapshot, not an operation history.

Reproduce the automated runs from the repository root:

```powershell
dotnet build .\ControlPlaneExperiment.slnx
pwsh -NoProfile -File .\tests\day-02.1.ps1
```

The first run's complete captured evidence is under
`.state\day-02.1-4511ebcf25b141c9946070511267fa87`. The concrete excerpts above
preserve the result in Git; ignored evidence files are not required to run it.

For a manual run, use the README commands. Stop the manager before running
`manage` again. At the end, with no manager running, clean up only the exact
identified child (the JSON intentionally still records its earlier observation):

```powershell
$state = Get-Content -Raw .\.state\platform.json | ConvertFrom-Json
$child = Get-Process -Id $state.Workload.ProcessId -ErrorAction Stop
if ($child.StartTime.ToUniversalTime().Ticks -ne $state.Workload.StartTimeUtcTicks) {
    throw 'PID now identifies a different process; refusing cleanup.'
}
Stop-Process -Id $child.Id
```

## What surprised me

Nothing surprising in these runs. Ready and pending restarts both followed
the expected path. This is limited evidence for a cooperative local child,
not proof that restart ownership is solved.

## What became uncomfortable

- Starting a process and saving its locator are not one operation. Death after
  process creation but before that save can leave an unrecorded child. A new
  manager with no locator reports `Stopped` and may duplicate it. The startup
  test killed the manager *after* locator persistence; it did not test this
  smaller gap. I have not solved or experimentally measured that gap.
- `Stopped` still means "no live process matching my saved locator," not
  "there is no workload on this machine." This is observation of a known
  incarnation, not general discovery.
- The old readiness pipe could not survive the manager. The replacement
  event can, but is local to the Windows session. Host/session movement is
  untested and unsupported. A live, signaled event still means one-time
  readiness, not current application health.
- `LastObservation` helps a reader see what management believed, but is not
  required to choose the next action. Rewriting it every 100 ms is deliberately
  crude. Calling it authoritative current state would be misleading.
- A failed save stops management but does not stop its child. Store I/O failure
  and process-exit-during-observation races have not been injected.
- One manager is a test precondition. The snapshot store offers no concurrency
  control. `IPlatformStore` is sufficient for these runs, but it does not make
  the eventual cluster-visible-state hypothesis true.

## What I currently believe

Observed: durable intent and the locator survived fresh manager processes;
both ready and pending children were reused without another start. Persisted
`Running` did not override a fresh `Stopped` observation. No persisted
"operation issued" flag was needed on these tested paths.

Interpretation: separating remembered evidence from live observation is useful
here. The locator does real work at restart; the last observation is historical
context. The start/save gap limits that interpretation. These results do not
establish that one management authority or this store shape is generally right.

## Questions for Day 2.2

Questions raised by the evidence, not a selected next experiment:

- What can a manager know if it dies between process creation and locator save?
- Can an existing but unrecorded incarnation be distinguished from absence
  without relying on a remembered successful start?
- Is the last observation worth persisting for management, or only for evidence?
- What should one-time readiness mean when the process later stops doing work?

No Day 2.2 implementation or recommendation is made at this checkpoint.
