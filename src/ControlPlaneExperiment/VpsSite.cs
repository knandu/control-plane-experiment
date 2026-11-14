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

// Durable administrator intent only. Implementations must never hold operational observations.
interface ISiteStore
{
    IReadOnlyList<SiteIntent> List();
    void Save(SiteIntent site);
    bool DeleteTombstone(SiteIntent reconciled);

    SiteIntent Find(string name) =>
        List().SingleOrDefault(site => site.Name == name)
            ?? throw new InvalidOperationException($"No site intent named '{name}'.");
}

static class SiteStores
{
    public const string CheckpointPrefix = "wfc-checkpoint:";

    // "<directory>" (Day 5.5 file store) or "wfc-checkpoint:<cluster>:<group>:HKLM\SOFTWARE\ControlPlaneExperiment\<key>".
    public static ISiteStore Open(string spec)
    {
        if (!spec.StartsWith(CheckpointPrefix, StringComparison.Ordinal))
        {
            return new FileSiteStore(spec);
        }
        if (!OperatingSystem.IsWindows() || spec[CheckpointPrefix.Length..].Split(':', 3) is not [var cluster, var group, var key]
            || cluster.Length == 0 || group.Length == 0)
        {
            throw new ArgumentException($"Store '{spec}' must be {CheckpointPrefix}<cluster>:<group>:<HKLM key>.");
        }
        return new RegistrySiteStore(cluster, group, key);
    }
}

// Day 5.6: site intent as REG_SZ values (one per SiteId) under a registry key that the clustered
// "VPS Management" resource checkpoints. Probed semantics (docs\day-05.6.md): the owner's changes are
// captured while the resource is Online and restored on the next Online wherever WFC places it; writes on a
// non-owner or while the resource is Offline are overwritten by the restore; deleting and recreating the
// checkpointed key silently stops capture. Hence: intent is read/written only on the owner while the role
// is Online, and only values are set or deleted -- the key itself is never deleted or recreated here.
[SupportedOSPlatform("windows")]
sealed class RegistrySiteStore : ISiteStore
{
    private const string Hive = @"HKLM\";
    private const string ExperimentRoot = @"SOFTWARE\ControlPlaneExperiment\";
    private readonly ClusterAuthority _role;
    private readonly string _cluster, _group, _subKey;

    public RegistrySiteStore(string cluster, string group, string key)
    {
        if (!key.StartsWith(Hive + ExperimentRoot, StringComparison.OrdinalIgnoreCase) || key.Length == (Hive + ExperimentRoot).Length
            || key.EndsWith('\\'))
        {
            throw new ArgumentException($"Checkpointed intent key '{key}' must be an experiment-owned key under {Hive}{ExperimentRoot}.");
        }
        (_cluster, _group, _subKey) = (cluster, group, key[Hive.Length..]);
        _role = new ClusterAuthority(cluster, group);
    }

    public IReadOnlyList<SiteIntent> List()
    {
        RequireRoleHere("read");
        using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(_subKey);
        return key is null ? [] : key.GetValueNames().Order(StringComparer.Ordinal).Select(name => Read(key, name)).ToArray();
    }

    public void Save(SiteIntent site)
    {
        site.Validated();
        RequireRoleHere("write");
        // CreateSubKey opens an existing key; it never recreates one that the checkpoint is watching.
        using (var key = Microsoft.Win32.Registry.LocalMachine.CreateSubKey(_subKey, writable: true))
        {
            key.SetValue(ValueName(site), FileSiteStore.Serialize(site), Microsoft.Win32.RegistryValueKind.String);
        }
        RequireRoleHere("confirm write");
    }

    public bool DeleteTombstone(SiteIntent reconciled)
    {
        if (reconciled.Desired != SiteDesired.Removed)
        {
            throw new InvalidOperationException("Only a Removed tombstone may be deleted.");
        }
        RequireRoleHere("delete");
        using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(_subKey, writable: true);
        if (key is null || !key.GetValueNames().Contains(ValueName(reconciled)) || Read(key, ValueName(reconciled)) != reconciled)
        {
            return false;
        }
        key.DeleteValue(ValueName(reconciled));
        return true;
    }

    // A copy on any other node, or written while the role is not Online, is not current intent.
    private void RequireRoleHere(string purpose)
    {
        var observed = _role.Observe();
        if (!string.Equals(observed.LocalNode, observed.OwnerNode, StringComparison.OrdinalIgnoreCase)
            || observed.GroupState != "Online" || observed.NodeState != "Up")
        {
            throw new InvalidOperationException(
                $"Checkpointed intent {purpose} refused: local={observed.LocalNode}; owner={observed.OwnerNode}; " +
                $"group '{_group}' on cluster '{_cluster}' is {observed.GroupState}. Intent is current only on the owner while the role is Online.");
        }
    }

    private static string ValueName(SiteIntent site) => site.SiteId.ToString("D");

    private static SiteIntent Read(Microsoft.Win32.RegistryKey key, string name)
    {
        if (key.GetValueKind(name) != Microsoft.Win32.RegistryValueKind.String || key.GetValue(name) is not string json)
        {
            throw new InvalidDataException($"Intent value '{name}' must be REG_SZ JSON.");
        }
        var site = FileSiteStore.Parse(json, name);
        if (ValueName(site) != name)
        {
            throw new InvalidDataException($"Intent value '{name}' holds SiteId {site.SiteId}.");
        }
        return site;
    }
}

sealed class FileSiteStore(string directory) : ISiteStore
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

    public static SiteIntent Parse(string json, string source) =>
        (JsonSerializer.Deserialize<SiteIntent>(json, JsonOptions)
            ?? throw new InvalidDataException($"{source} must not be JSON null.")).Validated();

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
        var store = SiteStores.Open(storePath);
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

    // One-shot Day 5.5 manager: establish authority, reconcile to convergence, exit.
    public static void Manage(string storePath, string cluster, string group, ExecutionTopology topology)
    {
        var store = SiteStores.Open(storePath);
        var site = SingleSite(store);
        if (site is null)
        {
            Console.WriteLine($"Intent: none; Result=Converged; no site intent; at={Now}.");
            return;
        }
        // Intent persisted under a wider topology is refused rather than silently truncated.
        site.ValidatedFor(topology);
        Console.WriteLine($"Intent: {FileSiteStore.Serialize(site)}; requiredReplicas={site.RequiredReplicas}; " +
            $"eligibleDomains=[{topology.Describe()}]; requiredDomains=[{RequiredDomains(topology, site)}]; at={Now}.");

        var admitted = new ClusterAuthority(cluster, group).Observe();
        Console.WriteLine($"Admission: local={admitted.LocalNode}; owner={admitted.OwnerNode}; authoritative={admitted.IsAuthoritative}; at={Now}.");
        if (!admitted.IsAuthoritative)
        {
            throw new InvalidOperationException("Cluster admission rejected: not current stable owner.");
        }
        var generations = EstablishAuthority(topology, admitted.LocalNode);

        var tally = new EffectTally();
        int matching = 0, pending = 0;
        for (var pass = 1; ; pass++)
        {
            var (decision, located) = ReconcilePass(site, topology, generations, tally, pass, logConverged: true);
            if (decision.Kind == SiteDecisionKind.Converged)
            {
                pending = 0;
                if (++matching < 2)
                {
                    Thread.Sleep(250);
                    continue;
                }
                Console.WriteLine($"Result=Converged; desired={site.Desired}; required={site.RequiredReplicas}; starts={tally.Starts}; stops={tally.Stops}; " +
                    $"realizations=[{Describe(located)}]; at={Now}.");
                Finalize(store, site);
                return;
            }
            matching = 0;
            pending = decision.Kind == SiteDecisionKind.Wait ? pending : 0;
            if (++pending == 240)
            {
                throw new TimeoutException("The site did not converge within 240 pending passes.");
            }
            if (tally.Starts + tally.Stops > 2 * topology.Count)
            {
                throw new InvalidOperationException($"Effect bound exceeded (starts={tally.Starts}; stops={tally.Stops}); refusing to continue.");
            }
            Thread.Sleep(250);
        }
    }

    // Day 5.6: the manager as the long-lived process of a WFC Generic Application resource. WFC starts it,
    // monitors the process, terminates it on Offline and restarts or fails it over by resource policy. It never
    // exits on convergence; an unexpected fault exits nonzero so that WFC, not a harness, observes the failure.
    // Each incarnation re-establishes authority through every fence before any effect: WFC lifecycle decides
    // where management runs, the generation decides which incarnation may mutate, the fence orders effects.
    public static int Serve(string storePath, string cluster, string group, string logPath, ExecutionTopology topology)
    {
        // Generic Application does not capture standard output; the manager keeps its own append-only log.
        var log = new StreamWriter(new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) { AutoFlush = true };
        Console.SetOut(log);
        Console.SetError(log);
        using var self = System.Diagnostics.Process.GetCurrentProcess();
        try
        {
            Console.WriteLine($"Serve: manager={self.Id}; startTicks={self.StartTime.ToUniversalTime().Ticks}; local={Environment.MachineName}; " +
                $"cluster={cluster}; group={group}; store={storePath}; eligibleDomains=[{topology.Describe()}]; at={Now}.");
            var store = SiteStores.Open(storePath);
            var role = new ClusterAuthority(cluster, group);

            ClusterAuthorityObservation admitted;
            for (var attempt = 1; ; attempt++)
            {
                // The group reports Pending until this resource's Online completes; authority needs Online.
                admitted = role.Observe();
                Console.WriteLine($"Admission: attempt={attempt}; local={admitted.LocalNode}; owner={admitted.OwnerNode}; " +
                    $"group={admitted.GroupState}; node={admitted.NodeState}; at={Now}.");
                if (!string.Equals(admitted.LocalNode, admitted.OwnerNode, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException("Cluster admission rejected: this node is not the WFC owner.");
                }
                if (admitted.GroupState == "Online" && admitted.NodeState == "Up")
                {
                    break;
                }
                if (attempt == 120)
                {
                    throw new TimeoutException("The management group did not become Online on this node.");
                }
                Thread.Sleep(500);
            }
            var generations = EstablishAuthority(topology, admitted.LocalNode);

            var tally = new EffectTally();
            string? intentSeen = null, convergedReported = null;
            int matching = 0, pending = 0, effectsBefore = 0;
            for (var pass = 1; ; pass++)
            {
                SiteIntent? site;
                IReadOnlyList<ObservedRealization> located;
                SiteDecision decision;
                try
                {
                    // Intent is re-read on every pass: an administrator change takes effect without a restart.
                    site = SingleSite(store);
                    var intent = site is null ? "none" : FileSiteStore.Serialize(site);
                    if (intent != intentSeen)
                    {
                        Console.WriteLine($"Intent: {intent}; requiredReplicas={site?.RequiredReplicas ?? 0}; " +
                            $"requiredDomains=[{(site is null ? "" : RequiredDomains(topology, site))}]; pass={pass}; at={Now}.");
                        (intentSeen, convergedReported, matching, effectsBefore) = (intent, null, 0, tally.Starts + tally.Stops);
                    }
                    if (site is null)
                    {
                        Thread.Sleep(1000);
                        continue;
                    }
                    site.ValidatedFor(topology);
                    (decision, located) = ReconcilePass(site, topology, generations, tally, pass, logConverged: convergedReported is null);
                }
                catch (Exception transient) when (transient is IOException or System.Net.Sockets.SocketException)
                {
                    // An unreachable fence withholds effects; the next pass observes afresh.
                    Console.WriteLine($"Pass {pass}: transient={transient.GetType().Name}: {transient.Message}; effects withheld; at={Now}.");
                    Thread.Sleep(2000);
                    continue;
                }

                if (decision.Kind == SiteDecisionKind.Converged)
                {
                    pending = 0;
                    if (++matching >= 2)
                    {
                        var summary = $"desired={site.Desired}; required={site.RequiredReplicas}; realizations=[{Describe(located)}]";
                        if (summary != convergedReported)
                        {
                            Console.WriteLine($"Result=Converged; {summary}; starts={tally.Starts}; stops={tally.Stops}; " +
                                $"manager={self.Id}; generations=[{string.Join(", ", topology.Domains.Select((domain, index) => $"{domain.Name}={generations[index]}"))}]; at={Now}.");
                            convergedReported = summary;
                            effectsBefore = tally.Starts + tally.Stops;
                            if (Finalize(store, site))
                            {
                                intentSeen = null;
                            }
                        }
                    }
                    Thread.Sleep(convergedReported is null ? 250 : 1000);
                    continue;
                }

                (matching, convergedReported) = (0, null);
                pending = decision.Kind == SiteDecisionKind.Wait ? pending : 0;
                if (++pending == 240)
                {
                    throw new TimeoutException("The site did not converge within 240 pending passes.");
                }
                if (tally.Starts + tally.Stops - effectsBefore > 2 * topology.Count)
                {
                    throw new InvalidOperationException($"Effect bound exceeded since last convergence (starts={tally.Starts}; stops={tally.Stops}); refusing to continue.");
                }
                Thread.Sleep(250);
            }
        }
        catch (Exception fault)
        {
            Console.WriteLine($"Fault: manager={self.Id}; {fault.GetType().Name}: {fault.Message}; exiting nonzero for WFC; at={Now}.");
            return 1;
        }
    }

    private sealed class EffectTally
    {
        public int Starts;
        public int Stops;
    }

    private static SiteIntent? SingleSite(ISiteStore store)
    {
        var sites = store.List();
        return sites.Count switch
        {
            0 => null,
            1 => sites[0],
            _ => throw new InvalidDataException("This experiment reconciles exactly one site.")
        };
    }

    private static string RequiredDomains(ExecutionTopology topology, SiteIntent site) =>
        string.Join(",", topology.Required(site.RequiredReplicas).Select(domain => domain.Name));

    // Every eligible domain is fenced, not only the required ones: surplus realizations must be stoppable.
    // No cooperation from any earlier manager incarnation is needed: advancing is what retires it.
    private static long[] EstablishAuthority(ExecutionTopology topology, string localNode)
    {
        var fences = topology.Domains.Select(domain => domain.Fence).ToArray();
        var domains = topology.Domains.Select(domain => domain.Name).ToArray();
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
                    reply = ClusterFenceExperiment.Request(fences[index], $"ADVANCE {localNode}", 30000);
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
        return generations.Select(generation => generation!.Value).ToArray();
    }

    // One fresh observation, one decision, at most one fenced effect.
    private static (SiteDecision Decision, IReadOnlyList<ObservedRealization> Located) ReconcilePass(
        SiteIntent site, ExecutionTopology topology, long[] generations, EffectTally tally, int pass, bool logConverged)
    {
        var fences = topology.Domains.Select(domain => domain.Fence).ToArray();
        var domains = topology.Domains.Select(domain => domain.Name).ToArray();
        var required = site.RequiredReplicas;
        var located = Observe(site.SiteId, topology);
        var realizations = located.Select(item => item.Match).ToArray();
        var decision = SiteReconciliation.Decide(topology, required, realizations);
        if (logConverged || decision.Kind != SiteDecisionKind.Converged)
        {
            Console.WriteLine($"Pass {pass}: required={required}; " +
                $"running={realizations.Count(match => match.State == WorkloadState.Running)}; " +
                $"starting={realizations.Count(match => match.State == WorkloadState.Starting)}; " +
                $"degraded={realizations.Count(match => match.State == WorkloadState.Degraded)}; live={realizations.Length}; " +
                $"realizations=[{Describe(located)}]; at={Now}.");
        }

        if (decision is { Kind: SiteDecisionKind.Stop, Victim: { } victim })
        {
            var index = Array.IndexOf(domains, victim.Domain);
            var incarnation = victim.Incarnation!;
            Console.WriteLine($"Decision=Stop; reason={decision.Reason}; " +
                $"domain={victim.Domain}; state={victim.State}; pid={incarnation.ProcessId}; runId={incarnation.RunId}; generation={generations[index]}; at={Now}.");
            var reply = Effect(fences[index], $"STOP {generations[index]} {incarnation.ProcessId} {incarnation.StartTimeUtcTicks} {incarnation.RunId}");
            tally.Stops += reply.StartsWith("STOPPED ", StringComparison.Ordinal) ? 1 : 0;
        }
        else if (decision.Kind == SiteDecisionKind.Start)
        {
            var index = Array.IndexOf(domains, decision.Domain);
            Console.WriteLine($"Decision=Start; reason={decision.Reason}; domain={domains[index]}; generation={generations[index]}; at={Now}.");
            Effect(fences[index], $"START {generations[index]} {site.SiteId} {site.Name} {site.RootPath}");
            tally.Starts++;
        }
        else if (decision.Kind == SiteDecisionKind.Wait)
        {
            Console.WriteLine($"Action=none; waiting for readiness evidence, not issuing another Start; at={Now}.");
        }
        return (decision, located);
    }

    private static bool Finalize(ISiteStore store, SiteIntent site)
    {
        if (site.Desired != SiteDesired.Removed)
        {
            return false;
        }
        // Safe: fences of every domain are advanced (no older authority can Start), the tombstone is
        // absorbing (no authority will choose Start for it), and zero realizations were freshly observed twice.
        var deleted = store.DeleteTombstone(site);
        Console.WriteLine($"Result=Finalized; intentDeleted={deleted}; siteId={site.SiteId}; at={Now}.");
        return deleted;
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