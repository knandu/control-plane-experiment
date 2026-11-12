# Control Plane Experiment

Recently, I built a control-plane-driven system for a very different workload.

It coordinated distributed compute resources: reconciling desired state with running workloads, making placement decisions, publishing available capacity, and recovering as machines and workloads changed.

Once it was working, I started wondering which parts of the architecture were consequences of that particular problem and which parts were more general.

So I'm trying a small experiment.

I'm going to remove the original domain, keep the ideas that seem important, and implement the smallest real system I can that still forces those ideas to confront failure, recovery, and operational state.

I'm giving myself seven logical "days." They're checkpoints rather than calendar days.

I don't know yet what the final architecture will look like.

## Why not just use Kubernetes?

That's an obvious question.

If my goal were simply to run these workloads reliably, Kubernetes would be a reasonable answer. But the system this experiment came from already had a high-availability framework. Adding another orchestrator would have given me two systems with overlapping responsibilities for availability, recovery, and lifecycle.

That made the more interesting question: what was the smallest control plane I actually needed?

This experiment lets me ask that question again, without the original domain getting in the way.

## Running the experiment

A seven-day experiment exploring control planes, reconciliation, and the gap between intent and operational reality.

This is an experiment, not production software. The current model reconciles
one desired running workload with a child process, observing readiness
separately from issuing a start. See the [Day 1 notebook](docs/day-01.md),
[Day 2.1 notebook](docs/day-02.1.md), [Day 2.2 notebook](docs/day-02.2.md),
and [Day 2.3 notebook](docs/day-02.3.md).
The [Day 2 reflection](docs/day-02.md) looks back across those three experiments.
The [Day 3.1 notebook](docs/day-03.1.md) tests clean authority movement without moving the workload.
The [experiment framing](docs/experiment-framing.md)
records rules introduced during Day 2.

With the .NET 10 SDK installed, run these commands from the repository root:

```powershell
dotnet build .\ControlPlaneExperiment.slnx
dotnet run --project .\src\ControlPlaneExperiment --no-build -- intent .\.state\platform.json
dotnet run --project .\src\ControlPlaneExperiment --no-build -- manage .\.state\platform.json
```

Run `intent` only once, with no manager running. Run exactly one manager at a
time. On Windows, it observes every 100 ms and keeps running after convergence;
stop it and repeat only the `manage` command to test recovery. Manager exit
deliberately leaves the child running. The Day 2.1 notebook includes validation
and explicit cleanup commands.
