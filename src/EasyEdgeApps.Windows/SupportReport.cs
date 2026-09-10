using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Windows;

public static class SupportReport
{
    public static string Create(CatalogStore store, string managerPath)
    {
        var edgeVersion = "Unavailable";
        try
        {
            var version = FileVersionInfo.GetVersionInfo(EdgeRuntime.Find()).FileVersion;
            if (Regex.IsMatch(version ?? "", "\\A[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\z")) edgeVersion = version;
        }
        catch { }
        var categories = new Dictionary<string, int> { ["Healthy"] = 0, ["Repairable"] = 0, ["Conflict"] = 0, ["RemovedRetained"] = 0 };
        var catalogStatus = "Healthy";
        try
        {
            foreach (var record in store.Read().Catalog.Apps)
            {
                if (record.Removed) { categories["RemovedRetained"]++; continue; }
                try
                {
                    store.CheckOwned(record, true);
                    var missing = record.Files.Any(file => SafeFiles.Hash(store.Layout.Resolve(CatalogStore.Address(record, file.Key))) == SafeFiles.Missing);
                    categories[missing ? "Repairable" : "Healthy"]++;
                }
                catch { categories["Conflict"]++; }
            }
        }
        catch { catalogStatus = "Conflict"; }
        string signature;
        try { signature = PublisherTrust.Inspect(managerPath).Status; } catch { signature = "Unavailable"; }
        return JsonSerializer.Serialize(new
        {
            Product = "Easy Edge Apps", Version = "2.0.0-preview.1", WindowsVersion = Environment.OSVersion.Version.ToString(),
            OperatingSystem64Bit = Environment.Is64BitOperatingSystem, Process64Bit = Environment.Is64BitProcess,
            DotNetVersion = Environment.Version.ToString(), InterfaceCulture = CultureInfo.CurrentUICulture.Name, EdgeVersion = edgeVersion,
            ManagerSignature = signature, CatalogStatus = catalogStatus, AppHealthCounts = categories
        }, StrictJson.Options);
    }
}