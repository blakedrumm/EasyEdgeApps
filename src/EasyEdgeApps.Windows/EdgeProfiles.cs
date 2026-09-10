using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Windows;

public sealed record EdgeProfileInfo(string DirectoryName, string DisplayName, string BookmarksPath, bool HasBookmarks);

public static class EdgeProfiles
{
    public static string DefaultRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Edge", "User Data");

    public static EdgeProfileInfo[] Discover(string userDataRoot)
    {
        userDataRoot = Path.GetFullPath(userDataRoot);
        SafeFiles.CheckPath(userDataRoot);
        if (!Directory.Exists(userDataRoot)) return Array.Empty<EdgeProfileInfo>();
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        var state = Path.Combine(userDataRoot, "Local State");
        if (File.Exists(state))
        {
            try
            {
                using var document = StrictJson.Parse(SafeFiles.Read(state, 4 * 1024 * 1024), 4 * 1024 * 1024, 32, 65536);
                if (document.RootElement.TryGetProperty("profile", out var profile) && profile.ValueKind == JsonValueKind.Object && profile.TryGetProperty("info_cache", out var cache) && cache.ValueKind == JsonValueKind.Object)
                    foreach (var entry in cache.EnumerateObject().Take(128))
                        if (entry.Value.ValueKind == JsonValueKind.Object && entry.Value.TryGetProperty("name", out var name) && name.ValueKind == JsonValueKind.String && name.GetString() is { Length: > 0 and <= 128 } value && !value.Any(char.IsControl)) names[entry.Name] = value;
            }
            catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException) { }
        }
        var profiles = new List<EdgeProfileInfo>();
        foreach (var directory in Directory.EnumerateDirectories(userDataRoot).Take(1024))
        {
            var name = Path.GetFileName(directory);
            try { if (Identity.Profile(name) != name) continue; SafeFiles.CheckPath(directory); }
            catch (ValidationException) { continue; }
            var bookmarks = Path.Combine(directory, "Bookmarks");
            SafeFiles.CheckPath(bookmarks);
            profiles.Add(new(name, names.TryGetValue(name, out var label) ? label + " (" + name + ")" : name, bookmarks, File.Exists(bookmarks)));
            if (profiles.Count > 128) throw new ValidationException("Too many Edge profiles. Select a Bookmarks file explicitly.");
        }
        return profiles.OrderBy(profile => profile.DirectoryName == "Default" ? 0 : 1).ThenBy(profile => profile.DirectoryName, StringComparer.Ordinal).ToArray();
    }
}