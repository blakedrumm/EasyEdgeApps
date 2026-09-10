using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using EasyEdgeApps.Core.Tests;

namespace EasyEdgeApps.Windows.Tests;

public sealed class CompiledNativeTests
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenJobObject(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetHandleInformation(IntPtr handle, out uint flags);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [Fact]
    public async Task LauncherFailureTerminatesItsOwnedChildDespiteAnotherJobHandle()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var executable = Path.Combine(repository, "tests", "EasyEdgeApps.NativeFixture", "bin", configuration, "net10.0-windows10.0.19041.0", "EasyEdgeApps.NativeFixture.exe");
        var directory = Path.Combine(fixture.Root, "owned-child");
        Directory.CreateDirectory(directory);
        var readyName = "Local\\EasyEdgeApps-Ready-" + Guid.NewGuid().ToString("N");
        var releaseName = "Local\\EasyEdgeApps-Release-" + Guid.NewGuid().ToString("N");
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, readyName);
        using var release = new EventWaitHandle(false, EventResetMode.ManualReset, releaseName);
        var appName = typeof(EeaFreshSession).GetField("AppName", BindingFlags.NonPublic | BindingFlags.Static)!;
        var previousName = appName.GetValue(null);
        var jobName = (string)typeof(EeaFreshSession).GetMethod("JobName", BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(null, [directory])!;
        var retainedJob = IntPtr.Zero;
        Process? child = null;
        Task? running = null;
        try
        {
            appName.SetValue(null, "Synthetic owned child");
            running = Task.Run(() => EeaFreshSession.RunProcess(executable, $"child \"{directory}\" \"{readyName}\" \"{releaseName}\"", directory));
            Assert.True(await Task.Run(() => ready.WaitOne(TimeSpan.FromSeconds(15))), "The synthetic owned child did not start.");
            child = Process.GetProcessById(int.Parse(File.ReadAllText(Path.Combine(directory, "child-id.txt"))));
            retainedJob = OpenJobObject(4, false, jobName);
            Assert.NotEqual(IntPtr.Zero, retainedJob);
            Assert.False(child.HasExited);
            Assert.Throws<System.ComponentModel.Win32Exception>(() => EeaFreshSession.RunProcess(executable, "unexpected duplicate launch", directory));
            Assert.False(child.HasExited);
            appName.SetValue(null, null);

            await Assert.ThrowsAsync<NullReferenceException>(() => running.WaitAsync(TimeSpan.FromSeconds(10)));

            Assert.True(child.WaitForExit(5000), "Launcher failure left its owned child running while another job handle was held.");
            Assert.False(File.Exists(Path.Combine(directory, "child-finished.txt")));
        }
        finally
        {
            release.Set();
            if (child is { HasExited: false }) { child.Kill(true); await child.WaitForExitAsync(); }
            child?.Dispose();
            if (retainedJob != IntPtr.Zero) CloseHandle(retainedJob);
            if (running is not null) await Record.ExceptionAsync(async () => await running.WaitAsync(TimeSpan.FromSeconds(10)));
            appName.SetValue(null, previousName);
        }
    }

    [Fact]
    public void WindowControllerOwnsItsJobHandleUntilItsWorkerExits()
    {
        using var fixture = new TestDirectory();
        var job = CreateJobObject(IntPtr.Zero, "Local\\EasyEdgeApps-Controller-Test-" + Guid.NewGuid().ToString("N"));
        Assert.NotEqual(IntPtr.Zero, job);
        Windowing.Controller? controller = null;
        try
        {
            controller = new(job, "EasyEdgeApps.Website." + new string('a', 64), Path.Combine(fixture.Root, "fresh-session.exe"), 1, false);
            var ownedJob = (IntPtr)typeof(Windowing.Controller).GetField("job", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(controller)!;
            var worker = (Thread)typeof(Windowing.Controller).GetField("thread", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(controller)!;
            Assert.NotEqual(job, ownedJob);
            Assert.True(CloseHandle(job));
            job = IntPtr.Zero;
            Assert.True(GetHandleInformation(ownedJob, out _));
            Assert.True(worker.IsAlive);

            controller.Dispose();

            Assert.True(worker.Join(TimeSpan.FromSeconds(5)));
            Assert.False(GetHandleInformation(ownedJob, out _));
            controller.CheckHealth();
        }
        finally
        {
            controller?.Dispose();
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }

    [Fact]
    public void CompiledPlacementPreservesIdentityBoundsAndUnrecognizedFiles()
    {
        using var fixture = new TestDirectory();
        var launcher = Path.Combine(fixture.Root, "fresh-session.exe");
        File.WriteAllBytes(launcher, [1]);
        var path = Path.Combine(fixture.Root, ".eea-window");
        var identity = "EasyEdgeApps.Website." + new string('a', 64);
        int[] work = [-1920, 40, 1920, 1040];
        int[] normal = [-1800, 60, 900, 700, 1];
        Assert.Equal(normal, Windowing.Placement.Normalize(normal, work));
        Assert.Equal(new[] { -1920, 40, 1920, 1040, 3 }, Windowing.Placement.Normalize([12000, -20000, 6000, 5000, 3], work));
        Assert.Equal(new[] { 0, 0, 320, 200, 1 }, Windowing.Placement.Normalize([0, 0, 1, 1, 1], [0, 0, 320, 200]));
        foreach (var invalid in new int[][] { [0, 0, -1, 500, 1], [0, 0, 500, 500, 2], [int.MaxValue, 0, 500, 500, 1], [0, 0, 500, 0, 1] })
            Assert.Null(Windowing.Placement.Normalize(invalid, work));
        Assert.True(Windowing.Placement.Write(path, identity, normal));
        Assert.Equal(normal, Windowing.Placement.Read(path, identity));
        Assert.Null(Windowing.Placement.Read(path, "EasyEdgeApps.Website." + new string('b', 64)));
        using (var locked = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.False(Windowing.Placement.Write(path, identity, normal));
        File.WriteAllText(path, "Unrecognized file");
        Assert.Null(Windowing.Placement.Read(path, identity));
        Assert.False(Windowing.Placement.Write(path, identity, normal));
        Assert.Equal("Unrecognized file", File.ReadAllText(path));
        Assert.False(Windowing.Placement.Write(Path.Combine(fixture.Root, "removed", ".eea-window"), identity, normal));
        Assert.False(Directory.Exists(Path.Combine(fixture.Root, "removed")));
        Assert.Empty(Directory.EnumerateFiles(fixture.Root, "*.tmp"));
    }

    [Theory]
    [InlineData(0, 0x100, 27, true, true, false, true)]
    [InlineData(-1, 0x100, 27, true, true, false, false)]
    [InlineData(0, 0x101, 27, true, true, false, false)]
    [InlineData(0, 0x100, 65, true, true, false, false)]
    [InlineData(0, 0x100, 27, false, true, false, false)]
    [InlineData(0, 0x100, 27, true, false, false, false)]
    [InlineData(0, 0x100, 27, true, true, true, false)]
    public void CompiledEscapeDecisionRequiresOwnedUnmodifiedFullscreenKeyDown(int code, int message, int key, bool owned, bool fullscreen, bool modified, bool expected)
    {
        Assert.Equal(expected, Windowing.Controller.ShouldHandleEscape(code, message, key, owned, fullscreen, modified));
    }

    [Fact]
    public async Task LtsControllerPreservesChildLifetimeInterruptionLeasesAndLongPathCleanup()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var executable = Path.Combine(repository, "tests", "EasyEdgeApps.NativeFixture", "bin", configuration, "net10.0-windows10.0.19041.0", "EasyEdgeApps.NativeFixture.exe");
        Assert.True(File.Exists(executable), "Build the compiled native fixture before running this test.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add("verify");
        start.ArgumentList.Add(Path.Combine(fixture.Root, "Sessions"));
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(70));
        try { await process.WaitForExitAsync(deadline.Token); }
        finally
        {
            if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
        }
        Assert.True(process.ExitCode == 0, await output + await errors);
        Assert.Empty(Directory.EnumerateDirectories(Path.Combine(fixture.Root, "Sessions")));
    }
}