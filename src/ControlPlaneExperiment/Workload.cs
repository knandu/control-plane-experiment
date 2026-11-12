using System.Diagnostics;
using System.Runtime.Versioning;

enum WorkloadState
{
    Stopped,
    Starting,
    Running
}

[SupportedOSPlatform("windows")]
static class Workload
{
    private static string ReadinessName(Guid runId) => $@"Local\ControlPlaneExperiment-{runId:N}";

    public static async Task RunAsync(Guid runId, int startupDelayMs)
    {
        using var readiness = new EventWaitHandle(false, EventResetMode.ManualReset, ReadinessName(runId));
        await Task.Delay(startupDelayMs);
        readiness.Set();
        await Task.Delay(Timeout.Infinite);
    }

    public static WorkloadIdentity Start(int startupDelayMs)
    {
        var runId = Guid.NewGuid();
        var startInfo = new ProcessStartInfo("dotnet")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            ArgumentList =
            {
                typeof(Workload).Assembly.Location, "--workload", runId.ToString(),
                startupDelayMs.ToString(System.Globalization.CultureInfo.InvariantCulture)
            }
        };

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Process.Start did not return a child process.");
        return new WorkloadIdentity(process.Id, process.StartTime.ToUniversalTime().Ticks, runId);
    }

    public static WorkloadState Observe(WorkloadIdentity? identity)
    {
        if (identity is null)
        {
            return WorkloadState.Stopped;
        }

        Process process;
        try
        {
            process = Process.GetProcessById(identity.ProcessId);
        }
        catch (ArgumentException)
        {
            return WorkloadState.Stopped;
        }

        using (process)
        {
            if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != identity.StartTimeUtcTicks)
            {
                return WorkloadState.Stopped;
            }

            if (!EventWaitHandle.TryOpenExisting(ReadinessName(identity.RunId), out var readiness))
            {
                return WorkloadState.Starting;
            }

            using (readiness)
            {
                return readiness.WaitOne(0) ? WorkloadState.Running : WorkloadState.Starting;
            }
        }
    }
}
