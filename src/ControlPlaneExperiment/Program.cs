if (!OperatingSystem.IsWindows())
{
    throw new PlatformNotSupportedException("This checkpoint uses a local Windows readiness event.");
}

if (args is ["--workload", var workloadId, var runId, var delay])
{
    _ = Guid.Parse(workloadId);
    await Workload.RunAsync(Guid.Parse(runId), int.Parse(delay));
    return;
}

if (args.Length < 2 || args[0] is not ("intent" or "manage")
    || (args[0] == "intent" && args.Length != 2) || args.Length > 3)
{
    throw new ArgumentException(
        "Usage: intent <state-file> | manage <state-file> [startup-delay-ms]. Run only one manager.");
}

IPlatformStore store = new FilePlatformStore(args[1]);
var state = store.Load();

if (args[0] == "intent")
{
    if (state is not null)
    {
        throw new InvalidOperationException("Platform state already exists; intent will not overwrite it.");
    }

    state = new PlatformState(Guid.NewGuid(), WorkloadState.Running);
    store.Save(state);
    Console.WriteLine($"Intent persisted: workload={state.WorkloadId}; desired={state.Desired}");
    return;
}

if (state is null)
{
    throw new InvalidOperationException("No durable intent exists. Run intent <state-file> first.");
}

if (state.Desired != WorkloadState.Running || state.WorkloadId == Guid.Empty)
{
    throw new InvalidDataException("This checkpoint requires a named workload with Running intent.");
}

var startupDelayMs = args.Length == 3 ? int.Parse(args[2]) : 500;
if (startupDelayMs is < 0 or > 5000)
{
    throw new ArgumentOutOfRangeException(nameof(startupDelayMs), "Use a delay between 0 and 5000 ms.");
}

var matchingObservations = 0;
var pendingObservations = 0;
var startOperations = 0;

Console.WriteLine($"Manager={Environment.ProcessId}; recovered workload={state.WorkloadId}; desired={state.Desired}");
Console.WriteLine("Manager exit leaves the workload running. Terminate it explicitly after the experiment.");

for (var observation = 1; ; observation++)
{
    var fresh = Workload.Discover(state.WorkloadId);
    var observed = fresh.State;
    Console.WriteLine(
        $"Observation {observation}: fresh={observed}; workload={state.WorkloadId}; " +
        $"pid={fresh.Incarnation?.ProcessId}; startTicks={fresh.Incarnation?.StartTimeUtcTicks}; runId={fresh.Incarnation?.RunId}; " +
        $"at={DateTimeOffset.UtcNow:O}.");

    if (observed == state.Desired)
    {
        pendingObservations = 0;
        matchingObservations++;

        if (matchingObservations == 2)
        {
            Console.WriteLine(
                $"Converged: two matching observations; starts this manager={startOperations}; pid={fresh.Incarnation?.ProcessId}.");
        }
    }
    else
    {
        matchingObservations = 0;

        if (observed == WorkloadState.Stopped)
        {
            var started = Workload.Start(state.WorkloadId, startupDelayMs);
            startOperations++;

            if (Environment.GetEnvironmentVariable("CONTROL_PLANE_PAUSE_BEFORE_LOCATOR_SAVE") == "1")
            {
                Console.WriteLine(
                    $"Action=start returned; former pre-locator-save pause; pid={started.ProcessId}; " +
                    $"startTicks={started.StartTimeUtcTicks}; runId={started.RunId}; experiment paused.");
                await Task.Delay(Timeout.Infinite);
            }

            Console.WriteLine(
                $"Action=start returned; pid={started.ProcessId}; startTicks={started.StartTimeUtcTicks}; " +
                $"runId={started.RunId}; readiness not yet observed.");
        }
        else
        {
            Console.WriteLine("Action=none; waiting for startup evidence, not issuing another start.");
        }

        if (++pendingObservations == 100)
        {
            throw new TimeoutException("The workload did not converge within 100 pending observations.");
        }
    }

    await Task.Delay(100);
}
