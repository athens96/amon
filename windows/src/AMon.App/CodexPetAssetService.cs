using System.IO;
using System.IO.Compression;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ImageSharpBgra32 = SixLabors.ImageSharp.PixelFormats.Bgra32;

namespace AMon.App;

public enum CodexPetAssetFormat
{
    Png,
    WebP,
}

public sealed record CodexPetAssetMetadata(
    CodexPetAssetFormat Format,
    int PixelWidth,
    int PixelHeight,
    int ByteCount,
    int SpriteVersion);

public sealed record CodexPetImportResult(
    string InstalledPath,
    CodexPetAssetMetadata Metadata,
    string? DisplayName);

public static class CodexPetAssetService
{
    public const int MaximumSpriteByteCount = 20 * 1024 * 1024;
    public const int MaximumArchiveByteCount = 40 * 1024 * 1024;
    public const int MaximumEntryCount = 256;
    private const int MaximumManifestByteCount = 64 * 1024;

    public static CodexPetImportResult Import(
        string sourcePath,
        int spriteVersion,
        string? applicationDataRoot = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        var file = new FileInfo(sourcePath);
        if (!file.Exists)
            throw new InvalidDataException("선택한 펫 파일을 찾을 수 없습니다.");

        byte[] data;
        string? displayName = null;
        int? manifestVersion = null;
        if (HasZipSignature(sourcePath))
        {
            if (file.Length > MaximumArchiveByteCount)
                throw new InvalidDataException("펫 ZIP은 최대 40 MiB까지 지원합니다.");
            (data, displayName, manifestVersion) =
                ReadSpriteFromArchive(sourcePath);
        }
        else
        {
            if (file.Length > MaximumSpriteByteCount)
                throw new InvalidDataException("펫 이미지는 최대 20 MiB까지 지원합니다.");
            data = File.ReadAllBytes(sourcePath);
        }

        var metadata = Validate(data, manifestVersion ?? spriteVersion);
        var root = applicationDataRoot
            ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        // Keep custom pets in the legacy directory so upgrades do not lose them.
        var directory = Path.Combine(root, "A-mon", "pets");
        Directory.CreateDirectory(directory);
        var extension = metadata.Format == CodexPetAssetFormat.Png ? "png" : "webp";
        var destination = Path.Combine(directory, $"spritesheet.{extension}");
        var temporary = Path.Combine(
            directory,
            $".spritesheet-{Guid.NewGuid():N}.{extension}");
        try
        {
            File.WriteAllBytes(temporary, data);
            _ = Validate(
                File.ReadAllBytes(temporary),
                metadata.SpriteVersion);
            File.Move(temporary, destination, overwrite: true);
            var obsolete = Path.Combine(
                directory,
                metadata.Format == CodexPetAssetFormat.Png
                    ? "spritesheet.webp"
                    : "spritesheet.png");
            if (File.Exists(obsolete))
                File.Delete(obsolete);
        }
        finally
        {
            if (File.Exists(temporary))
                File.Delete(temporary);
        }

        return new CodexPetImportResult(destination, metadata, displayName);
    }

    public static bool IsValidSprite(string? path, int spriteVersion = 1)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            return false;
        try
        {
            _ = Validate(File.ReadAllBytes(path), spriteVersion);
            return true;
        }
        catch (Exception exception) when (
            exception is IOException
                or InvalidDataException
                or NotSupportedException)
        {
            return false;
        }
    }

    public static CodexPetAssetMetadata Validate(byte[] data, int spriteVersion)
    {
        ArgumentNullException.ThrowIfNull(data);
        if (data.Length > MaximumSpriteByteCount)
            throw new InvalidDataException("펫 이미지는 최대 20 MiB까지 지원합니다.");
        var format = DetectFormat(data)
            ?? throw new InvalidDataException("PNG 또는 WebP 이미지만 사용할 수 있습니다.");
        var normalizedVersion =
            CodexPetSpriteLayout.NormalizeVersion(spriteVersion);
        var decoded = Decode(data);
        var expectedHeight =
            CodexPetSpriteLayout.SheetPixelHeightFor(normalizedVersion);
        if (decoded.Bitmap.PixelWidth != CodexPetSpriteLayout.SheetPixelWidth
            || decoded.Bitmap.PixelHeight != expectedHeight)
        {
            throw new InvalidDataException(
                $"Codex Pet V{normalizedVersion} 이미지는 정확히 "
                + $"{CodexPetSpriteLayout.SheetPixelWidth}×{expectedHeight}px이어야 합니다. "
                + $"현재 {decoded.Bitmap.PixelWidth}×{decoded.Bitmap.PixelHeight}px입니다.");
        }
        if (!decoded.HasTransparency)
            throw new InvalidDataException("투명 배경을 지원하는 펫 이미지가 필요합니다.");
        return new CodexPetAssetMetadata(
            format,
            decoded.Bitmap.PixelWidth,
            decoded.Bitmap.PixelHeight,
            data.Length,
            normalizedVersion);
    }

    public static BitmapSource LoadBitmapSource(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        return Decode(File.ReadAllBytes(path)).Bitmap;
    }

    private static (
        byte[] Data,
        string? DisplayName,
        int? SpriteVersion) ReadSpriteFromArchive(
        string sourcePath)
    {
        using var archive = ZipFile.OpenRead(sourcePath);
        if (archive.Entries.Count > MaximumEntryCount)
            throw new InvalidDataException("펫 ZIP은 최대 256개 파일까지 지원합니다.");
        var entries = new Dictionary<string, ZipArchiveEntry>(
            StringComparer.OrdinalIgnoreCase);
        foreach (var entry in archive.Entries)
        {
            var normalized = NormalizeArchivePath(entry.FullName);
            if (!entries.TryAdd(normalized, entry))
                throw new InvalidDataException($"ZIP에 중복 경로가 있습니다: {normalized}");
        }

        var manifests = entries
            .Where(static pair =>
                !IsMetadata(pair.Key)
                && string.Equals(
                    Path.GetFileName(pair.Key),
                    "pet.json",
                    StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (manifests.Length > 1)
            throw new InvalidDataException("ZIP에 pet.json이 둘 이상 있습니다.");

        ZipArchiveEntry sprite;
        string? displayName = null;
        int? spriteVersion = null;
        if (manifests.Length == 1)
        {
            var manifestData = ReadEntry(
                manifests[0].Value,
                MaximumManifestByteCount);
            var manifest = JsonSerializer.Deserialize<PetManifest>(
                manifestData,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? throw new InvalidDataException("pet.json을 읽을 수 없습니다.");
            var manifestDirectory = Path.GetDirectoryName(manifests[0].Key)?
                .Replace('\\', '/') ?? string.Empty;
            var combined = string.IsNullOrEmpty(manifestDirectory)
                ? manifest.SpritesheetPath
                : $"{manifestDirectory}/{manifest.SpritesheetPath}";
            var spritePath = NormalizeArchivePath(combined);
            if (!entries.TryGetValue(spritePath, out sprite!))
            {
                throw new InvalidDataException(
                    $"pet.json이 지정한 스프라이트시트를 찾을 수 없습니다: {spritePath}");
            }
            displayName = SanitizeDisplayName(manifest.DisplayName);
            if (manifest.SpriteVersionNumber is not null)
            {
                if (manifest.SpriteVersionNumber is not (1 or 2 or 3))
                {
                    throw new InvalidDataException(
                        $"지원하지 않는 Codex Pet 버전입니다: "
                        + $"{manifest.SpriteVersionNumber}");
                }
                spriteVersion = manifest.SpriteVersionNumber;
            }
        }
        else
        {
            var candidates = entries
                .Where(static pair =>
                    !IsMetadata(pair.Key)
                    && (string.Equals(
                            Path.GetFileName(pair.Key),
                            "spritesheet.png",
                            StringComparison.OrdinalIgnoreCase)
                        || string.Equals(
                            Path.GetFileName(pair.Key),
                            "spritesheet.webp",
                            StringComparison.OrdinalIgnoreCase)))
                .Select(static pair => pair.Value)
                .ToArray();
            if (candidates.Length == 0)
                throw new InvalidDataException("ZIP에서 spritesheet.png 또는 spritesheet.webp를 찾지 못했습니다.");
            if (candidates.Length > 1)
                throw new InvalidDataException("ZIP에 스프라이트시트가 둘 이상 있습니다.");
            sprite = candidates[0];
        }

        return (
            ReadEntry(sprite, MaximumSpriteByteCount),
            displayName,
            spriteVersion);
    }

    private static byte[] ReadEntry(ZipArchiveEntry entry, int maximumBytes)
    {
        if (entry.Length > maximumBytes)
            throw new InvalidDataException("ZIP 내부 파일이 허용 크기를 초과합니다.");
        using var input = entry.Open();
        using var output = new MemoryStream();
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var read = input.Read(buffer, 0, buffer.Length);
            if (read == 0)
                break;
            if (output.Length + read > maximumBytes)
                throw new InvalidDataException("ZIP 내부 파일이 허용 크기를 초과합니다.");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    private static string NormalizeArchivePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)
            || path.StartsWith('/')
            || path.StartsWith('\\')
            || path.Contains('\\')
            || path.Contains('\0')
            || Path.IsPathRooted(path))
            throw new InvalidDataException($"ZIP에 안전하지 않은 경로가 있습니다: {path}");
        var parts = new List<string>();
        foreach (var part in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == ".")
                continue;
            if (part == "..")
                throw new InvalidDataException($"ZIP에 안전하지 않은 경로가 있습니다: {path}");
            parts.Add(part);
        }
        if (parts.Count == 0)
            throw new InvalidDataException($"ZIP에 안전하지 않은 경로가 있습니다: {path}");
        return string.Join('/', parts);
    }

    private static bool IsMetadata(string path) =>
        path.Split('/').Contains("__MACOSX", StringComparer.OrdinalIgnoreCase)
        || Path.GetFileName(path).StartsWith("._", StringComparison.Ordinal);

    private static bool HasZipSignature(string path)
    {
        Span<byte> bytes = stackalloc byte[4];
        using var stream = File.OpenRead(path);
        if (stream.Read(bytes) != bytes.Length)
            return false;
        return bytes.SequenceEqual(
                [(byte)0x50, (byte)0x4b, (byte)0x03, (byte)0x04])
            || bytes.SequenceEqual(
                [(byte)0x50, (byte)0x4b, (byte)0x05, (byte)0x06])
            || bytes.SequenceEqual(
                [(byte)0x50, (byte)0x4b, (byte)0x07, (byte)0x08]);
    }

    private static CodexPetAssetFormat? DetectFormat(byte[] data)
    {
        ReadOnlySpan<byte> bytes = data;
        ReadOnlySpan<byte> png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
        if (bytes.StartsWith(png))
            return CodexPetAssetFormat.Png;
        return bytes.Length >= 12
            && bytes[..4].SequenceEqual("RIFF"u8)
            && bytes.Slice(8, 4).SequenceEqual("WEBP"u8)
                ? CodexPetAssetFormat.WebP
                : null;
    }

    private static DecodedSprite Decode(byte[] data)
    {
        try
        {
            using var image =
                SixLabors.ImageSharp.Image.Load<ImageSharpBgra32>(data);
            var stride = checked(image.Width * 4);
            var pixels = new byte[checked(stride * image.Height)];
            image.CopyPixelDataTo(pixels);
            var hasTransparency = false;
            for (var index = 3; index < pixels.Length; index += 4)
            {
                if (pixels[index] == byte.MaxValue)
                    continue;
                hasTransparency = true;
                break;
            }
            var bitmap = BitmapSource.Create(
                image.Width,
                image.Height,
                96,
                96,
                PixelFormats.Bgra32,
                palette: null,
                pixels,
                stride);
            bitmap.Freeze();
            return new DecodedSprite(bitmap, hasTransparency);
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            throw new InvalidDataException(
                "펫 이미지를 읽을 수 없습니다.",
                exception);
        }
    }

    private static string? SanitizeDisplayName(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;
        var oneLine = value
            .Replace('\r', ' ')
            .Replace('\n', ' ')
            .Trim();
        return oneLine[..Math.Min(80, oneLine.Length)];
    }

    private sealed record PetManifest(
        string? DisplayName,
        string SpritesheetPath,
        int? SpriteVersionNumber);

    private sealed record DecodedSprite(
        BitmapSource Bitmap,
        bool HasTransparency);
}
