using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Runtime.Versioning;

// Day 5.3: WFC places management authority; the execution domain's fence decides which authority
// incarnation may still mutate it. Advance and Start are both handled by one serial request loop.
[SupportedOSPlatform("windows")]
static class ClusterFenceExperiment
{
    public static void ServeDomain(
        string cluster, string group, int port, string generationPath, string gates, bool pauseInside,
        string? executionDomain = null)
    {
        var authority = new ClusterAuthority(cluster, group);
        var listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        Console.WriteLine($"Domain fence serving: domain={Environment.MachineName}; " +
            (executionDomain is null ? "" : $"executionDomain={executionDomain}; ") + $"port={port}; at={Now}.");
        var paused = false;
        while (true)
        {
            using var client = listener.AcceptTcpClient();
            using var stream = client.GetStream();
            using var reader = new StreamReader(stream);
            using var writer = new StreamWriter(stream) { AutoFlush = true };
            var request = reader.ReadLine() ?? string.Empty;
            Console.WriteLine($"Domain request: {request}; at={Now}.");
            string reply;
            try
            {
                reply = request.Split(' ') switch
                {
                    ["ADVANCE", var node] => Advance(authority, generationPath, node),
                    ["OBSERVE", var workload] when executionDomain is not null =>
                        ClusterActiveActiveExperiment.ObserveLocal(executionDomain, Guid.Parse(workload)),
                    ["START", var offered, var workload] when executionDomain is not null =>
                        ClusterActiveActiveExperiment.StartLocal(generationPath, long.Parse(offered, CultureInfo.InvariantCulture),
                            Guid.Parse(workload), executionDomain),
                    ["STOP", var offered, var pid, var ticks, var runId] when executionDomain is not null =>
                        ClusterActiveActiveExperiment.StopLocal(generationPath, long.Parse(offered, CultureInfo.InvariantCulture),
                            new WorkloadIncarnation(int.Parse(pid, CultureInfo.InvariantCulture),
                                long.Parse(ticks, CultureInfo.InvariantCulture), Guid.Parse(runId)), executionDomain),
                    ["OBSERVE", var workload] => $"OBSERVED {Workload.Discover(Guid.Parse(workload)).State}",
                    ["START", var offered, var workload] => Start(
                        generationPath, long.Parse(offered, CultureInfo.InvariantCulture), Guid.Parse(workload),
                        pauseInside && !paused ? () => { paused = true; ClusterStartExperiment.Pause(gates, "inside"); } : null),
                    _ => throw new InvalidOperationException("Unknown domain request."),
                };
            }
            catch (InvalidOperationException rejected)
            {
                reply = $"REJECTED {rejected.Message}";
            }
            catch (Exception failed)
            {
                reply = $"ERROR {failed.GetType().Name}: {failed.Message}";
            }
            Console.WriteLine($"Domain reply: {reply}; at={Now}.");
            writer.WriteLine(reply);
        }
    }

    private static string Advance(ClusterAuthority authority, string generationPath, string node)
    {
        // Minting is the only place WFC is consulted: only the node WFC names as owner may advance.
        var observed = authority.Observe();
        Console.WriteLine($"Advance ownership check: requester={node}; owner={observed.OwnerNode}; group={observed.GroupState}; at={Now}.");
        if (!string.Equals(observed.OwnerNode, node, StringComparison.OrdinalIgnoreCase) || observed.GroupState != "Online")
        {
            throw new InvalidOperationException($"Advance refused: requester={node} is not the WFC owner {observed.OwnerNode}.");
        }
        var current = File.Exists(generationPath)
            ? long.Parse(File.ReadAllText(generationPath), CultureInfo.InvariantCulture)
            : 0;
        new AuthorityGrant(generationPath, current + 1).Advance();
        return $"GENERATION {current + 1}";
    }

    private static string Start(string generationPath, long offered, Guid workload, Action? pause)
    {
        var child = new AuthorityGrant(generationPath, offered).WithCurrent("process creation", () =>
        {
            pause?.Invoke();
            return Workload.Start(workload, 100);
        });
        return $"STARTED pid={child.ProcessId}; startTicks={child.StartTimeUtcTicks}; runId={child.RunId}";
    }

    public static void Manage(string statePath, string cluster, string group, string domain, string gates, string pauseAt)
    {
        var state = new FilePlatformStore(statePath).Load()
            ?? throw new InvalidOperationException("No durable intent exists.");
        if (state.Desired != WorkloadState.Running || state.WorkloadId == Guid.Empty || state.EffectiveReplicas != 1)
        {
            throw new InvalidDataException("This experiment requires one named Running realization.");
        }
        var admitted = new ClusterAuthority(cluster, group).Observe();
        Console.WriteLine($"Admission: local={admitted.LocalNode}; owner={admitted.OwnerNode}; authoritative={admitted.IsAuthoritative}; at={Now}.");
        if (!admitted.IsAuthoritative)
        {
            throw new InvalidOperationException("Cluster admission rejected: not current stable owner.");
        }
        Console.WriteLine($"Authority advance requested: domain={domain}; at={Now}.");
        var advanced = Request(domain, $"ADVANCE {admitted.LocalNode}");
        Console.WriteLine($"Authority advance reply: {advanced}; at={Now}.");
        if (!advanced.StartsWith("GENERATION ", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Authority incarnation was not established.");
        }
        var generation = long.Parse(advanced["GENERATION ".Length..], CultureInfo.InvariantCulture);
        var observed = Request(domain, $"OBSERVE {state.WorkloadId}");
        Console.WriteLine($"Observation: {observed}; workload={state.WorkloadId}; generation={generation}; at={Now}.");
        if (observed != "OBSERVED Stopped")
        {
            // Starting/Running/Degraded all mean an incarnation exists; only absence justifies Start.
            Console.WriteLine($"Result=Converged; no effect required; at={Now}.");
            return;
        }
        Console.WriteLine($"Decision=Start; generation={generation}; at={Now}.");
        if (pauseAt == "decision")
        {
            ClusterStartExperiment.Pause(gates, "decision");
        }
        Console.WriteLine($"Effect requested: START generation={generation}; at={Now}.");
        Console.WriteLine($"Effect reply: {Request(domain, $"START {generation} {state.WorkloadId}")}; at={Now}.");
    }

    public static string Request(string domain, string request, int receiveTimeoutMs = 0)
    {
        var separator = domain.LastIndexOf(':');
        using var client = new TcpClient(domain[..separator], int.Parse(domain[(separator + 1)..], CultureInfo.InvariantCulture))
        {
            ReceiveTimeout = receiveTimeoutMs
        };
        using var stream = client.GetStream();
        using var writer = new StreamWriter(stream) { AutoFlush = true };
        using var reader = new StreamReader(stream);
        writer.WriteLine(request);
        return reader.ReadLine() ?? throw new IOException("Domain fence closed without a reply.");
    }

    private static string Now => DateTimeOffset.UtcNow.ToString("O");
}
