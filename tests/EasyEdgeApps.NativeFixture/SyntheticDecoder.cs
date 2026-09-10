using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.NativeFixture;

internal static class SyntheticDecoder
{
    internal static int WaitForCancellation()
    {
        using var input = new StreamReader(Console.OpenStandardInput(), Encoding.UTF8, false, 4096);
        var request = input.ReadToEnd();
        if (request.Length > 4096) return 3;
        var values = request.Split('\n');
        if (values.Length != 2 || !values[1].StartsWith("Local\\EasyEdgeApps-Decoder-", StringComparison.Ordinal)) return 3;
        var repository = new DirectoryInfo(AppContext.BaseDirectory);
        while (repository != null && !File.Exists(Path.Combine(repository.FullName, "EasyEdgeApps.ps1"))) repository = repository.Parent;
        if (repository == null) return 3;
        var path = Path.GetFullPath(values[0]);
        if (!path.StartsWith(Path.Combine(repository.FullName, "artifacts") + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || Path.GetFileName(path) != "decoder.pid") return 3;
        SafeFiles.CheckPath(path);
        using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
        {
            var bytes = Encoding.UTF8.GetBytes(Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
            output.Write(bytes, 0, bytes.Length);
            output.Flush(true);
        }
        var queried = QueryInformationJobObject(IntPtr.Zero, 9, out var limits, (uint)Marshal.SizeOf<ExtendedLimits>(), IntPtr.Zero);
        var report = JsonSerializer.SerializeToUtf8Bytes(new { Queried = queried, limits.Basic.Flags, limits.Basic.ActiveProcesses, ProcessMemory = limits.ProcessMemory.ToUInt64() });
        using (var output = new FileStream(Path.ChangeExtension(path, ".limits.json"), FileMode.CreateNew, FileAccess.Write, FileShare.Read))
        {
            output.Write(report, 0, report.Length);
            output.Flush(true);
        }
        using var ready = EventWaitHandle.OpenExisting(values[1]);
        ready.Set();
        using var stop = new ManualResetEvent(false);
        stop.WaitOne(30000);
        return 2;
    }

    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
    { public long ProcessTime, JobTime; public uint Flags; public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcesses; public UIntPtr Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)] private struct Counters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits { public BasicLimits Basic; public Counters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryInformationJobObject(IntPtr job, int informationClass, out ExtendedLimits information, uint length, IntPtr returnedLength);
}