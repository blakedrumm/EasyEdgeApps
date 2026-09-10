using System.Text.Json.Nodes;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Core.Tests;

public sealed class MigrationTests
{
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void RollbackRemovesOwnedShortcutsEnabledOnlyAfterMigration(bool desktop)
    {
        using var fixture = new TestDirectory();
        var original = Seed(fixture, 4, false, false);
        var id = Identity.LegacyId("News");
        var manifestPath = fixture.Layout.Resolve(new(StorageArea.Legacy, $"Apps/{id}/app.json"));
        var manifest = JsonNode.Parse(original[manifestPath])!;
        manifest[desktop ? "Desktop" : "StartMenu"] = false;
        original[manifestPath] = System.Text.Encoding.UTF8.GetBytes(manifest.ToJsonString());
        SafeFiles.AtomicWrite(manifestPath, original[manifestPath]);
        var shortcutPath = fixture.Layout.Resolve(new(desktop ? StorageArea.Desktop : StorageArea.Programs, "News.lnk"));
        File.Delete(shortcutPath);
        original.Remove(shortcutPath);
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts()) { AllowExperimentalMigration = true };
        var migrated = store.Migrate(store.PreviewMigration(id));
        Assert.False(File.Exists(shortcutPath));
        store.Save(migrated.Definition with { Desktop = true, StartMenu = true }, store.Read().Hash);
        Assert.True(File.Exists(shortcutPath));

        store.RollbackMigration(id, store.Read().Hash);

        Assert.False(File.Exists(shortcutPath));
        Assert.Empty(store.Read().Catalog.Apps);
        foreach (var file in original) Assert.Equal(file.Value, SafeFiles.Read(file.Key));
    }

    [Fact]
    public void LiveMigrationIsDeniedBeforeCreatingSuccessorState()
    {
        using var fixture = new TestDirectory();
        var before = Seed(fixture, 4, false, false);
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var id = Identity.LegacyId("News");
        var plan = store.PreviewMigration(id);
        Assert.Equal(CatalogStore.MigrationAcceptanceRequired, Assert.Throws<ValidationException>(() => store.Migrate(plan)).Message);
        Assert.Equal(CatalogStore.MigrationAcceptanceRequired, Assert.Throws<ValidationException>(() => store.RollbackMigration(id, SafeFiles.Missing)).Message);
        Assert.False(Directory.Exists(fixture.Layout.DataRoot));
        foreach (var file in before) Assert.Equal(file.Value, SafeFiles.Read(file.Key));
    }

    [Theory]
    [InlineData(1, false, false)]
    [InlineData(2, true, false)]
    [InlineData(3, false, true)]
    [InlineData(4, false, false)]
    public void ExplicitMigrationIsRepeatableAndRollbackRestoresOwnedBytes(int schema, bool fresh, bool taskbar)
    {
        using var fixture = new TestDirectory();
        var original = Seed(fixture, schema, fresh, taskbar);
        var id = Identity.LegacyId("News");
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts()) { AllowExperimentalMigration = true };
        var plan = store.PreviewMigration(id);
        Assert.Equal(SafeFiles.Missing, store.Read().Hash);
        var migrated = store.Migrate(plan);
        Assert.Equal(id, migrated.Definition.Id);
        Assert.Equal(StorageArea.Legacy, migrated.Storage);
        Assert.Equal(schema == 4 || taskbar, migrated.Definition.Window.DedicatedProfile);
        Assert.False(File.Exists(fixture.Layout.Resolve(new(StorageArea.Legacy, $"Apps/{id}/app.json"))));
        var hash = store.Read().Hash;
        Assert.Equal(id, store.Migrate(plan).Definition.Id);
        Assert.Equal(hash, store.Read().Hash);
        var renamed = store.Rename(id, "Renamed", hash);
        store.Save(renamed.Definition, store.Read().Hash, "replacement icon"u8.ToArray());
        store.RollbackMigration(id, store.Read().Hash);
        Assert.Empty(store.Read().Catalog.Apps);
        foreach (var file in original) Assert.Equal(file.Value, SafeFiles.Read(file.Key));
    }

    [Fact]
    public void SourceChangesInvalidateMigrationAndOutsideChangesBlockRollback()
    {
        using var fixture = new TestDirectory();
        Seed(fixture, 1, false, false);
        var id = Identity.LegacyId("News");
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts()) { AllowExperimentalMigration = true };
        var plan = store.PreviewMigration(id);
        var shortcut = fixture.Layout.Resolve(new(StorageArea.Desktop, "News.lnk"));
        SafeFiles.AtomicWrite(shortcut, "external"u8.ToArray());
        Assert.Throws<ValidationException>(() => store.Migrate(plan));
        Assert.Equal("external", File.ReadAllText(shortcut));
        store.Migrate(store.PreviewMigration(id));
        var manifest = fixture.Layout.Resolve(new(StorageArea.Legacy, $"Apps/{id}/app.json"));
        SafeFiles.AtomicWrite(manifest, "outside"u8.ToArray());
        Assert.Throws<ValidationException>(() => store.RollbackMigration(id, store.Read().Hash));
        Assert.Equal("outside", File.ReadAllText(manifest));
    }

    [Fact]
    public void FailureAfterOwnershipFenceRestoresLegacyManifestAndArtifacts()
    {
        using var fixture = new TestDirectory();
        var before = Seed(fixture, 4, false, false);
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts(), index => { if (index == 2) throw new IOException("Synthetic migration interruption"); }) { AllowExperimentalMigration = true };
        Assert.Throws<IOException>(() => store.Migrate(store.PreviewMigration(Identity.LegacyId("News"))));
        foreach (var file in before) Assert.Equal(file.Value, SafeFiles.Read(file.Key));
        Assert.Equal(SafeFiles.Missing, store.Read().Hash);
    }

    private static Dictionary<string, byte[]> Seed(TestDirectory fixture, int schema, bool fresh, bool taskbar)
    {
        var id = Identity.LegacyId("News");
        var value = JsonNode.Parse(JsonContractTests.Legacy(schema, fresh, taskbar))!;
        value["IconHash"] = Identity.Hash("icon"u8);
        value["LauncherHash"] = Identity.Hash("legacy launcher"u8);
        var files = new Dictionary<FileAddress, byte[]>
        {
            [new(StorageArea.Legacy, $"Apps/{id}/app.json")] = System.Text.Encoding.UTF8.GetBytes(value.ToJsonString()),
            [new(StorageArea.Legacy, $"Apps/{id}/icon.ico")] = "icon"u8.ToArray(),
            [new(StorageArea.Desktop, "News.lnk")] = "legacy desktop"u8.ToArray(),
            [new(StorageArea.Programs, "News.lnk")] = "legacy start"u8.ToArray(),
            [new(StorageArea.Legacy, $"Apps/{id}/AppProfile/Cookies")] = "synthetic browser data"u8.ToArray(),
            [new(StorageArea.Legacy, $"Apps/{id}/unrelated.txt")] = "unrelated data"u8.ToArray(),
            [new(StorageArea.Legacy, $"Apps/{id}/.eea-window")] = "synthetic placement"u8.ToArray()
        };
        if (schema > 1) files[new(StorageArea.Legacy, $"Apps/{id}/fresh-session.exe")] = "legacy launcher"u8.ToArray();
        foreach (var file in files) SafeFiles.AtomicWrite(fixture.Layout.Resolve(file.Key), file.Value);
        return files.ToDictionary(file => fixture.Layout.Resolve(file.Key), file => file.Value);
    }
}