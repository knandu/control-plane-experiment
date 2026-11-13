using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

sealed record ClusterAuthorityObservation(string LocalNode, string OwnerNode, string GroupState, string NodeState)
{
    public bool IsAuthoritative =>
        string.Equals(LocalNode, OwnerNode, StringComparison.OrdinalIgnoreCase)
        && NodeState == "Up" && GroupState is "Online" or "Offline";
}

[SupportedOSPlatform("windows")]
sealed class ClusterAuthority(string clusterName, string groupName)
{
    // This is an ownership observation, not a grant retained across the check-to-effect interval.
    // AuthorityGrant's same-session mutex is deliberately not substituted with this cluster query.
    public ClusterAuthorityObservation Observe()
    {
        var cluster = OpenCluster(null);
        if (cluster == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), $"Cannot open cluster '{clusterName}'.");
        }

        try
        {
            var actualCluster = new StringBuilder(256);
            var clusterLength = (uint)actualCluster.Capacity;
            var informationError = GetClusterInformation(cluster, actualCluster, ref clusterLength, IntPtr.Zero);
            if (informationError != 0)
            {
                throw new Win32Exception(checked((int)informationError), "Cannot identify the local cluster.");
            }
            if (!string.Equals(actualCluster.ToString(), clusterName, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException($"Local cluster '{actualCluster}' does not match expected '{clusterName}'.");
            }

            var group = OpenClusterGroup(cluster, groupName);
            if (group == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"Cannot open authority group '{groupName}'.");
            }

            try
            {
                var owner = new StringBuilder(256);
                var length = (uint)owner.Capacity;
                var groupState = GetClusterGroupState(group, owner, ref length);
                if (groupState == -1)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot observe authority group ownership.");
                }

                if (owner.Length == 0)
                {
                    throw new InvalidDataException("Cluster authority observation returned no owner.");
                }

                var localNode = Environment.MachineName;
                var node = OpenClusterNode(cluster, localNode);
                if (node == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), $"Local machine '{localNode}' is not an available cluster node.");
                }

                try
                {
                    var nodeState = GetClusterNodeState(node);
                    if (nodeState == -1)
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot observe local cluster node state.");
                    }

                    return new ClusterAuthorityObservation(localNode, owner.ToString(), groupState switch
                    {
                        0 => "Online",
                        1 => "Offline",
                        2 => "Failed",
                        3 => "PartialOnline",
                        4 => "Pending",
                        _ => throw new InvalidDataException($"Unrecognized cluster group state: {groupState}.")
                    }, nodeState switch
                    {
                        0 => "Up",
                        1 => "Down",
                        2 => "Paused",
                        3 => "Joining",
                        _ => throw new InvalidDataException($"Unrecognized cluster node state: {nodeState}.")
                    });
                }
                finally
                {
                    CloseClusterNode(node);
                }
            }
            finally
            {
                CloseClusterGroup(group);
            }
        }
        finally
        {
            CloseCluster(cluster);
        }
    }

    [DllImport("clusapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenCluster(string? clusterName);

    [DllImport("clusapi.dll", CharSet = CharSet.Unicode)]
    private static extern uint GetClusterInformation(
        IntPtr cluster, StringBuilder clusterName, ref uint length, IntPtr versionInfo);

    [DllImport("clusapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenClusterGroup(IntPtr cluster, string groupName);

    [DllImport("clusapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClusterGroupState(IntPtr group, StringBuilder ownerNode, ref uint length);

    [DllImport("clusapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenClusterNode(IntPtr cluster, string nodeName);

    [DllImport("clusapi.dll", SetLastError = true)]
    private static extern int GetClusterNodeState(IntPtr node);

    [DllImport("clusapi.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseClusterNode(IntPtr node);

    [DllImport("clusapi.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseClusterGroup(IntPtr group);

    [DllImport("clusapi.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseCluster(IntPtr cluster);
}
