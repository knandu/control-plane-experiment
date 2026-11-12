using System.Text.Json;
using System.Text.Json.Serialization;

interface IPlatformStore
{
    PlatformState? Load();
    void Save(PlatformState state);
}

sealed record PlatformState(
    Guid WorkloadId,
    WorkloadState Desired,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Replicas = null)
{
    [JsonIgnore]
    public int EffectiveReplicas
    {
        get
        {
            var count = Replicas ?? 1;
            return count >= 1 ? count : throw new InvalidDataException("Replicas must be at least 1.");
        }
    }
}

sealed class FilePlatformStore(string path) : IPlatformStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        RespectRequiredConstructorParameters = true,
        Converters = { new JsonStringEnumConverter<WorkloadState>() }
    };

    public PlatformState? Load()
    {
        try
        {
            using var stream = File.OpenRead(path);
            return JsonSerializer.Deserialize<PlatformState>(stream, JsonOptions)
                ?? throw new InvalidDataException("Platform state must not be JSON null.");
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

    public void Save(PlatformState state)
    {
        var fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        var temporaryPath = fullPath + ".tmp";

        using (var stream = new FileStream(temporaryPath, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            JsonSerializer.Serialize(stream, state, JsonOptions);
            stream.Flush(flushToDisk: true);
        }

        File.Move(temporaryPath, fullPath, overwrite: true);
    }
}
