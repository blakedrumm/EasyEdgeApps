using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace EasyEdgeApps.Core;

public static class StrictJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true, PropertyNameCaseInsensitive = false, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter(allowIntegerValues: false) }
    };

    public static JsonDocument Parse(ReadOnlyMemory<byte> data, int maximumBytes = 16 * 1024 * 1024, int maximumDepth = 16, int maximumValues = 4096)
    {
        if (data.Length is < 2 || data.Length > maximumBytes) throw new ValidationException("JSON input is empty or exceeds its size bound.");
        if (data.Span.StartsWith(new byte[] { 0xef, 0xbb, 0xbf })) data = data[3..];
        try
        {
            _ = new UTF8Encoding(false, true).GetCharCount(data.Span);
            var reader = new Utf8JsonReader(data.Span, new JsonReaderOptions { MaxDepth = maximumDepth });
            var fields = new Stack<HashSet<string>>();
            var values = 0;
            while (reader.Read())
            {
                if (reader.TokenType is not (JsonTokenType.PropertyName or JsonTokenType.EndArray or JsonTokenType.EndObject) && ++values > maximumValues)
                    throw new ValidationException("JSON contains too many values.");
                if (reader.TokenType == JsonTokenType.StartObject) fields.Push(new(StringComparer.OrdinalIgnoreCase));
                else if (reader.TokenType == JsonTokenType.EndObject) fields.Pop();
                else if (reader.TokenType == JsonTokenType.PropertyName)
                {
                    var name = reader.GetString()!;
                    if (name is "$type" or "__type" || !fields.Peek().Add(name)) throw new ValidationException("Duplicate or type-metadata JSON fields are not supported.");
                }
                else if (reader.TokenType == JsonTokenType.String) _ = reader.GetString();
            }
            return JsonDocument.Parse(data, new JsonDocumentOptions { MaxDepth = maximumDepth });
        }
        catch (Exception failure) when (failure is JsonException or DecoderFallbackException or InvalidOperationException)
        { throw new ValidationException("Input is not bounded, well-formed UTF-8 JSON."); }
    }

    public static void Fields(JsonElement value, string[] required, params string[] optional)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new ValidationException("Expected a JSON object.");
        foreach (var name in required) if (!value.TryGetProperty(name, out _)) throw new ValidationException("A required field is missing: " + name);
        foreach (var property in value.EnumerateObject())
            if (!required.Contains(property.Name, StringComparer.Ordinal) && !optional.Contains(property.Name, StringComparer.Ordinal))
                throw new ValidationException("Unsupported field: " + property.Name);
    }

    public static string Text(JsonElement value, string field, string? fallback = null)
    {
        if (!value.TryGetProperty(field, out var item)) return fallback ?? throw new ValidationException("Missing text field: " + field);
        return item.ValueKind == JsonValueKind.String ? item.GetString()! : throw new ValidationException("Invalid text field: " + field);
    }

    public static int Integer(JsonElement value, string field)
    {
        if (!value.TryGetProperty(field, out var item) || item.ValueKind != JsonValueKind.Number || !item.TryGetInt32(out var result))
            throw new ValidationException("Invalid integer field: " + field);
        return result;
    }

    public static bool Boolean(JsonElement value, string field, bool? fallback = null)
    {
        if (!value.TryGetProperty(field, out var item)) return fallback ?? throw new ValidationException("Missing Boolean field: " + field);
        return item.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => throw new ValidationException("Invalid Boolean field: " + field) };
    }

    public static byte[] Base64(string value, int maximum, int? exact = null)
    {
        if (value.Length == 0 || value.Length > 4L * ((maximum + 2L) / 3)) throw new ValidationException("Encoded data exceeds its bound.");
        byte[] data;
        try { data = Convert.FromBase64String(value); }
        catch (FormatException) { throw new ValidationException("Invalid encoded data."); }
        if (data.Length > maximum || (exact.HasValue && data.Length != exact) || Convert.ToBase64String(data) != value)
            throw new ValidationException("Noncanonical or invalid encoded data length.");
        return data;
    }
}

public sealed record LegacyManifest(int SchemaVersion, AppDefinition App, string EdgePath, string IconHash, string? LauncherHash, string? LauncherSourceHash, byte[] OriginalBytes);

public static class ManifestCodec
{
    public static LegacyManifest ReadLegacy(byte[] bytes, string expectedId)
    {
        using var document = StrictJson.Parse(bytes, 32768);
        var root = document.RootElement;
        var schema = StrictJson.Integer(root, "SchemaVersion");
        var name = StrictJson.Text(root, "Name");
        var url = StrictJson.Text(root, "Url");
        var id = StrictJson.Text(root, "Id");
        if (StrictJson.Text(root, "Product") != "EasyEdgeApps" || schema is < 1 or > 4 || id != expectedId || id != Identity.LegacyId(name) || name != Identity.Name(name) || url != Identity.Website(url))
            throw new ValidationException("Legacy settings do not match their version, name or directory identity.");
        var fresh = StrictJson.Boolean(root, "FreshSession", schema < 3 ? false : null);
        var taskbar = StrictJson.Boolean(root, "Taskbar", schema < 3 ? false : null);
        if ((schema < 3 && (fresh != (schema == 2) || taskbar)) || (schema == 3 && !fresh && !taskbar))
            throw new ValidationException("Invalid legacy session schema.");
        var mode = schema == 4 ? StrictJson.Text(root, "LaunchMode") : "Maximized";
        if (!Enum.TryParse<LaunchMode>(mode, false, out var launchMode) || !Enum.IsDefined(launchMode) || launchMode.ToString() != mode)
            throw new ValidationException("Invalid window mode.");
        var window = new WindowSettings
        {
            FreshSession = fresh, Taskbar = taskbar, DedicatedProfile = schema == 4 ? StrictJson.Boolean(root, "DedicatedProfile") : taskbar,
            LaunchMode = launchMode, AlwaysOnTop = schema == 4 && StrictJson.Boolean(root, "AlwaysOnTop")
        };
        var edge = StrictJson.Text(root, "EdgePath");
        if (!Path.IsPathFullyQualified(edge) || !string.Equals(Path.GetFileName(edge), "msedge.exe", StringComparison.OrdinalIgnoreCase) || edge.IndexOfAny(['"', '\r', '\n']) >= 0)
            throw new ValidationException("Invalid saved Edge executable.");
        var iconHash = StrictJson.Text(root, "IconHash");
        var launcherHash = window.Owned ? StrictJson.Text(root, "LauncherHash") : null;
        var sourceHash = window.Owned ? StrictJson.Text(root, "LauncherSourceHash") : null;
        if (!Identity.IsId(iconHash) || (window.Owned && (!Identity.IsId(launcherHash!) || !Identity.IsId(sourceHash!)))) throw new ValidationException("Invalid saved file identity.");
        var app = new AppDefinition
        {
            Id = id, DisplayName = name, Aliases = [name], Url = url, Notes = StrictJson.Text(root, "Notes", ""),
            EdgeProfile = StrictJson.Text(root, "EdgeProfile", ""), Desktop = StrictJson.Boolean(root, "Desktop"), StartMenu = StrictJson.Boolean(root, "StartMenu"),
            Window = window, IconKind = StrictJson.Text(root, "IconKind", "Custom")
        }.Normalize();
        return new(schema, app, edge, iconHash, launcherHash, sourceHash, bytes.ToArray());
    }
}

public static class KitCodec
{
    public static AppKit Read(byte[] bytes)
    {
        using var document = StrictJson.Parse(bytes);
        var root = document.RootElement;
        StrictJson.Fields(root, ["Product", "SchemaVersion", "Name", "Apps"], "Notes");
        var schema = StrictJson.Integer(root, "SchemaVersion");
        if (StrictJson.Text(root, "Product") != "EasyEdgeApps.AppKit" || schema is not (1 or 2) || root.GetProperty("Apps").ValueKind != JsonValueKind.Array)
            throw new ValidationException("Unsupported App Kit.");
        var apps = new List<KitApp>();
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in root.GetProperty("Apps").EnumerateArray())
        {
            StrictJson.Fields(item, ["Name", "Url", "Desktop", "StartMenu", "Icon"], schema == 1 ? ["Notes"] : ["Notes", "FreshSession"]);
            var name = Identity.Name(StrictJson.Text(item, "Name"));
            if (!names.Add(Identity.NameKey(name))) throw new ValidationException("Duplicate normalized app name.");
            var icon = item.GetProperty("Icon");
            var kind = StrictJson.Text(icon, "Kind");
            PortableIcon portable;
            if (kind == "Generated")
            {
                StrictJson.Fields(icon, ["Kind", "Version"]);
                if (StrictJson.Integer(icon, "Version") != 1) throw new ValidationException("Unsupported automatic icon version.");
                portable = new();
            }
            else if (kind == "Embedded")
            {
                StrictJson.Fields(icon, ["Kind", "Data", "Sha256"]);
                var data = StrictJson.Text(icon, "Data");
                var hash = StrictJson.Text(icon, "Sha256");
                var image = StrictJson.Base64(data, 1024 * 1024);
                if (!Identity.IsId(hash) || Identity.Hash(image) != hash) throw new ValidationException("Embedded icon checksum mismatch.");
                IconContract.Validate(image);
                portable = new(kind, 1, data, hash);
            }
            else throw new ValidationException("Unsupported portable icon kind.");
            var app = new KitApp(name, Identity.Website(StrictJson.Text(item, "Url")), StrictJson.Boolean(item, "Desktop"), StrictJson.Boolean(item, "StartMenu"),
                Identity.Notes(StrictJson.Text(item, "Notes", "")), portable, schema == 2 && StrictJson.Boolean(item, "FreshSession", false));
            if (!app.Desktop && !app.StartMenu) throw new ValidationException("Choose a shortcut placement.");
            apps.Add(app);
        }
        if (apps.Count is < 1 or > 100) throw new ValidationException("A kit must contain 1 to 100 websites.");
        return new(schema, Identity.Name(StrictJson.Text(root, "Name")), apps.ToArray(), Identity.Notes(StrictJson.Text(root, "Notes", "")));
    }

    public static byte[] Write(AppKit kit)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("Product", "EasyEdgeApps.AppKit"); writer.WriteNumber("SchemaVersion", kit.SchemaVersion);
            writer.WriteString("Name", kit.Name); writer.WriteString("Notes", kit.Notes); writer.WriteStartArray("Apps");
            foreach (var app in kit.Apps)
            {
                writer.WriteStartObject(); writer.WriteString("Name", app.Name); writer.WriteString("Url", app.Url);
                writer.WriteBoolean("Desktop", app.Desktop); writer.WriteBoolean("StartMenu", app.StartMenu); writer.WriteString("Notes", app.Notes);
                if (kit.SchemaVersion == 2) writer.WriteBoolean("FreshSession", app.FreshSession);
                var icon = app.Icon ?? new();
                writer.WriteStartObject("Icon"); writer.WriteString("Kind", icon.Kind);
                if (icon.Kind == "Generated") writer.WriteNumber("Version", icon.Version);
                else { writer.WriteString("Data", icon.Data); writer.WriteString("Sha256", icon.Sha256); }
                writer.WriteEndObject(); writer.WriteEndObject();
            }
            writer.WriteEndArray(); writer.WriteEndObject();
        }
        var bytes = stream.ToArray();
        _ = Read(bytes);
        return bytes;
    }
}

public static class IconContract
{
    public static void Validate(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is < 22 or > 1048576 || BinaryPrimitives.ReadUInt16LittleEndian(bytes) != 0 || BinaryPrimitives.ReadUInt16LittleEndian(bytes[2..]) != 1)
            throw new ValidationException("Use a valid ICO no larger than 1 MiB.");
        var count = BinaryPrimitives.ReadUInt16LittleEndian(bytes[4..]);
        if (count is < 1 or > 32 || 6 + count * 16 > bytes.Length) throw new ValidationException("Invalid ICO directory.");
        for (var frame = 0; frame < count; frame++)
        {
            var entry = bytes.Slice(6 + frame * 16, 16);
            var width = entry[0] == 0 ? 256 : entry[0];
            var height = entry[1] == 0 ? 256 : entry[1];
            var size = BinaryPrimitives.ReadUInt32LittleEndian(entry[8..]);
            var offset = BinaryPrimitives.ReadUInt32LittleEndian(entry[12..]);
            if (offset < 6 + count * 16 || size < 24 || (ulong)offset + size > (ulong)bytes.Length) throw new ValidationException("Invalid ICO frame bounds.");
            var image = bytes.Slice((int)offset, (int)size);
            if (image.StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }))
            {
                if (size < 33 || !image.Slice(12, 4).SequenceEqual("IHDR"u8) || BinaryPrimitives.ReadUInt32BigEndian(image[8..]) != 13 ||
                    BinaryPrimitives.ReadUInt32BigEndian(image[16..]) != width || BinaryPrimitives.ReadUInt32BigEndian(image[20..]) != height)
                    throw new ValidationException("Invalid PNG icon dimensions.");
            }
            else if (size < 40 || BinaryPrimitives.ReadUInt32LittleEndian(image) < 40 || BinaryPrimitives.ReadInt32LittleEndian(image[4..]) != width || BinaryPrimitives.ReadInt32LittleEndian(image[8..]) != height * 2)
                throw new ValidationException("Invalid DIB icon dimensions.");
        }
    }
}