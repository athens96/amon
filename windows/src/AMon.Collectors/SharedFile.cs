namespace AMon.Collectors;

internal static class SharedFile
{
    private const int BufferSize = 64 * 1024;
    private const FileShare LiveLogShare =
        FileShare.ReadWrite | FileShare.Delete;

    public static FileStream OpenRead(string path, bool asynchronous = true) =>
        new(
            path,
            FileMode.Open,
            FileAccess.Read,
            LiveLogShare,
            BufferSize,
            asynchronous
                ? FileOptions.Asynchronous | FileOptions.SequentialScan
                : FileOptions.SequentialScan);

    public static IEnumerable<string> ReadLines(string path)
    {
        using var stream = OpenRead(path, asynchronous: false);
        using var reader = new StreamReader(stream);
        while (reader.ReadLine() is { } line)
            yield return line;
    }

    public static async Task<string> ReadAllTextAsync(
        string path,
        CancellationToken cancellationToken)
    {
        await using var stream = OpenRead(path);
        using var reader = new StreamReader(stream);
        return await reader.ReadToEndAsync(cancellationToken);
    }
}
