namespace AMon.Quotas;

/// Text-file access seam so auth stores test against in-memory files. Paths are absolute.
public interface IQuotaFileSystem
{
    bool Exists(string path);
    string ReadText(string path);
    void WriteText(string path, string text);
    void Delete(string path);
}

public sealed class LocalQuotaFileSystem : IQuotaFileSystem
{
    public bool Exists(string path) => File.Exists(path);

    public string ReadText(string path) => File.ReadAllText(path);

    public void WriteText(string path, string text)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
            Directory.CreateDirectory(directory);
        var temporary = Path.Combine(
            directory ?? string.Empty,
            $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporary, text);
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            // Never leave a plaintext copy of a credential behind when the swap fails.
            if (File.Exists(temporary))
                File.Delete(temporary);
        }
    }

    public void Delete(string path)
    {
        if (File.Exists(path))
            File.Delete(path);
    }
}
