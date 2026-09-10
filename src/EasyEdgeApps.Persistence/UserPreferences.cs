using System.Text.Json;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Persistence;

public sealed record UserPreferences
{
    public string Product { get; init; } = "EasyEdgeApps.Preferences";
    public int SchemaVersion { get; init; } = 1;
    public string Theme { get; init; } = "Original";
    public bool CheckUpdates { get; init; }
    public bool Diagnostics { get; init; }
    public bool Tiles { get; init; }
    public bool MotionEnabled { get; init; } = true;
    public double TextSize { get; init; } = 16;
    public bool DefaultDesktop { get; init; } = true;
    public bool DefaultStartMenu { get; init; } = true;
    public string DefaultProfile { get; init; } = "";
    public string LastUpdateCheckUtc { get; init; } = "";

    public UserPreferences Validate()
    {
        if (Product != "EasyEdgeApps.Preferences" || SchemaVersion != 1 || Theme is not ("Original" or "System" or "Light" or "Dark") ||
            (TextSize is not (14 or 16 or 18 or 24) && TextSize != 56.0 / 3.0 && TextSize != 64.0 / 3.0) ||
            (!DefaultDesktop && !DefaultStartMenu) || DefaultProfile is null || LastUpdateCheckUtc is null ||
            (LastUpdateCheckUtc.Length != 0 && !DateTimeOffset.TryParseExact(LastUpdateCheckUtc, "O", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out _)))
            throw new ValidationException("Invalid or unsupported preferences.");
        _ = Identity.Profile(DefaultProfile);
        return this;
    }
}

public sealed class PreferenceStore(StoreLayout layout)
{
    public UserPreferences Read()
    {
        var path = layout.Resolve(new(StorageArea.Data, "preferences.json"));
        if (!File.Exists(path)) return ReadLegacy();
        using var document = StrictJson.Parse(SafeFiles.Read(path, 16384), 16384);
        try { return (document.RootElement.Deserialize<UserPreferences>(StrictJson.Options) ?? throw new ValidationException("Invalid preferences.")).Validate(); }
        catch (JsonException) { throw new ValidationException("Invalid or unsupported preferences. The stored file is unchanged."); }
    }

    private UserPreferences ReadLegacy()
    {
        if (layout.LegacyRoot is null) return new();
        var path = layout.Resolve(new(StorageArea.Legacy, "settings.json"));
        if (!File.Exists(path)) return new();
        using var document = StrictJson.Parse(SafeFiles.Read(path, 16384), 16384, 4, 32);
        var settings = document.RootElement;
        StrictJson.Fields(settings, ["Product", "SchemaVersion", "AutomaticUpdateChecks", "DebugLogging", "DefaultEdgeProfile", "DefaultDesktop", "DefaultStartMenu", "MotionEnabled", "TextSize"]);
        var points = StrictJson.Integer(settings, "TextSize");
        if (StrictJson.Text(settings, "Product") != "EasyEdgeApps.Settings" || StrictJson.Integer(settings, "SchemaVersion") != 1 || points is not (12 or 14 or 16 or 18))
            throw new ValidationException("Invalid or unsupported legacy preferences. The stored file is unchanged.");
        return new UserPreferences
        {
            CheckUpdates = StrictJson.Boolean(settings, "AutomaticUpdateChecks"),
            Diagnostics = StrictJson.Boolean(settings, "DebugLogging"),
            DefaultProfile = StrictJson.Text(settings, "DefaultEdgeProfile"),
            DefaultDesktop = StrictJson.Boolean(settings, "DefaultDesktop"),
            DefaultStartMenu = StrictJson.Boolean(settings, "DefaultStartMenu"),
            MotionEnabled = StrictJson.Boolean(settings, "MotionEnabled"),
            TextSize = points * 4.0 / 3.0
        }.Validate();
    }

    public void Save(UserPreferences preferences)
    {
        SafeFiles.AtomicWrite(layout.Resolve(new(StorageArea.Data, "preferences.json")), JsonSerializer.SerializeToUtf8Bytes(preferences.Validate(), StrictJson.Options));
    }

    public void Record(string operation, string outcome)
    {
        if (!Read().Diagnostics) return;
        if (operation is not ("Save" or "Remove" or "Repair" or "Import" or "Migration" or "Update" or "Recovery") || outcome is not ("Success" or "Conflict" or "Cancelled" or "Failed")) throw new ValidationException("Diagnostics accept category codes only.");
        var path = layout.Resolve(new(StorageArea.Data, "Logs/events.jsonl"));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (File.Exists(path) && new FileInfo(path).Length > 128 * 1024)
        {
            var previous = layout.Resolve(new(StorageArea.Data, "Logs/events.previous.jsonl"));
            File.Move(path, previous, true);
        }
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { Utc = DateTimeOffset.UtcNow.ToString("O"), Operation = operation, Outcome = outcome });
        stream.Write(bytes); stream.WriteByte(10);
    }

    public void ClearLogs()
    {
        foreach (var name in new[] { "Logs/events.jsonl", "Logs/events.previous.jsonl" })
        {
            var path = layout.Resolve(new(StorageArea.Data, name));
            if (File.Exists(path)) File.Delete(path);
        }
    }
}