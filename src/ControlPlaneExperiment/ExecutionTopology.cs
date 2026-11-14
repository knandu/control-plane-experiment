using System.Text.RegularExpressions;

sealed record EligibleDomain(string Name, string Fence);

// The configured, ordered set of execution domains a site may be realized in. This is experiment topology
// supplied at runtime (one name=fence entry per domain), not cluster membership: it is never derived from WFC
// node state, and its size is not an architectural replica limit. Order is the fixed preference projection
// (replicas=N realizes the first N configured domains); it is not a scheduler.
sealed class ExecutionTopology
{
    private ExecutionTopology(IReadOnlyList<EligibleDomain> domains) => Domains = domains;

    public IReadOnlyList<EligibleDomain> Domains { get; }

    public int Count => Domains.Count;

    public static bool IsValidName(string? name) => name is not null && Regex.IsMatch(name, @"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$");

    public static ExecutionTopology Parse(IReadOnlyList<string> entries)
    {
        if (entries.Count == 0)
        {
            throw new ArgumentException("At least one eligible execution domain (name=host:port) must be configured.");
        }
        var domains = entries.Select(entry =>
        {
            var separator = entry.IndexOf('=');
            var name = separator < 0 ? null : entry[..separator];
            var fence = separator < 0 ? "" : entry[(separator + 1)..];
            var port = fence.LastIndexOf(':');
            if (!IsValidName(name) || port <= 0 || !int.TryParse(fence.AsSpan(port + 1), out var number) || number is < 1 or > 65535)
            {
                throw new ArgumentException($"Eligible domain '{entry}' must be name=host:port.");
            }
            return new EligibleDomain(name!, fence);
        }).ToArray();
        if (domains.DistinctBy(domain => domain.Name, StringComparer.Ordinal).Count() != domains.Length
            || domains.DistinctBy(domain => domain.Fence, StringComparer.OrdinalIgnoreCase).Count() != domains.Length)
        {
            throw new ArgumentException("Eligible domain names and fence endpoints must be unique.");
        }
        return new ExecutionTopology(domains);
    }

    // 1-based configured position; null for a domain outside the configured topology.
    public int? Rank(string? domain)
    {
        for (var index = 0; index < Domains.Count; index++)
        {
            if (string.Equals(Domains[index].Name, domain, StringComparison.Ordinal))
            {
                return index + 1;
            }
        }
        return null;
    }

    public IReadOnlyList<EligibleDomain> Required(int replicas) => Domains.Take(replicas).ToArray();

    public string Describe() => string.Join(",", Domains.Select(domain => domain.Name));
}
