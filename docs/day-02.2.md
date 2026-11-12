# Day 2.2

## The question

What happens if the manager dies after starting a child but before saving its
locator? Can this implementation recover from intent plus its current way of
observing reality, or does it start a duplicate?

## Before trying it

Day 2.1 identified this gap but did not exercise it. I expect the surviving
child to be invisible to `Observe(null)`, and expect the next manager to start
another child. That is a prediction, not a result yet.

The [experiment framing](experiment-framing.md) was introduced after Day 2.1
and refined before this run. It was not a Day 1 methodology. For this checkpoint
I am reproducing the missing-locator case, not selecting a recovery design.

## What I changed

Added one opt-in pause after `Workload.Start` returns and before `store.Save`
records its locator. Setting `CONTROL_PLANE_PAUSE_BEFORE_LOCATOR_SAVE=1` in
that manager's environment prints the returned locator and waits indefinitely
until the experiment kills the manager. Without that setting, the normal
path is unchanged.

The pause widens a real gap so I can hit it deterministically. It does not
erase previously saved data, fabricate a workload, or repair recovery.

Added `tests/day-02.2.ps1` and extracted the existing Day 2.1 test functions
into `tests/process-helpers.ps1` for reuse. The test removes the pause setting
from ordinary manager launches and enables it only in the first manager.
No store API, durable fields, workload behavior, or discovery mechanism changed.

## The experiment

Ran the clean baseline and all three existing Day 2.1 restart cases first;
all passed. Then ran this sequence, with only one manager alive at a time:

1. Persisted intent for logical workload
   `87f4a2f1-f211-468d-ab0e-e0b8da8e2212`.
2. Manager 25036 observed `Stopped`, saved that observation, and started child
   PID 4960. The injected pause occurred before the locator save.
3. Force-terminated only manager 25036, not its process tree.
4. Read the state file and independently checked that child 4960 was still
   alive and its readiness event was signaled.
5. Started manager 28864 normally against the same state file.
6. It reported `Stopped`, started child 15772, and reported convergence.
7. Independently verified that both 4960 and 15772 were alive with their
   original start times and signaled readiness events. Then terminated both
   identified children as test cleanup.

## What I observed

At the pause, successful process creation and missing durable locator were
visible together:

```text
Action=start returned; locator NOT persisted; pid=4960; startTicks=639300941200276403; runId=2b6e5384-3100-4c1d-99b7-408aa9514ff1; experiment paused.
```

Actual state after killing the first manager, before restart:

```json
{
  "WorkloadId": "87f4a2f1-f211-468d-ab0e-e0b8da8e2212",
  "Desired": "Running",
  "Workload": null,
  "LastObservation": {
    "State": "Stopped",
    "At": "2026-11-12T15:28:40.0159279+00:00"
  }
}
```

The second manager did not recover a locator from this record. Selected output:

```text
Saved observation=Stopped; not current truth.
Observation 1: fresh=Stopped; evidence persisted.
Action=start returned; locator persisted; pid=15772; readiness not yet observed.
Observation 7: fresh=Running; evidence persisted.
Observation 8: fresh=Running; evidence persisted.
Converged: two matching observations; starts this manager=1; pid=15772.
```

External checks after stopping the second manager:

```text
Fresh external observation: pid=4960; alive; readiness signaled.
Fresh external observation: pid=15772; alive; readiness signaled.
LIMITATION REPRODUCED: two live ready children (4960, 15772); one locator; manager reported convergence.
```

The final JSON retained the same intent and logical workload ID, but recorded
only PID 15772 and its new run ID, `8ce76ef9-5386-4f3b-b92d-f7d88bad38cb`.
Its saved observation was `Running` at `2026-11-12T15:28:41.9885142+00:00`.
It said nothing about the still-live original.

The external test learned the orphan locator from the paused manager's output
for observation and safe cleanup. It did **not** put that locator in platform
state or hand it to the next manager.

I also inspected the orphan's live command line. It contained `--workload`,
the random run ID `2b6e5384-3100-4c1d-99b7-408aa9514ff1`, and the startup
delay `500`; it did not contain the logical workload ID. The ready event is
also named by run ID, not logical workload ID.

## What surprised me

The predicted duplicate occurred; I am not claiming a surprise. The concrete
result is narrower and less comfortable than "restart works": management
reported convergence while the test could observe two live ready children.

## What became uncomfortable

- The logged `fresh=Stopped` was not a fresh machine-wide finding of absence.
  `Observe(null)` returns `Stopped` without looking for any process. Its input
  was missing because the locator save had never happened.
- Fresh observation is only as useful as its scope. Here the manager observes
  a *known incarnation*, so it cannot rediscover an unknown one through that
  function.
- The original child exposed its existence, process identity, random run ID,
  and readiness. It did not expose a logical-intent association through the
  command line or event checked here. The test knew that association from
  watching the old manager; the restarted manager had neither that history
  nor the missing locator.
- This is not proof that all OS-level rediscovery is impossible. No general
  process inventory or alternative discovery protocol was tried.
- Two matching observations establish that the recorded incarnation is ready.
  They do not establish that only one incarnation is running for this intent.
- Saving a locator handled the tested Day 2.1 restarts, but the save itself
  has an ordering dependency on the external action. A durable file snapshot
  did not make those two operations one transaction.

## What I currently believe

Observed: the gap produces a surviving unrecorded child, a duplicate start,
and reported convergence with both children still ready. Intent survived;
the association needed by this observer did not.

Interpretation: the current recovery claim depends on locator persistence
having completed. This result identifies a problem, not the right remedy.
It does not yet justify an operation ledger, another durable field, a worker
abstraction, fencing, or a more elaborate store.

Open questions, without choosing another experiment: what identity could
reality expose to associate an unrecorded incarnation with intent? What should
management claim when it cannot establish that association? Would remembering
another intermediate state answer that question or merely move the gap?

## Validation and stopping point

```powershell
dotnet build .\ControlPlaneExperiment.slnx
pwsh -NoProfile -File .\tests\day-02.1.ps1
pwsh -NoProfile -File .\tests\day-02.2.ps1
```

The full build passed with zero warnings and errors. All four existing process
experiments passed. The new test passed by **reproducing the known limitation**,
not by fixing it; it asserts that the duplicate exists. Both test children
were explicitly cleaned up by PID and verified start time.

Logs, pre-restart state, final state, and the external orphan observation are
captured locally under `.state\day-02.2-c54ab60795e140caa03ec662db850385`.
The excerpts here keep the evidence in Git; the ignored files are not needed
to reproduce the run.

Stopping at Day 2.2 with the failure visible. No recovery design is selected
or implemented, and no later checkpoint has been started.
