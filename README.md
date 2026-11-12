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

## Day 1

A seven-day experiment exploring control planes, reconciliation, and the gap between intent and operational reality.

This is an experiment, not production software. The current model reconciles
one desired running workload with an owned child process, observing readiness
separately from issuing a start. See the [Day 1 notebook](docs/day-01.md).

With the .NET 10 SDK installed, run these commands from the repository root:

```powershell
dotnet build .\ControlPlaneExperiment.slnx
dotnet run --project .\src\ControlPlaneExperiment --no-build
```

The program exits after two matching observations, or fails after 100
observations without convergence. Observations are separated by 100 ms.
On normal completion or an exception, it terminates its owned child process.
Abrupt controller termination and recovery are not handled.
