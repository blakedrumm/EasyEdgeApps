using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Xml;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Windows;

public sealed record ShortcutInfo(string Target, string Arguments, string Description, string Icon, int WindowStyle, string AppId);

public static class Shortcuts
{
    public static byte[] Create(string stagePath, string target, string icon, string id)
    {
        SafeFiles.CheckPath(stagePath);
        var shortcut = CreateLink(target, icon, id);
        try { ((System.Runtime.InteropServices.ComTypes.IPersistFile)shortcut).Save(stagePath, true); }
        finally { Marshal.FinalReleaseComObject(shortcut); }
        return SafeFiles.Read(stagePath, 65536);
    }

    public static byte[] CreateBytes(string target, string icon, string id)
    {
        var shortcut = CreateLink(target, icon, id);
        System.Runtime.InteropServices.ComTypes.IStream memory = null;
        var count = IntPtr.Zero;
        try
        {
            Marshal.ThrowExceptionForHR(CreateStreamOnHGlobal(IntPtr.Zero, true, out memory));
            ((IPersistStream)shortcut).Save(memory, true);
            memory.Stat(out var information, 1);
            if (information.cbSize is <= 0 or > 65536) throw new ValidationException("The serialized shortcut exceeds its size bound.");
            var bytes = new byte[checked((int)information.cbSize)];
            memory.Seek(0, 0, IntPtr.Zero);
            count = Marshal.AllocCoTaskMem(sizeof(int));
            memory.Read(bytes, bytes.Length, count);
            if (Marshal.ReadInt32(count) != bytes.Length) throw new IOException("The shortcut stream was incomplete.");
            return bytes;
        }
        finally
        {
            if (count != IntPtr.Zero) Marshal.FreeCoTaskMem(count);
            if (memory != null) Marshal.FinalReleaseComObject(memory);
            Marshal.FinalReleaseComObject(shortcut);
        }
    }

    private static object CreateLink(string target, string icon, string id)
    {
        if (!Identity.IsId(id)) throw new ValidationException("Invalid website shortcut identity.");
        object shortcut = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-c000-000000000046"), true));
        try
        {
            var link = (IShellLink)shortcut;
            link.SetPath(target);
            link.SetArguments("");
            link.SetWorkingDirectory(Path.GetDirectoryName(target));
            link.SetDescription("EasyEdgeApps:" + id);
            link.SetIconLocation(icon, 0);
            link.SetShowCmd(1);
            var properties = (IPropertyStore)shortcut;
            var key = new PropertyKey { Format = new("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3"), Id = 5 };
            var value = new PropertyValue { Type = 31, Text = Marshal.StringToCoTaskMemUni("EasyEdgeApps.Website." + id) };
            try { Marshal.ThrowExceptionForHR(properties.SetValue(ref key, ref value)); }
            finally { Marshal.FreeCoTaskMem(value.Text); }
            Marshal.ThrowExceptionForHR(properties.Commit());
            return shortcut;
        }
        catch { Marshal.FinalReleaseComObject(shortcut); throw; }
    }

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CreateStreamOnHGlobal(IntPtr memory, [MarshalAs(UnmanagedType.Bool)] bool deleteOnRelease, out System.Runtime.InteropServices.ComTypes.IStream stream);

    [ComImport, Guid("00000109-0000-0000-c000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistStream
    {
        void GetClassID(out Guid classId);
        [PreserveSig] int IsDirty();
        void Load(System.Runtime.InteropServices.ComTypes.IStream stream);
        void Save(System.Runtime.InteropServices.ComTypes.IStream stream, [MarshalAs(UnmanagedType.Bool)] bool clearDirty);
        void GetSizeMax(out long size);
    }

    [ComImport, Guid("000214f9-0000-0000-c000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLink
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, IntPtr data, uint flags);
        void GetIDList(out IntPtr list);
        void SetIDList(IntPtr list);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder description, int length);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int length);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int length);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        void GetHotkey(out ushort hotkey);
        void SetHotkey(ushort hotkey);
        void GetShowCmd(out int command);
        void SetShowCmd(int command);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey { public Guid Format; public uint Id; }

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

    public static ShortcutInfo Read(string path)
    {
        SafeFiles.CheckPath(path);
        if (!File.Exists(path) || new FileInfo(path).Length > 65536) throw new ValidationException("Missing or oversized shortcut.");
        object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true));
        object shortcut = null;
        try
        {
            dynamic automation = shell;
            shortcut = automation.CreateShortcut(path);
            dynamic link = shortcut;
            return new((string)link.TargetPath, (string)link.Arguments, (string)link.Description, (string)link.IconLocation, (int)link.WindowStyle, EasyEdgeApps.Taskbar.Native.GetShortcutAppId(path));
        }
        finally
        {
            if (shortcut != null) Marshal.FinalReleaseComObject(shortcut);
            Marshal.FinalReleaseComObject(shell);
        }
    }
}

public static class EdgeRuntime
{
    public static string Find()
    {
        foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) }.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (string.IsNullOrWhiteSpace(root)) continue;
            var candidate = Path.Combine(root, "Microsoft", "Edge", "Application", "msedge.exe");
            if (File.Exists(candidate)) return candidate;
        }
        throw new ValidationException("Microsoft Edge was not found in a supported installation location.");
    }

    public static string SharedArguments(AppDefinition app)
    {
        app = app.Normalize();
        var arguments = "--app=\"" + app.Url + "\"";
        if (app.Window.LaunchMode == LaunchMode.Maximized) arguments += " --start-maximized";
        if (app.EdgeProfile.Length != 0) arguments += " --profile-directory=\"" + app.EdgeProfile + "\"";
        return arguments;
    }

    public static IDisposable LegacyWriterLease()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var mutex = new Mutex(false, "Local\\EasyEdgeApps-" + identity.User.Value);
        try
        {
            bool acquired;
            try { acquired = mutex.WaitOne(0); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) throw new ValidationException("Another legacy manager change is in progress. Finish it before continuing.");
            return new MutexLease(mutex);
        }
        catch { mutex.Dispose(); throw; }
    }

    private sealed class MutexLease(Mutex mutex) : IDisposable
    {
        public void Dispose() { mutex.ReleaseMutex(); mutex.Dispose(); }
    }
}

public sealed class DesktopArtifacts : IAppArtifacts
{
    public IDisposable AcquireWriterLease() => EdgeRuntime.LegacyWriterLease();
    private readonly string template;
    private readonly Func<string> findEdge;
    public DesktopArtifacts(string launcherTemplate, Func<string> edgeResolver = null)
    { template = Path.GetFullPath(launcherTemplate); findEdge = edgeResolver ?? EdgeRuntime.Find; }

    public AppArtifacts Build(AppRecord record, StoreLayout layout, byte[] iconBytes, bool regenerateIcon)
    {
        var definition = record.Definition.Normalize();
        var launcher = SafeFiles.Read(template, 256 * 1024 * 1024);
        if (launcher.Length < 2 || launcher[0] != 'M' || launcher[1] != 'Z') throw new ValidationException("The prebuilt launcher template is invalid.");
        var iconPath = layout.Resolve(CatalogStore.Address(record, "Icon"));
        var launcherPath = layout.Resolve(CatalogStore.Address(record, "Launcher"));
        if (File.Exists(launcherPath))
        {
            using var stopped = new FileStream(launcherPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        }
        if (iconBytes == null && !regenerateIcon && File.Exists(iconPath)) iconBytes = SafeFiles.Read(iconPath, 1024 * 1024);
        iconBytes ??= IconService.Generate(definition.DisplayName);
        IconService.Validate(iconBytes);
        var edge = findEdge();
        var version = "2.0.0-preview.1";
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["Icon"] = iconBytes, ["Launcher"] = launcher,
            ["Configuration"] = Configuration(definition, edge, Identity.Hash(launcher), version)
        };
        foreach (var slot in new[] { "Desktop", "StartMenu" })
        {
            if (!(slot == "Desktop" ? definition.Desktop : definition.StartMenu)) continue;
            if (layout.Resolve(CatalogStore.Address(record, slot)).Length > 240) throw new ValidationException("The selected shortcut path is too long.");
            files[slot] = Shortcuts.CreateBytes(launcherPath, iconPath, definition.Id);
        }
        return new(edge, version, files);
    }

    public void ValidateLegacy(LegacyManifest manifest, StoreLayout layout)
    {
        var record = new AppRecord { Definition = manifest.App, Storage = StorageArea.Legacy, ShortcutName = manifest.App.DisplayName };
        var target = manifest.App.Window.Owned ? layout.Resolve(CatalogStore.Address(record, "Launcher")) : manifest.EdgePath;
        var expectedArguments = manifest.App.Window.Owned ? "" : EdgeRuntime.SharedArguments(manifest.App);
        foreach (var slot in new[] { "Desktop", "StartMenu" })
        {
            var requested = slot == "Desktop" ? manifest.App.Desktop : manifest.App.StartMenu;
            var path = layout.Resolve(CatalogStore.Address(record, slot));
            if (!File.Exists(path)) continue;
            if (!requested) throw new ValidationException("An unrelated shortcut occupies the legacy name.");
            var shortcut = Shortcuts.Read(path);
            if (!StringComparer.OrdinalIgnoreCase.Equals(shortcut.Target, target) || shortcut.Arguments != expectedArguments || shortcut.Description != "EasyEdgeApps:" + manifest.App.Id ||
                !StringComparer.OrdinalIgnoreCase.Equals(shortcut.Icon, layout.Resolve(CatalogStore.Address(record, "Icon")) + ",0") ||
                (manifest.SchemaVersion >= 3 && manifest.App.Window.Owned && shortcut.AppId != "EasyEdgeApps.Website." + manifest.App.Id) || (manifest.SchemaVersion == 4 && shortcut.WindowStyle != 1))
                throw new ValidationException("A legacy shortcut was changed outside Easy Edge Apps.");
        }
        IconService.Validate(SafeFiles.Read(layout.Resolve(CatalogStore.Address(record, "Icon")), 1024 * 1024));
    }

    public static byte[] Configuration(AppDefinition app, string edge, string launcherHash, string version)
    {
        app = app.Normalize();
        using var stream = new MemoryStream();
        using (var writer = XmlWriter.Create(stream, new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = true, CloseOutput = false }))
        {
            writer.WriteStartElement("EasyEdgeApps.Launcher"); writer.WriteAttributeString("SchemaVersion", "1");
            foreach (var entry in new Dictionary<string, string>
            {
                ["Id"] = app.Id, ["Name"] = app.DisplayName, ["Url"] = app.Url, ["EdgePath"] = edge, ["EdgeProfile"] = app.EdgeProfile,
                ["FreshSession"] = app.Window.FreshSession.ToString().ToLowerInvariant(), ["DedicatedProfile"] = app.Window.DedicatedProfile.ToString().ToLowerInvariant(),
                ["Taskbar"] = app.Window.Taskbar.ToString().ToLowerInvariant(), ["StartMenu"] = app.StartMenu.ToString().ToLowerInvariant(),
                ["LaunchMode"] = ((int)app.Window.LaunchMode).ToString(CultureInfo.InvariantCulture), ["AlwaysOnTop"] = app.Window.AlwaysOnTop.ToString().ToLowerInvariant(),
                ["LauncherHash"] = launcherHash, ["Version"] = version
            }) writer.WriteElementString(entry.Key, entry.Value);
            writer.WriteEndElement();
        }
        return stream.ToArray();
    }
}