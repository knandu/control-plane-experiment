if (args is ["--workload"])
{
    await Task.Delay(500);
    Console.WriteLine("ready");
    await Task.Delay(Timeout.Infinite);
    return;
}

if (args.Length != 0)
{
    throw new ArgumentException("Run without arguments to start the Day 1 experiment.");
}

var desired = WorkloadState.Running;
var matchingObservations = 0;
var startOperations = 0;
await using var workload = new Workload();

Console.WriteLine($"Desired={desired}");

for (var observation = 1; observation <= 100; observation++)
{
    var observed = await workload.ObserveAsync();
    Console.WriteLine($"Observation {observation}: observed={observed}");

    if (observed == desired)
    {
        matchingObservations++;
        Console.WriteLine("Action=none; intent matches this observation.");

        if (matchingObservations == 2)
        {
            Console.WriteLine(
                $"Converged: two matching observations; start operations={startOperations}.");
            return;
        }
    }
    else
    {
        matchingObservations = 0;

        if (observed == WorkloadState.Stopped)
        {
            workload.Start();
            startOperations++;
            Console.WriteLine("Action=start returned; readiness has not yet been observed.");
        }
        else
        {
            Console.WriteLine("Action=none; waiting for startup evidence, not issuing another start.");
        }
    }

    await Task.Delay(100);
}

throw new TimeoutException("The workload did not converge within 100 observations.");
