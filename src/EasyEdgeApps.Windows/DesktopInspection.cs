using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Xml;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;
using EasyEdgeApps.SiteLauncher;

namespace EasyEdgeApps.Windows;

public sealed class DesktopInspection
{
    private readonly CatalogStore store;
    private readonly Lazy<string> edge;
    private readonly Lazy<string> launcherHash;

    public DesktopInspection(CatalogStore catalog, string launcherTemplate, Func<string> edgeResolver = null)
    {
        store = catalog;
        edge = new(() =>
        {
            var path = Path.GetFullPath((edgeResolver ?? EdgeRuntime.Find)());
            SafeFiles.CheckPath(path);
            if (!File.Exists(path) || !Path.GetFileName(path).Equals("msedge.exe", StringComparison.OrdinalIgnoreCase)) throw new ValidationException("Microsoft Edge is not available.");
            return path;
        });
        launcherHash = new(() =>
        {
            var path = Path.GetFullPath(launcherTemplate);
            SafeFiles.CheckPath(path);
            using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                if (input.ReadByte() != 'M' || input.ReadByte() != 'Z') throw new ValidationException("The bundled launcher is invalid.");
            return SafeFiles.Hash(path);
        });
    }

    public AppCheck[] ReadAll(CatalogSnapshot snapshot)
    {
        var results = snapshot.Catalog.Apps.Where(record => !record.Removed).Select(Check).ToList();
        var known = snapshot.Catalog.Apps.Select(record => record.Definition.Id).ToHashSet(StringComparer.Ordinal);
        try
        {
            var root = store.Layout.Resolve(new(StorageArea.Data, "Apps"));
            if (Directory.Exists(root))
            {
                var count = 0;
                foreach (var directory in Directory.EnumerateDirectories(root))
                {
                    if (++count > 5000) throw new ValidationException("The saved website folder count exceeds its inspection bound.");
                    var id = Path.GetFileName(directory);
                    if (!Identity.IsId(id) || known.Contains(id)) continue;
                    SafeFiles.CheckPath(directory);
                    results.Add(new(id, "App folder " + id[..8], "Conflict", false, ["No catalog ownership was found. This folder may contain retained data. No repair or deletion was performed."]));
                }
            }
        }
        catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException)
        { results.Add(new("", "Saved apps", "Blocked", false, ["The saved website folders could not be safely inspected."])); }
        if (snapshot.Catalog.Apps.All(record => record.Removed))
        {
            try { _ = edge.Value; }
            catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException or ArgumentException)
            { results.Add(new("", "Microsoft Edge", "Blocked", false, ["Microsoft Edge was not found in a supported installation location or could not be read."])); }
            try { _ = launcherHash.Value; }
            catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException or ArgumentException)
            { results.Add(new("", "Manager package", "Blocked", false, ["The bundled website launcher is missing or invalid. Restore the complete manager package."])); }
        }
        return results.OrderBy(result => result.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }

    public AppCheck Check(AppRecord record)
    {
        var result = store.Check(record) with
        {
            BrowsingMode = record.Definition.Window.FreshSession ? "Fresh Guest session (temporary)" : record.Definition.Window.DedicatedProfile ? "Dedicated app profile (persistent)" : "Normal Edge profile"
        };
        if (record.Removed) return result with { CanRepair = false };
        var issues = result.Issues.ToList();
        var conflict = result.Status == "Conflict";
        var blocked = false;
        if (!conflict)
        {
            try
            {
                var icon = store.Layout.Resolve(CatalogStore.Address(record, "Icon"));
                if (File.Exists(icon)) IconService.Validate(SafeFiles.Read(icon, 1024 * 1024));
                var configurationPath = store.Layout.Resolve(CatalogStore.Address(record, "Configuration"));
                if (File.Exists(configurationPath))
                {
                    var configuration = LaunchConfiguration.Read(Path.GetDirectoryName(configurationPath), false);
                    var app = record.Definition;
                    if (configuration.Id != app.Id || configuration.Name != app.DisplayName || configuration.Url != app.Url || configuration.EdgeProfile != app.EdgeProfile ||
                        configuration.EdgePath != record.EdgePath || configuration.LauncherHash != record.Files["Launcher"] || configuration.Version != record.LauncherVersion ||
                        configuration.FreshSession != app.Window.FreshSession || configuration.DedicatedProfile != app.Window.DedicatedProfile || configuration.Taskbar != app.Window.Taskbar ||
                        configuration.StartMenu != app.StartMenu || configuration.LaunchMode != (int)app.Window.LaunchMode || configuration.AlwaysOnTop != app.Window.AlwaysOnTop)
                        throw new ValidationException("Launcher settings do not match the owned website definition.");
                }
                foreach (var slot in new[] { "Desktop", "StartMenu" }.Where(record.Files.ContainsKey))
                {
                    var path = store.Layout.Resolve(CatalogStore.Address(record, slot));
                    if (!File.Exists(path)) continue;
                    var shortcut = Shortcuts.Read(path);
                    if (!shortcut.Target.Equals(store.Layout.Resolve(CatalogStore.Address(record, "Launcher")), StringComparison.OrdinalIgnoreCase) || shortcut.Arguments.Length != 0 ||
                        shortcut.Description != "EasyEdgeApps:" + record.Definition.Id || shortcut.AppId != "EasyEdgeApps.Website." + record.Definition.Id || shortcut.WindowStyle != 1 ||
                        !shortcut.Icon.Equals(icon + ",0", StringComparison.OrdinalIgnoreCase)) throw new ValidationException("Shortcut metadata does not match its owned website identity.");
                }
            }
            catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException or ArgumentException or XmlException or COMException)
            {
                conflict = true;
                issues.Add("Owned icon, launcher settings or shortcut metadata could not be verified. Restore trusted files before repair.");
            }
        }
        try
        {
            if (!record.EdgePath.Equals(edge.Value, StringComparison.OrdinalIgnoreCase)) issues.Add("Update the owned configuration to the current Edge executable.");
        }
        catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException or ArgumentException)
        {
            blocked = true;
            issues.Add("Microsoft Edge was not found in a supported installation location or could not be read.");
        }
        try
        {
            if (record.Files["Launcher"] != launcherHash.Value) issues.Add("Update the owned website launcher to this manager's bundled version.");
        }
        catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException or ArgumentException)
        {
            blocked = true;
            issues.Add("The bundled website launcher is missing or invalid. Restore the complete manager package.");
        }
        var status = conflict ? "Conflict" : blocked ? "Blocked" : issues.Count == 0 ? "Healthy" : "Repairable";
        return result with { Status = status, CanRepair = status == "Repairable", Issues = issues.ToArray() };
    }
}