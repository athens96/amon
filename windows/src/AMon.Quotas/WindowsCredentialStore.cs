using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace AMon.Quotas;

/// Read-only access to Windows Credential Manager generic credentials — where go-keyring-based
/// tools (`gh`, Antigravity's `agy`) keep their tokens on Windows, under `service:account` targets.
public interface IWindowsCredentialStore
{
    /// The credential blob for `targetName`, decoded as text; `null` when absent or unreadable.
    string? ReadGenericCredential(string targetName);
}

public sealed class WindowsCredentialStore : IWindowsCredentialStore
{
    public string? ReadGenericCredential(string targetName)
    {
        if (!OperatingSystem.IsWindows())
            return null;
        return ReadOnWindows(targetName);
    }

    [SupportedOSPlatform("windows")]
    private static string? ReadOnWindows(string targetName)
    {
        if (!NativeMethods.CredRead(targetName, NativeMethods.CredTypeGeneric, 0, out var handle) || handle == IntPtr.Zero)
            return null;
        try
        {
            var credential = Marshal.PtrToStructure<NativeMethods.Credential>(handle);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
                return null;
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return DecodeBlob(bytes);
        }
        finally
        {
            NativeMethods.CredFree(handle);
        }
    }

    /// go-keyring writes UTF-8; tools that use the Win32 API directly often write UTF-16LE. A blob
    /// with interleaved NULs is read as UTF-16, otherwise as UTF-8.
    internal static string? DecodeBlob(byte[] bytes)
    {
        if (bytes.Length == 0)
            return null;
        var looksUtf16 = bytes.Length % 2 == 0 && bytes.Length >= 2 && bytes[1] == 0;
        var text = looksUtf16 ? Encoding.Unicode.GetString(bytes) : Encoding.UTF8.GetString(bytes);
        text = text.TrimEnd('\0').Trim();
        return text.Length == 0 ? null : text;
    }

    private static class NativeMethods
    {
        public const int CredTypeGeneric = 1;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct Credential
        {
            public uint Flags;
            public uint Type;
            public IntPtr TargetName;
            public IntPtr Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public IntPtr TargetAlias;
            public IntPtr UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        public static extern void CredFree(IntPtr buffer);
    }
}
