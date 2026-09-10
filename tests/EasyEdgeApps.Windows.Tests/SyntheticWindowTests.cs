using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using EasyEdgeApps.Core.Tests;
using Microsoft.Win32.SafeHandles;

namespace EasyEdgeApps.Windows.Tests;

public sealed class SyntheticWindowTests
{
    [Fact]
    public Task ControllerRestoresAndCapturesOnlyItsOwnedSyntheticWindow() => VerifyController(false);

    [DesktopTopmostFact]
    public Task ControllerMarksOnlyItsOwnedSyntheticWindowTopmost() => VerifyController(true);

    private static async Task VerifyController(bool topmost)
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var executable = Path.Combine(repository, "tests", "EasyEdgeApps.NativeFixture", "bin", configuration, "net10.0-windows10.0.19041.0", "EasyEdgeApps.NativeFixture.exe");
        var jobName = "Local\\EasyEdgeApps-SyntheticWindow-" + Guid.NewGuid().ToString("N");
        using var job = CreateJobObject(IntPtr.Zero, jobName);
        Assert.False(job.IsInvalid);
        using var owned = await WindowProcess.Start(executable, job);
        using var unrelated = await WindowProcess.Start(executable, null);
        Assert.True(EeaWindowProbe.Belongs(jobName, owned.Window));
        Assert.False(EeaWindowProbe.Belongs(jobName, unrelated.Window));
        var unrelatedBounds = EeaWindowProbe.Bounds(unrelated.Window);
        var launcher = Path.Combine(fixture.Root, "fresh-session.exe");
        File.WriteAllBytes(launcher, [1]);
        var state = Path.Combine(fixture.Root, ".eea-window");
        var identity = "EasyEdgeApps.Website." + new string('c', 64);
        var work = EeaWindowProbe.WorkArea(owned.Window);
        var saved = Windowing.Placement.Normalize([work[0] + 40, work[1] + 50, 700, 500, 1], work);
        Assert.True(Windowing.Placement.Write(state, identity, saved));
        var controller = new Windowing.Controller(job.DangerousGetHandle(), identity, launcher, 0, topmost);
        int[] moved;
        try
        {
            await WaitFor(() => { controller.CheckHealth(); return (!topmost || EeaWindowProbe.IsTopmost(owned.Window)) && EeaWindowProbe.Bounds(owned.Window).SequenceEqual(saved.Take(4)); },
                () => "The controller did not restore its owned window or satisfy the requested topmost acceptance. Expected=" + string.Join(",", saved) + "; matching windows=" + EeaWindowProbe.Find(jobName).Length + "; " + EeaWindowProbe.Describe(owned.Window));
            Assert.False(EeaWindowProbe.IsTopmost(unrelated.Window));
            Assert.Equal(unrelatedBounds, EeaWindowProbe.Bounds(unrelated.Window));
            moved = Windowing.Placement.Normalize([work[0] + 65, work[1] + 70, 760, 540, 1], work);
            EeaWindowProbe.Resize(jobName, owned.Window, moved[0], moved[1], moved[2], moved[3]);
            var captured = typeof(Windowing.Controller).GetField("lastPlacement", BindingFlags.Instance | BindingFlags.NonPublic)!;
            await WaitFor(() => captured.GetValue(controller) is int[] placement && placement.SequenceEqual(moved), () => "The controller did not capture the owned window's new placement. " + EeaWindowProbe.Describe(owned.Window));
            controller.CheckHealth();
        }
        finally
        {
            var stop = Stopwatch.StartNew();
            controller.Dispose();
            Assert.True(stop.Elapsed < TimeSpan.FromSeconds(6), "Controller disposal exceeded its shutdown bound.");
        }
        Assert.Equal(moved, Windowing.Placement.Read(state, identity));
        Assert.False(EeaWindowProbe.IsTopmost(unrelated.Window));
        Assert.Equal(unrelatedBounds, EeaWindowProbe.Bounds(unrelated.Window));
        EeaWindowProbe.Close(jobName, owned.Window);
        await owned.Process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(0, owned.Process.ExitCode);
        Assert.False(unrelated.Process.HasExited);
    }

    private static async Task WaitFor(Func<bool> condition, Func<string> failure)
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < TimeSpan.FromSeconds(10))
        {
            if (condition()) return;
            await Task.Delay(25);
        }
        Assert.Fail(failure());
    }

    private sealed class WindowProcess(Process process, IntPtr window) : IDisposable
    {
        public Process Process { get; } = process;
        public IntPtr Window { get; } = window;

        public static async Task<WindowProcess> Start(string executable, SafeFileHandle? job)
        {
            var gateName = "Local\\EasyEdgeApps-WindowGate-" + Guid.NewGuid().ToString("N");
            using var gate = new EventWaitHandle(false, EventResetMode.ManualReset, gateName);
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            start.ArgumentList.Add("window"); start.ArgumentList.Add(gateName);
            var process = Process.Start(start)!;
            try
            {
                if (job is not null) Assert.True(AssignProcessToJobObject(job, process.Handle), "The synthetic window could not join its owned job.");
                gate.Set();
                var handle = await process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(12));
                Assert.True(long.TryParse(handle, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) && value != 0, "The synthetic process did not expose its native window.");
                return new(process, new IntPtr(value));
            }
            catch
            {
                if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
                process.Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            if (!Process.HasExited) { Process.Kill(true); Process.WaitForExit(10000); }
            Process.Dispose();
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
}

public sealed class DesktopTopmostFactAttribute : FactAttribute
{
    public DesktopTopmostFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("EEA_TEST_TOPMOST") != "1")
            Skip = "UNVERIFIED desktop acceptance: run with EEA_TEST_TOPMOST=1 in disposable Windows. The current hosted session ignored a successful direct HWND_TOPMOST request.";
    }
}