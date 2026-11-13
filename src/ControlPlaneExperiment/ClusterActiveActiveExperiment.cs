using System.Globalization;
using System.Runtime.Versioning;

// Day 5.4: one WFC-placed manager reconciles Replicas=N across N cluster nodes.
// Projection (experiment-fixed, not persisted): domain-K is realized only on the K-th fence endpoint's node.
// Each node's fence owns an independent generation; the manager mutates nothing until every fence has
// accepted its ADVANCE. That is N independently established fences, not one atomic global grant.
[SupportedOSPlatform("windows")]
static class ClusterActiveActiveExperiment
{
    private const int StartupDelayMs = 1000;

    public static string ObserveLocal(string executionDomain, Guid workload) =>
        string.Join(" ", new[] { "OBSERVED", executionDomain, Environment.MachineName }.Concat(
            Workload.DiscoverAll(workload).Select(match =>
                $"{match.State}|{match.Domain ?? "<none>"}|{match.Incarnation!.ProcessId}|" +
                $"{match.Incarnation.StartTimeUtcTicks}|{match.Incarnation.RunId}")));

    public static string StartLocal(string generationPath, long offered, Guid workload, string executionDomain)
    {
        var child = new AuthorityGrant(generationPath, offered).WithCurrent("process creation",
            () => Workload.Start(workload, StartupDelayMs, executionDomain));
        return $"STARTED domain={executionDomain}; pid={child.ProcessId}; startTicks={child.StartTimeUtcTicks}; runId={child.RunId}";
    }

    public static string StopLocal(string generationPath, long offered, WorkloadIncarnation victim, string executionDomain)
    {
        // Generation answers "may this authority mutate?"; Workload.Stop's PID+start-ticks check answers
        // "is this still the incarnation that was decided on?". Both must pass.
        var stopped = Workload.Stop(new DiscoveredWorkload(WorkloadState.Running, victim, executionDomain),
            new AuthorityGrant(generationPath, offered));
        return $"{(stopped ? "STOPPED" : "SKIPPED")} domain={executionDomain}; pid={victim.ProcessId}; " +
            $"startTicks={victim.StartTimeUtcTicks}; runId={victim.RunId}";
    }

    public static void Manage(string statePath, string cluster, string group, string[] fences)
    {
        var state = new FilePlatformStore(statePath).Load()
            ?? throw new InvalidOperationException("No durable intent exists.");
        var replicas = state.EffectiveReplicas;
        if (state.Desired != WorkloadState.Running || state.WorkloadId == Guid.Empty || replicas != fences.Length)
        {
            throw new InvalidDataException("This experiment requires Running intent with one replica per execution node.");
        }
        var domains = Enumerable.Range(1, replicas).Select(index => $"domain-{index}").ToArray();
        Console.WriteLine($"Projection: {string.Join("; ", domains.Select((domain, index) => $"{domain}->{fences[index]}"))}; " +
            $"workload={state.WorkloadId}; replicas={replicas}; at={Now}.");

        var admitted = new ClusterAuthority(cluster, group).Observe();
        Console.WriteLine($"Admission: local={admitted.LocalNode}; owner={admitted.OwnerNode}; authoritative={admitted.IsAuthoritative}; at={Now}.");
        if (!admitted.IsAuthoritative)
        {
            throw new InvalidOperationException("Cluster admission rejected: not current stable owner.");
        }

        var generations = new long?[replicas];
        var deadline = DateTime.UtcNow.AddMinutes(3);
        for (var round = 1; generations.Any(generation => generation is null); round++)
        {
            for (var index = 0; index < replicas; index++)
            {
                if (generations[index] is not null)
                {
                    continue;
                }
                string reply;
                try
                {
                    reply = ClusterFenceExperiment.Request(fences[index], $"ADVANCE {admitted.LocalNode}", 30000);
                }
                catch (Exception unreachable) when (unreachable is IOException or System.Net.Sockets.SocketException)
                {
                    reply = $"UNREACHABLE {unreachable.Message}";
                }
                Console.WriteLine($"Advance {domains[index]}: round={round}; reply={reply}; at={Now}.");
                if (reply.StartsWith("GENERATION ", StringComparison.Ordinal))
                {
                    generations[index] = long.Parse(reply["GENERATION ".Length..], CultureInfo.InvariantCulture);
                }
            }
            var established = generations.Count(generation => generation is not null);
            Console.WriteLine($"Authority establishment: round={round}; established={established}/{replicas}; " +
                $"effects={(established == replicas ? "permitted" : "withheld")}; at={Now}.");
            if (established < replicas)
            {
                if (DateTime.UtcNow >= deadline)
                {
                    throw new TimeoutException("Authority was not established on every execution domain.");
                }
                Thread.Sleep(2000);
            }
        }
        Console.WriteLine($"Authority usable: generations=[{string.Join(", ", domains.Select((domain, index) => $"{domain}={generations[index]}"))}]; at={Now}.");

        int starts = 0, stops = 0, matching = 0, pending = 0;
        for (var pass = 1; ; pass++)
        {
            var located = new List<(int Index, DiscoveredWorkload Match)>();
            for (var index = 0; index < replicas; index++)
            {
                var reply = ClusterFenceExperiment.Request(fences[index], $"OBSERVE {state.WorkloadId}", 30000).Split(' ');
                if (reply is not ["OBSERVED", var fenceDomain, _, ..] || fenceDomain != domains[index])
                {
                    throw new InvalidDataException($"Unexpected observation from {domains[index]}: {string.Join(' ', reply)}.");
                }
                foreach (var entry in reply[3..])
                {
                    var fields = entry.Split('|');
                    var match = new DiscoveredWorkload(Enum.Parse<WorkloadState>(fields[0]),
                        new WorkloadIncarnation(int.Parse(fields[2], CultureInfo.InvariantCulture),
                            long.Parse(fields[3], CultureInfo.InvariantCulture), Guid.Parse(fields[4])), fields[1]);
                    if (match.Domain != domains[index])
                    {
                        // A realization's domain must agree with the machine it runs on; Day 4's invalid-domain rule.
                        throw new InvalidOperationException(
                            $"Domain placement violation: node of {domains[index]} hosts realization claiming {match.Domain}; " +
                            $"pid={match.Incarnation!.ProcessId}. No Start issued. No Stop issued.");
                    }
                    located.Add((index, match));
                }
            }
            var realizations = located.Select(item => item.Match).ToArray();
            var victim = DomainReconciliation.SelectVictim(realizations, replicas);
            Console.WriteLine($"Pass {pass}: generations=[{string.Join(",", generations)}]; " +
                $"running={realizations.Count(match => match.State == WorkloadState.Running)}; " +
                $"starting={realizations.Count(match => match.State == WorkloadState.Starting)}; live={realizations.Length}; " +
                $"realizations=[{Describe(located, fences)}]; at={Now}.");

            if (victim is null && realizations.Length == replicas && realizations.All(match => match.State == WorkloadState.Running))
            {
                pending = 0;
                if (++matching == 2)
                {
                    Console.WriteLine($"Result=Converged; starts={starts}; stops={stops}; realizations=[{Describe(located, fences)}]; at={Now}.");
                    return;
                }
            }
            else
            {
                matching = 0;
                if (victim is not null)
                {
                    var index = located.Single(item => item.Match == victim).Index;
                    var incarnation = victim.Incarnation!;
                    Console.WriteLine($"Decision=Stop; domain={victim.Domain}; state={victim.State}; pid={incarnation.ProcessId}; generation={generations[index]}; at={Now}.");
                    var reply = Effect(fences[index], $"STOP {generations[index]} {incarnation.ProcessId} {incarnation.StartTimeUtcTicks} {incarnation.RunId}");
                    stops += reply.StartsWith("STOPPED ", StringComparison.Ordinal) ? 1 : 0;
                    pending = 0;
                }
                else if (realizations.Length < replicas)
                {
                    var index = Array.FindIndex(domains, domain => realizations.All(match => match.Domain != domain));
                    Console.WriteLine($"Decision=Start; domain={domains[index]}; generation={generations[index]}; at={Now}.");
                    Effect(fences[index], $"START {generations[index]} {state.WorkloadId}");
                    starts++;
                    pending = 0;
                }
                else
                {
                    Console.WriteLine($"Action=none; waiting for startup evidence, not issuing another Start; at={Now}.");
                }
                if (++pending == 100)
                {
                    throw new TimeoutException("The workload did not converge within 100 pending passes.");
                }
            }
            Thread.Sleep(250);
        }
    }

    private static string Effect(string fence, string request)
    {
        var reply = ClusterFenceExperiment.Request(fence, request, 30000);
        Console.WriteLine($"Effect reply: {reply}; at={Now}.");
        if (!reply.StartsWith("STARTED ", StringComparison.Ordinal) && !reply.StartsWith("STOPPED ", StringComparison.Ordinal)
            && !reply.StartsWith("SKIPPED ", StringComparison.Ordinal))
        {
            // A rejected effect means this authority incarnation is superseded on that domain: stop managing.
            throw new InvalidOperationException($"Effect not performed: {reply}");
        }
        return reply;
    }

    private static string Describe(IEnumerable<(int Index, DiscoveredWorkload Match)> located, string[] fences) =>
        string.Join("; ", located.OrderBy(item => item.Index).Select(item =>
            $"fence={fences[item.Index]},domain={item.Match.Domain},state={item.Match.State},pid={item.Match.Incarnation!.ProcessId}," +
            $"startTicks={item.Match.Incarnation.StartTimeUtcTicks},runId={item.Match.Incarnation.RunId}"));

    private static string Now => DateTimeOffset.UtcNow.ToString("O");
}
