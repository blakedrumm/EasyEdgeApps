using EasyEdgeApps.Core;

namespace EasyEdgeApps.Core.Tests;

public sealed class ContractTests
{
    [Fact]
    public void NewAppDefaultsAreOwnedAndRemembered()
    {
        var app = new AppDefinition { DisplayName = "News", Url = "https://example.com/" }.Normalize();
        Assert.True(app.Window.DedicatedProfile);
        Assert.False(app.Window.FreshSession || app.Window.Taskbar || app.Window.AlwaysOnTop);
        Assert.Equal(LaunchMode.RememberLast, app.Window.LaunchMode);
    }

    [Theory]
    [InlineData(LaunchMode.FullScreen, false)]
    [InlineData(LaunchMode.RememberLast, true)]
    public void ClearingFreshConflictsBeforeBatchApply(LaunchMode mode, bool topmost)
    {
        var first = new AppDefinition { DisplayName = "Alpha", Url = "https://example.com/before" };
        var second = new AppDefinition { DisplayName = "Bravo", Url = "https://example.org/", Window = new() { FreshSession = true, DedicatedProfile = false, LaunchMode = mode, AlwaysOnTop = topmost } };
        var kit = new AppKit(2, "Regression", [new("Alpha", "https://example.com/after"), new("Bravo", second.Url)]);
        var rows = KitPlanner.Preview(kit, [first, second]);
        Assert.Equal("Update", rows[0].Action);
        Assert.Equal("Conflict", rows[1].Action);
        Assert.Contains("dedicated or Fresh", rows[1].Detail);
        Assert.Throws<ValidationException>(() => KitPlanner.Apply(kit.Apps[1], 2, second));
        var legacyRows = KitPlanner.Preview(kit with { SchemaVersion = 1 }, [first, second]);
        Assert.Equal(second.Window, legacyRows[1].Effective!.Window);
        Assert.Equal(second.Id, legacyRows[1].Effective!.Id);
    }

    [Fact]
    public void WindowCombinationMatrixRejectsOnlyIncompatibleStates()
    {
        foreach (var fresh in new[] { false, true })
        foreach (var dedicated in new[] { false, true })
        foreach (var taskbar in new[] { false, true })
        foreach (var start in new[] { false, true })
        foreach (var mode in Enum.GetValues<LaunchMode>())
        foreach (var topmost in new[] { false, true })
        {
            var settings = new WindowSettings { FreshSession = fresh, DedicatedProfile = dedicated, Taskbar = taskbar, LaunchMode = mode, AlwaysOnTop = topmost };
            var invalid = (taskbar && (!dedicated || !start)) || (topmost && mode == LaunchMode.FullScreen) || (!fresh && !dedicated && (topmost || mode == LaunchMode.FullScreen));
            var error = Record.Exception(() => settings.Validate(start));
            Assert.Equal(invalid, error is ValidationException);
        }
    }

    [Fact]
    public void LegacyNamesNormalizeButPermanentIdentityDoesNotChange()
    {
        Assert.Equal(Identity.LegacyId("My News"), Identity.LegacyId(" my news "));
        Assert.Equal(Identity.LegacyId("Caf\u00e9"), Identity.LegacyId("Cafe\u0301"));
        var original = new AppDefinition { DisplayName = "First", Url = "https://example.com/" };
        var renamed = (original with { DisplayName = "Second", Aliases = ["First"] }).Normalize();
        var plan = KitPlanner.Preview(new(1, "Old kit", [new("First", "https://example.org/")]), [renamed]);
        Assert.Equal(original.Id, plan[0].Effective!.Id);
        Assert.Equal("Second", plan[0].Effective!.DisplayName);
        Assert.Equal("Conflict", KitPlanner.Preview(new(1, "Aliases", [new("First", original.Url), new("Second", original.Url)]), [renamed])[1].Action);
    }

    [Theory]
    [InlineData("file:///C:/Windows")]
    [InlineData("https://user:secret@example.com/")]
    [InlineData("https://example.com/\" --injected")]
    [InlineData("https://example.com/\\bad")]
    public void UnsafeWebsiteIsRejected(string website) => Assert.Throws<ValidationException>(() => Identity.Website(website));
}