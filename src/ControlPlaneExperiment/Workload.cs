using System.ComponentModel;
using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

enum WorkloadState
{
    Stopped,
    Starting,
    Running
}

sealed record WorkloadIncarnation(int ProcessId, long StartTimeUtcTicks, Guid RunId);

sealed record DiscoveredWorkload(WorkloadState State, WorkloadIncarnation? Incarnation);

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

    public static WorkloadIncarnation Start(Guid workloadId, int startupDelayMs, AuthorityGrant? authority = null)
    {
        var runId = Guid.NewGuid();
        var startInfo = new ProcessStartInfo("dotnet")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            ArgumentList =
            {
                typeof(Workload).Assembly.Location, "--workload", workloadId.ToString(), runId.ToString(),
                startupDelayMs.ToString(System.Globalization.CultureInfo.InvariantCulture)
            }
        };

        WorkloadIncarnation Create()
        {
            if (authority is not null
                && Environment.GetEnvironmentVariable("CONTROL_PLANE_PAUSE_AFTER_START_AUTHORITY_CHECK_EVENT") is { } eventName)
            {
                using var resume = EventWaitHandle.OpenExisting(eventName);
                Console.WriteLine(
                    $"Experiment paused: after boundary authority check; before Process.Start; " +
                    $"authorityEpoch={authority.Epoch}; resumeEvent={eventName}; at={DateTimeOffset.UtcNow:O}.");
                resume.WaitOne();
                Console.WriteLine($"Experiment resumed: locked process creation; at={DateTimeOffset.UtcNow:O}.");
            }

            using var process = Process.Start(startInfo)
                ?? throw new InvalidOperationException("Process.Start did not return a child process.");
            return new WorkloadIncarnation(process.Id, process.StartTime.ToUniversalTime().Ticks, runId);
        }

        return authority is null ? Create() : authority.WithCurrent("process creation", Create);
    }

    public static DiscoveredWorkload Discover(Guid workloadId)
    {
        using var current = Process.GetCurrentProcess();
        using var searcher = new ManagementObjectSearcher(
            $"SELECT ProcessId, CreationDate, CommandLine FROM Win32_Process " +
            $"WHERE Name = 'dotnet.exe' AND SessionId = {current.SessionId}");
        using var candidates = searcher.Get();
        var matches = new List<DiscoveredWorkload>();

        foreach (ManagementBaseObject candidate in candidates)
        {
            using (candidate)
            {
                var commandLine = candidate["CommandLine"] as string
                    ?? throw new InvalidOperationException("A candidate process command line could not be inspected.");
                var arguments = SplitCommandLine(commandLine);
                if (arguments.Length != 6
                    || !string.Equals(arguments[1], typeof(Workload).Assembly.Location, StringComparison.OrdinalIgnoreCase)
                    || arguments[2] != "--workload"
                    || !Guid.TryParseExact(arguments[3], "D", out var logicalId)
                    || logicalId != workloadId)
                {
                    continue;
                }

                if (!Guid.TryParseExact(arguments[4], "D", out var runId))
                {
                    throw new InvalidDataException("A matching workload exposed an invalid run ID.");
                }

                Process process;
                try
                {
                    process = Process.GetProcessById(checked((int)(uint)candidate["ProcessId"]));
                }
                catch (ArgumentException)
                {
                    continue; // Exited between enumeration and inspection.
                }

                using (process)
                {
                    if (process.HasExited)
                    {
                        continue;
                    }

                    var startTicks = process.StartTime.ToUniversalTime().Ticks;
                    var creationTicks = ManagementDateTimeConverter.ToDateTime(
                        (string)candidate["CreationDate"]).ToUniversalTime().Ticks;
                    // WMI exposes microseconds; reject a reused PID before trusting its launch metadata.
                    if (startTicks / 10 != creationTicks / 10)
                    {
                        continue;
                    }

                    var incarnation = new WorkloadIncarnation(process.Id, startTicks, runId);
                    var observed = Observe(incarnation);
                    if (observed != WorkloadState.Stopped)
                    {
                        matches.Add(new DiscoveredWorkload(observed, incarnation));
                    }
                }
            }
        }

        if (matches.Count > 1)
        {
            throw new InvalidOperationException(
                $"Multiple live realizations of workload {workloadId}: " +
                $"{string.Join(", ", matches.Select(match => match.Incarnation!.ProcessId))}. No Start issued.");
        }

        return matches.SingleOrDefault() ?? new DiscoveredWorkload(WorkloadState.Stopped, null);
    }

    private static WorkloadState Observe(WorkloadIncarnation incarnation)
    {
        Process process;
        try
        {
            process = Process.GetProcessById(incarnation.ProcessId);
        }
        catch (ArgumentException)
        {
            return WorkloadState.Stopped;
        }

        using (process)
        {
            if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != incarnation.StartTimeUtcTicks)
            {
                return WorkloadState.Stopped;
            }

            if (!EventWaitHandle.TryOpenExisting(ReadinessName(incarnation.RunId), out var readiness))
            {
                return WorkloadState.Starting;
            }

            using (readiness)
            {
                return readiness.WaitOne(0) ? WorkloadState.Running : WorkloadState.Starting;
            }
        }
    }

    private static string[] SplitCommandLine(string commandLine)
    {
        var pointer = CommandLineToArgvW(commandLine, out var count);
        if (pointer == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        try
        {
            return Enumerable.Range(0, count)
                .Select(index => Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer, index * IntPtr.Size))
                    ?? throw new InvalidDataException("Process command line contained a null argument."))
                .ToArray();
        }
        finally
        {
            LocalFree(pointer);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr pointer);
}
