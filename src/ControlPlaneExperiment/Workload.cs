using System.Diagnostics;

enum WorkloadState
{
    Stopped,
    Starting,
    Running
}

sealed class Workload : IAsyncDisposable
{
    private Process? process;
    private Task<string?>? readiness;

    public void Start()
    {
        if (process is not null)
        {
            throw new InvalidOperationException("A start has already been issued.");
        }

        var startInfo = new ProcessStartInfo("dotnet")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
            ArgumentList = { typeof(Workload).Assembly.Location, "--workload" }
        };

        process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Process.Start did not return a child process.");
        readiness = process.StandardOutput.ReadLineAsync();
    }

    public async Task<WorkloadState> ObserveAsync()
    {
        if (process is null)
        {
            return WorkloadState.Stopped;
        }

        if (process.HasExited)
        {
            throw new InvalidOperationException(
                $"The workload exited unexpectedly with code {process.ExitCode}; recovery is not implemented.");
        }

        var signal = readiness
            ?? throw new InvalidOperationException("The child process has no readiness observation.");

        if (!signal.IsCompleted)
        {
            return WorkloadState.Starting;
        }

        if (await signal != "ready")
        {
            throw new InvalidDataException("The workload did not send the expected readiness signal.");
        }

        return WorkloadState.Running;
    }

    public async ValueTask DisposeAsync()
    {
        if (process is null)
        {
            return;
        }

        using (process)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await process.WaitForExitAsync(timeout.Token);
            Console.WriteLine("Cleanup: owned child process has exited.");
        }
    }
}
