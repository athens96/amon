using System.Net;
using System.Net.Http.Json;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json.Serialization;

namespace AMon.Update;

public sealed record UpdateInfo(
    string Version,
    string Filename,
    string Sha256,
    long SizeBytes,
    string? Notes,
    string Architecture,
    string DownloadPlatform);

public enum AutomaticUpdateOutcome
{
    Disabled,
    NoUpdate,
    Ready
}

public sealed record AutomaticUpdateResult(
    AutomaticUpdateOutcome Outcome,
    UpdateInfo? Update = null,
    string? StagedPath = null);

public sealed class UpdateService
{
    private readonly HttpClient _httpClient;
    private readonly Architecture _processArchitecture;

    public UpdateService(HttpClient httpClient)
        : this(httpClient, RuntimeInformation.ProcessArchitecture)
    {
    }

    internal UpdateService(HttpClient httpClient, Architecture processArchitecture)
    {
        _httpClient = httpClient;
        _processArchitecture = processArchitecture;
    }

    public async Task<UpdateInfo?> CheckAsync(
        string serverUrl,
        Version currentVersion,
        CancellationToken cancellationToken = default)
    {
        var (architecture, platform) = CurrentReleaseTarget();
        var response = await GetLatestAsync(serverUrl, platform, cancellationToken);
        if ((response.StatusCode == HttpStatusCode.NotFound
                || response.StatusCode == HttpStatusCode.BadRequest)
            && platform == "windows-x64")
        {
            response.Dispose();
            platform = "windows";
            response = await GetLatestAsync(serverUrl, platform, cancellationToken);
        }
        using (response)
        {
            if (response.StatusCode == HttpStatusCode.NotFound) return null;
            response.EnsureSuccessStatusCode();
            var dto = await response.Content.ReadFromJsonAsync<ReleaseDto>(
                cancellationToken: cancellationToken)
                ?? throw new InvalidDataException("The release response was empty.");
            var responseArchitecture = dto.Architecture?.ToLowerInvariant();
            var legacyX64 = platform == "windows"
                && architecture == "x64"
                && responseArchitecture is null;
            if (!Version.TryParse(dto.Version, out var available)
                || string.IsNullOrWhiteSpace(dto.Filename)
                || dto.Filename != Path.GetFileName(dto.Filename)
                || dto.Sha256 is null
                || dto.Sha256.Length != 64
                || dto.Sha256.Any(character => !Uri.IsHexDigit(character))
                || (!legacyX64 && responseArchitecture != architecture))
            {
                throw new InvalidDataException("The release response was invalid.");
            }
            return available > currentVersion
                ? new UpdateInfo(
                    dto.Version!,
                    dto.Filename,
                    dto.Sha256.ToLowerInvariant(),
                    dto.SizeBytes,
                    dto.Notes,
                    architecture,
                    platform)
                : null;
        }
    }

    public async Task<AutomaticUpdateResult> PrepareAutomaticUpdateAsync(
        bool autoUpdateEnabled,
        string serverUrl,
        Version currentVersion,
        string stagingDirectory,
        CancellationToken cancellationToken = default)
    {
        if (!autoUpdateEnabled)
            return new AutomaticUpdateResult(AutomaticUpdateOutcome.Disabled);

        var update = await CheckAsync(serverUrl, currentVersion, cancellationToken);
        if (update is null)
            return new AutomaticUpdateResult(AutomaticUpdateOutcome.NoUpdate);

        var staged = await DownloadAndVerifyAsync(
            serverUrl, update, stagingDirectory, cancellationToken);
        return new AutomaticUpdateResult(AutomaticUpdateOutcome.Ready, update, staged);
    }

    public async Task<string> DownloadAndVerifyAsync(
        string serverUrl,
        UpdateInfo update,
        string stagingDirectory,
        CancellationToken cancellationToken = default)
    {
        var (architecture, platform) = CurrentReleaseTarget();
        if (update.Architecture != architecture
            || (update.DownloadPlatform != platform
                && !(architecture == "x64" && update.DownloadPlatform == "windows")))
        {
            throw new InvalidDataException(
                "The update architecture did not match the running process.");
        }
        Directory.CreateDirectory(stagingDirectory);
        var target = Path.Combine(stagingDirectory, update.Filename);
        var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var endpoint = ApiBase(serverUrl) + "/app/download/"
                + Uri.EscapeDataString(update.Version) + "?platform="
                + Uri.EscapeDataString(update.DownloadPlatform);
            await using var source = await _httpClient.GetStreamAsync(endpoint, cancellationToken);
            await using (var destination = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await source.CopyToAsync(destination, cancellationToken);
                await destination.FlushAsync(cancellationToken);
                destination.Flush(flushToDisk: true);
            }
            var info = new FileInfo(temporary);
            if (update.SizeBytes > 0 && info.Length != update.SizeBytes)
                throw new InvalidDataException("The update size did not match the manifest.");
            await using var file = File.OpenRead(temporary);
            var digest = Convert.ToHexString(
                await SHA256.HashDataAsync(file, cancellationToken)).ToLowerInvariant();
            if (!CryptographicOperations.FixedTimeEquals(
                Convert.FromHexString(digest), Convert.FromHexString(update.Sha256)))
                throw new InvalidDataException("The update SHA-256 did not match the manifest.");
            File.Move(temporary, target, overwrite: true);
            return target;
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private Task<HttpResponseMessage> GetLatestAsync(
        string serverUrl,
        string platform,
        CancellationToken cancellationToken)
    {
        var endpoint = ApiBase(serverUrl) + "/app/latest?platform="
            + Uri.EscapeDataString(platform);
        return _httpClient.GetAsync(endpoint, cancellationToken);
    }

    private (string Architecture, string Platform) CurrentReleaseTarget()
    {
        return _processArchitecture switch
        {
            Architecture.X64 => ("x64", "windows-x64"),
            Architecture.Arm64 => ("arm64", "windows-arm64"),
            _ => throw new PlatformNotSupportedException(
                $"Automatic updates are not available for {_processArchitecture}.")
        };
    }

    private static string ApiBase(string serverUrl)
    {
        var root = serverUrl.Trim().TrimEnd('/');
        var marker = root.IndexOf("/api/v1", StringComparison.OrdinalIgnoreCase);
        if (marker >= 0) root = root[..marker];
        if (!Uri.TryCreate(root, UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttps && uri.Host != "127.0.0.1"
                && uri.Host != "localhost"))
            throw new ArgumentException("A valid HTTPS server URL is required.", nameof(serverUrl));
        return root + "/api/v1";
    }

    private sealed record ReleaseDto(
        [property: JsonPropertyName("version")] string? Version,
        [property: JsonPropertyName("filename")] string Filename,
        [property: JsonPropertyName("sha256")] string? Sha256,
        [property: JsonPropertyName("size_bytes")] long SizeBytes,
        [property: JsonPropertyName("notes")] string? Notes,
        [property: JsonPropertyName("architecture")] string? Architecture);
}
