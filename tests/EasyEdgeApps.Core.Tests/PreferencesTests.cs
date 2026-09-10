using System.Text.Json;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Core.Tests;

public sealed class PreferencesTests
{
    [Theory]
    [InlineData(12, false)]
    [InlineData(14, true)]
    [InlineData(16, false)]
    [InlineData(18, true)]
    public void LegacyPreferencesMapWithoutWritingEitherStore(int points, bool enabled)
    {
        using var fixture = new TestDirectory();
        var path = fixture.Layout.Resolve(new(StorageArea.Legacy, "settings.json"));
        var bytes = LegacySettings(points, enabled);
        SafeFiles.AtomicWrite(path, bytes);
        var store = new PreferenceStore(fixture.Layout);
        var mapped = store.Read();
        Assert.Equal(points * 4.0 / 3.0, (double)mapped.TextSize);
        Assert.Equal(enabled, mapped.CheckUpdates);
        Assert.Equal(enabled, mapped.Diagnostics);
        Assert.Equal("Profile 3", mapped.DefaultProfile);
        Assert.Equal("Original", mapped.Theme);
        Assert.False(mapped.DefaultDesktop);
        Assert.True(mapped.DefaultStartMenu);
        Assert.Equal(enabled, JsonSerializer.SerializeToElement(mapped).GetProperty("MotionEnabled").GetBoolean());
        Assert.False(File.Exists(fixture.Layout.Resolve(new(StorageArea.Data, "preferences.json"))));
        Assert.Equal(bytes, File.ReadAllBytes(path));
        store.Save(mapped);
        Assert.Equal(mapped, store.Read());
        Assert.Equal(bytes, File.ReadAllBytes(path));
    }

    [Theory]
    [InlineData("MotionEnabled", null)]
    [InlineData("MotionEnabled", "\"false\"")]
    [InlineData("Product", "\"Other.Settings\"")]
    [InlineData("SchemaVersion", "2")]
    [InlineData("TextSize", "13")]
    [InlineData("TextSize", "12.5")]
    [InlineData("DefaultEdgeProfile", "\"../Profile 1\"")]
    [InlineData("DefaultStartMenu", "false")]
    [InlineData("Unknown", "true")]
    public void InvalidLegacyPreferencesAreNotSilentlyResetOrWritten(string field, string? value)
    {
        using var fixture = new TestDirectory();
        var settings = System.Text.Json.Nodes.JsonNode.Parse(LegacySettings(12, false))!.AsObject();
        if (value is null) settings.Remove(field);
        else settings[field] = System.Text.Json.Nodes.JsonNode.Parse(value);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(settings);
        var path = fixture.Layout.Resolve(new(StorageArea.Legacy, "settings.json"));
        SafeFiles.AtomicWrite(path, bytes);
        Assert.Throws<ValidationException>(() => new PreferenceStore(fixture.Layout).Read());
        Assert.Equal(bytes, File.ReadAllBytes(path));
        Assert.False(File.Exists(fixture.Layout.Resolve(new(StorageArea.Data, "preferences.json"))));
    }

    [Fact]
    public void ExplicitCompiledPreferencesTakePrecedenceOverLegacySettings()
    {
        using var fixture = new TestDirectory();
        var store = new PreferenceStore(fixture.Layout);
        var expected = new UserPreferences { TextSize = 24, DefaultProfile = "Default", Theme = "Dark" };
        store.Save(expected);
        var path = fixture.Layout.Resolve(new(StorageArea.Legacy, "settings.json"));
        SafeFiles.AtomicWrite(path, "invalid legacy data"u8.ToArray());
        Assert.Equal(expected, store.Read());
        Assert.Equal("invalid legacy data", File.ReadAllText(path));
    }

    private static byte[] LegacySettings(int points, bool enabled) => JsonSerializer.SerializeToUtf8Bytes(new
    {
        Product = "EasyEdgeApps.Settings", SchemaVersion = 1,
        AutomaticUpdateChecks = enabled, DebugLogging = enabled,
        DefaultEdgeProfile = "Profile 3", DefaultDesktop = false, DefaultStartMenu = true,
        MotionEnabled = enabled, TextSize = points
    });

    [Fact]
    public void TextSizeAndNewWebsitePlacementsRoundTripWithoutChangingOptIns()
    {
        using var fixture = new TestDirectory();
        var bytes = "{\"Product\":\"EasyEdgeApps.Preferences\",\"SchemaVersion\":1,\"TextSize\":24,\"DefaultDesktop\":false,\"DefaultStartMenu\":true}"u8.ToArray();
        SafeFiles.AtomicWrite(fixture.Layout.Resolve(new(StorageArea.Data, "preferences.json")), bytes);
        var store = new PreferenceStore(fixture.Layout);
        var settings = store.Read();
        Assert.False(settings.CheckUpdates);
        Assert.False(settings.Diagnostics);
        store.Save(settings);
        using var document = JsonDocument.Parse(File.ReadAllBytes(fixture.Layout.Resolve(new(StorageArea.Data, "preferences.json"))));
        Assert.Equal(24, document.RootElement.GetProperty("TextSize").GetInt32());
        Assert.False(document.RootElement.GetProperty("DefaultDesktop").GetBoolean());
        Assert.True(document.RootElement.GetProperty("DefaultStartMenu").GetBoolean());
    }

    [Theory]
    [InlineData("{\"TextSize\":999}")]
    [InlineData("{\"DefaultDesktop\":false,\"DefaultStartMenu\":false}")]
    [InlineData("{\"DefaultProfile\":null}")]
    [InlineData("{\"LastUpdateCheckUtc\":null}")]
    public void InvalidPreferencesFailClosedWithoutOverwritingTheirBytes(string json)
    {
        using var fixture = new TestDirectory();
        var path = fixture.Layout.Resolve(new(StorageArea.Data, "preferences.json"));
        SafeFiles.AtomicWrite(path, System.Text.Encoding.UTF8.GetBytes(json));
        Assert.Throws<ValidationException>(() => new PreferenceStore(fixture.Layout).Read());
        Assert.Equal(json, File.ReadAllText(path));
    }
}