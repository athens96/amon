using System.Net;
using System.Net.Http.Json;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using AMon.Update;

namespace AMon.Update.Tests;

public sealed class UpdateServiceTests
{
    [Fact]
    public async Task DisabledAutomaticUpdatesDoNotMakeNetworkRequests()
    {
        var handler = new StubHandler(_ => throw new InvalidOperationException("network called"));
        var service = new UpdateService(new HttpClient(handler));
        var result = await service.PrepareAutomaticUpdateAsync(
            false, "https://amon.example", new Version(1, 0, 0), Path.GetTempPath(),
            TestContext.Current.CancellationToken);
        Assert.Equal(AutomaticUpdateOutcome.Disabled, result.Outcome);
        Assert.Equal(0, handler.Requests);
    }

    [Fact]
    public async Task EnabledAutomaticUpdatesStageAValidatedArtifact()
    {
        var bytes = "wpf-release"u8.ToArray();
        var sha = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        var handler = new StubHandler(request => request.RequestUri!.AbsolutePath.EndsWith("/latest")
            ? new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new
                {
                    version = "2.0.0", filename = "amon-windows-2.0.0.zip",
                    sha256 = sha, size_bytes = bytes.Length, notes = "rewrite",
                    architecture = "x64"
                })
            }
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) });
        var directory = Path.Combine(Path.GetTempPath(), "amon-update-" + Guid.NewGuid().ToString("N"));
        try
        {
            var result = await new UpdateService(new HttpClient(handler), Architecture.X64)
                .PrepareAutomaticUpdateAsync(
                    true, "https://amon.example", new Version(1, 0, 0), directory,
                    TestContext.Current.CancellationToken);
            Assert.Equal(AutomaticUpdateOutcome.Ready, result.Outcome);
            Assert.Equal(bytes, await File.ReadAllBytesAsync(
                result.StagedPath!, TestContext.Current.CancellationToken));
            Assert.All(handler.RequestUris, uri =>
                Assert.Equal("windows-x64", QueryPlatform(uri)));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Arm64RequestsOnlyTheArm64Channel()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.NotFound));
        var result = await new UpdateService(new HttpClient(handler), Architecture.Arm64)
            .CheckAsync(
                "https://amon.example",
                new Version(1, 0, 0),
                TestContext.Current.CancellationToken);

        Assert.Null(result);
        var request = Assert.Single(handler.RequestUris);
        Assert.Equal("windows-arm64", QueryPlatform(request));
    }

    [Fact]
    public async Task X64CanFallBackToTheLegacyWindowsChannel()
    {
        var sha = new string('a', 64);
        var handler = new StubHandler(request =>
            QueryPlatform(request.RequestUri!) == "windows-x64"
                ? new HttpResponseMessage(HttpStatusCode.BadRequest)
                : new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new
                    {
                        version = "2.0.0",
                        filename = "amon-windows-2.0.0.zip",
                        sha256 = sha,
                        size_bytes = 12
                    })
                });

        var update = await new UpdateService(new HttpClient(handler), Architecture.X64)
            .CheckAsync(
                "https://amon.example",
                new Version(1, 0, 0),
                TestContext.Current.CancellationToken);

        Assert.NotNull(update);
        Assert.Equal("x64", update.Architecture);
        Assert.Equal("windows", update.DownloadPlatform);
        Assert.Equal(
            ["windows-x64", "windows"],
            handler.RequestUris.Select(QueryPlatform));
    }

    [Fact]
    public async Task RejectsAManifestForAnotherArchitecture()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new
            {
                version = "2.0.0",
                filename = "amon-windows-arm64-2.0.0.zip",
                sha256 = new string('a', 64),
                size_bytes = 12,
                architecture = "arm64"
            })
        });

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            new UpdateService(new HttpClient(handler), Architecture.X64).CheckAsync(
                "https://amon.example",
                new Version(1, 0, 0),
                TestContext.Current.CancellationToken));
        Assert.Equal(1, handler.Requests);
    }

    [Fact]
    public async Task RejectsPrereleaseVersionsFromTheStableWindowsChannel()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new
            {
                version = "2.0.0-beta",
                filename = "amon-windows-x64-2.0.0-beta.zip",
                sha256 = new string('a', 64),
                size_bytes = 12,
                architecture = "x64"
            })
        });

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            new UpdateService(new HttpClient(handler), Architecture.X64).CheckAsync(
                "https://amon.example",
                new Version(1, 0, 0),
                TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task CurrentReleaseVersionDoesNotTriggerAnotherUpdate()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new
            {
                version = "2.4.1",
                filename = "amon-windows-x64-2.4.1.zip",
                sha256 = new string('a', 64),
                size_bytes = 12,
                architecture = "x64"
            })
        });

        var update = await new UpdateService(new HttpClient(handler), Architecture.X64)
            .CheckAsync(
                "https://amon.example",
                new Version(2, 4, 1),
                TestContext.Current.CancellationToken);

        Assert.Null(update);
        Assert.Equal(1, handler.Requests);
    }

    [Fact]
    public async Task Arm64RejectsAnUnlabelledManifest()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new
            {
                version = "2.0.0",
                filename = "amon-windows-2.0.0.zip",
                sha256 = new string('a', 64),
                size_bytes = 12
            })
        });

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            new UpdateService(new HttpClient(handler), Architecture.Arm64).CheckAsync(
                "https://amon.example",
                new Version(1, 0, 0),
                TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task RefusesToDownloadUpdateInfoForAnotherArchitecture()
    {
        var handler = new StubHandler(_ => throw new InvalidOperationException("network called"));
        var update = new UpdateInfo(
            "2.0.0",
            "amon-windows-arm64-2.0.0.zip",
            new string('a', 64),
            12,
            null,
            "arm64",
            "windows-arm64");

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            new UpdateService(new HttpClient(handler), Architecture.X64)
                .DownloadAndVerifyAsync(
                    "https://amon.example",
                    update,
                    Path.GetTempPath(),
                    TestContext.Current.CancellationToken));
        Assert.Equal(0, handler.Requests);
    }

    [Fact]
    public async Task UnsupportedProcessArchitectureDoesNotMakeNetworkRequests()
    {
        var handler = new StubHandler(_ => throw new InvalidOperationException("network called"));

        await Assert.ThrowsAsync<PlatformNotSupportedException>(() =>
            new UpdateService(new HttpClient(handler), Architecture.X86).CheckAsync(
                "https://amon.example",
                new Version(1, 0, 0),
                TestContext.Current.CancellationToken));
        Assert.Equal(0, handler.Requests);
    }

    private static string? QueryPlatform(Uri uri)
    {
        return uri.Query.TrimStart('?')
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Split('=', 2))
            .Where(parts => parts.Length == 2 && parts[0] == "platform")
            .Select(parts => Uri.UnescapeDataString(parts[1]))
            .FirstOrDefault();
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        public int Requests { get; private set; }
        public List<Uri> RequestUris { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            RequestUris.Add(request.RequestUri!);
            return Task.FromResult(response(request));
        }
    }
}
