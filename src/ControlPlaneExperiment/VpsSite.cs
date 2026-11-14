using System.Globalization;
using System.Net;
using System.Runtime.Versioning;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

// Day 5.5: administrator-authored virtual HTTP site intent, realized by the Day 5.4 fenced reconciler.
// Durable intent is only what the administrator asked for. Everything operational (processes, RunIds,
// health, node occupancy, WFC owner, generations) is rediscovered on every manager pass and every Get.
enum SiteDesired
{
    Running,
    Stopped,
    // Absorbing tombstone: realizations converge away, then the manager deletes the document.
    Removed
}

sealed record SiteIntent(Guid SiteId, string Name, string RootPath, SiteDesired Desired, int DesiredReplicas)
{
    [JsonIgnore]
    public int RequiredReplicas => Desired == SiteDesired.Running ? DesiredReplicas : 0;

    // Intrinsic validation only. The upper bound belongs to the configured topology: see ValidatedFor.
    public SiteIntent Validated()
    {
        if (SiteId == Guid.Empty)
        {
            throw new InvalidDataException("SiteId must not be empty.");
        }
        if (!Regex.IsMatch(Name, @"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"))
        {
            throw new InvalidDataException($"Name '{Name}' is not a lower-case DNS host name.");
        }
        // UNC without whitespace: the fence protocol is space-delimited, and content lives outside this control plane.
        if (!Regex.IsMatch(RootPath, @"^\\\\[A-Za-z0-9.-]+\\[^\\\s]+(\\[^\\\s]+)*$"))
        {
            throw new InvalidDataException($"RootPath '{RootPath}' must be a UNC path without whitespace.");
        }
        if (DesiredReplicas < 1)
        {
            throw new InvalidDataException("DesiredReplicas must be at least 1.");
        }
        return this;
    }

    public SiteIntent ValidatedFor(ExecutionTopology topology)
    {
        Validated();
        if (DesiredReplicas > topology.Count)
        {
            throw new InvalidDataException(
                $"DesiredReplicas must be between 1 and {topology.Count} (configured eligible domains: {topology.Describe()}).");
        }
        return this;
    }
}

sealed class FileSiteStore(string directory)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        RespectRequiredConstructorParameters = true,
        // Rejects operational fields (PID, RunId, owner, generation, ...) if anything ever writes them.
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter<SiteDesired>() }
    };

    public IReadOnlyList<SiteIntent> List() =>
        Directory.Exists(directory)
            ? Directory.GetFiles(directory, "*.json").Order(StringComparer.Ordinal).Select(Read).ToArray()
            : [];

    public SiteIntent Find(string name) =>
        List().SingleOrDefault(site => site.Name == name)
            ?? throw new InvalidOperationException($"No site intent named '{name}'.");

    public void Save(SiteIntent site)
    {
        site.Validated();
        Directory.CreateDirectory(directory);
        var path = PathOf(site);
        var temporary = path + ".tmp";
        using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            JsonSerializer.Serialize(stream, site, JsonOptions);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temporary, path, overwrite: true);
    }

    // Deletes only the exact tombstone the caller reconciled; any other content is left untouched.
    public bool DeleteTombstone(SiteIntent reconciled)
    {
        if (reconciled.Desired != SiteDesired.Removed)
        {
            throw new InvalidOperationException("Only a Removed tombstone may be deleted.");
        }
        var path = PathOf(reconciled);
        if (!File.Exists(path) || Read(path) != reconciled)
        {
            return false;
        }
        File.Delete(path);
        return true;
    }

    public static string Serialize(SiteIntent site) =>
        JsonSerializer.Serialize(site, new JsonSerializerOptions(JsonOptions) { WriteIndented = false });

    private string PathOf(SiteIntent site) => Path.Combine(directory, $"{site.SiteId:D}.json");

    private static SiteIntent Read(string path)
    {
        using var stream = File.OpenRead(path);
        return (JsonSerializer.Deserialize<SiteIntent>(stream, JsonOptions)
            ?? throw new InvalidDataException($"{path} must not be JSON null.")).Validated();
    }
}

// One HTTP realization of a site. http.sys owns port 80 and dispatches by Host/:authority to the
// process that registered http://<Name>:80/; the registration lives and dies with this process.
[SupportedOSPlatform("windows")]
static class VpsRealization
{
    public static async Task RunAsync(Guid siteId, Guid runId, int startupDelayMs, string domain, string name, string rootPath)
    {
        using var readiness = new EventWaitHandle(false, EventResetMode.ManualReset, Workload.ReadinessName(runId));
        using var started = new EventWaitHandle(false, EventResetMode.ManualReset, Workload.StartedName(runId));
        await Task.Delay(startupDelayMs);
        while (!Readable(rootPath))
        {
            // Never-completed startup stays Starting: no started witness is set until content is reachable.
            await Task.Delay(1000);
        }
        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://{name}:80/");
        listener.Start();
        var healthy = true;
        started.Set();
        readiness.Set();
        _ = Task.Run(async () =>
        {
            while (true)
            {
                await Task.Delay(1000);
                // Health loss after completed startup is Degraded (started set, readiness reset); not persisted anywhere.
                healthy = Readable(rootPath);
                if (healthy) readiness.Set(); else readiness.Reset();
            }
        });
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rootPath));
        while (true)
        {
            var context = await listener.GetContextAsync();
            try
            {
                Serve(context, root, healthy, siteId, runId, domain, name);
            }
            catch (Exception failed) when (failed is IOException or HttpListenerException or UnauthorizedAccessException)
            {
                try { context.Response.StatusCode = 500; } catch (InvalidOperationException) { }
            }
            finally
            {
                context.Response.Close();
            }
        }
    }

    private static bool Readable(string rootPath)
    {
        try
        {
            return File.Exists(Path.Combine(rootPath, "index.html"));
        }
        catch (Exception failed) when (failed is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static void Serve(HttpListenerContext context, string root, bool healthy,
        Guid siteId, Guid runId, string domain, string name)
    {
        var response = context.Response;
        response.Headers["X-VPS-Site"] = $"{name};siteId={siteId}";
        response.Headers["X-VPS-Realization"] = $"node={Environment.MachineName};domain={domain};pid={Environment.ProcessId};runId={runId}";
        if (!healthy)
        {
            response.StatusCode = 503;
            return;
        }
        if (context.Request.HttpMethod is not ("GET" or "HEAD"))
        {
            response.StatusCode = 405;
            return;
        }
        var relative = Uri.UnescapeDataString(context.Request.Url!.AbsolutePath).TrimStart('/').Replace('/', '\\');
        var full = Path.GetFullPath(Path.Combine(root, relative.Length == 0 ? "index.html" : relative));
        if (!full.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase) || !File.Exists(full))
        {
            response.StatusCode = 404;
            return;
        }
        var body = File.ReadAllBytes(full);
        response.ContentType = full.EndsWith(".html", StringComparison.OrdinalIgnoreCase) ? "text/html; charset=utf-8" : "application/octet-stream";
        response.ContentLength64 = body.Length;
        if (context.Request.HttpMethod == "GET")
        {
            response.OutputStream.Write(body);
        }
    }
}

sealed record ObservedRealization(string Fence, string Node, DiscoveredWorkload Match);

[SupportedOSPlatform("windows")]
static class VpsSites
{
    private const int StartupDelayMs = 1000;

    public static string StartLocal(string generationPath, long offered, Guid siteId, string name, string rootPath, string executionDomain)
    {
        var site = new SiteIntent(siteId, name, rootPath, SiteDesired.Running, 1).Validated();
        var child = new AuthorityGrant(generationPath, offered).WithCurrent("process creation",
            () => Workload.Start(site.SiteId, StartupDelayMs, executionDomain, siteName: site.Name, rootPath: site.RootPath));
        return $"STARTED domain={executionDomain}; pid={child.ProcessId}; startTicks={child.StartTimeUtcTicks}; runId={child.RunId}";
    }

    // Fresh, unfenced, read-only observation of one site across the configured domains. Never persisted.
    public static IReadOnlyList<ObservedRealization> Observe(Guid siteId, ExecutionTopology topology)
    {
        var observed = new List<ObservedRealization>();
        foreach (var (domain, fence) in topology.Domains)
        {
            var reply = ClusterFenceExperiment.Request(fence, $"OBSERVE {siteId}", 30000).Split(' ');
            if (reply is not ["OBSERVED", var fenceDomain, var machine, ..] || fenceDomain != domain)
            {
                throw new InvalidDataException($"Unexpected observation from {domain}: {string.Join(' ', reply)}.");
            }
            foreach (var entry in reply[3..])
            {
                var fields = entry.Split('|');
                var match = new DiscoveredWorkload(Enum.Parse<WorkloadState>(fields[0]),
                    new WorkloadIncarnation(int.Parse(fields[2], CultureInfo.InvariantCulture),
                        long.Parse(fields[3], CultureInfo.InvariantCulture), Guid.Parse(fields[4])), fields[1]);
                if (match.Domain != domain)
                {
                    throw new InvalidOperationException(
                        $"Domain placement violation: node of {domain} hosts realization claiming {match.Domain}; " +
                        $"pid={match.Incarnation!.ProcessId}. No Start issued. No Stop issued.");
                }
                observed.Add(new ObservedRealization(fence, machine, match));
            }
        }
        return observed;
    }

    public static void Admin(string verb, string storePath, string[] arguments)
    {
        var store = new FileSiteStore(storePath);
        SiteIntent Mutate(string name, Func<SiteIntent, SiteIntent> change, ExecutionTopology? topology = null)
        {
            var site = store.Find(name);
            if (site.Desired == SiteDesired.Removed)
            {
                throw new InvalidOperationException($"Site '{name}' is being removed; Removed is terminal.");
            }
            var changed = change(site);
            if (topology is not null)
            {
                changed.ValidatedFor(topology);
            }
            store.Save(changed);
            return changed;
        }

        SiteIntent written;
        switch (verb, arguments)
        {
            case ("new", [var name, var rootPath, var replicas, .. var domains]):
                var newTopology = ExecutionTopology.Parse(domains);
                if (store.List().Any(site => site.Name == name))
                {
                    throw new InvalidOperationException($"Site '{name}' already exists.");
                }
                written = new SiteIntent(Guid.NewGuid(), name, rootPath, SiteDesired.Running,
                    int.Parse(replicas, CultureInfo.InvariantCulture)).ValidatedFor(newTopology);
                store.Save(written);
                break;
            case ("set", [var name, var replicas, .. var domains]):
                var setTopology = ExecutionTopology.Parse(domains);
                written = Mutate(name, site => site with { DesiredReplicas = int.Parse(replicas, CultureInfo.InvariantCulture) }, setTopology);
                break;
            case ("suspend", [var name]):
                written = Mutate(name, site => site with { Desired = SiteDesired.Stopped });
                break;
            case ("resume", [var name]):
                written = Mutate(name, site => site with { Desired = SiteDesired.Running });
                break;
            case ("remove", [var name]):
                written = Mutate(name, site => site with { Desired = SiteDesired.Removed });
                break;
            case ("get", var domains):
                var getTopology = domains.Length == 0 ? null : ExecutionTopology.Parse(domains);
                Console.WriteLine(JsonSerializer.Serialize(store.List().Select(site =>
                {
                    var observed = getTopology is null ? null : Observe(site.SiteId, getTopology);
                    return new
                    {
                        Intent = site,
                        ObservedAt = DateTimeOffset.UtcNow.ToString("O"),
                        Realizations = observed?.Select(item => new
                        {
                            item.Node, item.Match.Domain, State = item.Match.State.ToString(), Pid = item.Match.Incarnation!.ProcessId,
                            StartTicks = item.Match.Incarnation.StartTimeUtcTicks, item.Match.Incarnation.RunId
                        }),
                        RunningNodes = observed?.Where(item => item.Match.State == WorkloadState.Running).Select(item => item.Node)
                    };
                }).ToArray(), new JsonSerializerOptions { Converters = { new JsonStringEnumConverter<SiteDesired>() } }));
                return;
            default:
                throw new ArgumentException("Usage: vps new <store> <name> <rootPath> <replicas> <domain=host:port>... | " +
                    "vps set <store> <name> <replicas> <domain=host:port>... | " +
                    "vps suspend|resume|remove <store> <name> | vps get <store> [domain=host:port...]");
        }
        Console.WriteLine($"Intent persisted: {FileSiteStore.Serialize(written)}");
    }

    public static void Manage(string storePath, string cluster, string group, ExecutionTopology topology)
    {
        var store = new FileSiteStore(storePath);
        var sites = store.List();
        if (sites.Count > 1)
        {
            throw new InvalidDataException("This experiment reconciles exactly one site.");
        }
        if (sites.Count == 0)
        {
            Console.WriteLine($"Intent: none; Result=Converged; no site intent; at={Now}.");
            return;
        }
        var site = sites[0];
        // Intent persisted under a wider topology is refused rather than silently truncated.
        site.ValidatedFor(topology);
        var required = site.RequiredReplicas;
        var fences = topology.Domains.Select(domain => domain.Fence).ToArray();
        var domains = topology.Domains.Select(domain => domain.Name).ToArray();
        Console.WriteLine($"Intent: {FileSiteStore.Serialize(site)}; requiredReplicas={required}; " +
            $"eligibleDomains=[{topology.Describe()}]; requiredDomains=[{string.Join(",", domains.Take(required))}]; at={Now}.");

        var admitted = new ClusterAuthority(cluster, group).Observe();
        Console.WriteLine($"Admission: local={admitted.LocalNode}; owner={admitted.OwnerNode}; authoritative={admitted.IsAuthoritative}; at={Now}.");
        if (!admitted.IsAuthoritative)
        {
            throw new InvalidOperationException("Cluster admission rejected: not current stable owner.");
        }

        // Every eligible domain is fenced, not only the required ones: surplus realizations must be stoppable.
        var generations = new long?[fences.Length];
        var deadline = DateTime.UtcNow.AddMinutes(3);
        for (var round = 1; generations.Any(generation => generation is null); round++)
        {
            for (var index = 0; index < fences.Length; index++)
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
            Console.WriteLine($"Authority establishment: round={round}; established={established}/{fences.Length}; " +
                $"effects={(established == fences.Length ? "permitted" : "withheld")}; at={Now}.");
            if (established < fences.Length)
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
            var located = Observe(site.SiteId, topology);
            var realizations = located.Select(item => item.Match).ToArray();
            var decision = SiteReconciliation.Decide(topology, required, realizations);
            Console.WriteLine($"Pass {pass}: required={required}; " +
                $"running={realizations.Count(match => match.State == WorkloadState.Running)}; " +
                $"starting={realizations.Count(match => match.State == WorkloadState.Starting)}; " +
                $"degraded={realizations.Count(match => match.State == WorkloadState.Degraded)}; live={realizations.Length}; " +
                $"realizations=[{Describe(located)}]; at={Now}.");

            if (decision.Kind == SiteDecisionKind.Converged)
            {
                pending = 0;
                if (++matching < 2)
                {
                    Thread.Sleep(250);
                    continue;
                }
                Console.WriteLine($"Result=Converged; desired={site.Desired}; required={required}; starts={starts}; stops={stops}; " +
                    $"realizations=[{Describe(located)}]; at={Now}.");
                if (site.Desired == SiteDesired.Removed)
                {
                    // Safe: fences of every domain are advanced (no older authority can Start), the tombstone is
                    // absorbing (no authority will choose Start for it), and zero realizations were freshly observed twice.
                    var deleted = store.DeleteTombstone(site);
                    Console.WriteLine($"Result=Finalized; intentDeleted={deleted}; siteId={site.SiteId}; at={Now}.");
                }
                return;
            }

            matching = 0;
            if (decision is { Kind: SiteDecisionKind.Stop, Victim: { } victim })
            {
                var index = Array.IndexOf(domains, victim.Domain);
                var incarnation = victim.Incarnation!;
                Console.WriteLine($"Decision=Stop; reason={decision.Reason}; " +
                    $"domain={victim.Domain}; state={victim.State}; pid={incarnation.ProcessId}; runId={incarnation.RunId}; generation={generations[index]}; at={Now}.");
                var reply = Effect(fences[index], $"STOP {generations[index]} {incarnation.ProcessId} {incarnation.StartTimeUtcTicks} {incarnation.RunId}");
                stops += reply.StartsWith("STOPPED ", StringComparison.Ordinal) ? 1 : 0;
                pending = 0;
            }
            else if (decision.Kind == SiteDecisionKind.Start)
            {
                var index = Array.IndexOf(domains, decision.Domain);
                Console.WriteLine($"Decision=Start; reason={decision.Reason}; domain={domains[index]}; generation={generations[index]}; at={Now}.");
                Effect(fences[index], $"START {generations[index]} {site.SiteId} {site.Name} {site.RootPath}");
                starts++;
                pending = 0;
            }
            else
            {
                Console.WriteLine($"Action=none; waiting for readiness evidence, not issuing another Start; at={Now}.");
            }
            if (++pending == 240)
            {
                throw new TimeoutException("The site did not converge within 240 pending passes.");
            }
            if (starts + stops > 2 * fences.Length)
            {
                throw new InvalidOperationException($"Effect bound exceeded (starts={starts}; stops={stops}); refusing to continue.");
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
            throw new InvalidOperationException($"Effect not performed: {reply}");
        }
        return reply;
    }

    private static string Describe(IEnumerable<ObservedRealization> located) =>
        string.Join("; ", located.OrderBy(item => item.Match.Domain, StringComparer.Ordinal).Select(item =>
            $"node={item.Node},domain={item.Match.Domain},state={item.Match.State},pid={item.Match.Incarnation!.ProcessId}," +
            $"startTicks={item.Match.Incarnation.StartTimeUtcTicks},runId={item.Match.Incarnation.RunId}"));

    private static string Now => DateTimeOffset.UtcNow.ToString("O");
}

enum SiteDecisionKind
{
    Converged,
    Stop,
    Start,
    Wait
}

sealed record SiteDecision(SiteDecisionKind Kind, string Reason, string? Domain = null, DiscoveredWorkload? Victim = null);

// One next effect from fresh observation over the configured topology. Pure: no I/O, no persisted workflow.
static class SiteReconciliation
{
    public static SiteDecision Decide(ExecutionTopology topology, int required, IReadOnlyList<DiscoveredWorkload> realizations)
    {
        if (required < 0 || required > topology.Count)
        {
            throw new InvalidDataException($"Required replicas {required} exceed the {topology.Count} configured eligible domains.");
        }
        var outside = realizations.FirstOrDefault(match => topology.Rank(match.Domain) is null);
        if (outside is not null)
        {
            throw new InvalidOperationException($"Domain placement violation: realization claims unconfigured domain " +
                $"'{outside.Domain}'. No Start issued. No Stop issued.");
        }
        var victim = DomainReconciliation.SelectVictim(realizations, required, topology.Rank);
        if (victim is not null)
        {
            return new SiteDecision(SiteDecisionKind.Stop,
                topology.Rank(victim.Domain) > required ? "not-required-domain" : "collision-or-degraded", victim.Domain, victim);
        }
        var empty = topology.Required(required).FirstOrDefault(domain => realizations.All(match => match.Domain != domain.Name));
        if (empty is not null)
        {
            return new SiteDecision(SiteDecisionKind.Start, "required-domain-empty", empty.Name);
        }
        // No surplus, no collision, every required domain occupied: exactly `required` realizations remain.
        return realizations.All(match => match.State == WorkloadState.Running)
            ? new SiteDecision(SiteDecisionKind.Converged, "required-domains-running")
            : new SiteDecision(SiteDecisionKind.Wait, "awaiting-readiness");
    }

    // Local, effect-free probe of validation, derivation and decision for an arbitrary configured topology.
    // observed: "-" or comma-separated domain:State entries (State = Running|Starting|Degraded).
    public static void Plan(string replicas, string observed, string[] domains)
    {
        var topology = ExecutionTopology.Parse(domains);
        var intent = new SiteIntent(Guid.NewGuid(), "plan.example.test", @"\\plan\root", SiteDesired.Running,
            int.Parse(replicas, CultureInfo.InvariantCulture)).ValidatedFor(topology);
        var realizations = observed == "-" ? [] : observed.Split(',').Select((entry, index) =>
        {
            var separator = entry.LastIndexOf(':');
            return new DiscoveredWorkload(Enum.Parse<WorkloadState>(entry[(separator + 1)..]),
                new WorkloadIncarnation(1000 + index, 1000 + index, Guid.NewGuid()), entry[..separator]);
        }).ToArray();
        var decision = Decide(topology, intent.RequiredReplicas, realizations);
        Console.WriteLine($"eligibleDomains=[{topology.Describe()}]; eligibleCount={topology.Count}; " +
            $"requiredDomains=[{string.Join(",", topology.Required(intent.RequiredReplicas).Select(domain => domain.Name))}]; " +
            $"decision={decision.Kind}; domain={decision.Domain ?? "-"}; reason={decision.Reason}");
    }
}