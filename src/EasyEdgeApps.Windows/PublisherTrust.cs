using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Windows;

public sealed record PublisherResult(string Status, string Thumbprint, bool Timestamped);

public static class PublisherTrust
{
    public static PublisherResult Verify(string path, string expectedThumbprint)
    {
        if (expectedThumbprint == null || !Regex.IsMatch(expectedThumbprint, "\\A[A-Fa-f0-9]{40}\\z")) throw new ValidationException("A production publisher thumbprint must be configured before updates can be trusted.");
        var result = Inspect(path);
        if (result.Status != "Valid" || !StringComparer.OrdinalIgnoreCase.Equals(result.Thumbprint, expectedThumbprint) || !result.Timestamped)
            throw new ValidationException("The artifact lacks the expected trusted publisher signature and verified timestamp. Unsigned test artifacts cannot be installed by the updater.");
        return result;
    }

    public static PublisherResult Inspect(string path)
    {
        path = Path.GetFullPath(path);
        SafeFiles.CheckPath(path);
        if (!File.Exists(path)) return new("Missing", "", false);
        var file = new TrustFile { Size = (uint)Marshal.SizeOf<TrustFile>(), Path = Marshal.StringToCoTaskMemUni(path) };
        var filePointer = Marshal.AllocCoTaskMem(Marshal.SizeOf<TrustFile>());
        Marshal.StructureToPtr(file, filePointer, false);
        var data = new TrustData { Size = (uint)Marshal.SizeOf<TrustData>(), UIChoice = 2, RevocationChecks = 1, UnionChoice = 1, File = filePointer, StateAction = 1, ProviderFlags = 0x1000 | 0x80 };
        var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
        try
        {
            var status = WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            if (status != 0) return new(status == unchecked((int)0x800B0100) ? "NotSigned" : "Untrusted", "", false);
            var provider = WTHelperProvDataFromStateData(data.StateData);
            var signerPointer = WTHelperGetProvSignerFromChain(provider, 0, false, 0);
            if (signerPointer == IntPtr.Zero) return new("Untrusted", "", false);
            var signer = Marshal.PtrToStructure<ProviderSigner>(signerPointer);
            if (signer.Error != 0 || signer.CertificateCount == 0 || signer.Certificates == IntPtr.Zero) return new("Untrusted", "", false);
            var certificate = Marshal.PtrToStructure<ProviderCertificate>(signer.Certificates);
            using var signerCertificate = new X509Certificate2(certificate.Certificate);
            var timestamp = false;
            if (signer.CounterSignerCount != 0)
            {
                var counterPointer = WTHelperGetProvSignerFromChain(provider, 0, true, 0);
                if (counterPointer != IntPtr.Zero)
                {
                    var counter = Marshal.PtrToStructure<ProviderSigner>(counterPointer);
                    timestamp = counter.Error == 0 && counter.CertificateCount != 0 && counter.Certificates != IntPtr.Zero;
                }
            }
            return new("Valid", signerCertificate.Thumbprint, timestamp);
        }
        finally
        {
            data.StateAction = 2;
            WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            Marshal.FreeCoTaskMem(file.Path); Marshal.FreeCoTaskMem(filePointer);
        }
    }

    [StructLayout(LayoutKind.Sequential)] private struct TrustFile { public uint Size; public IntPtr Path, File, KnownSubject; }
    [StructLayout(LayoutKind.Sequential)] private struct TrustData
    {
        public uint Size; public IntPtr PolicyCallbackData, SipClientData; public uint UIChoice, RevocationChecks, UnionChoice;
        public IntPtr File; public uint StateAction; public IntPtr StateData, UrlReference; public uint ProviderFlags, UIContext;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ProviderCertificate { public uint Size; public IntPtr Certificate; }
    [StructLayout(LayoutKind.Sequential)] private struct ProviderSigner
    {
        public uint Size, VerifyLow, VerifyHigh, CertificateCount; public IntPtr Certificates; public uint SignerType;
        public IntPtr Signer; public uint Error, CounterSignerCount; public IntPtr CounterSigners, ChainContext;
    }
    [DllImport("wintrust.dll", ExactSpelling = true)] private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
    [DllImport("wintrust.dll", ExactSpelling = true)] private static extern IntPtr WTHelperProvDataFromStateData(IntPtr state);
    [DllImport("wintrust.dll", ExactSpelling = true)] private static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint signer, [MarshalAs(UnmanagedType.Bool)] bool counterSigner, uint counterIndex);
}