using System;
using System.Globalization;
using System.IO;
using System.Threading;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.NativeFixture;

internal static class SyntheticPin
{
    internal static int WaitForCancellation()
    {
        var root = Path.GetFullPath(AppContext.BaseDirectory);
        var repository = new DirectoryInfo(root);
        while (repository != null && !File.Exists(Path.Combine(repository.FullName, "EasyEdgeApps.ps1"))) repository = repository.Parent;
        if (repository == null || !root.StartsWith(Path.Combine(repository.FullName, "artifacts") + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return 3;
        SafeFiles.CheckPath(root);
        var eventName = File.ReadAllText(Path.Combine(root, "pin-ready.txt"));
        if (!eventName.StartsWith("Local\\EasyEdgeApps-Synthetic-Pin-", StringComparison.Ordinal) || eventName.Length > 128) return 3;
        File.WriteAllText(Path.Combine(root, "pin-helper.pid"), Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
        using var ready = EventWaitHandle.OpenExisting(eventName);
        ready.Set();
        using var stop = new ManualResetEvent(false);
        stop.WaitOne(30000);
        return 2;
    }
}