using System.Diagnostics;
using System.Runtime.Versioning;

[SupportedOSPlatform("windows")]
static class ClusterManagement
{
    public static async Task ObserveAsync(string statePath, string clusterName, string groupName, int observations)
    {
        if (observations is < 1 or > 100)
        {
            throw new ArgumentOutOfRangeException(nameof(observations), "Use between 1 and 100 observations.");
        }

        var state = new FilePlatformStore(statePath).Load()
            ?? throw new InvalidOperationException("No durable intent exists. Run intent <state-file> first.");
        if (state.Desired != WorkloadState.Running || state.WorkloadId == Guid.Empty)
        {
            throw new InvalidDataException("This checkpoint requires a named workload with Running intent.");
        }

        var desiredReplicas = state.EffectiveReplicas;
        var authority = new ClusterAuthority(clusterName, groupName);
        using var manager = Process.GetCurrentProcess();
        Console.WriteLine(
            $"Cluster manager={manager.Id}; managerStartTicks={manager.StartTime.ToUniversalTime().Ticks}; " +
            $"workload={state.WorkloadId}; effects=disabled; fencing=unproven.");

        for (var observation = 1; observation <= observations; observation++)
        {
            var current = authority.Observe();
            Console.WriteLine(
                $"Cluster authority: observation={observation}; cluster={clusterName}; group={groupName}; " +
                $"localNode={current.LocalNode}; ownerNode={current.OwnerNode}; groupState={current.GroupState}; " +
                $"nodeState={current.NodeState}; authoritative={current.IsAuthoritative.ToString().ToLowerInvariant()}; " +
                $"at={DateTimeOffset.UtcNow:O}.");

            if (!current.IsAuthoritative)
            {
                Console.WriteLine(
                    $"Cluster reconciliation: observation={observation}; admission=skipped; reason=not-current-owner-or-not-stable; " +
                    "reconciliationAttempted=false; effects=disabled; starts=0; stops=0.");
            }
            else
            {
                // Day 5.1 admits only the observation portion of reconciliation. No ownership query
                // here can authorize a later Start/Stop; that check-to-effect boundary is still open.
                var realizations = desiredReplicas == 1
                    ? SingleRealization(state.WorkloadId)
                    : Workload.DiscoverAll(state.WorkloadId);
                Console.WriteLine(
                    $"Cluster reconciliation: observation={observation}; admission=admitted; reconciliationAttempted=true; " +
                    $"workload={state.WorkloadId}; desiredReplicas={desiredReplicas}; liveCount={realizations.Count}; " +
                    $"runningCount={realizations.Count(match => match.State == WorkloadState.Running)}; " +
                    $"startingCount={realizations.Count(match => match.State == WorkloadState.Starting)}; " +
                    $"degradedCount={realizations.Count(match => match.State == WorkloadState.Degraded)}; " +
                    "scope=local-observation-only; effects=disabled; starts=0; stops=0.");
            }

            if (observation < observations)
            {
                await Task.Delay(250);
            }
        }
    }

    private static IReadOnlyList<DiscoveredWorkload> SingleRealization(Guid workloadId)
    {
        var fresh = Workload.Discover(workloadId);
        return fresh.Incarnation is null ? [] : [fresh];
    }
}
