using System.Text.Json;

namespace AMon.LocalData;

public sealed class ConfigStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    public ConfigStore(string? path = null)
    {
        Path = path ?? System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "A-mon",
            "config.json");
    }

    public string Path { get; }
    public string BackupPath => Path + ".bak";

    public async Task<AppConfig> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(Path))
        {
            var created = NewConfig();
            await SaveAsync(created, cancellationToken);
            return created;
        }

        AppConfig config;
        await using (var stream = File.OpenRead(Path))
        {
            config = await JsonSerializer.DeserializeAsync<AppConfig>(
                stream,
                JsonOptions,
                cancellationToken)
                ?? throw new InvalidDataException("Configuration file contained JSON null.");
        }
        config.Paths ??= new ToolPaths();
        config.Pet ??= new PetConfig();
        if (string.IsNullOrWhiteSpace(config.DeviceId))
        {
            config.DeviceId = Guid.NewGuid().ToString("D");
            await SaveAsync(config, cancellationToken);
        }

        return config;
    }

    public async Task SaveAsync(AppConfig config, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(config);
        if (string.IsNullOrWhiteSpace(config.DeviceId))
            config.DeviceId = Guid.NewGuid().ToString("D");

        var directory = System.IO.Path.GetDirectoryName(Path)
            ?? throw new InvalidOperationException("Configuration path has no directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = System.IO.Path.Combine(directory, $".{System.IO.Path.GetFileName(Path)}.{Guid.NewGuid():N}.tmp");

        try
        {
            await using (var stream = new FileStream(
                temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, config, JsonOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }

            if (File.Exists(Path))
                File.Replace(temporaryPath, Path, BackupPath, ignoreMetadataErrors: true);
            else
                File.Move(temporaryPath, Path);
        }
        finally
        {
            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);
        }
    }

    private static AppConfig NewConfig() => new() { DeviceId = Guid.NewGuid().ToString("D") };
}
