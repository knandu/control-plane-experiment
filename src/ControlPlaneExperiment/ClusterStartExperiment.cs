using System.Runtime.Versioning;

[SupportedOSPlatform("windows")]
static class ClusterStartExperiment
{
    public static void Pause(string directory, string stage)
    {
        Directory.CreateDirectory(directory);
        Console.WriteLine($"Experiment paused: stage={stage}; at={DateTimeOffset.UtcNow:O}.");
        File.WriteAllText(Path.Combine(directory, stage + ".reached"), DateTimeOffset.UtcNow.ToString("O"));
        var deadline = DateTime.UtcNow.AddMinutes(3);
        while (!File.Exists(Path.Combine(directory, stage + ".release")))
        {
            if (DateTime.UtcNow >= deadline)
            {
                throw new TimeoutException($"Experiment release missing: {stage}.");
            }
            Thread.Sleep(25);
        }
        Console.WriteLine($"Experiment released: stage={stage}; at={DateTimeOffset.UtcNow:O}.");
    }

    public static void Run(string statePath, string cluster, string group, string gates, string pauseAt)
    {
        var state = new FilePlatformStore(statePath).Load()
            ?? throw new InvalidOperationException("No durable intent exists.");
        if (state.Desired != WorkloadState.Running || state.WorkloadId == Guid.Empty || state.EffectiveReplicas != 1)
        {
            throw new InvalidDataException("This experiment requires one named Running realization.");
        }
        var authority = new ClusterAuthority(cluster, group);
        var admitted = authority.Observe();
        Console.WriteLine($"Admission: local={admitted.LocalNode}; owner={admitted.OwnerNode}; authoritative={admitted.IsAuthoritative}; at={DateTimeOffset.UtcNow:O}.");
        if (!admitted.IsAuthoritative)
        {
            throw new InvalidOperationException("Cluster admission rejected: not current stable owner.");
        }
        var observed = Workload.Discover(state.WorkloadId);
        Console.WriteLine($"Observation: state={observed.State}; workload={state.WorkloadId}; at={DateTimeOffset.UtcNow:O}.");
        if (observed.Incarnation is null)
        {
            Console.WriteLine($"Decision=Start; workload={state.WorkloadId}; at={DateTimeOffset.UtcNow:O}.");
            if (pauseAt == "decision")
            {
                Pause(gates, "decision");
            }
            if (pauseAt == "recheck")
            {
                var rechecked = authority.Observe();
                Console.WriteLine($"Boundary recheck: local={rechecked.LocalNode}; owner={rechecked.OwnerNode}; authoritative={rechecked.IsAuthoritative}; at={DateTimeOffset.UtcNow:O}.");
                if (!rechecked.IsAuthoritative) { throw new InvalidOperationException("Recheck rejected non-owner."); }
                Pause(gates, "recheck");
            }
            // Phase A deliberately retains the admitted decision without another authority check.
            var child = Workload.Start(state.WorkloadId, 100);
            Console.WriteLine($"Effect=Start; pid={child.ProcessId}; startTicks={child.StartTimeUtcTicks}; runId={child.RunId}; at={DateTimeOffset.UtcNow:O}.");
        }
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (Workload.Discover(state.WorkloadId).State != WorkloadState.Running)
        {
            if (DateTime.UtcNow >= deadline) { throw new TimeoutException("Workload did not become Running."); }
            Thread.Sleep(25);
        }
        Console.WriteLine($"Result=Running; local={Environment.MachineName}; observedOwner={authority.Observe().OwnerNode}; at={DateTimeOffset.UtcNow:O}.");
        Pause(gates, "complete");
    }
}
