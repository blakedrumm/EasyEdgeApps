using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;

#if !EEA_MODERN_RUNTIME
[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]
#endif

public static class FreshSessionProcessFixture
{
    private static string ExecutablePath
    {
        get
        {
#if EEA_MODERN_RUNTIME
            return Environment.ProcessPath;
#else
            return Assembly.GetExecutingAssembly().Location;
#endif
        }
    }

    private static string Command(string mode, string directory, string readyName, string releaseName)
    {
        return mode + " \"" + directory + "\" \"" + readyName + "\" \"" + releaseName + "\"";
    }

    private static Process Start(string arguments)
    {
        return Process.Start(new ProcessStartInfo(ExecutablePath, arguments) { UseShellExecute = false, CreateNoWindow = true });
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Verify(string root)
    {
        FileStream allocationLease;
        string allocatedDirectory = EeaFreshSession.CreateSession(root, out allocationLease);
        using (allocationLease)
        {
            Task<bool> competingCleanup = Task.Factory.StartNew(delegate { return EeaFreshSession.TryCleanup(root, allocatedDirectory); });
            Check(competingCleanup.Wait(10000) && !competingCleanup.Result && Directory.Exists(allocatedDirectory), "A newly allocated session must stay leased before its browser starts.");
        }
        Check(EeaFreshSession.TryCleanup(root, allocatedDirectory), "An abandoned allocation must support later cleanup.");

        string longPathDirectory = EeaFreshSession.CreateSession(root);
        string deepDirectory = @"\\?\" + Path.Combine(longPathDirectory, "Profile", new string('a', 100), new string('b', 100));
        Check(deepDirectory.Length > 260, "The profile fixture must exceed the legacy path limit.");
        Directory.CreateDirectory(deepDirectory);
        File.WriteAllText(Path.Combine(deepDirectory, "Cookies"), "Synthetic long-path profile.");
        Check(EeaFreshSession.TryCleanup(root, longPathDirectory) && !Directory.Exists(longPathDirectory), "Long Edge profile paths must support owned-only cleanup.");

        string lockedDirectory = EeaFreshSession.CreateSession(root);
        FileStream lockedFile = new FileStream(Path.Combine(lockedDirectory, "Cookies"), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        Task<bool> cleanup = Task.Factory.StartNew(delegate { return EeaFreshSession.CleanupAfterExit(root, lockedDirectory); });
        try { Check(!cleanup.Wait(200), "Cleanup must not finish while a profile file is locked."); }
        finally { lockedFile.Dispose(); }
        Check(cleanup.Wait(10000) && cleanup.Result && !Directory.Exists(lockedDirectory), "Cleanup must retry a temporary file lock after browser exit.");

        string readyName = "Local\\EasyEdgeApps-Ready-" + Guid.NewGuid().ToString("N");
        string releaseName = "Local\\EasyEdgeApps-Release-" + Guid.NewGuid().ToString("N");
        using (EventWaitHandle ready = new EventWaitHandle(false, EventResetMode.ManualReset, readyName))
        using (EventWaitHandle release = new EventWaitHandle(false, EventResetMode.ManualReset, releaseName))
        {
            string directory = EeaFreshSession.CreateSession(root);
            Task running = Task.Factory.StartNew(delegate
            {
                EeaFreshSession.RunProcess(ExecutablePath, Command("parent", directory, readyName, releaseName), directory);
            });
            try
            {
                Check(ready.WaitOne(15000), "The owned child fixture did not start.");
                Check(!running.IsCompleted, "The session ended before its child process.");
                Check(!EeaFreshSession.TryCleanup(root, directory), "A live job must block cleanup even without a launcher lease.");
            }
            finally { release.Set(); }
            Check(running.Wait(15000), "The session did not finish after its child exited.");
            Check(File.Exists(Path.Combine(directory, "child-finished.txt")), "The child must finish before profile cleanup.");
            Check(EeaFreshSession.TryCleanup(root, directory), "Completed child-tree data must be removable.");

            ready.Reset();
            release.Reset();
            directory = EeaFreshSession.CreateSession(root);
            using (Process supervisor = Start(Command("supervisor", directory, readyName, releaseName)))
            {
                try
                {
                    Check(ready.WaitOne(15000), "The interruption fixture did not start.");
                    int childId = Int32.Parse(File.ReadAllText(Path.Combine(directory, "child-id.txt")), CultureInfo.InvariantCulture);
                    using (Process child = Process.GetProcessById(childId))
                    {
                        supervisor.Kill();
                        Check(supervisor.WaitForExit(10000) && child.WaitForExit(10000), "Interrupting a launcher must close only its owned child tree.");
                    }
                    Check(!File.Exists(Path.Combine(directory, "child-finished.txt")), "The interrupted child must not continue using the profile.");
                    Check(EeaFreshSession.TryCleanup(root, directory), "Interrupted owned profiles must support later cleanup.");
                }
                finally
                {
                    release.Set();
                    if (!supervisor.HasExited) { supervisor.Kill(); supervisor.WaitForExit(10000); }
                }
            }
        }
        Console.WriteLine("PASS: Child-tree lifetime, active-job cleanup protection, launcher interruption, and later cleanup.");
    }

    public static int Main(string[] arguments)
    {
        try
        {
#if EEA_MODERN_RUNTIME
            if (arguments.Length == 1 && arguments[0] == ".png") return EasyEdgeApps.NativeFixture.SyntheticDecoder.WaitForCancellation();
            if (arguments.Length == 1 && arguments[0] == "--pin") return EasyEdgeApps.NativeFixture.SyntheticPin.WaitForCancellation();
            if (arguments.Length == 2 && arguments[0] == "window") return EasyEdgeApps.NativeFixture.SyntheticWindow.Run(arguments[1]);
#endif
            if (arguments[0] == "verify") { Verify(arguments[1]); return 0; }
            string directory = arguments[1];
            if (arguments[0] == "child")
            {
                using (EventWaitHandle ready = EventWaitHandle.OpenExisting(arguments[2]))
                using (EventWaitHandle release = EventWaitHandle.OpenExisting(arguments[3]))
                {
                    File.WriteAllText(Path.Combine(directory, "child-id.txt"), Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
                    ready.Set();
                    if (!release.WaitOne(20000)) return 2;
                    File.WriteAllText(Path.Combine(directory, "child-finished.txt"), "Synthetic completed child.");
                }
            }
            else if (arguments[0] == "parent")
            {
                using (Process child = Start(Command("child", directory, arguments[2], arguments[3]))) { }
            }
            else if (arguments[0] == "supervisor")
            {
                EeaFreshSession.RunProcess(ExecutablePath, Command("parent", directory, arguments[2], arguments[3]), directory);
            }
            else { return 3; }
            return 0;
        }
        catch (Exception failure)
        {
            bool legacyPaths;
            bool blockLongPaths;
            AppContext.TryGetSwitch("Switch.System.IO.UseLegacyPathHandling", out legacyPaths);
            AppContext.TryGetSwitch("Switch.System.IO.BlockLongPaths", out blockLongPaths);
#if EEA_MODERN_RUNTIME
            Console.Error.WriteLine("Runtime: " + Environment.Version + "; target: " + AppContext.TargetFrameworkName);
#else
            Console.Error.WriteLine("Runtime: " + Environment.Version + "; target: " + AppDomain.CurrentDomain.SetupInformation.TargetFrameworkName);
            Console.Error.WriteLine("Configuration: " + AppDomain.CurrentDomain.SetupInformation.ConfigurationFile);
#endif
            Console.Error.WriteLine("Legacy paths: " + legacyPaths + "; block long paths: " + blockLongPaths);
            Console.Error.WriteLine(failure.ToString());
            return 1;
        }
    }
}