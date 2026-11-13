// Day 4 per-domain victim selection, shared by the local manager and the Day 5.4 cluster projection.
// Order: surplus domain, then collision non-keeper, then the lowest-numbered Degraded realization.
static class DomainReconciliation
{
    public static DiscoveredWorkload? SelectVictim(IReadOnlyList<DiscoveredWorkload> realizations, int desiredReplicas)
    {
        var victim = realizations.Where(match => DomainNumber(match.Domain) > desiredReplicas)
            .OrderByDescending(match => DomainNumber(match.Domain))
            .ThenByDescending(match => HealthPriority(match.State))
            .ThenByDescending(match => match.Incarnation!.StartTimeUtcTicks)
            .ThenByDescending(match => match.Incarnation!.ProcessId)
            .ThenByDescending(match => match.Incarnation!.RunId)
            .FirstOrDefault();
        if (victim is null)
        {
            var collision = realizations.GroupBy(match => match.Domain, StringComparer.Ordinal)
                .Where(group => group.Count() > 1)
                .OrderBy(group => DomainNumber(group.Key))
                .FirstOrDefault();
            if (collision is not null)
            {
                var keeper = collision.OrderBy(match => HealthPriority(match.State))
                    .ThenBy(match => match.Incarnation!.StartTimeUtcTicks)
                    .ThenBy(match => match.Incarnation!.ProcessId)
                    .ThenBy(match => match.Incarnation!.RunId)
                    .First();
                victim = collision.Where(match => match != keeper)
                    .OrderByDescending(match => HealthPriority(match.State))
                    .ThenByDescending(match => match.Incarnation!.StartTimeUtcTicks)
                    .ThenByDescending(match => match.Incarnation!.ProcessId)
                    .ThenByDescending(match => match.Incarnation!.RunId)
                    .First();
            }
        }

        return victim ?? realizations.Where(match => match.State == WorkloadState.Degraded)
            .OrderBy(match => DomainNumber(match.Domain))
            .FirstOrDefault();
    }

    public static int HealthPriority(WorkloadState state) => state switch
    {
        WorkloadState.Running => 0,
        WorkloadState.Starting => 1,
        WorkloadState.Degraded => 2,
        _ => throw new InvalidOperationException($"Unexpected live realization state: {state}.")
    };

    public static int? DomainNumber(string? domain) =>
        domain is not null && domain.StartsWith("domain-", StringComparison.Ordinal)
        && int.TryParse(domain.AsSpan(7), System.Globalization.NumberStyles.None,
            System.Globalization.CultureInfo.InvariantCulture, out var number)
        && number > 0 && domain == $"domain-{number.ToString(System.Globalization.CultureInfo.InvariantCulture)}"
            ? number : null;
}
