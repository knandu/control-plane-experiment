using System.ComponentModel;
using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

enum WorkloadState
{
    Stopped,
    Starting,
    Running,
    Degraded
}

sealed record WorkloadIncarnation(int ProcessId, long StartTimeUtcTicks, Guid RunId);

sealed record DiscoveredWorkload(WorkloadState State, WorkloadIncarnation? Incarnation, string? Domain = null);

[SupportedOSPlatform("windows")]
static class Workload
{
    private static string ReadinessName(Guid runId) => $@"Local\ControlPlaneExperiment-{runId:N}";
    private static string StartedName(Guid runId) => $@"Local\ControlPlaneExperiment-Started-{runId:N}";

    public static async Task RunAsync(Guid runId, int startupDelayMs)
    {
        using var readiness = new EventWaitHandle(false, EventResetMode.ManualReset, ReadinessName(runId));
        using var started = new EventWaitHandle(false, EventResetMode.ManualReset, StartedName(runId));
        await Task.Delay(startupDelayMs);
        if (Environment.GetEnvironmentVariable("CONTROL_PLANE_PAUSE_BEFORE_READINESS_EVENT") is { } eventName)
        {
            using var resume = EventWaitHandle.OpenExisting(eventName);
            Console.WriteLine(
                $"Experiment paused: before readiness; runId={runId}; resumeEvent={eventName}; at={DateTimeOffset.UtcNow:O}.");
            resume.WaitOne();
        }
        started.Set();
        readiness.Set();
        await Task.Delay(Timeout.Infinite);
    }

    public static WorkloadIncarnation Start(
        Guid workloadId, int startupDelayMs, string? domain = null, AuthorityGrant? authority = null)
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
        if (domain is not null)
        {
            startInfo.ArgumentList.Add(domain);
        }

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

    public static bool Stop(DiscoveredWorkload victim, AuthorityGrant? authority = null)
    {
        var incarnation = victim.Incarnation
            ?? throw new ArgumentException("Stop requires a discovered incarnation.", nameof(victim));

        bool Skipped(string reason)
        {
            Console.WriteLine(
                $"Termination skipped: reason={reason}; pid={incarnation.ProcessId}; " +
                $"expectedStartTicks={incarnation.StartTimeUtcTicks}; runId={incarnation.RunId}; " +
                $"domain={victim.Domain}; at={DateTimeOffset.UtcNow:O}.");
            return false;
        }

        bool Terminate()
        {
            if (authority is not null
                && Environment.GetEnvironmentVariable("CONTROL_PLANE_PAUSE_AFTER_STOP_AUTHORITY_CHECK_EVENT") is { } eventName)
            {
                using var resume = EventWaitHandle.OpenExisting(eventName);
                Console.WriteLine(
                    $"Experiment paused: after boundary authority check; before Process.Kill; " +
                    $"authorityEpoch={authority.Epoch}; resumeEvent={eventName}; at={DateTimeOffset.UtcNow:O}.");
                resume.WaitOne();
                Console.WriteLine($"Experiment resumed: locked process termination; at={DateTimeOffset.UtcNow:O}.");
            }

            Process process;
            try
            {
                process = Process.GetProcessById(incarnation.ProcessId);
            }
            catch (ArgumentException)
            {
                return Skipped("process no longer exists");
            }

            using (process)
            {
                try
                {
                    if (process.HasExited)
                    {
                        return Skipped("process already exited");
                    }

                    var actualStartTicks = process.StartTime.ToUniversalTime().Ticks;
                    if (actualStartTicks != incarnation.StartTimeUtcTicks)
                    {
                        return Skipped($"incarnation mismatch,actualStartTicks={actualStartTicks}");
                    }

                    process.Kill(entireProcessTree: true);
                    if (!process.WaitForExit(5000))
                    {
                        throw new TimeoutException($"Stopped process {incarnation.ProcessId} did not exit within 5000 ms.");
                    }
                    Console.WriteLine(
                        $"Process terminated: pid={incarnation.ProcessId}; startTicks={actualStartTicks}; " +
                        $"runId={incarnation.RunId}; domain={victim.Domain}; at={DateTimeOffset.UtcNow:O}.");
                    return true;
                }
                catch (InvalidOperationException) when (process.HasExited)
                {
                    return Skipped("process exited before termination");
                }
            }
        }

        return authority is null ? Terminate() : authority.WithCurrent("process termination", Terminate);
    }

    public static DiscoveredWorkload Discover(Guid workloadId)
    {
        var matches = DiscoverAll(workloadId);
        if (matches.Count > 1)
        {
            throw new InvalidOperationException(
                $"Multiple live realizations of workload {workloadId}: " +
                $"{string.Join(", ", matches.Select(match => match.Incarnation!.ProcessId))}. No Start issued.");
        }

        return matches.SingleOrDefault() ?? new DiscoveredWorkload(WorkloadState.Stopped, null);
    }

    public static IReadOnlyList<DiscoveredWorkload> DiscoverAll(Guid workloadId)
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
                if (arguments.Length is not (6 or 7)
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
                        matches.Add(new DiscoveredWorkload(
                            observed, incarnation, arguments.Length == 7 ? arguments[6] : null));
                    }
                }
            }
        }

        return matches.OrderBy(match => match.Incarnation!.StartTimeUtcTicks)
            .ThenBy(match => match.Incarnation!.ProcessId)
            .ThenBy(match => match.Incarnation!.RunId)
            .ToArray();
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
                if (readiness.WaitOne(0))
                {
                    return WorkloadState.Running;
                }

                if (!EventWaitHandle.TryOpenExisting(StartedName(incarnation.RunId), out var started))
                {
                    return WorkloadState.Starting;
                }

                using (started)
                {
                    return started.WaitOne(0) ? WorkloadState.Degraded : WorkloadState.Starting;
                }
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
