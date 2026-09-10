using System.Text.Json;
using System.Text.RegularExpressions;

namespace EasyEdgeApps.Core;

public sealed record FavoriteCandidate(string Name, string Url, string Folder, bool CanImport, string Reason);

public static class Favorites
{
    public static FavoriteCandidate[] Read(byte[] bytes, IReadOnlyCollection<AppDefinition> destination)
        => Read(bytes, destination, null);

    public static FavoriteCandidate[] Read(byte[] bytes, IReadOnlyCollection<AppDefinition> destination, Func<string, bool>? nameUnavailable)
    {
        using var document = StrictJson.Parse(bytes, 16 * 1024 * 1024, 256, 250000);
        var root = document.RootElement;
        if (!root.TryGetProperty("roots", out var roots) || !roots.TryGetProperty("bookmark_bar", out var bar) || StrictJson.Text(bar, "type") != "folder") throw new ValidationException("The file has no Edge Favorites bar.");
        var candidates = new List<FavoriteCandidate>();
        var visited = 0;
        var names = destination.SelectMany(app => app.Aliases.Append(app.DisplayName)).Select(Identity.NameKey).ToHashSet(StringComparer.Ordinal);
        var urls = destination.Select(app => app.Url).ToHashSet(StringComparer.Ordinal);
        void Visit(JsonElement node, string folder, int depth)
        {
            if (++visited > 10000 || depth > 64) throw new ValidationException("Favorites exceed the traversal bound.");
            var type = StrictJson.Text(node, "type");
            if (type == "folder")
            {
                var title = Regex.Replace(StrictJson.Text(node, "name", ""), "[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]", " ");
                if (title.Length > 256) title = title[..256];
                var next = depth == 0 ? "" : folder.Length == 0 ? title : folder + " / " + title;
                if (next.Length > 1024) next = next[..1024];
                if (!node.TryGetProperty("children", out var children) || children.ValueKind != JsonValueKind.Array) throw new ValidationException("Invalid Favorites folder.");
                foreach (var child in children.EnumerateArray()) Visit(child, next, depth + 1);
                return;
            }
            var name = Regex.Replace(StrictJson.Text(node, "name", ""), "[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]", " ");
            if (name.Length > 256) name = name[..256];
            try
            {
                if (type != "url") throw new ValidationException("Unsupported Favorite type.");
                var url = Identity.Website(StrictJson.Text(node, "url"));
                if (new Uri(url).Scheme != Uri.UriSchemeHttps) throw new ValidationException("Favorites import requires HTTPS.");
                name = Regex.Replace(name.Normalize(), "[<>:\"/\\\\|?*\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]", " ");
                name = Regex.Replace(name, "\\s+", " ").Trim().TrimEnd('.').Trim();
                if (name.Length == 0) name = new Uri(url).IdnHost;
                if (name.Length > 60)
                {
                    name = name[..60];
                    if (char.IsHighSurrogate(name[^1])) name = name[..^1];
                    name = name.Trim().TrimEnd('.').Trim();
                }
                if (Regex.IsMatch(name, "^(CON|PRN|AUX|NUL|COM[1-9\\u00b9\\u00b2\\u00b3]|LPT[1-9\\u00b9\\u00b2\\u00b3])(\\..*)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)) name = "Website " + name;
                name = Identity.Name(name);
                var unique = urls.Add(url);
                var renamed = false;
                if (unique)
                {
                    var stem = name;
                    var suffixNumber = 2;
                    while (names.Contains(Identity.NameKey(name)) || nameUnavailable?.Invoke(name) == true)
                    {
                        if (suffixNumber > 10000) throw new ValidationException("Too many Favorites share a shortcut name.");
                        var suffix = " (" + suffixNumber++ + ")";
                        var prefix = stem[..Math.Min(stem.Length, 60 - suffix.Length)];
                        if (char.IsHighSurrogate(prefix[^1])) prefix = prefix[..^1];
                        name = Identity.Name(prefix.TrimEnd() + suffix);
                        renamed = true;
                    }
                    names.Add(Identity.NameKey(name));
                }
                candidates.Add(new(name, url, folder, unique, unique ? renamed ? "Available with a different shortcut name" : "Ready" : "Address already saved or selected"));
            }
            catch (ValidationException) { candidates.Add(new(name, "", folder, false, "Only complete HTTPS website addresses can be added")); }
        }
        Visit(bar, "", 0);
        return candidates.ToArray();
    }

    public static AppKit ToKit(IEnumerable<FavoriteCandidate> selected, bool desktop = true, bool startMenu = true)
    {
        var items = selected.ToArray();
        if (items.Any(item => !item.CanImport || new Uri(Identity.Website(item.Url)).Scheme != Uri.UriSchemeHttps)) throw new ValidationException("Choose only supported, new HTTPS Favorites.");
        return KitCodec.Read(KitCodec.Write(new(1, "Edge Favorites bar", items.Select(item => new KitApp(item.Name, item.Url, desktop, startMenu)).ToArray())));
    }
}