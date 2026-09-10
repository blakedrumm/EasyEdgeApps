using System;
using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;



public static partial class EeaFreshSession
{
    private const string Marker = "EasyEdgeApps.FreshSession:1";
    private const string MarkerFile = ".eea-session";
    private static bool FreshMode = true;
    private static int WindowMode = 1;
    private static bool AlwaysOnTop = false;

    [STAThread]
    public static int RunConfigured(string[] arguments)
    {
        try
        {
            bool pinRequest = arguments.Length == 1 && arguments[0] == "--pin";
            bool pinState = arguments.Length == 1 && arguments[0] == "--pin-state";
            if (arguments.Length != 0 && !pinRequest && !pinState) throw new InvalidOperationException("Unexpected launcher arguments.");
            string edge = Configuration.EdgePath;
            string website = Configuration.Url;
            string name = Configuration.Name;
            string root = Path.Combine(Path.GetDirectoryName(LauncherFile), "Sessions");
            if (name.Length != 0) EasyEdgeApps.Taskbar.Native.SetProcessIdentity(AppId(root));
            AppName = name;
            CheckCurrentUser();
            if (pinRequest || pinState)
            {
                if (name.Length == 0) throw new InvalidOperationException("This launcher has no website identity.");
                if (pinState) return GetPinState();
                return ConfirmPinResult(RequestPin(), GetPinState());
            }
            if (!Configuration.DedicatedProfile && !FreshMode) { RunShared(edge, website); return 0; }
            if (!FreshMode) { RunPersistent(Path.Combine(Path.GetDirectoryName(root), "AppProfile"), edge, website); return 0; }
            if (!Run(root, edge, website))
            {
                MessageBox.Show("Some temporary website data could not be removed. It will never be reused. Cleanup will be retried next time this website opens.", "Easy Edge Apps", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 2;
            }
            return 0;
        }
        catch
        {
            if (arguments.Length == 1 && (arguments[0] == "--pin" || arguments[0] == "--pin-state")) return 4;
            MessageBox.Show("The website app could not start or finish safely. No normal-profile fallback was requested. Ask your helper to check Edge availability, browser policies, and this website's saved shortcuts.", "Easy Edge Apps", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    public static void CheckPolicy()
    {
        CheckPolicy(true);
    }

    private static void CheckPolicy(bool fresh)
    {
        foreach (RegistryView view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        foreach (RegistryHive hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
        using (RegistryKey baseKey = RegistryKey.OpenBaseKey(hive, view))
        foreach (string suffix in new[] { "", "\\Recommended" })
        using (RegistryKey key = baseKey.OpenSubKey("Software\\Policies\\Microsoft\\Edge" + suffix))
        {
            if (key == null) continue;
            object userData = key.GetValue("UserDataDir", null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            if (fresh) CheckPolicyValues(userData, key.GetValue("BrowserGuestModeEnabled", null), key.GetValue("BrowserSignin", null));
            else if (userData != null) throw new InvalidOperationException("Edge UserDataDir policy prevents a verified app profile.");
        }
    }

    public static void CheckPolicyValues(object userDataDirectory, object guestModeEnabled, object browserSignin)
    {
        if (userDataDirectory != null)
            throw new InvalidOperationException("Edge UserDataDir policy prevents a verified isolated profile.");
        if (guestModeEnabled != null && !Object.Equals(guestModeEnabled, 1))
            throw new InvalidOperationException("Edge guest mode is unavailable by policy.");
        if (browserSignin != null && !Object.Equals(browserSignin, 0) && !Object.Equals(browserSignin, 1))
            throw new InvalidOperationException("Edge browser sign-in policy prevents a verified guest session.");
    }

    public static void CheckPath(string path)
    {
        for (string current = Path.GetFullPath(path); !String.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
        {
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Session paths must not contain reparse points.");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }

    private static string JobName(string directory)
    {
        if (Path.GetFileName(directory) == "AppProfile")
            return "Local\\EasyEdgeApps-App-" + AppId(Path.Combine(Path.GetDirectoryName(directory), "Sessions"));
        return "Local\\EasyEdgeApps-Fresh-" + Path.GetFileName(directory);
    }

    public static string CreateSession(string root)
    {
        FileStream lease;
        string directory = CreateSession(root, out lease);
        lease.Dispose();
        return directory;
    }

    public static string CreateSession(string root, out FileStream lease)
    {
        CheckPath(root);
        Directory.CreateDirectory(root);
        string directory = Path.Combine(root, Guid.NewGuid().ToString("N"));
        if (Directory.Exists(directory) || File.Exists(directory)) throw new IOException("Session identity collision.");
        Directory.CreateDirectory(directory);
        lease = new FileStream(Path.Combine(directory, MarkerFile), FileMode.CreateNew, FileAccess.Write, FileShare.None);
        try
        {
            byte[] data = Encoding.ASCII.GetBytes(Marker);
            lease.Write(data, 0, data.Length);
            lease.Flush(true);
        }
        catch { lease.Dispose(); throw; }
        return directory;
    }

    private static void CheckTree(string directory)
    {
        CheckPath(directory);
        foreach (string entry in Directory.GetFileSystemEntries(directory))
        {
            CheckPath(entry);
            if (Directory.Exists(entry)) CheckTree(entry);
        }
    }

    private static bool JobIsActive(string directory)
    {
        IntPtr job = OpenJobObject(4, false, JobName(directory));
        if (job == IntPtr.Zero)
        {
            if (Marshal.GetLastWin32Error() == 2) return false;
            return true;
        }
        try
        {
            AccountingInformation accounting;
            if (!QueryInformationJobObject(job, 1, out accounting, (uint)Marshal.SizeOf(typeof(AccountingInformation)), IntPtr.Zero)) return true;
            return accounting.ActiveProcesses != 0;
        }
        finally { CloseHandle(job); }
    }

    public static bool TryCleanup(string root, string directory)
    {
        try
        {
            root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
            directory = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar);
            if (!String.Equals(Path.GetDirectoryName(directory), root, StringComparison.OrdinalIgnoreCase) ||
                !Regex.IsMatch(Path.GetFileName(directory), "\\A[a-f0-9]{32}\\z")) return false;
            if (!Directory.Exists(directory)) return true;
            if (!directory.StartsWith(@"\\?\", StringComparison.Ordinal))
                directory = directory.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + directory.Substring(2) : @"\\?\" + directory;
            CheckPath(directory);
            string markerPath = Path.Combine(directory, MarkerFile);
            CheckPath(markerPath);
            using (FileStream marker = new FileStream(markerPath, FileMode.Open, FileAccess.Read, FileShare.None))
            {
                if (marker.Length != Marker.Length) return false;
                using (StreamReader reader = new StreamReader(marker, Encoding.ASCII, false, 128, true))
                    if (reader.ReadToEnd() != Marker) return false;
                if (JobIsActive(directory)) return false;
                CheckTree(directory);
                foreach (string entry in Directory.GetFileSystemEntries(directory))
                {
                    if (String.Equals(entry, markerPath, StringComparison.OrdinalIgnoreCase)) continue;
                    CheckPath(entry);
                    if (Directory.Exists(entry)) Directory.Delete(entry, true);
                    else File.Delete(entry);
                }
            }
            File.Delete(markerPath);
            Directory.Delete(directory, false);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    public static bool CleanupAfterExit(string root, string directory)
    {
        for (int attempt = 0; attempt < 50; attempt++)
        {
            if (TryCleanup(root, directory)) return true;
            if (attempt < 49) System.Threading.Thread.Sleep(100);
        }
        return false;
    }

    public static string Arguments(string website, string directory)
    {
        return Arguments(website, directory, true);
    }

    public static string Arguments(string website, string directory, bool fresh)
    {
        return Arguments(website, directory, fresh, 1);
    }

    public static string Arguments(string website, string directory, bool fresh, int mode)
    {
        Uri address;
        if (website.Length > 2048 || !Uri.TryCreate(website, UriKind.Absolute, out address) ||
            (address.Scheme != "https" && address.Scheme != "http") || address.UserInfo.Length != 0 ||
            Regex.IsMatch(website, "[\\s\\p{Cc}\\p{Cf}\"\\\\]")) throw new InvalidOperationException("Invalid session website.");
        if (!Path.IsPathRooted(directory) || directory.IndexOf('"') >= 0) throw new InvalidOperationException("Invalid session directory.");
        if (mode < 0 || mode > 2) throw new InvalidOperationException("Invalid window mode.");
        string window = mode == 1 ? " --start-maximized" : (mode == 2 ? " --start-fullscreen" : "");
        return "--app=\"" + website + "\"" + window + " --user-data-dir=\"" + directory +
            "\"" + (fresh ? " --guest" : "") + " --no-first-run --no-default-browser-check --disable-background-mode";
    }

    private static void CheckCurrentUser()
    {
        using (System.Security.Principal.WindowsIdentity identity = System.Security.Principal.WindowsIdentity.GetCurrent())
        {
            if (identity.IsSystem || new System.Security.Principal.WindowsPrincipal(identity).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator))
                throw new InvalidOperationException("Website apps require a non-elevated user session.");
        }
    }

    public static bool Run(string root, string executable, string website)
    {
        CheckCurrentUser();
        CheckPolicy();
        CheckPath(root);
        if (!File.Exists(executable)) throw new FileNotFoundException("Edge is unavailable.");
        if (Directory.Exists(root))
            foreach (string previous in Directory.GetDirectories(root)) TryCleanup(root, previous);
        FileStream lease;
        string directory = CreateSession(root, out lease);
        try
        {
            using (lease)
                RunProcess(executable, Arguments(website, Path.Combine(directory, "Profile"), true, WindowMode), directory);
        }
        finally
        {
            CleanupAfterExit(root, directory);
        }
        return !Directory.Exists(directory);
    }

    public static FileStream OpenAppProfile(string directory)
    {
        const string profileMarker = "EasyEdgeApps.AppProfile:1";
        CheckPath(directory);
        bool exists = Directory.Exists(directory);
        Directory.CreateDirectory(directory);
        string marker = Path.Combine(directory, ".eea-app-profile");
        CheckPath(marker);
        FileStream lease = new FileStream(marker, exists ? FileMode.Open : FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        try
        {
            byte[] expected = Encoding.ASCII.GetBytes(profileMarker);
            if (!exists) { lease.Write(expected, 0, expected.Length); lease.Flush(true); }
            else
            {
                if (lease.Length != expected.Length) throw new InvalidOperationException("The app profile is not recognized.");
                foreach (byte value in expected)
                    if (lease.ReadByte() != value) throw new InvalidOperationException("The app profile is not recognized.");
            }
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }

    public static void RunPersistent(string directory, string executable, string website)
    {
        CheckCurrentUser();
        CheckPolicy(false);
        CheckPath(directory);
        if (!File.Exists(executable)) throw new FileNotFoundException("Edge is unavailable.");
        string appId = AppId(Path.Combine(Path.GetDirectoryName(directory), "Sessions"));
        using (System.Threading.Mutex mutex = new System.Threading.Mutex(false, "Local\\EasyEdgeApps-AppWindow-" + appId))
        {
            bool acquired;
            try { acquired = mutex.WaitOne(0); }
            catch (System.Threading.AbandonedMutexException) { acquired = true; }
            if (!acquired)
            {
                IntPtr existingJob = OpenJobObject(4, false, JobName(directory));
                if (existingJob == IntPtr.Zero) return;
                try { EasyEdgeApps.Taskbar.Native.FocusJobWindow(existingJob, appId); }
                finally { CloseHandle(existingJob); }
                return;
            }
            try
            {
                using (FileStream lease = OpenAppProfile(directory))
                    RunProcess(executable, Arguments(website, Path.Combine(directory, "Profile"), false, WindowMode), directory);
            }
            finally { mutex.ReleaseMutex(); }
        }
    }

    public static int ConfirmPinResult(int requestResult, int pinState)
    {
        return pinState == 0 ? 0 : (requestResult == 3 && pinState == 3 ? 3 : 4);
    }

    private static int GetPinState()
    {
        if (!EasyEdgeApps.Taskbar.Native.SupportsPinRequests()) return 4;
        using (EasyEdgeApps.Taskbar.Native.PinClient client = new EasyEdgeApps.Taskbar.Native.PinClient())
        using (EasyEdgeApps.Taskbar.Native.PinOperation operation = client.CheckPinned())
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(10);
            while (!operation.IsCompleted && DateTime.UtcNow < deadline)
            {
                Application.DoEvents();
                System.Threading.Thread.Sleep(10);
            }
            return operation.IsCompleted ? (operation.Result ? 0 : 3) : 4;
        }
    }

    private static int RequestPin()
    {
        int result = 3;
        using (Form form = new Form())
        using (Timer timer = new Timer())
        using (EasyEdgeApps.Taskbar.Native.PinClient client = new EasyEdgeApps.Taskbar.Native.PinClient())
        {
            EasyEdgeApps.Taskbar.Native.PinOperation operation = null;
            bool requesting = false;
            DateTime deadline = DateTime.UtcNow.AddMinutes(2);
            form.Text = AppName;
            form.ClientSize = new System.Drawing.Size(420, 110);
            form.Font = new System.Drawing.Font("Segoe UI", 12);
            form.StartPosition = FormStartPosition.CenterScreen;
            form.FormBorderStyle = FormBorderStyle.FixedDialog;
            form.MaximizeBox = false;
            form.MinimizeBox = false;
            string iconPath = Path.Combine(Path.GetDirectoryName(LauncherFile), "icon.ico");
            CheckPath(iconPath);
            if (File.Exists(iconPath)) form.Icon = new System.Drawing.Icon(iconPath);
            Label label = new Label();
            label.Text = "Taskbar pin pending.";
            label.AutoSize = true;
            label.Location = new System.Drawing.Point(18, 18);
            form.Controls.Add(label);
            Button cancel = new Button();
            cancel.Text = "Cancel";
            cancel.AutoSize = true;
            cancel.Location = new System.Drawing.Point(305, 62);
            cancel.Click += delegate { result = 3; form.Close(); };
            form.Controls.Add(cancel);
            form.CancelButton = cancel;
            timer.Interval = 100;
            timer.Tick += delegate
            {
                try
                {
                    if (DateTime.UtcNow >= deadline) { result = 4; form.Close(); return; }
                    if (operation == null) { operation = client.CheckPinned(); return; }
                    if (!operation.IsCompleted) return;
                    bool pinned = operation.Result;
                    operation.Dispose();
                    operation = null;
                    if (pinned) { result = 0; form.Close(); return; }
                    if (requesting) { result = 3; form.Close(); return; }
                    if (!client.IsPinningAllowed) return;
                    requesting = true;
                    operation = client.RequestPin();
                }
                catch { result = 4; form.Close(); }
            };
            form.Shown += delegate { form.Activate(); timer.Start(); };
            try { Application.Run(form); }
            finally { timer.Stop(); if (operation != null) operation.Dispose(); if (form.Icon != null) form.Icon.Dispose(); }
        }
        return result;
    }

    private static string AppName = "";

    public static string AppId(string root)
    {
        string identity = Path.GetFileName(Path.GetDirectoryName(root));
        if (!Regex.IsMatch(identity, "\\A[a-f0-9]{64}\\z"))
        {
            using (System.Security.Cryptography.SHA256 hash = System.Security.Cryptography.SHA256.Create())
                identity = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToUpperInvariant()))).Replace("-", "").ToLowerInvariant();
        }
        return "EasyEdgeApps.Website." + identity;
    }

    public static void RunProcess(string executable, string arguments, string directory)
    {
        IntPtr job = IntPtr.Zero;
        IntPtr completion = IntPtr.Zero;
        EasyEdgeApps.Windowing.Controller windowController = null;
        ProcessInformation process = new ProcessInformation();
        bool assigned = false;
        try
        {
            job = CreateJobObject(IntPtr.Zero, JobName(directory));
            if (job == IntPtr.Zero || Marshal.GetLastWin32Error() == 183) throw new Win32Exception();
            ExtendedLimitInformation limits = new ExtendedLimitInformation();
            limits.Basic.LimitFlags = 0x2000;
            if (!SetJobLimits(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation)))) throw new Win32Exception();
            completion = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
            if (completion == IntPtr.Zero) throw new Win32Exception();
            CompletionInformation association = new CompletionInformation();
            association.Key = new IntPtr(1);
            association.Port = completion;
            if (!SetJobCompletion(job, 7, ref association, (uint)Marshal.SizeOf(typeof(CompletionInformation)))) throw new Win32Exception();
            StartupInformation startup = new StartupInformation();
            startup.Size = Marshal.SizeOf(typeof(StartupInformation));
            StringBuilder command = new StringBuilder("\"" + executable + "\" " + arguments);
            if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, 4, IntPtr.Zero, Path.GetDirectoryName(executable), ref startup, out process)) throw new Win32Exception();
            if (!AssignProcessToJobObject(job, process.Process)) throw new Win32Exception();
            assigned = true;
            if (WindowMode != 1 || AlwaysOnTop)
            {
                string launcher = LauncherFile;
                windowController = new EasyEdgeApps.Windowing.Controller(job, AppId(Path.Combine(Path.GetDirectoryName(launcher), "Sessions")), launcher, WindowMode, AlwaysOnTop);
            }
            if (ResumeThread(process.Thread) == UInt32.MaxValue) throw new Win32Exception();
            for (;;)
            {
                uint message;
                UIntPtr key;
                IntPtr overlapped;
                bool dequeued = GetQueuedCompletionStatus(completion, out message, out key, out overlapped, AppName.Length == 0 ? UInt32.MaxValue : 250);
                if (!dequeued)
                {
                    if (Marshal.GetLastWin32Error() != 258) throw new Win32Exception();
                }
                if (dequeued && message == 4 && key.ToUInt64() == 1) break;
                if (windowController != null) windowController.CheckHealth();
                if (AppName.Length != 0)
                {
                    string launcher = LauncherFile;
                    EasyEdgeApps.Taskbar.Native.ApplyJobIdentity(job, AppId(Path.Combine(Path.GetDirectoryName(launcher), "Sessions")), launcher, AppName, Path.Combine(Path.GetDirectoryName(launcher), "icon.ico"));
                }
            }
        }
        finally
        {
            try { if (windowController != null) windowController.Dispose(); }
            finally
            {
                if (assigned) TerminateJobObject(job, 1);
                if (process.Process != IntPtr.Zero && !assigned) TerminateProcess(process.Process, 1);
                if (process.Thread != IntPtr.Zero) CloseHandle(process.Thread);
                if (process.Process != IntPtr.Zero) CloseHandle(process.Process);
                if (job != IntPtr.Zero) CloseHandle(job);
                if (completion != IntPtr.Zero) CloseHandle(completion);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct AccountingInformation
    {
        public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime;
        public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long ProcessTime, JobTime;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation
    {
        public BasicLimitInformation Basic;
        public IoCounters Counters;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct CompletionInformation { public IntPtr Key, Port; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInformation
    {
        public int Size;
        public string Reserved, Desktop, Title;
        public uint X, Y, Width, Height, CharacterWidth, CharacterHeight, FillAttribute, Flags;
        public ushort ShowWindow, ReservedSize;
        public IntPtr ReservedData, StandardInput, StandardOutput, StandardError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenJobObject(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", EntryPoint = "SetInformationJobObject", SetLastError = true)]
    private static extern bool SetJobLimits(IntPtr job, int informationClass, ref ExtendedLimitInformation information, uint length);
    [DllImport("kernel32.dll", EntryPoint = "SetInformationJobObject", SetLastError = true)]
    private static extern bool SetJobCompletion(IntPtr job, int informationClass, ref CompletionInformation information, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int informationClass, out AccountingInformation information, uint length, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateIoCompletionPort(IntPtr file, IntPtr existing, UIntPtr key, uint threads);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetQueuedCompletionStatus(IntPtr port, out uint bytes, out UIntPtr key, out IntPtr overlapped, uint milliseconds);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInformation startup, out ProcessInformation process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")]
    private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")]
    private static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}
namespace EasyEdgeApps.Taskbar
{
    using System;
    using System.Runtime.InteropServices;
    using System.Text.RegularExpressions;

    public static class Native
    {
        private static readonly Guid PropertyInterface = new Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");
        private static readonly Guid AppModel = new Guid("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3");

        [StructLayout(LayoutKind.Sequential)]
        private struct PropertyKey
        {
            public Guid Format;
            public uint Id;
            public PropertyKey(uint id) { Format = AppModel; Id = id; }
        }

        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropertyValue
        {
            [FieldOffset(0)] public ushort Type;
            [FieldOffset(8)] public IntPtr Text;
        }

        [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropertyValue value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropertyValue value);
            [PreserveSig] int Commit();
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr binding, uint flags, ref Guid requestedInterface, out IPropertyStore store);
        [DllImport("shell32.dll", PreserveSig = true)]
        private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid requestedInterface, out IPropertyStore store);
        [DllImport("ole32.dll", PreserveSig = true)]
        private static extern int PropVariantClear(ref PropertyValue value);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        private static void CheckAppId(string appId)
        {
            if (appId == null || !Regex.IsMatch(appId, "\\AEasyEdgeApps\\.Website\\.[a-f0-9]{64}\\z"))
                throw new ArgumentException("Invalid website taskbar identity.");
        }

        private static string Read(IPropertyStore store, uint id)
        {
            PropertyKey key = new PropertyKey(id);
            PropertyValue value;
            Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
            try
            {
                if (value.Type == 0) return "";
                if (value.Type != 31) throw new InvalidOperationException("Unexpected taskbar property type.");
                return Marshal.PtrToStringUni(value.Text) ?? "";
            }
            finally { PropVariantClear(ref value); }
        }

        private static void Write(IPropertyStore store, uint id, string text)
        {
            PropertyKey key = new PropertyKey(id);
            PropertyValue value = new PropertyValue();
            value.Type = 31;
            value.Text = Marshal.StringToCoTaskMemUni(text);
            try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); }
            finally { PropVariantClear(ref value); }
        }

        public static string GetShortcutAppId(string path)
        {
            Guid requestedInterface = PropertyInterface;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 0, ref requestedInterface, out store));
            try { return Read(store, 5); }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static void SetShortcutAppId(string path, string appId)
        {
            CheckAppId(appId);
            Guid requestedInterface = PropertyInterface;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 2, ref requestedInterface, out store));
            try { Write(store, 5, appId); Marshal.ThrowExceptionForHR(store.Commit()); }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static string GetWindowAppId(IntPtr window)
        {
            Guid requestedInterface = PropertyInterface;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref requestedInterface, out store));
            try { return Read(store, 5); }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static void SetWindowIdentity(IntPtr window, string appId, string launcher, string name, string icon)
        {
            CheckAppId(appId);
            if (!System.IO.Path.IsPathRooted(launcher) || launcher.IndexOf('"') >= 0 || !System.IO.Path.IsPathRooted(icon) || icon.IndexOf('"') >= 0)
                throw new ArgumentException("Invalid website relaunch path.");
            Guid requestedInterface = PropertyInterface;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref requestedInterface, out store));
            try
            {
                Write(store, 2, "\"" + launcher + "\"");
                Write(store, 3, icon + ",0");
                Write(store, 4, name);
                Write(store, 5, appId);
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static void SetProcessIdentity(string appId)
        {
            CheckAppId(appId);
            Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(appId));
        }

        [ComImport, Guid("db32ab74-de52-4fe6-b7b6-95ff9f8395df"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface ITaskbarFactory
        {
            [PreserveSig] int GetIids(out uint count, out IntPtr values);
            [PreserveSig] int GetRuntimeClassName(out IntPtr value);
            [PreserveSig] int GetTrustLevel(out int value);
            [PreserveSig] int GetDefault(out ITaskbarManager manager);
        }

        [ComImport, Guid("87490a19-1ad9-49f4-b2e8-86738dc5ac40"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface ITaskbarManager
        {
            [PreserveSig] int GetIids(out uint count, out IntPtr values);
            [PreserveSig] int GetRuntimeClassName(out IntPtr value);
            [PreserveSig] int GetTrustLevel(out int value);
            [PreserveSig] int IsSupported(out byte value);
            [PreserveSig] int IsPinningAllowed(out byte value);
            [PreserveSig] int IsCurrentAppPinned(out IAsyncBoolean operation);
            [PreserveSig] int IsAppListEntryPinned(IntPtr entry, out IAsyncBoolean operation);
            [PreserveSig] int RequestPinCurrentApp(out IAsyncBoolean operation);
            [PreserveSig] int RequestPinAppListEntry(IntPtr entry, out IAsyncBoolean operation);
        }

        [ComImport, Guid("cdb5efb3-5788-509d-9be1-71ccb8a3362a"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAsyncBoolean
        {
            [PreserveSig] int GetIids(out uint count, out IntPtr values);
            [PreserveSig] int GetRuntimeClassName(out IntPtr value);
            [PreserveSig] int GetTrustLevel(out int value);
            [PreserveSig] int SetCompleted(IntPtr handler);
            [PreserveSig] int GetCompleted(out IntPtr handler);
            [PreserveSig] int GetResults(out byte value);
        }

        [ComImport, Guid("00000036-0000-0000-c000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAsyncInfo
        {
            [PreserveSig] int GetIids(out uint count, out IntPtr values);
            [PreserveSig] int GetRuntimeClassName(out IntPtr value);
            [PreserveSig] int GetTrustLevel(out int value);
            [PreserveSig] int GetId(out uint value);
            [PreserveSig] int GetStatus(out int value);
            [PreserveSig] int GetErrorCode(out int value);
            [PreserveSig] int Cancel();
            [PreserveSig] int Close();
        }

        [DllImport("combase.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int WindowsCreateString(string text, uint length, out IntPtr value);
        [DllImport("combase.dll", PreserveSig = true)]
        private static extern int WindowsDeleteString(IntPtr value);
        [DllImport("combase.dll", PreserveSig = true)]
        private static extern int RoGetActivationFactory(IntPtr name, ref Guid requestedInterface, [MarshalAs(UnmanagedType.IUnknown)] out object factory);

        public static bool SupportsPinRequests()
        {
            try
            {
                using (Microsoft.Win32.RegistryKey key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\LimitedAccessFeatures\com.microsoft.windows.taskbar.pin"))
                {
                    object required = key == null ? null : key.GetValue("4096B239A7295B635C090E647E867B5707DA6AB6CB78340B01FE4E0C8F4953D4", null);
                    if (required != null && !Object.Equals(required, 0)) return false;
                }
                object marker = GetFactory(new Guid("cdfefd63-e879-4134-b9a7-8283f05f9480"));
                Marshal.ReleaseComObject(marker);
                return true;
            }
            catch (COMException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (System.Security.SecurityException) { return false; }
            catch (EntryPointNotFoundException) { return false; }
        }

        private static object GetFactory(Guid requestedInterface)
        {
            const string className = "Windows.UI.Shell.TaskbarManager";
            IntPtr name;
            Marshal.ThrowExceptionForHR(WindowsCreateString(className, (uint)className.Length, out name));
            try
            {
                object factory;
                Marshal.ThrowExceptionForHR(RoGetActivationFactory(name, ref requestedInterface, out factory));
                return factory;
            }
            finally { WindowsDeleteString(name); }
        }

        public sealed class PinOperation : IDisposable
        {
            private IAsyncBoolean operation;
            internal PinOperation(object value) { operation = (IAsyncBoolean)value; }
            public bool IsCompleted
            {
                get
                {
                    int status;
                    Marshal.ThrowExceptionForHR(((IAsyncInfo)operation).GetStatus(out status));
                    return status != 0;
                }
            }
            public bool Result
            {
                get
                {
                    byte result;
                    Marshal.ThrowExceptionForHR(operation.GetResults(out result));
                    return result != 0;
                }
            }
            public void Dispose()
            {
                if (operation == null) return;
                IAsyncInfo information = (IAsyncInfo)operation;
                int status;
                if (information.GetStatus(out status) >= 0 && status == 0) information.Cancel();
                information.Close();
                Marshal.ReleaseComObject(operation);
                operation = null;
            }
        }

        public sealed class PinClient : IDisposable
        {
            private ITaskbarManager manager;
            public PinClient()
            {
                if (!SupportsPinRequests()) throw new NotSupportedException("Windows taskbar pin requests are unavailable on this device.");
                object factory = GetFactory(new Guid("db32ab74-de52-4fe6-b7b6-95ff9f8395df"));
                try { Marshal.ThrowExceptionForHR(((ITaskbarFactory)factory).GetDefault(out manager)); }
                finally { Marshal.ReleaseComObject(factory); }
            }
            public bool IsPinningAllowed
            {
                get
                {
                    byte supported;
                    byte allowed;
                    Marshal.ThrowExceptionForHR(manager.IsSupported(out supported));
                    Marshal.ThrowExceptionForHR(manager.IsPinningAllowed(out allowed));
                    return supported != 0 && allowed != 0;
                }
            }
            public PinOperation CheckPinned()
            {
                IAsyncBoolean operation;
                Marshal.ThrowExceptionForHR(manager.IsCurrentAppPinned(out operation));
                return new PinOperation(operation);
            }
            public PinOperation RequestPin()
            {
                IAsyncBoolean operation;
                Marshal.ThrowExceptionForHR(manager.RequestPinCurrentApp(out operation));
                return new PinOperation(operation);
            }
            public void Dispose()
            {
                if (manager == null) return;
                Marshal.ReleaseComObject(manager);
                manager = null;
            }
        }

        private delegate bool WindowCallback(IntPtr window, IntPtr state);
        [DllImport("user32.dll")]
        private static extern bool EnumWindows(WindowCallback callback, IntPtr state);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int capacity);
        [DllImport("kernel32.dll")]
        private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("kernel32.dll")]
        private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool belongs);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadImage(IntPtr module, string name, uint type, int width, int height, uint flags);
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr word, IntPtr data, uint flags, uint timeout, out UIntPtr result);
        private static IntPtr appIcon;

        public static void FocusJobWindow(IntPtr job, string appId)
        {
            CheckAppId(appId);
            EnumWindows(delegate(IntPtr window, IntPtr state)
            {
                if (!IsWindowVisible(window)) return true;
                uint processId;
                GetWindowThreadProcessId(window, out processId);
                IntPtr process = OpenProcess(0x1000, false, processId);
                if (process == IntPtr.Zero) return true;
                try
                {
                    bool belongs;
                    if (!IsProcessInJob(process, job, out belongs) || !belongs || GetWindowAppId(window) != appId) return true;
                    if (IsIconic(window)) ShowWindow(window, 9);
                    SetForegroundWindow(window);
                    return false;
                }
                catch (COMException) { return true; }
                finally { CloseHandle(process); }
            }, IntPtr.Zero);
        }

        public static void ApplyJobIdentity(IntPtr job, string appId, string launcher, string name, string icon)
        {
            CheckAppId(appId);
            if (job == IntPtr.Zero) throw new ArgumentException("A browser job is required.");
            EnumWindows(delegate(IntPtr window, IntPtr state)
            {
                if (!IsWindowVisible(window)) return true;
                System.Text.StringBuilder className = new System.Text.StringBuilder(128);
                GetClassName(window, className, className.Capacity);
                if (className.ToString() != "Chrome_WidgetWin_1") return true;
                uint processId;
                GetWindowThreadProcessId(window, out processId);
                IntPtr process = OpenProcess(0x1000, false, processId);
                if (process == IntPtr.Zero) return true;
                try
                {
                    bool belongs;
                    if (IsProcessInJob(process, job, out belongs) && belongs)
                    {
                        if (GetWindowAppId(window) != appId) SetWindowIdentity(window, appId, launcher, name, icon);
                        if (appIcon == IntPtr.Zero) appIcon = LoadImage(IntPtr.Zero, icon, 1, 32, 32, 0x10);
                        if (appIcon != IntPtr.Zero)
                        {
                            UIntPtr currentIcon;
                            if (SendMessageTimeout(window, 0x7f, new IntPtr(1), IntPtr.Zero, 2, 100, out currentIcon) != IntPtr.Zero && currentIcon.ToUInt64() != unchecked((ulong)appIcon.ToInt64()))
                            {
                                UIntPtr ignored;
                                SendMessageTimeout(window, 0x80, new IntPtr(1), appIcon, 2, 100, out ignored);
                                SendMessageTimeout(window, 0x80, IntPtr.Zero, appIcon, 2, 100, out ignored);
                            }
                        }
                    }
                }
                catch (COMException) { }
                finally { CloseHandle(process); }
                return true;
            }, IntPtr.Zero);
        }
    }
}
namespace EasyEdgeApps.Windowing
{
    using System;
    using System.ComponentModel;
    using System.Diagnostics;
    using System.IO;
    using System.Runtime.InteropServices;
    using System.Text;
    using System.Text.RegularExpressions;
    using System.Threading;
    using System.Windows.Forms;

    public static class Placement
    {
        private static byte[] Prefix(string appId)
        {
            if (appId == null || !Regex.IsMatch(appId, "\\AEasyEdgeApps\\.Website\\.[a-f0-9]{64}\\z")) throw new ArgumentException("Invalid window identity.");
            return Encoding.ASCII.GetBytes("EasyEdgeApps.Window:1\n" + appId + "\n");
        }

        private static bool Valid(int[] value)
        {
            return value != null && value.Length == 5 && Math.Abs((long)value[0]) <= 262144 && Math.Abs((long)value[1]) <= 262144 &&
                value[2] > 0 && value[2] <= 65536 && value[3] > 0 && value[3] <= 65536 && (value[4] == 1 || value[4] == 3);
        }

        public static int[] Normalize(int[] value, int[] work)
        {
            if (!Valid(value) || work == null || work.Length != 4 || Math.Abs((long)work[0]) > 262144 || Math.Abs((long)work[1]) > 262144 || work[2] < 1 || work[2] > 65536 || work[3] < 1 || work[3] > 65536) return null;
            int width = Math.Min(work[2], Math.Max(500, value[2]));
            int height = Math.Min(work[3], Math.Max(400, value[3]));
            return new[] { Math.Max(work[0], Math.Min(value[0], work[0] + work[2] - width)), Math.Max(work[1], Math.Min(value[1], work[1] + work[3] - height)), width, height, value[4] };
        }

        public static int[] Read(string path, string appId)
        {
            try
            {
                byte[] prefix = Prefix(appId);
                EeaFreshSession.CheckPath(path);
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
                using (BinaryReader reader = new BinaryReader(stream))
                {
                    if (stream.Length != prefix.Length + 20) return null;
                    foreach (byte expected in prefix) if (reader.ReadByte() != expected) return null;
                    int[] value = new int[5];
                    for (int index = 0; index < value.Length; index++) value[index] = reader.ReadInt32();
                    return Valid(value) ? value : null;
                }
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        public static bool Write(string path, string appId, int[] value)
        {
            string temporary = null;
            try
            {
                if (!Valid(value) || Path.GetFileName(path) != ".eea-window") return false;
                byte[] prefix = Prefix(appId);
                string directory = Path.GetDirectoryName(path);
                EeaFreshSession.CheckPath(path);
                if (!Directory.Exists(directory) || !File.Exists(Path.Combine(directory, "fresh-session.exe"))) return false;
                if (File.Exists(path) && Read(path, appId) == null) return false;
                temporary = Path.Combine(directory, ".eea-window-" + Guid.NewGuid().ToString("N") + ".tmp");
                using (FileStream stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (BinaryWriter writer = new BinaryWriter(stream))
                {
                    writer.Write(prefix);
                    foreach (int number in value) writer.Write(number);
                    writer.Flush();
                    stream.Flush(true);
                }
                EeaFreshSession.CheckPath(path);
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
                temporary = null;
                return true;
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
            finally
            {
                if (temporary != null)
                    try { File.Delete(temporary); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
            }
        }
    }

    public sealed class Controller : IDisposable
    {
        private readonly IntPtr job;
        private readonly string appId, launcher, statePath;
        private readonly int mode;
        private readonly bool topmost;
        private readonly Thread thread;
        private readonly ManualResetEvent ready = new ManualResetEvent(false);
        private volatile bool stopping;
        private Exception failure;
        private IntPtr window, keyboardHook, locationHook;
        private uint windowProcess;
        private int[] lastPlacement;
        private bool escapePending;
        private long escapeRetryAfter;
        private KeyboardCallback keyboardCallback;
        private EventCallback locationCallback;
        private MessageSink sink;
        private ApplicationContext context;

        public Controller(IntPtr job, string appId, string launcher, int mode, bool topmost)
        {
            if (job == IntPtr.Zero || mode < 0 || mode > 2) throw new ArgumentException("Invalid window controller.");
            this.appId = appId;
            this.launcher = launcher;
            this.mode = mode;
            this.topmost = topmost;
            statePath = Path.Combine(Path.GetDirectoryName(launcher), ".eea-window");
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.SetApartmentState(ApartmentState.STA);
            IntPtr process = GetCurrentProcess();
            if (!DuplicateHandle(process, job, process, out this.job, 0, false, 2)) throw new Win32Exception();
            try { thread.Start(); }
            catch { CloseHandle(this.job); ready.Dispose(); throw; }
            if (!ready.WaitOne(10000)) { Dispose(); throw new InvalidOperationException("Window controls could not initialize."); }
            try { CheckHealth(); } catch { Dispose(); throw; }
        }

        public void CheckHealth()
        {
            if (failure != null) throw new InvalidOperationException("Owned window controls are unavailable.", failure);
        }

        public static bool ShouldHandleEscape(int code, int message, int key, bool ownedForeground, bool fullscreen, bool modified)
        {
            return code == 0 && message == 0x100 && key == 27 && ownedForeground && fullscreen && !modified;
        }

        private void Run()
        {
            IntPtr previousDpi = IntPtr.Zero;
            System.Windows.Forms.Timer timer = null;
            try
            {
                previousDpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
                lastPlacement = Placement.Read(statePath, appId);
                context = new ApplicationContext();
                sink = new MessageSink(this);
                if (mode == 2)
                {
                    keyboardCallback = Keyboard;
                    keyboardHook = SetWindowsHookEx(13, keyboardCallback, GetModuleHandle(null), 0);
                    if (keyboardHook == IntPtr.Zero) throw new Win32Exception();
                }
                timer = new System.Windows.Forms.Timer();
                timer.Interval = 250;
                timer.Tick += delegate { try { Tick(); } catch (Win32Exception) { } };
                timer.Start();
                ready.Set();
                if (!stopping) Application.Run(context);
            }
            catch (Exception exception) { failure = exception; ready.Set(); }
            finally
            {
                try
                {
                    if (timer != null) timer.Dispose();
                    if (keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(keyboardHook);
                    if (locationHook != IntPtr.Zero) UnhookWinEvent(locationHook);
                    keyboardHook = locationHook = IntPtr.Zero;
                    if (mode == 0 && lastPlacement != null && File.Exists(launcher)) Placement.Write(statePath, appId, lastPlacement);
                    if (sink != null) sink.DestroyHandle();
                    if (context != null) context.Dispose();
                    if (previousDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(previousDpi);
                }
                finally { CloseHandle(job); }
            }
        }

        private bool Owns(IntPtr candidate)
        {
            if (candidate == IntPtr.Zero || !IsWindowVisible(candidate) || (GetWindowLongPtr(candidate, -20).ToInt64() & 0x80) != 0) return false;
            StringBuilder name = new StringBuilder(128);
            GetClassName(candidate, name, name.Capacity);
            if (name.ToString() != "Chrome_WidgetWin_1") return false;
            if (GetWindow(candidate, 4) != IntPtr.Zero) return false;
            return ProcessBelongsToJob(candidate);
        }

        private bool ProcessBelongsToJob(IntPtr candidate)
        {
            uint processId;
            GetWindowThreadProcessId(candidate, out processId);
            IntPtr process = OpenProcess(0x1000, false, processId);
            if (process == IntPtr.Zero) return false;
            try { bool belongs; return IsProcessInJob(process, job, out belongs) && belongs; }
            finally { CloseHandle(process); }
        }

        private void Tick()
        {
            if (stopping) { context.ExitThread(); return; }
            if (!Owns(window))
            {
                window = IntPtr.Zero;
                EnumWindows(delegate(IntPtr candidate, IntPtr state) { if (!Owns(candidate)) return true; window = candidate; return false; }, IntPtr.Zero);
                if (window == IntPtr.Zero) return;
                GetWindowThreadProcessId(window, out windowProcess);
                if (locationHook != IntPtr.Zero) UnhookWinEvent(locationHook);
                locationCallback = delegate(IntPtr hook, uint eventType, IntPtr changedWindow, int objectId, int childId, uint eventThread, uint time)
                {
                    if (!stopping && changedWindow == window && objectId == 0 && childId == 0)
                        try { Capture(); } catch { }
                };
                locationHook = SetWinEventHook(0x800b, 0x800b, IntPtr.Zero, locationCallback, windowProcess, 0, 0);
                if (mode == 0) Restore();
            }
            if (topmost && !IsFullScreen(window) && (GetWindowLongPtr(window, -20).ToInt64() & 8) == 0) SetWindowPos(window, new IntPtr(-1), 0, 0, 0, 0, 0x4013);
            if (!IsFullScreen(window)) escapePending = false;
            Capture();
        }

        private static MonitorInformation MonitorFor(Rectangle rectangle)
        {
            MonitorInformation information = new MonitorInformation();
            information.Size = Marshal.SizeOf(typeof(MonitorInformation));
            if (!GetMonitorInfo(MonitorFromRect(ref rectangle, 2), ref information)) throw new Win32Exception();
            return information;
        }

        private void Restore()
        {
            if (lastPlacement == null || !Owns(window)) return;
            Rectangle desired = new Rectangle { Left = lastPlacement[0], Top = lastPlacement[1], Right = lastPlacement[0] + lastPlacement[2], Bottom = lastPlacement[1] + lastPlacement[3] };
            Rectangle work = MonitorFor(desired).Work;
            int[] restored = Placement.Normalize(lastPlacement, new[] { work.Left, work.Top, work.Right - work.Left, work.Bottom - work.Top });
            if (restored == null) return;
            ShowWindowAsync(window, 9);
            SetWindowPos(window, IntPtr.Zero, restored[0], restored[1], restored[2], restored[3], 0x4014);
            if (restored[4] == 3) ShowWindowAsync(window, 3);
        }

        private void Capture()
        {
            if (mode != 0 || !Owns(window) || IsIconic(window) || IsFullScreen(window)) return;
            Rectangle rectangle;
            if (IsZoomed(window))
            {
                WindowPlacement placement = new WindowPlacement();
                placement.Length = Marshal.SizeOf(typeof(WindowPlacement));
                if (!GetWindowPlacement(window, ref placement)) return;
                rectangle = placement.Normal;
                Rectangle current;
                if (!GetWindowRect(window, out current)) return;
                MonitorInformation monitor = MonitorFor(current);
                int horizontalOffset = monitor.Work.Left - monitor.Bounds.Left;
                int verticalOffset = monitor.Work.Top - monitor.Bounds.Top;
                rectangle.Left += horizontalOffset; rectangle.Right += horizontalOffset;
                rectangle.Top += verticalOffset; rectangle.Bottom += verticalOffset;
            }
            else if (!GetWindowRect(window, out rectangle)) return;
            Rectangle work = MonitorFor(rectangle).Work;
            lastPlacement = Placement.Normalize(new[] { rectangle.Left, rectangle.Top, rectangle.Right - rectangle.Left, rectangle.Bottom - rectangle.Top, IsZoomed(window) ? 3 : 1 }, new[] { work.Left, work.Top, work.Right - work.Left, work.Bottom - work.Top });
        }

        private static bool IsFullScreen(IntPtr candidate)
        {
            Rectangle rectangle;
            if (!GetWindowRect(candidate, out rectangle)) return false;
            Rectangle monitor = MonitorFor(rectangle).Bounds;
            return rectangle.Left == monitor.Left && rectangle.Top == monitor.Top && rectangle.Right == monitor.Right && rectangle.Bottom == monitor.Bottom;
        }

        private IntPtr Keyboard(int code, IntPtr message, IntPtr data)
        {
            try
            {
                if (code == 0 && message.ToInt32() == 0x100)
                {
                    IntPtr foreground = GetForegroundWindow();
                    uint processId;
                    bool ownedForeground = window != IntPtr.Zero
                        ? foreground == window && GetWindowThreadProcessId(window, out processId) != 0 && processId == windowProcess
                        : Owns(foreground);
                    if (ownedForeground)
                    {
                        int key = Marshal.ReadInt32(data);
                        if (key == 27 && ShouldHandleEscape(code, message.ToInt32(), key, ownedForeground, IsFullScreen(foreground), ModifiersDown()) && !escapePending)
                        {
                            escapePending = PostMessage(sink.Handle, 0x8031, foreground, IntPtr.Zero);
                        }
                    }
                }
            }
            catch { }
            return CallNextHookEx(keyboardHook, code, message, data);
        }

        private static bool ModifiersDown()
        {
            return (GetAsyncKeyState(0x11) & 0x8000) != 0 || (GetAsyncKeyState(0x12) & 0x8000) != 0 || (GetAsyncKeyState(0x10) & 0x8000) != 0 || (GetAsyncKeyState(0x5b) & 0x8000) != 0 || (GetAsyncKeyState(0x5c) & 0x8000) != 0;
        }

        private void Escape(IntPtr target)
        {
            try
            {
                if (stopping || (window != IntPtr.Zero && target != window) || Stopwatch.GetTimestamp() < escapeRetryAfter || !Owns(target) || !IsFullScreen(target) || ModifiersDown() || GetForegroundWindow() != target) return;
                Input[] inputs = new Input[2];
                inputs[0].Type = inputs[1].Type = 1;
                inputs[0].Data.Keyboard.Key = inputs[1].Data.Keyboard.Key = 122;
                inputs[1].Data.Keyboard.Flags = 2;
                if (SendInput(2, inputs, Marshal.SizeOf(typeof(Input))) == 2) escapeRetryAfter = Stopwatch.GetTimestamp() + Stopwatch.Frequency;
            }
            catch (Win32Exception) { }
            finally { escapePending = false; }
        }

        public void Dispose()
        {
            stopping = true;
            if (sink != null) PostMessage(sink.Handle, 16, IntPtr.Zero, IntPtr.Zero);
            if (thread == null || thread == Thread.CurrentThread || thread.Join(5000)) ready.Dispose();
        }

        private sealed class MessageSink : NativeWindow
        {
            private readonly Controller owner;
            internal MessageSink(Controller owner) { this.owner = owner; CreateHandle(new CreateParams { Parent = new IntPtr(-3) }); }
            protected override void WndProc(ref Message message)
            {
                if (message.Msg == 16) { owner.context.ExitThread(); return; }
                if (message.Msg == 0x8031) { owner.Escape(message.WParam); return; }
                base.WndProc(ref message);
            }
        }

        private delegate bool WindowCallback(IntPtr window, IntPtr state);
        private delegate IntPtr KeyboardCallback(int code, IntPtr message, IntPtr data);
        private delegate void EventCallback(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time);
        [StructLayout(LayoutKind.Sequential)] private struct Rectangle { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] private struct MonitorInformation { public int Size; public Rectangle Bounds, Work; public uint Flags; }
        [StructLayout(LayoutKind.Sequential)] private struct WindowPlacement { public int Length, Flags, Show; public Point Minimum, Maximum; public Rectangle Normal; }
        [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput { public ushort Key, Scan; public uint Flags, Time; public UIntPtr Extra; }
        [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
        [StructLayout(LayoutKind.Explicit)] private struct InputUnion { [FieldOffset(0)] public KeyboardInput Keyboard; [FieldOffset(0)] public MouseInput Mouse; }
        [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public InputUnion Data; }
        [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr state);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
        [DllImport("user32.dll")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, uint process);
        [DllImport("kernel32.dll")] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool belongs);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr source, IntPtr targetProcess, out IntPtr target, uint access, bool inherit, uint options);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rectangle rectangle);
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromRect(ref Rectangle rectangle, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInformation information);
        [DllImport("user32.dll")] private static extern bool GetWindowPlacement(IntPtr window, ref WindowPlacement placement);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsZoomed(IntPtr window);
        [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int left, int top, int width, int height, uint flags);
        [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int hook, KeyboardCallback callback, IntPtr module, uint thread);
        [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint minimum, uint maximum, IntPtr module, EventCallback callback, uint process, uint thread, uint flags);
        [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr word, IntPtr data);
        [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] inputs, int size);
    }
}