using System.Runtime.InteropServices;

namespace AMon.Update;

public static class ExecutableArchitectureVerifier
{
    public static void Verify(string executablePath, Architecture expectedArchitecture)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);
        var expectedMachine = expectedArchitecture switch
        {
            Architecture.X64 => (ushort)0x8664,
            Architecture.Arm64 => (ushort)0xAA64,
            _ => throw new PlatformNotSupportedException(
                $"Windows update executables are not supported for {expectedArchitecture}.")
        };

        using var stream = new FileStream(
            executablePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var reader = new BinaryReader(stream);
        if (stream.Length < 64 || reader.ReadUInt16() != 0x5A4D)
            throw new InvalidDataException("The update executable has an invalid PE header.");

        stream.Position = 0x3C;
        var peOffset = reader.ReadInt32();
        if (peOffset < 0 || peOffset > stream.Length - 6)
            throw new InvalidDataException("The update executable has an invalid PE header.");

        stream.Position = peOffset;
        if (reader.ReadUInt32() != 0x00004550)
            throw new InvalidDataException("The update executable has an invalid PE signature.");
        if (reader.ReadUInt16() != expectedMachine)
            throw new InvalidDataException(
                "The update executable architecture did not match the running process.");
    }
}
