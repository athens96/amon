using System.IO.Compression;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace AMon.App.Tests;

public sealed class CodexPetAssetServiceTests
{
    [Fact]
    public void ImportsMacCompatiblePngIntoApplicationData()
    {
        using var sandbox = new TestDirectory();
        var source = Path.Combine(sandbox.Path, "pet.png");
        File.WriteAllBytes(source, CreateSpritePng());

        var result = CodexPetAssetService.Import(
            source,
            spriteVersion: 1,
            applicationDataRoot: sandbox.Path);

        Assert.Equal(
            Path.Combine(sandbox.Path, "A-mon", "pets", "spritesheet.png"),
            result.InstalledPath);
        Assert.True(File.Exists(result.InstalledPath));
        Assert.Equal(CodexPetAssetFormat.Png, result.Metadata.Format);
        Assert.Equal(1536, result.Metadata.PixelWidth);
        Assert.Equal(1872, result.Metadata.PixelHeight);
        Assert.Equal(1, result.Metadata.SpriteVersion);
        Assert.True(CodexPetAssetService.IsValidSprite(result.InstalledPath));
    }

    [Fact]
    public void ImportsManifestPackageAndKeepsDisplayName()
    {
        using var sandbox = new TestDirectory();
        var package = Path.Combine(sandbox.Path, "pet.zip");
        using (var archive = ZipFile.Open(package, ZipArchiveMode.Create))
        {
            WriteEntry(
                archive,
                "friendly/pet.json",
                Encoding.UTF8.GetBytes(
                    """{"displayName":"Codex Buddy","spritesheetPath":"assets/spritesheet.png","spriteVersionNumber":2}"""));
            WriteEntry(
                archive,
                "friendly/assets/spritesheet.png",
                CreatePng(
                    CodexPetSpriteLayout.SheetPixelWidth,
                    CodexPetSpriteLayout.V2SheetPixelHeight));
        }

        var result = CodexPetAssetService.Import(
            package,
            spriteVersion: 1,
            applicationDataRoot: sandbox.Path);

        Assert.Equal("Codex Buddy", result.DisplayName);
        Assert.Equal(2, result.Metadata.SpriteVersion);
        Assert.Equal(2288, result.Metadata.PixelHeight);
        Assert.True(File.Exists(result.InstalledPath));
    }

    [Fact]
    public void ImportsV3ManifestPackageAndKeepsRunningAwayRowContract()
    {
        using var sandbox = new TestDirectory();
        var package = Path.Combine(sandbox.Path, "pet-v3.zip");
        using (var archive = ZipFile.Open(package, ZipArchiveMode.Create))
        {
            WriteEntry(
                archive,
                "pet.json",
                Encoding.UTF8.GetBytes(
                    """{"displayName":"amon","spritesheetPath":"spritesheet.png","spriteVersionNumber":3}"""));
            WriteEntry(
                archive,
                "spritesheet.png",
                CreatePng(
                    CodexPetSpriteLayout.SheetPixelWidth,
                    CodexPetSpriteLayout.V3SheetPixelHeight));
        }

        var result = CodexPetAssetService.Import(
            package,
            spriteVersion: 1,
            applicationDataRoot: sandbox.Path);

        Assert.Equal(3, result.Metadata.SpriteVersion);
        Assert.Equal(2496, result.Metadata.PixelHeight);
    }

    [Fact]
    public void RejectsSpriteWithWrongDimensions()
    {
        var data = CreatePng(192, 208);

        var exception = Assert.Throws<InvalidDataException>(
            () => CodexPetAssetService.Validate(data, spriteVersion: 1));

        Assert.Contains("1536", exception.Message);
        Assert.Contains("1872", exception.Message);
    }

    [Fact]
    public void RejectsArchivePathTraversal()
    {
        using var sandbox = new TestDirectory();
        var package = Path.Combine(sandbox.Path, "unsafe.zip");
        using (var archive = ZipFile.Open(package, ZipArchiveMode.Create))
        {
            WriteEntry(archive, "../spritesheet.png", CreateSpritePng());
        }

        Assert.Throws<InvalidDataException>(
            () => CodexPetAssetService.Import(
                package,
                spriteVersion: 1,
                applicationDataRoot: sandbox.Path));
    }

    [Fact]
    public void ImportsExternalCodexPetArchiveWhenProvided()
    {
        var archive = Environment.GetEnvironmentVariable(
            "AMON_CODEX_PET_TEST_ARCHIVE");
        if (string.IsNullOrWhiteSpace(archive))
            return;
        using var sandbox = new TestDirectory();

        var result = CodexPetAssetService.Import(
            archive,
            spriteVersion: 1,
            applicationDataRoot: sandbox.Path);

        Assert.Equal("Svinushka", result.DisplayName);
        Assert.Equal(CodexPetAssetFormat.WebP, result.Metadata.Format);
        Assert.Equal(2, result.Metadata.SpriteVersion);
        Assert.Equal(1536, result.Metadata.PixelWidth);
        Assert.Equal(2288, result.Metadata.PixelHeight);
        Assert.True(CodexPetAssetService.IsValidSprite(
            result.InstalledPath,
            result.Metadata.SpriteVersion));
    }

    private static byte[] CreateSpritePng() =>
        CreatePng(
            CodexPetSpriteLayout.SheetPixelWidth,
            CodexPetSpriteLayout.V1SheetPixelHeight);

    private static byte[] CreatePng(int width, int height)
    {
        var stride = checked(width * 4);
        var pixels = new byte[checked(stride * height)];
        pixels[0] = 0x90;
        pixels[1] = 0x70;
        pixels[2] = 0xff;
        pixels[3] = 0x80;
        var bitmap = BitmapSource.Create(
            width,
            height,
            96,
            96,
            PixelFormats.Bgra32,
            palette: null,
            pixels,
            stride);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    private static void WriteEntry(
        ZipArchive archive,
        string name,
        byte[] contents)
    {
        var entry = archive.CreateEntry(name);
        using var stream = entry.Open();
        stream.Write(contents);
    }

    private sealed class TestDirectory : IDisposable
    {
        public TestDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"amon-pet-tests-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            if (Directory.Exists(Path))
                Directory.Delete(Path, recursive: true);
        }
    }
}
