using System.Text;
using System.Text.Json;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Core.Tests;

public sealed class JsonContractTests
{
    [Theory]
    [InlineData("{\"name\":1,\"Name\":2}")]
    [InlineData("{\"a\":01}")]
    [InlineData("{\"a\":1.}")]
    [InlineData("{\"a\":1,}")]
    [InlineData("{\"$type\":\"System.Type\"}")]
    [InlineData("/*no*/{}")]
    public void MalformedJsonFailsClosed(string json) => Assert.Throws<ValidationException>(() => StrictJson.Parse(Encoding.UTF8.GetBytes(json)));

    [Fact]
    public void JsonLimitsAreEnforcedBeforeMaterializingData()
    {
        Assert.Throws<ValidationException>(() => StrictJson.Parse("[1,2,3]"u8.ToArray(), maximumValues: 3));
        Assert.Throws<ValidationException>(() => StrictJson.Parse("[[[0]]]"u8.ToArray(), maximumDepth: 2));
        Assert.Throws<ValidationException>(() => StrictJson.Parse(new byte[] { 123, 34, 97, 34, 58, 34, 255, 34, 125 }));
        using var valid = StrictJson.Parse("{\"date\":\"2026-09-09T00:00:00Z\",\"number\":1.2e3}"u8.ToArray());
        Assert.Equal(JsonValueKind.String, valid.RootElement.GetProperty("date").ValueKind);
    }

    [Theory]
    [InlineData(LaunchMode.FullScreen, false, false)]
    [InlineData(LaunchMode.FullScreen, false, true)]
    [InlineData(LaunchMode.RememberLast, true, false)]
    [InlineData(LaunchMode.RememberLast, true, true)]
    public void ExplicitAndOmittedFreshBothConflict(LaunchMode mode, bool topmost, bool omit)
    {
        var destination = new AppDefinition { DisplayName = "News", Url = "https://example.com/", Window = new() { FreshSession = true, DedicatedProfile = false, LaunchMode = mode, AlwaysOnTop = topmost } };
        var bytes = KitCodec.Write(new(2, "Test", [new("News", destination.Url)]));
        if (omit) bytes = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace(",\"FreshSession\":false", "", StringComparison.Ordinal));
        var kit = KitCodec.Read(bytes);
        Assert.Equal("Conflict", KitPlanner.Preview(kit, [destination])[0].Action);
        Assert.Equal(destination.Window, KitPlanner.Preview(kit with { SchemaVersion = 1 }, [destination])[0].Effective!.Window);
    }

    [Theory]
    [InlineData(1, false, false)]
    [InlineData(2, true, false)]
    [InlineData(3, false, true)]
    [InlineData(3, true, false)]
    [InlineData(4, false, false)]
    public void LegacyVersionsPreserveEffectiveBehavior(int schema, bool fresh, bool taskbar)
    {
        var bytes = Legacy(schema, fresh, taskbar);
        var manifest = ManifestCodec.ReadLegacy(bytes, Identity.LegacyId("News"));
        Assert.Equal(fresh, manifest.App.Window.FreshSession);
        Assert.Equal(schema == 4 || taskbar, manifest.App.Window.DedicatedProfile);
        Assert.Equal(schema == 4 ? LaunchMode.RememberLast : LaunchMode.Maximized, manifest.App.Window.LaunchMode);
        Assert.False(manifest.App.Window.AlwaysOnTop);
        Assert.Equal(bytes, manifest.OriginalBytes);
        Assert.Equal("2026-09-09T00:00:00Z", manifest.App.Notes);
    }

    [Fact]
    public void KitsExcludeLocalSettingsAndRejectUnknownFields()
    {
        var bytes = KitCodec.Write(new(1, "Kit", [new("News", "http://example.com:8080/path?q=1#home")]));
        var json = Encoding.UTF8.GetString(bytes);
        Assert.DoesNotContain("DedicatedProfile", json);
        Assert.DoesNotContain("FreshSession", json);
        Assert.Throws<ValidationException>(() => KitCodec.Read(Encoding.UTF8.GetBytes(json.Replace("\"Desktop\":true", "\"DedicatedProfile\":true,\"Desktop\":true", StringComparison.Ordinal))));
        Assert.Equal("http://example.com:8080/path?q=1#home", KitCodec.Read(bytes).Apps[0].Url);
    }

    [Fact]
    public void HistoricalNameAndProfileBoundsMatchPowerShell()
    {
        Assert.Equal("Profile 000000", Identity.Profile("Profile 000000"));
        Assert.Throws<ValidationException>(() => Identity.Profile("Profile 1234567"));
        Assert.Throws<ValidationException>(() => Identity.Name(new string('a', 61)));
    }

    public static byte[] Legacy(int schema, bool fresh, bool taskbar)
    {
        var values = new Dictionary<string, object>
        {
            ["Product"] = "EasyEdgeApps", ["SchemaVersion"] = schema, ["Id"] = Identity.LegacyId("News"), ["Name"] = "News", ["Url"] = "https://example.com/",
            ["Desktop"] = true, ["StartMenu"] = true, ["EdgePath"] = @"C:\Program Files\Microsoft\Edge\Application\msedge.exe", ["IconHash"] = new string('a', 64),
            ["Notes"] = "2026-09-09T00:00:00Z", ["FreshSession"] = fresh, ["Taskbar"] = taskbar, ["LauncherHash"] = new string('b', 64), ["LauncherSourceHash"] = new string('c', 64)
        };
        if (schema == 4) { values["DedicatedProfile"] = true; values["LaunchMode"] = "RememberLast"; values["AlwaysOnTop"] = false; }
        return JsonSerializer.SerializeToUtf8Bytes(values);
    }
}