using EasyEdgeApps.Core;
using EasyEdgeApps.Core.Tests;
using EasyEdgeApps.Persistence;
using EasyEdgeApps.Windows;

namespace EasyEdgeApps.Windows.Tests;

public sealed class ProfileTests
{
    [Fact]
    public void DiscoveryReadsOnlyKnownProfilesAndLeavesBytesUnchanged()
    {
        using var fixture = new TestDirectory();
        var root = Path.Combine(fixture.Root, "EdgeFixtures");
        foreach (var name in new[] { "Default", "Profile 01", "System Profile", "Guest Profile" })
        {
            Directory.CreateDirectory(Path.Combine(root, name));
            File.WriteAllText(Path.Combine(root, name, "Bookmarks"), "synthetic bookmarks");
        }
        File.WriteAllText(Path.Combine(root, "Local State"), """{"profile":{"info_cache":{"Default":{"name":"Personal"},"../other":{"name":"Ignore"}}}}""");
        var hashes = Directory.GetFiles(root, "*", SearchOption.AllDirectories).ToDictionary(path => path, SafeFiles.Hash);
        var profiles = EdgeProfiles.Discover(root);
        Assert.Equal(new[] { "Default", "Profile 01" }, profiles.Select(profile => profile.DirectoryName));
        Assert.Equal("Personal (Default)", profiles[0].DisplayName);
        Assert.All(profiles, profile => Assert.True(profile.HasBookmarks));
        foreach (var file in hashes) Assert.Equal(file.Value, SafeFiles.Hash(file.Key));
    }

    [Fact]
    public async Task NewDraftUsesCurrentProfileDefaultWithoutChangingExistingWebsites()
    {
        var profile = "Profile 01";
        using var editor = new EditorSession(createNew: () => new AppDefinition { EdgeProfile = profile });
        Assert.False(editor.IsDirty);
        Assert.Null(editor.SelectedId);
        Assert.Equal(profile, editor.Draft.Definition.EdgeProfile);
        Assert.True(editor.Draft.Definition.Window.DedicatedProfile);
        profile = "Default";
        await editor.NavigateAsync(null, DraftChoice.Discard, (draft, _) => Task.FromResult(draft.Definition));
        Assert.Equal("Default", editor.Draft.Definition.EdgeProfile);
    }
}