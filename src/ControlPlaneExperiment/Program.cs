if (!OperatingSystem.IsWindows())
{
    throw new PlatformNotSupportedException("This checkpoint uses a local Windows readiness event.");
}

if (args.Length is 4 or 5 && args[0] == "--workload")
{
    _ = Guid.Parse(args[1]);
    if (args.Length == 5 && string.IsNullOrWhiteSpace(args[4]))
    {
        throw new ArgumentException("A logical execution domain must not be empty.");
    }

    await Workload.RunAsync(Guid.Parse(args[2]), int.Parse(args[3]));
    return;
}

if (args is ["--workload", var siteArgument, var siteRunId, var siteDelay, var siteDomain, var siteName, var siteRoot]
    && ExecutionTopology.IsValidName(siteDomain))
{
    await VpsRealization.RunAsync(Guid.Parse(siteArgument), Guid.Parse(siteRunId),
        int.Parse(siteDelay, System.Globalization.CultureInfo.InvariantCulture), siteDomain, siteName, siteRoot);
    return;
}

if (args is ["vps", var vpsVerb, var vpsStore, .. var vpsArguments])
{
    try
    {
        VpsSites.Admin(vpsVerb, vpsStore, vpsArguments);
    }
    catch (Exception refused) when (refused is InvalidOperationException or InvalidDataException or ArgumentException or FormatException)
    {
        Console.Error.WriteLine($"Refused: {refused.Message}");
        Environment.ExitCode = 2;
    }
    return;
}

if (args is ["vps-manage", var vpsManageStore, var vpsCluster, var vpsGroup, .. var vpsDomains])
{
    VpsSites.Manage(vpsManageStore, vpsCluster, vpsGroup, ExecutionTopology.Parse(vpsDomains));
    return;
}

if (args is ["vps-serve", var serveStore, var serveCluster, var serveGroup, var serveLog, .. var serveDomains])
{
    Environment.ExitCode = VpsSites.Serve(serveStore, serveCluster, serveGroup, serveLog, ExecutionTopology.Parse(serveDomains));
    return;
}

if (args is ["vps-plan", var planReplicas, var planObserved, .. var planDomains])
{
    try
    {
        SiteReconciliation.Plan(planReplicas, planObserved, planDomains);
    }
    catch (Exception refused) when (refused is InvalidOperationException or InvalidDataException or ArgumentException or FormatException)
    {
        Console.Error.WriteLine($"Refused: {refused.Message}");
        Environment.ExitCode = 2;
    }
    return;
}

if (args is ["grant", var grantPath, var grantEpoch])
{
    new AuthorityGrant(grantPath, long.Parse(grantEpoch, System.Globalization.CultureInfo.InvariantCulture)).Advance();
    return;
}

if (args is ["experiment-cluster-start", var experimentState, var experimentCluster, var experimentGroup,
    var experimentGates, var experimentPause])
{
    if (experimentPause is not ("none" or "decision" or "recheck"))
    {
        throw new ArgumentException("Experiment pause must be none, decision or recheck.");
    }
    ClusterStartExperiment.Run(experimentState, experimentCluster, experimentGroup, experimentGates, experimentPause);
    return;
}

if (args is ["fence-domain", var fenceCluster, var fenceGroup, var fencePort, var fenceGeneration, var fenceGates,
    var fencePause and ("none" or "inside")])
{
    ClusterFenceExperiment.ServeDomain(fenceCluster, fenceGroup, int.Parse(fencePort, System.Globalization.CultureInfo.InvariantCulture),
        fenceGeneration, fenceGates, fencePause == "inside");
    return;
}

if (args is ["fence-execution-domain", var executionCluster, var executionGroup, var executionPort, var executionGeneration,
    var executionGates, var executionDomain] && ExecutionTopology.IsValidName(executionDomain))
{
    ClusterFenceExperiment.ServeDomain(executionCluster, executionGroup,
        int.Parse(executionPort, System.Globalization.CultureInfo.InvariantCulture),
        executionGeneration, executionGates, false, executionDomain);
    return;
}

if (args is ["experiment-active-active", var activeState, var activeCluster, var activeGroup, var fence1, var fence2, var fence3])
{
    ClusterActiveActiveExperiment.Manage(activeState, activeCluster, activeGroup, [fence1, fence2, fence3]);
    return;
}

if (args is ["experiment-fenced-start", var fencedState, var fencedCluster, var fencedGroup, var fencedDomain,
    var fencedGates, var fencedPause and ("none" or "decision")])
{
    ClusterFenceExperiment.Manage(fencedState, fencedCluster, fencedGroup, fencedDomain, fencedGates, fencedPause);
    return;
}

if (args.Length is 5 or 6 && args[0] == "manage-cluster-observe")
{
    if (args[4] != "--effects-disabled")
    {
        throw new ArgumentException("Cluster management requires --effects-disabled in Day 5.1.");
    }
    await ClusterManagement.ObserveAsync(args[1], args[2], args[3],
        args.Length == 6 ? int.Parse(args[5], System.Globalization.CultureInfo.InvariantCulture) : 2);
    return;
}

string? authorityPath = null;
if (args.Length >= 4 && args[0] == "manage" && args[^2] == "--authority-file")
{
    authorityPath = args[^1];
    args = args[..^2];
}

long? authorityEpoch = null;
if (args.Length >= 4 && args[0] == "manage" && args[^2] == "--authority-epoch")
{
    authorityEpoch = long.Parse(args[^1], System.Globalization.CultureInfo.InvariantCulture);
    if (authorityEpoch <= 0)
    {
        throw new ArgumentOutOfRangeException(nameof(authorityEpoch), "Use a positive authority epoch.");
    }

    args = args[..^2];
}

var authority = authorityPath is null ? null : new AuthorityGrant(
    authorityPath, authorityEpoch ?? throw new ArgumentException("--authority-file requires --authority-epoch."));

int? replicas = null;
if (args is ["intent", _, "--replicas", var replicaCount])
{
    replicas = int.Parse(replicaCount, System.Globalization.CultureInfo.InvariantCulture);
    args = args[..2];
}

if (args.Length < 2 || args[0] is not ("intent" or "manage")
    || (args[0] == "intent" && args.Length != 2) || args.Length > 3)
{
    throw new ArgumentException(
        "Usage: intent <state-file> [--replicas <count>] | grant <authority-file> <epoch> | " +
        "manage-cluster-observe <state-file> <cluster> <group> --effects-disabled [observations] | " +
        "manage <state-file> [startup-delay-ms] [--authority-epoch <epoch> [--authority-file <path>]]. " +
        "Run only one manager; assign epochs explicitly for a clean handoff.");
}

IPlatformStore store = new FilePlatformStore(args[1]);
var state = store.Load();

if (args[0] == "intent")
{
    if (state is not null && replicas is null)
    {
        throw new InvalidOperationException("Platform state already exists; intent will not overwrite it.");
    }

    state = state is null
        ? new PlatformState(Guid.NewGuid(), WorkloadState.Running, replicas)
        : state with { Replicas = replicas };
    _ = state.EffectiveReplicas;
    store.Save(state);
    Console.WriteLine($"Intent persisted: workload={state.WorkloadId}; desired={state.Desired}");
    return;
}

if (state is null)
{
    throw new InvalidOperationException("No durable intent exists. Run intent <state-file> first.");
}

if (state.Desired != WorkloadState.Running || state.WorkloadId == Guid.Empty)
{
    throw new InvalidDataException("This checkpoint requires a named workload with Running intent.");
}

var desiredReplicas = state.EffectiveReplicas;
var domains = desiredReplicas > 1
    ? Enumerable.Range(1, desiredReplicas).Select(index =>
        $"domain-{index.ToString(System.Globalization.CultureInfo.InvariantCulture)}").ToArray()
    : [];
var startupDelayMs = args.Length == 3 ? int.Parse(args[2]) : 500;
if (startupDelayMs is < 0 or > 5000)
{
    throw new ArgumentOutOfRangeException(nameof(startupDelayMs), "Use a delay between 0 and 5000 ms.");
}

var matchingObservations = 0;
var pendingObservations = 0;
var startOperations = 0;
var stopOperations = 0;

using var manager = System.Diagnostics.Process.GetCurrentProcess();
Console.WriteLine(
    $"Manager={manager.Id}; recovered workload={state.WorkloadId}; desired={state.Desired}; " +
    $"managerStartTicks={manager.StartTime.ToUniversalTime().Ticks}; " +
    $"authorityEpoch={authorityEpoch?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "implicit"}.");
Console.WriteLine("Manager exit leaves the workload running. Terminate it explicitly after the experiment.");

Task<string?>? relinquishment = null;
if (authorityEpoch is not null)
{
    if (authority is null)
    {
        Console.WriteLine(
            $"Authority acquired: epoch={authorityEpoch}; manager={manager.Id}; explicit experimental assignment, not election. " +
            "Send 'relinquish' on stdin and wait for exit before assigning the next epoch.");
    }
    else
    {
        Console.WriteLine(
            $"Authority offered: epoch={authorityEpoch}; manager={manager.Id}; file={Path.GetFullPath(authorityPath!)}; " +
            (desiredReplicas == 1
                ? "Start requires the current recorded grant. Send 'relinquish' on stdin for a clean exit."
                : "Start and Stop require the current recorded grant. Send 'relinquish' on stdin for a clean exit."));
    }
    relinquishment = Task.Run(Console.ReadLine);
}

for (var observation = 1; ; observation++)
{
    if (relinquishment is { IsCompleted: true })
    {
        if (await relinquishment != "relinquish")
        {
            throw new InvalidOperationException("Explicit authority mode expects 'relinquish' on stdin.");
        }

        Console.WriteLine(
            $"Authority relinquished: epoch={authorityEpoch}; manager={manager.Id}; " +
            $"starts this manager={startOperations}; " +
            (desiredReplicas > 1 ? $"stops this manager={stopOperations}; " : "") +
            "workload left untouched.");
        return;
    }

    IReadOnlyList<DiscoveredWorkload> realizations;
    DiscoveredWorkload? victim = null;
    if (desiredReplicas == 1)
    {
        var fresh = Workload.Discover(state.WorkloadId);
        realizations = fresh.Incarnation is null ? [] : [fresh];
        Console.WriteLine(
            $"Observation {observation}: fresh={fresh.State}; workload={state.WorkloadId}; " +
            $"pid={fresh.Incarnation?.ProcessId}; startTicks={fresh.Incarnation?.StartTimeUtcTicks}; runId={fresh.Incarnation?.RunId}; " +
            $"manager={manager.Id}; authorityEpoch={authorityEpoch?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "implicit"}; " +
            $"at={DateTimeOffset.UtcNow:O}.");
    }
    else
    {
        realizations = Workload.DiscoverAll(state.WorkloadId);
        var occupancy = realizations.GroupBy(match => match.Domain, StringComparer.Ordinal).ToArray();
        var collisions = occupancy.Where(group => group.Count() > 1).ToArray();
        var unrecognized = occupancy.Where(group => DomainNumber(group.Key) is null).ToArray();
        if (unrecognized.Length > 0)
        {
            throw new InvalidOperationException(
                $"Domain isolation violation for workload {state.WorkloadId}: " +
                $"occupancy=[{string.Join("; ", occupancy.Select(group =>
                    $"domain={group.Key ?? "<none>"},pids={string.Join(",", group.Select(match => match.Incarnation!.ProcessId))}"))}]; " +
                $"collisions=[{string.Join(",", collisions.Select(group => group.Key ?? "<none>"))}]; " +
                $"unrecognized=[{string.Join(",", unrecognized.Select(group => group.Key ?? "<none>"))}]; " +
                $"desiredReplicas={desiredReplicas}; liveCount={realizations.Count}. No Start issued. No Stop issued.");
        }

        victim = DomainReconciliation.SelectVictim(realizations, desiredReplicas);

        Console.WriteLine(
            $"Observation {observation}: desiredReplicas={desiredReplicas}; " +
            $"runningCount={realizations.Count(match => match.State == WorkloadState.Running)}; " +
            $"startingCount={realizations.Count(match => match.State == WorkloadState.Starting)}; " +
            $"liveCount={realizations.Count}; degradedCount={realizations.Count(match => match.State == WorkloadState.Degraded)}; " +
            $"workload={state.WorkloadId}; realizations=[{Describe(realizations)}]; " +
            $"manager={manager.Id}; authorityEpoch={authorityEpoch?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "implicit"}; " +
            $"at={DateTimeOffset.UtcNow:O}.");
    }

    if (victim is null && realizations.Count == desiredReplicas
        && realizations.All(match => match.State == WorkloadState.Running))
    {
        pendingObservations = 0;
        matchingObservations++;

        if (matchingObservations == 2)
        {
            Console.WriteLine(desiredReplicas == 1
                ? $"Converged: two matching observations; starts this manager={startOperations}; pid={realizations[0].Incarnation!.ProcessId}."
                : $"Converged: two matching observations; starts this manager={startOperations}; " +
                  $"stops this manager={stopOperations}; " +
                  $"replicas={desiredReplicas}; realizations=[{Describe(realizations)}].");
        }
    }
    else
    {
        matchingObservations = 0;

        if (victim is not null)
        {
            var incarnation = victim.Incarnation!;
            Console.WriteLine(
                $"Decision=stop; workload={state.WorkloadId}; manager={manager.Id}; " +
                $"authorityEpoch={authorityEpoch?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "implicit"}; " +
                $"domain={victim.Domain}; pid={incarnation.ProcessId}; startTicks={incarnation.StartTimeUtcTicks}; " +
                $"runId={incarnation.RunId}; observation={observation}; at={DateTimeOffset.UtcNow:O}.");

            authority?.WithCurrent("manager pre-check", () => true);
            if (Environment.GetEnvironmentVariable("CONTROL_PLANE_PAUSE_BEFORE_STOP_EVENT") is { } resumeEventName)
            {
                using var resume = EventWaitHandle.OpenExisting(resumeEventName);
                Console.WriteLine(
                    $"Experiment paused: after Stop decision; before process termination; " +
                    $"stops this manager={stopOperations}; resumeEvent={resumeEventName}; at={DateTimeOffset.UtcNow:O}.");
                resume.WaitOne();
                Console.WriteLine(
                    $"Experiment resumed: continuing decided Stop without rediscovery; at={DateTimeOffset.UtcNow:O}.");
            }

            if (Workload.Stop(victim, authority))
            {
                stopOperations++;
            }
            Console.WriteLine(
                $"Action=stop returned; pid={incarnation.ProcessId}; startTicks={incarnation.StartTimeUtcTicks}; " +
                $"runId={incarnation.RunId}; domain={victim.Domain}; stops this manager={stopOperations}; " +
                $"at={DateTimeOffset.UtcNow:O}.");
            pendingObservations = 0;
        }
        else if (realizations.Count < desiredReplicas)
        {
            var targetDomain = desiredReplicas > 1
                ? domains.First(domain => !realizations.Any(match => match.Domain == domain))
                : null;
            Console.WriteLine(
                $"Decision=start; workload={state.WorkloadId}; manager={manager.Id}; " +
                $"authorityEpoch={authorityEpoch?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "implicit"}; " +
                (targetDomain is null ? "" : $"domain={targetDomain}; ") +
                $"observation={observation}; at={DateTimeOffset.UtcNow:O}.");

            authority?.WithCurrent("manager pre-check", () => true);

            if (Environment.GetEnvironmentVariable("CONTROL_PLANE_PAUSE_BEFORE_START_EVENT") is { } resumeEventName)
            {
                using var resume = EventWaitHandle.OpenExisting(resumeEventName);
                Console.WriteLine(
                    $"Experiment paused: after Start decision; before process creation; " +
                    $"starts this manager={startOperations}; resumeEvent={resumeEventName}; at={DateTimeOffset.UtcNow:O}.");
                resume.WaitOne();
                Console.WriteLine(
                    $"Experiment resumed: continuing decided Start without rediscovery; at={DateTimeOffset.UtcNow:O}.");
            }

            var started = Workload.Start(state.WorkloadId, startupDelayMs, targetDomain, authority);
            startOperations++;

            if (Environment.GetEnvironmentVariable("CONTROL_PLANE_PAUSE_BEFORE_LOCATOR_SAVE") == "1")
            {
                Console.WriteLine(
                    $"Action=start returned; former pre-locator-save pause; pid={started.ProcessId}; " +
                    $"startTicks={started.StartTimeUtcTicks}; runId={started.RunId}; " +
                    (targetDomain is null ? "" : $"domain={targetDomain}; ") + "experiment paused.");
                await Task.Delay(Timeout.Infinite);
            }

            Console.WriteLine(
                $"Action=start returned; pid={started.ProcessId}; startTicks={started.StartTimeUtcTicks}; " +
                $"runId={started.RunId}; " + (targetDomain is null ? "" : $"domain={targetDomain}; ") +
                "readiness not yet observed.");
            if (desiredReplicas > 1)
            {
                pendingObservations = 0;
            }
        }
        else
        {
            Console.WriteLine("Action=none; waiting for startup evidence, not issuing another start.");
        }

        if (++pendingObservations == 100)
        {
            throw new TimeoutException("The workload did not converge within 100 pending observations.");
        }
    }

    await Task.Delay(100);
}

static string Describe(IReadOnlyList<DiscoveredWorkload> realizations) =>
    string.Join("; ", realizations.Select(match =>
        $"domain={match.Domain},state={match.State},pid={match.Incarnation!.ProcessId}," +
        $"startTicks={match.Incarnation.StartTimeUtcTicks},runId={match.Incarnation.RunId}"));

static int? DomainNumber(string? domain) => DomainReconciliation.DomainNumber(domain);
