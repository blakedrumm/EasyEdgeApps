using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Windows;

public sealed class IconWorkerClient(string executable)
{
    public async Task<byte[]> FromFileAsync(string path, CancellationToken token)
    {
        var format = Path.GetExtension(path).ToLowerInvariant();
        if (format is not (".ico" or ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp" or ".svg")) throw new ValidationException("Choose an ICO, PNG, JPEG, GIF, BMP or static SVG image.");
        return await ConvertAsync(SafeFiles.Read(Path.GetFullPath(path), IconService.MaximumInputBytes), format, token);
    }

    public async Task<byte[]> ConvertAsync(byte[] bytes, string format, CancellationToken token)
    {
        if (bytes.Length > IconService.MaximumInputBytes || format is not (".ico" or ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp" or ".svg")) throw new ValidationException("Unsupported image input.");
        token.ThrowIfCancellationRequested();
        SafeFiles.CheckPath(Path.GetFullPath(executable));
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add(format);
        using var process = Process.Start(start) ?? throw new ValidationException("The image worker could not start.");
        var job = CreateJobObject(IntPtr.Zero, null);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 | 0x100 | 0x8, ActiveProcesses = 1 }, ProcessMemory = new UIntPtr(384 * 1024 * 1024) };
            if (job == IntPtr.Zero || !SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>()) || !AssignProcessToJobObject(job, process.Handle))
                throw new ValidationException("The image worker resource limits could not be applied.");
            var outputTask = ReadBounded(process.StandardOutput.BaseStream, deadline.Token);
            await process.StandardInput.BaseStream.WriteAsync(bytes, deadline.Token);
            process.StandardInput.Close();
            var output = await outputTask;
            await process.WaitForExitAsync(deadline.Token);
            if (process.ExitCode != 0) throw new ValidationException("The image could not be decoded within the safety limits. The previous icon is unchanged.");
            IconContract.Validate(output);
            return output;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { throw new ValidationException("Image conversion exceeded its time limit. The previous icon is unchanged."); }
        finally
        {
            if (job != IntPtr.Zero) CloseHandle(job);
            if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
        }
    }

    private static async Task<byte[]> ReadBounded(Stream input, CancellationToken token)
    {
        using var output = new MemoryStream();
        var buffer = new byte[32768];
        int count;
        while ((count = await input.ReadAsync(buffer, token)) != 0)
        {
            if (output.Length + count > 1024 * 1024) throw new ValidationException("The image worker exceeded its output bound.");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }

    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
    { public long ProcessTime, JobTime; public uint Flags; public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcesses; public UIntPtr Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)] private struct Counters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits { public BasicLimits Basic; public Counters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimits information, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
}