# Day 1

## The question

Can a small, single-process controller make the gap between asking for a
workload and observing it running explicit, without needing a framework?

## What I currently believe

Written before implementing the model:

- One desired workload and one child process should be enough to expose a
  reconciliation loop.
- A successful process-start call is not enough evidence that the workload
  is ready. I expect a separate readiness signal to make this visible.
- Repeated observations while startup is pending should not cause repeated
  starts.
- An in-memory desired state and a bounded run should be sufficient for this
  checkpoint. Neither says anything yet about recovery after controller exit.

## What I built

One .NET 10 console executable, using installed SDK 10.0.404 and target
framework `net10.0`. No external packages or test project.

The controller holds `Running` as in-memory desired state. An observation
reports `Stopped` when it owns no child, `Starting` while the child's readiness
read is pending, and `Running` after receiving `ready` while the process has
not exited. A mismatch causes one process-start operation; subsequent pending
observations wait rather than start another process.

The same executable has a child mode: wait 500 ms, write `ready` to standard
output, then stay alive. That delay deliberately exposes startup; it is not
evidence about how real applications initialize. The controller checks every
100 ms, accepts two matching observations, and fails if 100 observations do
not converge. Each reconciliation pass issues at most one start.

Unexpected exit or invalid readiness fails explicitly, without recovery.
Structured cleanup kills the owned child and waits up to five seconds for
exit. This is experiment teardown, not reconciliation of stopped intent.

## What I observed

On Windows, `dotnet build .\ControlPlaneExperiment.slnx` succeeded with zero
warnings and errors. The README run command then completed successfully.
There are no automated tests; this checkpoint's evidence is the real process
run, not a simulated lifecycle.

In the first run, observation 1 was `Stopped`, observations 2 through 6 were
`Starting`, and observations 7 and 8 were `Running`. Exactly one start was
issued. Selected output:

```text
Desired=Running
Observation 1: observed=Stopped
Action=start returned; readiness has not yet been observed.
Observation 2: observed=Starting
Action=none; waiting for startup evidence, not issuing another start.
```

Later in that same run:

```text
Observation 7: observed=Running
Action=none; intent matches this observation.
Observation 8: observed=Running
Action=none; intent matches this observation.
Converged: two matching observations; start operations=1.
Cleanup: owned child process has exited.
```

The initial model held up for this cooperative startup. The start operation
returned before readiness was observed. This does not yet demonstrate
recovery, independent workload discovery, or durable intent.

## What feels unresolved

- `Running` means "has signaled ready and has not been observed exiting."
  The second matching observation reuses the same readiness signal; it is
  not a fresh health check, and the child could exit just after observation.
- `Stopped` means no child owned by this controller, not an inventory of
  workloads on the machine.
- The observation-count bound is not a hard wall-clock deadline for every
  operating-system call.
- Unexpected child exit is an error, not a recovered state. No failure was
  injected in this checkpoint.
- Intent and the child handle disappear with the controller. Abrupt controller
  termination may leave a child behind; structured cleanup does not solve that.

## Possible next experiment

What does the controller observe if the child exits after signaling readiness,
and is "fail the run" still a useful response? That is a question to test,
not a decision yet to add a recovery framework.
