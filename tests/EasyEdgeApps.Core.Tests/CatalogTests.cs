using System.Text;
using System.Text.Json.Nodes;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Core.Tests;

public sealed class SyntheticArtifacts : IAppArtifacts
{
    public IDisposable AcquireWriterLease() => new MemoryStream();
    public AppArtifacts Build(AppRecord record, StoreLayout layout, byte[]? iconBytes, bool regenerateIcon)
    {
        var bytes = Encoding.UTF8.GetBytes(record.Definition.Url + record.Definition.DisplayName);
        var files = new Dictionary<string, byte[]> { ["Icon"] = iconBytes ?? "icon"u8.ToArray(), ["Launcher"] = "prebuilt"u8.ToArray(), ["Configuration"] = bytes };
        if (record.Definition.Desktop) files["Desktop"] = Encoding.UTF8.GetBytes(record.Definition.Id);
        if (record.Definition.StartMenu) files["StartMenu"] = Encoding.UTF8.GetBytes(record.Definition.Id);
        return new("synthetic-edge", "test", files);
    }
    public void ValidateLegacy(LegacyManifest manifest, StoreLayout layout) { }
}

public sealed class CatalogTests
{
    [Fact]
    public void CatalogCapacityRejectsNewIdentityBeforeChangingOwnedFiles()
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var retained = Enumerable.Range(0, 5000).Select(index => new AppRecord
        {
            Definition = new AppDefinition { DisplayName = "Retired " + index, Url = "https://example.com/" }.Normalize(),
            ShortcutName = "Retired " + index,
            Removed = true,
            Revision = 1
        }).ToArray();
        var catalogPath = Path.Combine(fixture.Layout.DataRoot, "catalog.json");
        SafeFiles.AtomicWrite(catalogPath, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new Catalog { Apps = retained }, StrictJson.Options));
        var before = store.Read();
        Assert.Equal(5000, before.Catalog.Apps.Length);
        var definition = new AppDefinition { DisplayName = "One too many", Url = "https://new.example.com/" };

        Assert.Throws<ValidationException>(() => store.Save(definition, before.Hash));

        Assert.Equal(before.Hash, store.Read().Hash);
        Assert.False(Directory.Exists(Path.Combine(fixture.Layout.DataRoot, "Apps", definition.Id)));
        Assert.False(File.Exists(fixture.Layout.Resolve(new(StorageArea.Desktop, definition.DisplayName + ".lnk"))));
        Assert.False(File.Exists(fixture.Layout.Resolve(new(StorageArea.Programs, definition.DisplayName + ".lnk"))));
    }

    [Theory]
    [InlineData(false, false, "Repairable", true)]
    [InlineData(true, false, "Conflict", false)]
    [InlineData(false, true, "Conflict", false)]
    public void ReadOnlyCheckDistinguishesMissingAndChangedOwnedFiles(bool customIcon, bool changed, string status, bool canRepair)
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var saved = store.Save(new() { DisplayName = "Inspection", Url = "https://example.com/", IconKind = customIcon ? "Custom" : "Generated" }, SafeFiles.Missing);
        var healthy = store.Check(saved);
        Assert.Equal("Healthy", healthy.Status);
        Assert.Empty(healthy.Issues);
        var icon = fixture.Layout.Resolve(CatalogStore.Address(saved, "Icon"));
        if (changed) File.WriteAllText(icon, "outside change");
        else File.Delete(icon);
        var before = store.Read().Hash;
        var check = store.Check(saved);
        Assert.Equal(saved.Definition.Id, check.Id);
        Assert.Equal(status, check.Status);
        Assert.Equal(canRepair, check.CanRepair);
        Assert.NotEmpty(check.Issues);
        Assert.Equal(before, store.Read().Hash);
        if (changed) Assert.Equal("outside change", File.ReadAllText(icon));
        else Assert.False(File.Exists(icon));
    }

    [Theory]
    [InlineData("Product", false)]
    [InlineData("StoreId", false)]
    [InlineData("Apps", false)]
    [InlineData("Apps", true)]
    [InlineData("Apps/0", true)]
    [InlineData("Apps/0/Definition", true)]
    [InlineData("Apps/0/Definition/Id", false)]
    [InlineData("Apps/0/Definition/Id", true)]
    [InlineData("Apps/0/Definition/Window", true)]
    [InlineData("Apps/0/Definition/Window/DedicatedProfile", false)]
    [InlineData("Apps/0/Definition/Aliases", true)]
    [InlineData("Apps/0/Files", true)]
    [InlineData("Apps/0/Files/Launcher", false)]
    public void MalformedDurableCatalogCannotInventIdentityOrOwnership(string field, bool setNull)
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var saved = store.Save(new() { DisplayName = "Retained identity", Url = "https://example.com/" }, SafeFiles.Missing);
        var path = Path.Combine(fixture.Layout.DataRoot, "catalog.json");
        var document = JsonNode.Parse(File.ReadAllBytes(path))!;
        var segments = field.Split('/');
        var parent = document;
        foreach (var segment in segments[..^1]) parent = parent is JsonArray array ? array[int.Parse(segment)]! : parent[segment]!;
        if (parent is JsonArray records) records[int.Parse(segments[^1])] = null;
        else if (setNull) parent[segments[^1]] = null;
        else parent.AsObject().Remove(segments[^1]);
        var bytes = Encoding.UTF8.GetBytes(document.ToJsonString());
        SafeFiles.AtomicWrite(path, bytes);
        Assert.Throws<ValidationException>(() => store.Read());
        Assert.Equal(bytes, File.ReadAllBytes(path));
        store.CheckOwned(saved);
    }

    [Fact]
    public void RenamePreservesIdentityPathsAliasesAndCaseOnlyNames()
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var original = store.Save(new() { DisplayName = "First", Url = "https://example.com/" }, SafeFiles.Missing);
        var renamed = store.Rename(original.Definition.Id, "Second", store.Read().Hash);
        var caseOnly = store.Rename(original.Definition.Id, "second", store.Read().Hash);
        Assert.Equal(original.Definition.Id, caseOnly.Definition.Id);
        Assert.Equal(CatalogStore.Address(original, "Launcher"), CatalogStore.Address(caseOnly, "Launcher"));
        Assert.Equal(CatalogStore.Address(original, "StartMenu"), CatalogStore.Address(caseOnly, "StartMenu"));
        Assert.Contains("First", caseOnly.Definition.Aliases);
        Assert.Contains("Second", caseOnly.Definition.Aliases);
        var result = store.Import(store.Preview(new(1, "Old kit", [new("First", "https://example.org/")])));
        Assert.True(result.Completed);
        Assert.Equal("second", store.Read().Catalog.Apps.Single().Definition.DisplayName);
        Assert.Throws<ValidationException>(() => store.Save(new() { DisplayName = "FIRST", Url = "https://example.net/" }, store.Read().Hash));
    }

    [Theory]
    [InlineData(LaunchMode.FullScreen, false)]
    [InlineData(LaunchMode.RememberLast, true)]
    public void PredictableLateConflictLeavesWholeBatchUnchanged(LaunchMode mode, bool topmost)
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        store.Save(new() { DisplayName = "Alpha", Url = "https://example.com/" }, SafeFiles.Missing);
        store.Save(new() { DisplayName = "Bravo", Url = "https://example.org/", Window = new() { FreshSession = true, DedicatedProfile = false, LaunchMode = mode, AlwaysOnTop = topmost } }, store.Read().Hash);
        var before = store.Read();
        var plan = store.Preview(new(2, "Test", [new("Alpha", "https://example.com/changed"), new("Bravo", "https://example.org/")]));
        var result = store.Import(plan);
        Assert.False(result.Completed);
        Assert.Equal(new[] { "Not attempted", "Conflict" }, result.Results.Select(row => row.Status));
        Assert.Equal(before.Hash, store.Read().Hash);
        foreach (var app in before.Catalog.Apps) store.CheckOwned(app);
    }

    [Fact]
    public void NewKitAppsUseTheDestinationProfileAndApprovalBindsThatDefault()
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var preferences = new PreferenceStore(fixture.Layout);
        store.Save(new() { DisplayName = "Existing", Url = "https://example.com/", EdgeProfile = "Profile 1" }, SafeFiles.Missing);
        preferences.Save(new() { DefaultProfile = "Profile 3", DefaultDesktop = false });
        var kit = new AppKit(1, "Default profile kit", [new("Existing", "https://example.com/updated"), new("New", "https://example.org/")]);
        var before = store.Read().Hash;
        var preview = store.Preview(kit);
        Assert.Equal("Profile 1", preview.Rows[0].Effective!.EdgeProfile);
        Assert.Equal("Profile 3", preview.Rows[1].Effective!.EdgeProfile);
        Assert.True(preview.Rows[1].Effective!.Desktop);
        Assert.Equal(before, store.Read().Hash);
        preferences.Save(new() { DefaultProfile = "Profile 4" });
        Assert.Throws<ValidationException>(() => store.Import(preview));
        Assert.Equal(before, store.Read().Hash);
        Assert.True(store.Import(store.Preview(kit)).Completed);
        Assert.Equal("Profile 4", store.Read().Catalog.Apps.Single(app => app.Definition.DisplayName == "New").Definition.EdgeProfile);
        Assert.Equal("Profile 1", store.Read().Catalog.Apps.Single(app => app.Definition.DisplayName == "Existing").Definition.EdgeProfile);
    }

    [Theory]
    [InlineData(StorageArea.Desktop)]
    [InlineData(StorageArea.Programs)]
    public void UnownedShortcutConflictsAreDetectedBeforeAnySelectedImportWrites(StorageArea area)
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        store.Save(new() { DisplayName = "Alpha", Url = "https://alpha.example.com/" }, SafeFiles.Missing);
        var occupied = fixture.Layout.Resolve(new(area, "Bravo.lnk"));
        SafeFiles.AtomicWrite(occupied, "unrelated shortcut"u8.ToArray());
        var before = store.Read();
        var plan = store.Preview(new(1, "Selected kit", [new("Alpha", "https://alpha.example.com/updated"), new("Bravo", "https://bravo.example.com/")]));
        Assert.Equal(new[] { "Update", "Conflict" }, plan.Rows.Select(row => row.Action));
        var result = store.Import(plan);
        Assert.False(result.Completed);
        Assert.Equal(new[] { "Not attempted", "Conflict" }, result.Results.Select(row => row.Status));
        Assert.Equal(before.Hash, store.Read().Hash);
        Assert.Equal("unrelated shortcut", File.ReadAllText(occupied));
        foreach (var record in before.Catalog.Apps) store.CheckOwned(record);
        File.Delete(occupied);
        var approved = store.Preview(plan.Kit);
        Assert.Equal("Add", approved.Rows[1].Action);
        File.WriteAllText(occupied, "arrived after preview");
        Assert.False(store.Import(approved).Completed);
        Assert.Equal(before.Hash, store.Read().Hash);
        Assert.Equal("arrived after preview", File.ReadAllText(occupied));
    }

    [Fact]
    public void FavoritesSkipOccupiedAndRetiredNamesWithoutAdoptingData()
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var removed = store.Save(new() { DisplayName = "News", Url = "https://example.com/" }, SafeFiles.Missing);
        store.Remove(removed.Definition.Id, store.Read().Hash);
        var desktop = fixture.Layout.Resolve(new(StorageArea.Desktop, "News (2).lnk"));
        var startMenu = fixture.Layout.Resolve(new(StorageArea.Programs, "News (3).lnk"));
        var retained = fixture.Layout.Resolve(new(StorageArea.Legacy, $"Apps/{Identity.LegacyId("News (4)")}/AppProfile/Cookies"));
        var emptyLegacy = fixture.Layout.Resolve(new(StorageArea.Legacy, $"Apps/{Identity.LegacyId("News (5)")}"));
        SafeFiles.AtomicWrite(desktop, "unrelated desktop"u8.ToArray());
        SafeFiles.AtomicWrite(startMenu, "unrelated Start entry"u8.ToArray());
        SafeFiles.AtomicWrite(retained, "synthetic retained data"u8.ToArray());
        Directory.CreateDirectory(emptyLegacy);
        var before = store.Read().Hash;
        var favorite = Assert.Single(store.ReadFavorites("""
            {"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"url","name":"News","url":"https://example.com/"}]}}}
            """u8.ToArray()));
        Assert.True(favorite.CanImport);
        Assert.Equal("News (6)", favorite.Name);
        Assert.Equal("Available with a different shortcut name", favorite.Reason);
        Assert.Equal(before, store.Read().Hash);
        Assert.Equal("unrelated desktop", File.ReadAllText(desktop));
        Assert.Equal("unrelated Start entry", File.ReadAllText(startMenu));
        Assert.Equal("synthetic retained data", File.ReadAllText(retained));
        Assert.Empty(Directory.EnumerateFileSystemEntries(emptyLegacy));
        Assert.Equal("Add", Assert.Single(store.Preview(Favorites.ToKit([favorite])).Rows).Action);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void FavoritesNewOnlyApprovalRejectsConcurrentNamesAndUrls(bool sameName)
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var kit = Favorites.ToKit([new("News", "https://example.com/", "", true, "Available")]);
        var approved = store.Preview(kit, true);
        Assert.True(approved.NewOnly);
        Assert.Equal("Add", Assert.Single(approved.Rows).Action);
        Assert.NotEqual(store.Preview(kit).Fingerprint, approved.Fingerprint);
        Assert.Throws<ValidationException>(() => store.Import(approved with { NewOnly = false }));
        Assert.Equal(SafeFiles.Missing, store.Read().Hash);
        var competing = store.Save(new() { DisplayName = sameName ? "News" : "Other name", Url = sameName ? "https://other.example.com/" : "https://example.com/", Notes = "Concurrent saved draft" }, SafeFiles.Missing);
        var before = store.Read().Hash;
        Assert.Throws<ValidationException>(() => store.Import(approved));
        var refreshed = store.Preview(kit, true);
        Assert.Equal("Conflict", Assert.Single(refreshed.Rows).Action);
        Assert.False(store.Import(refreshed).Completed);
        Assert.Equal(before, store.Read().Hash);
        Assert.Equal(System.Text.Json.JsonSerializer.Serialize(competing.Definition, StrictJson.Options), System.Text.Json.JsonSerializer.Serialize(Assert.Single(store.Read().Catalog.Apps).Definition, StrictJson.Options));
        store.CheckOwned(competing);
    }

    [Fact]
    public void ApprovalBindsAllKitFieldsAndCatalogBytes()
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var plan = store.Preview(new(1, "Kit", [new("News", "https://example.com/")]));
        Assert.Throws<ValidationException>(() => store.Import(plan with { Kit = plan.Kit with { Notes = "changed" } }));
        store.Save(new() { DisplayName = "Other", Url = "https://example.net/" }, SafeFiles.Missing);
        Assert.Throws<ValidationException>(() => store.Import(plan));
    }

    [Fact]
    public void MissingCustomIconRequiresExplicitReplacementRatherThanSilentRegeneration()
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var saved = store.Save(new() { DisplayName = "Custom icon", Url = "https://example.com/", IconKind = "Custom" }, SafeFiles.Missing, "custom image"u8.ToArray());
        File.Delete(fixture.Layout.Resolve(CatalogStore.Address(saved, "Icon")));
        var before = store.Read().Hash;
        Assert.Contains("custom icon", Assert.Throws<ValidationException>(() => store.Repair(saved.Definition.Id, before)).Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(before, store.Read().Hash);
        Assert.False(File.Exists(fixture.Layout.Resolve(CatalogStore.Address(saved, "Icon"))));
        var replacement = store.Save(saved.Definition, before, "chosen replacement"u8.ToArray());
        Assert.Equal("Custom", replacement.Definition.IconKind);
        Assert.Equal("chosen replacement", File.ReadAllText(fixture.Layout.Resolve(CatalogStore.Address(saved, "Icon"))));
        store.CheckOwned(replacement);
    }

    [Theory]
    [InlineData("Desktop")]
    [InlineData("StartMenu")]
    [InlineData("Launcher")]
    [InlineData("Configuration")]
    [InlineData("Icon")]
    public void MatchingKitImportPreviewsAndRepairsMissingOwnedFiles(string slot)
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var kit = new AppKit(1, "Repair kit", [new("News", "https://example.com/")]);
        Assert.True(store.Import(store.Preview(kit)).Completed);
        var saved = Assert.Single(store.Read().Catalog.Apps);
        var path = fixture.Layout.Resolve(CatalogStore.Address(saved, slot));
        File.Delete(path);
        var plan = store.Preview(kit);
        Assert.Equal("Update", Assert.Single(plan.Rows).Action);
        Assert.False(File.Exists(path));
        var imported = store.Import(plan);
        Assert.True(imported.Completed);
        Assert.Equal("Updated", Assert.Single(imported.Results).Status);
        var repaired = Assert.Single(store.Read().Catalog.Apps);
        Assert.Equal(saved.Definition.Id, repaired.Definition.Id);
        Assert.Equal(saved.Definition.Window, repaired.Definition.Window);
        Assert.True(File.Exists(path));
        store.CheckOwned(repaired);
    }

    [Fact]
    public void UnchangedImportsDoNotRewriteCatalogOrFiles()
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var kit = new AppKit(1, "Kit", [new("News", "https://example.com/")]);
        Assert.True(store.Import(store.Preview(kit)).Completed);
        var before = store.Read().Hash;
        Assert.Equal("Unchanged", store.Import(store.Preview(kit)).Results[0].Status);
        Assert.Equal(before, store.Read().Hash);
    }

    [Fact]
    public void MissingManifestAndRemovalNeverAdoptOrEraseBrowserData()
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new SyntheticArtifacts());
        var retainedId = Identity.LegacyId("Retained");
        var retained = fixture.Layout.Resolve(new(StorageArea.Legacy, $"Apps/{retainedId}/AppProfile/Cookies"));
        SafeFiles.AtomicWrite(retained, "synthetic"u8.ToArray());
        Assert.Throws<ValidationException>(() => store.Save(new() { DisplayName = "Retained", Url = "https://example.com/" }, SafeFiles.Missing));
        Assert.Contains(store.LegacyApps(), item => item.Id == retainedId && item.Manifest is null);
        var saved = store.Save(new() { DisplayName = "New", Url = "https://example.com/" }, SafeFiles.Missing);
        var cookies = fixture.Layout.Resolve(new(StorageArea.Data, $"Apps/{saved.Definition.Id}/AppProfile/Cookies"));
        SafeFiles.AtomicWrite(cookies, "keep"u8.ToArray());
        store.Remove(saved.Definition.Id, store.Read().Hash);
        Assert.Equal("keep", File.ReadAllText(cookies));
        Assert.Equal("synthetic", File.ReadAllText(retained));
        Assert.Throws<ValidationException>(() => store.Save(saved.Definition, store.Read().Hash));
    }
}