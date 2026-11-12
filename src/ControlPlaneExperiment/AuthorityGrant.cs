using System.Globalization;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;

sealed class AuthorityRejectedException(long offered, long current, string boundary)
    : InvalidOperationException(
        $"Authority rejected: boundary={boundary}; offeredEpoch={offered}; currentEpoch={current}; " +
        $"at={DateTimeOffset.UtcNow:O}.");

[SupportedOSPlatform("windows")]
sealed class AuthorityGrant
{
    private readonly string path;
    private readonly string mutexName;

    public long Epoch { get; }

    public AuthorityGrant(string path, long epoch)
    {
        if (epoch <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(epoch), "Use a positive authority epoch.");
        }

        this.path = Path.GetFullPath(path);
        mutexName = $@"Local\ControlPlaneExperiment-Authority-{Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(this.path.ToUpperInvariant())))}";
        Epoch = epoch;
    }

    public void Advance()
    {
        Console.WriteLine($"Authority advance requested: offeredEpoch={Epoch}; at={DateTimeOffset.UtcNow:O}.");
        Locked(() =>
        {
            var current = ReadEpoch();
            if (current is { } previous && Epoch <= previous)
            {
                throw new AuthorityRejectedException(Epoch, previous, "grant");
            }

            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporaryPath = path + ".tmp";
            using (var stream = new FileStream(temporaryPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                stream.Write(Encoding.UTF8.GetBytes(Epoch.ToString(CultureInfo.InvariantCulture)));
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, path, overwrite: true);
            Console.WriteLine(
                $"Authority advanced: previousEpoch={current?.ToString(CultureInfo.InvariantCulture) ?? "none"}; " +
                $"currentEpoch={Epoch}; at={DateTimeOffset.UtcNow:O}.");
            return true;
        });
    }

    public T WithCurrent<T>(string boundary, Func<T> effect) => Locked(() =>
    {
        var current = ReadEpoch()
            ?? throw new InvalidOperationException("No recorded authority grant exists.");
        if (Epoch != current)
        {
            throw new AuthorityRejectedException(Epoch, current, boundary);
        }

        Console.WriteLine(
            $"Authority accepted: boundary={boundary}; offeredEpoch={Epoch}; currentEpoch={current}; " +
            $"at={DateTimeOffset.UtcNow:O}.");
        return effect();
    });

    private T Locked<T>(Func<T> operation)
    {
        using var mutex = new Mutex(false, mutexName);
        if (!mutex.WaitOne(0))
        {
            Console.WriteLine($"Authority lock waiting: offeredEpoch={Epoch}; at={DateTimeOffset.UtcNow:O}.");
            mutex.WaitOne();
        }

        try
        {
            return operation();
        }
        finally
        {
            mutex.ReleaseMutex();
        }
    }

    private long? ReadEpoch()
    {
        try
        {
            var epoch = long.Parse(File.ReadAllText(path), CultureInfo.InvariantCulture);
            return epoch > 0 ? epoch : throw new InvalidDataException("Recorded authority must be positive.");
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }
    }
}
