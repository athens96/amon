using System.IO.Compression;
using System.Text;
using AMon.Update;

namespace AMon.Update.Tests;

public sealed class ArchiveInstallerTests
{
    [Fact]
    public void InstallsTheEntirePayloadAndRemovesFilesMissingFromTheRelease()
    {
        using var fixture = new InstallerFixture();
        fixture.WriteInstalled("A-mon.exe", "old app");
        fixture.WriteInstalled("Hooks/AMon.ClaudeHook.exe", "old hook");
        fixture.WriteInstalled("obsolete.dll", "old");
        fixture.CreateArchive(new Dictionary<string, string>
        {
            ["release/A-mon.exe"] = "new app",
            ["release/Hooks/AMon.ClaudeHook.exe"] = "new hook",
            ["release/AMon.Updater.exe"] = "new updater",
            ["release/current.dll"] = "new library",
        });
        var verified = new List<string>();
        string? launched = null;

        ArchiveInstaller.InstallAndLaunch(
            fixture.Archive,
            fixture.Application,
            fixture.DetachedUpdater,
            executable => verified.Add(Path.GetFileName(executable)),
            executable => launched = executable);

        Assert.Equal(fixture.Application, launched);
        Assert.Equal("new app", File.ReadAllText(fixture.Application));
        Assert.Equal(
            "new hook",
            File.ReadAllText(Path.Combine(
                fixture.InstallDirectory, "Hooks", "AMon.ClaudeHook.exe")));
        Assert.Equal(
            "new updater",
            File.ReadAllText(Path.Combine(fixture.InstallDirectory, "AMon.Updater.exe")));
        Assert.True(File.Exists(Path.Combine(fixture.InstallDirectory, "current.dll")));
        Assert.False(File.Exists(Path.Combine(fixture.InstallDirectory, "obsolete.dll")));
        Assert.Equal(
            ["A-mon.exe", "AMon.ClaudeHook.exe", "AMon.Updater.exe"],
            verified.Order(StringComparer.OrdinalIgnoreCase));
    }

    [Fact]
    public void LaunchFailureRollsBackTheWholeInstallation()
    {
        using var fixture = new InstallerFixture();
        fixture.WriteInstalled("A-mon.exe", "old app");
        fixture.WriteInstalled("Hooks/AMon.ClaudeHook.exe", "old hook");
        fixture.WriteInstalled("old-only.dll", "keep");
        fixture.CreateArchive(new Dictionary<string, string>
        {
            ["A-mon.exe"] = "new app",
            ["Hooks/AMon.ClaudeHook.exe"] = "new hook",
            ["new-only.dll"] = "remove on rollback",
        });

        Assert.Throws<InvalidOperationException>(() =>
            ArchiveInstaller.InstallAndLaunch(
                fixture.Archive,
                fixture.Application,
                fixture.DetachedUpdater,
                _ => { },
                _ => throw new InvalidOperationException("launch failed")));

        Assert.Equal("old app", File.ReadAllText(fixture.Application));
        Assert.Equal(
            "old hook",
            File.ReadAllText(Path.Combine(
                fixture.InstallDirectory, "Hooks", "AMon.ClaudeHook.exe")));
        Assert.True(File.Exists(Path.Combine(fixture.InstallDirectory, "old-only.dll")));
        Assert.False(File.Exists(Path.Combine(fixture.InstallDirectory, "new-only.dll")));
    }

    [Fact]
    public void ExecutableVerificationFailureLeavesTheInstallationUntouched()
    {
        using var fixture = new InstallerFixture();
        fixture.WriteInstalled("A-mon.exe", "old app");
        fixture.CreateArchive(new Dictionary<string, string>
        {
            ["A-mon.exe"] = "new app",
            ["Hooks/AMon.ClaudeHook.exe"] = "unsigned",
        });

        Assert.Throws<InvalidDataException>(() =>
            ArchiveInstaller.InstallAndLaunch(
                fixture.Archive,
                fixture.Application,
                fixture.DetachedUpdater,
                executable =>
                {
                    if (executable.EndsWith(
                            "AMon.ClaudeHook.exe", StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException("unsigned");
                    }
                },
                _ => throw new Xunit.Sdk.XunitException("must not launch")));

        Assert.Equal("old app", File.ReadAllText(fixture.Application));
        Assert.False(Directory.Exists(Path.Combine(fixture.InstallDirectory, "Hooks")));
    }

    [Fact]
    public void RejectsTraversalBeforeChangingTheInstallation()
    {
        using var fixture = new InstallerFixture();
        fixture.WriteInstalled("A-mon.exe", "old app");
        fixture.CreateArchive(new Dictionary<string, string>
        {
            ["payload/A-mon.exe"] = "new app",
            ["payload/../../escaped.txt"] = "escape",
        });

        Assert.Throws<InvalidDataException>(() =>
            ArchiveInstaller.InstallAndLaunch(
                fixture.Archive,
                fixture.Application,
                fixture.DetachedUpdater,
                _ => { },
                _ => { }));

        Assert.Equal("old app", File.ReadAllText(fixture.Application));
        Assert.False(File.Exists(Path.Combine(fixture.Root, "escaped.txt")));
    }

    [Fact]
    public void RejectsAnUpdaterRunningInsideTheInstallationTree()
    {
        using var fixture = new InstallerFixture();
        fixture.WriteInstalled("A-mon.exe", "old app");
        var inTreeUpdater = fixture.WriteInstalled("AMon.Updater.exe", "running");
        fixture.CreateArchive(new Dictionary<string, string>
        {
            ["A-mon.exe"] = "new app",
            ["AMon.Updater.exe"] = "replacement",
        });

        Assert.Throws<InvalidOperationException>(() =>
            ArchiveInstaller.InstallAndLaunch(
                fixture.Archive,
                fixture.Application,
                inTreeUpdater,
                _ => { },
                _ => { }));

        Assert.Equal("old app", File.ReadAllText(fixture.Application));
        Assert.Equal("running", File.ReadAllText(inTreeUpdater));
    }

    [Fact]
    public void SupportsAnArchiveStagedUnderTheInstallationWhenUpdaterIsExternal()
    {
        using var fixture = new InstallerFixture(archiveInsideInstallation: true);
        fixture.WriteInstalled("A-mon.exe", "old app");
        fixture.CreateArchive(new Dictionary<string, string>
        {
            ["A-mon.exe"] = "new app",
            ["Hooks/AMon.ClaudeHook.exe"] = "new hook",
        });

        ArchiveInstaller.InstallAndLaunch(
            fixture.Archive,
            fixture.Application,
            fixture.DetachedUpdater,
            _ => { },
            _ => { });

        Assert.Equal("new app", File.ReadAllText(fixture.Application));
        Assert.True(File.Exists(Path.Combine(
            fixture.InstallDirectory, "Hooks", "AMon.ClaudeHook.exe")));
    }

    [Fact]
    public void RejectsCaseInsensitiveDuplicatePaths()
    {
        using var fixture = new InstallerFixture();
        fixture.WriteInstalled("A-mon.exe", "old app");
        fixture.CreateArchive(new Dictionary<string, string>
        {
            ["A-mon.exe"] = "new app",
            ["Hooks/AMon.ClaudeHook.exe"] = "one",
            ["hooks/amon.claudehook.exe"] = "two",
        });

        Assert.Throws<InvalidDataException>(() =>
            ArchiveInstaller.InstallAndLaunch(
                fixture.Archive,
                fixture.Application,
                fixture.DetachedUpdater,
                _ => { },
                _ => { }));
        Assert.Equal("old app", File.ReadAllText(fixture.Application));
    }

    private sealed class InstallerFixture : IDisposable
    {
        public InstallerFixture(bool archiveInsideInstallation = false)
        {
            Root = Path.Combine(
                Path.GetTempPath(), "amon-installer-test-" + Guid.NewGuid().ToString("N"));
            InstallDirectory = Path.Combine(Root, "installed");
            Directory.CreateDirectory(InstallDirectory);
            Application = Path.Combine(InstallDirectory, "A-mon.exe");
            DetachedUpdater = Path.Combine(Root, "AMon.Updater.detached-test.exe");
            File.WriteAllText(DetachedUpdater, "helper");
            Archive = archiveInsideInstallation
                ? Path.Combine(InstallDirectory, "updates", "release.zip")
                : Path.Combine(Root, "release.zip");
        }

        public string Root { get; }
        public string InstallDirectory { get; }
        public string Application { get; }
        public string DetachedUpdater { get; }
        public string Archive { get; }

        public string WriteInstalled(string relativePath, string content)
        {
            var path = Path.Combine(
                InstallDirectory,
                relativePath.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, content);
            return path;
        }

        public void CreateArchive(IReadOnlyDictionary<string, string> entries)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Archive)!);
            using var zip = ZipFile.Open(Archive, ZipArchiveMode.Create);
            foreach (var pair in entries)
            {
                var entry = zip.CreateEntry(pair.Key);
                using var output = entry.Open();
                var bytes = Encoding.UTF8.GetBytes(pair.Value);
                output.Write(bytes);
            }
        }

        public void Dispose()
        {
            if (Directory.Exists(Root))
                Directory.Delete(Root, recursive: true);
        }
    }
}
