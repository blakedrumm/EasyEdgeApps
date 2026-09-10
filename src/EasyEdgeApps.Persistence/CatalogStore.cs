using System.Text;
using System.Text.Json;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Persistence;

public sealed record AppRecord
{
    public AppDefinition Definition { get; init; } = new();
    public StorageArea Storage { get; init; } = StorageArea.Data;
    public string ShortcutName { get; init; } = "";
    public string EdgePath { get; init; } = "";
    public string LauncherVersion { get; init; } = "";
    public Dictionary<string, string> Files { get; init; } = new(StringComparer.Ordinal);
    public string? MigrationTransaction { get; init; }
    public bool Removed { get; init; }
    public long Revision { get; init; }
}

public sealed record Catalog
{
    public string Product { get; init; } = "EasyEdgeApps.Catalog";
    public int SchemaVersion { get; init; } = 1;
    public int ReaderProtocol { get; init; } = 1;
    public int WriterProtocol { get; init; } = 1;
    public string StoreId { get; init; } = Identity.NewId();
    public long Revision { get; init; }
    public AppRecord[] Apps { get; init; } = [];
}

public sealed record CatalogSnapshot(Catalog Catalog, string Hash);
public sealed record AppArtifacts(string EdgePath, string LauncherVersion, Dictionary<string, byte[]> Files);
public interface IAppArtifacts
{
    AppArtifacts Build(AppRecord record, StoreLayout layout, byte[]? iconBytes, bool regenerateIcon);
    void ValidateLegacy(LegacyManifest manifest, StoreLayout layout);
    IDisposable AcquireWriterLease();
}

public sealed record ImportPlan(AppKit Kit, string CatalogHash, KitPlanRow[] Rows, string Fingerprint)
{
    public bool NewOnly { get; init; }
}
public sealed record OperationRow(string Name, string Status, string Detail);
public sealed record AppCheck(string Id, string Name, string Status, bool CanRepair, string[] Issues)
{
    public string BrowsingMode { get; init; } = "Unknown";
}
public sealed record ImportResult(bool Completed, OperationRow[] Results);
public sealed record MigrationPlan(string Id, string CatalogHash, string ManifestHash, Dictionary<string, string> Files, string Fingerprint);
public sealed record LegacyInventory(string Id, string Status, LegacyManifest? Manifest);

public sealed class CatalogStore(StoreLayout layout, IAppArtifacts artifacts, Action<int>? transactionFault = null)
{
    public StoreLayout Layout => layout;
    public bool AllowExperimentalMigration { get; init; }
    public const string MigrationAcceptanceRequired = "Live legacy migration and rollback are disabled in this preview until cross-session writer exclusion and rollback pass disposable-Windows acceptance. Isolated synthetic fixtures remain supported.";
    private const int MaximumCatalogBytes = 16 * 1024 * 1024;
    private const int MaximumCatalogApps = 5000;
    private const int MaximumCatalogDepth = 32;
    private const int MaximumCatalogValues = 250000;
    private static readonly FileAddress CatalogAddress = new(StorageArea.Data, "catalog.json");
    private static readonly string[] Slots = ["Icon", "Launcher", "Configuration", "Desktop", "StartMenu"];

    public static FileAddress Address(AppRecord record, string slot) => slot switch
    {
        "Icon" => new(record.Storage, $"Apps/{record.Definition.Id}/icon.ico"),
        "Launcher" => new(record.Storage, $"Apps/{record.Definition.Id}/fresh-session.exe"),
        "Configuration" => new(record.Storage, $"Apps/{record.Definition.Id}/eea-launch.xml"),
        "Desktop" => new(StorageArea.Desktop, record.ShortcutName + ".lnk"),
        "StartMenu" => new(StorageArea.Programs, record.ShortcutName + ".lnk"),
        _ => throw new ValidationException("Unsupported owned file slot.")
    };

    public CatalogSnapshot Read()
    {
        var path = layout.Resolve(CatalogAddress);
        if (!File.Exists(path)) return new(new(), SafeFiles.Missing);
        var bytes = SafeFiles.Read(path, MaximumCatalogBytes);
        using var document = StrictJson.Parse(bytes, MaximumCatalogBytes, MaximumCatalogDepth, MaximumCatalogValues);
        StrictJson.Fields(document.RootElement, ["Product", "SchemaVersion", "ReaderProtocol", "WriterProtocol", "StoreId", "Revision", "Apps"]);
        var storedApps = document.RootElement.GetProperty("Apps");
        if (storedApps.ValueKind != JsonValueKind.Array || storedApps.GetArrayLength() > MaximumCatalogApps) throw new ValidationException("The catalog website collection is invalid.");
        foreach (var stored in storedApps.EnumerateArray())
        {
            RequireRecordFields(stored, ["Definition", "Storage", "ShortcutName", "EdgePath", "LauncherVersion", "Files", "Removed", "Revision"]);
            var definition = stored.GetProperty("Definition");
            RequireRecordFields(definition, ["Id", "DisplayName", "Aliases", "Url", "Notes", "EdgeProfile", "Desktop", "StartMenu", "Window", "IconKind"]);
            RequireRecordFields(definition.GetProperty("Window"), ["FreshSession", "DedicatedProfile", "Taskbar", "LaunchMode", "AlwaysOnTop"]);
            if (definition.GetProperty("Aliases").ValueKind != JsonValueKind.Array || definition.GetProperty("Aliases").EnumerateArray().Any(alias => alias.ValueKind != JsonValueKind.String) || stored.GetProperty("Files").ValueKind != JsonValueKind.Object)
                throw new ValidationException("Catalog aliases or owned file metadata are invalid.");
        }
        Catalog catalog;
        try { catalog = document.RootElement.Deserialize<Catalog>(StrictJson.Options) ?? throw new ValidationException("Invalid successor catalog."); }
        catch (JsonException) { throw new ValidationException("Catalog fields do not match the stored schema."); }
        if (catalog.Product != "EasyEdgeApps.Catalog" || catalog.SchemaVersion != 1 || catalog.ReaderProtocol != 1 || catalog.WriterProtocol != 1 || !Identity.IsId(catalog.StoreId) || catalog.Revision < 0)
            throw new ValidationException("This catalog requires another compatible manager version.");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var aliases = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var record in catalog.Apps)
        {
            var normalized = record.Definition.Normalize();
            if (!ids.Add(normalized.Id) || record.Storage is not (StorageArea.Data or StorageArea.Legacy) || Identity.Name(record.ShortcutName) != record.ShortcutName || record.Revision < 0 ||
                JsonSerializer.Serialize(normalized, StrictJson.Options) != JsonSerializer.Serialize(record.Definition, StrictJson.Options) || record.Files.Any(file => !Slots.Contains(file.Key) || !Identity.IsId(file.Value)))
                throw new ValidationException("Catalog website identity or ownership metadata is invalid.");
            if (record.MigrationTransaction is not null && !Guid.TryParseExact(record.MigrationTransaction, "N", out _)) throw new ValidationException("Invalid recorded migration transaction.");
            var requiredSlots = record.Removed ? [] : Slots.Where(slot => slot is not ("Desktop" or "StartMenu") || (slot == "Desktop" ? normalized.Desktop : normalized.StartMenu)).ToArray();
            if (!record.Files.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(requiredSlots)) throw new ValidationException("The catalog does not record complete website artifact ownership.");
            foreach (var name in normalized.Aliases.Append(normalized.DisplayName))
            {
                var key = Identity.NameKey(name);
                if (aliases.TryGetValue(key, out var owner) && owner != normalized.Id) throw new ValidationException("Catalog aliases have conflicting owners.");
                aliases[key] = normalized.Id;
            }
        }
        return new(catalog, Identity.Hash(bytes));
    }

    private static void RequireRecordFields(JsonElement value, string[] fields)
    {
        if (value.ValueKind != JsonValueKind.Object || fields.Any(field => !value.TryGetProperty(field, out var member) || member.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined))
            throw new ValidationException("A stored catalog record has missing or null required fields.");
    }

    public FavoriteCandidate[] ReadFavorites(byte[] bytes)
    {
        var catalog = Read().Catalog;
        var reserved = catalog.Apps.SelectMany(record => record.Definition.Aliases.Append(record.Definition.DisplayName).Append(record.ShortcutName)).Select(Identity.NameKey).ToHashSet(StringComparer.Ordinal);
        bool NameUnavailable(string name)
        {
            if (reserved.Contains(Identity.NameKey(name))) return true;
            if (Path.Exists(layout.Resolve(new(StorageArea.Desktop, name + ".lnk"))) || Path.Exists(layout.Resolve(new(StorageArea.Programs, name + ".lnk")))) return true;
            return layout.LegacyRoot is not null && Path.Exists(layout.Resolve(new(StorageArea.Legacy, $"Apps/{Identity.LegacyId(name)}")));
        }
        return Favorites.Read(bytes, catalog.Apps.Where(record => !record.Removed).Select(record => record.Definition).ToArray(), NameUnavailable);
    }

    public IReadOnlyList<LegacyInventory> LegacyApps()
    {
        if (layout.LegacyRoot is null) return [];
        var root = Path.Combine(layout.Root(StorageArea.Legacy), "Apps");
        SafeFiles.CheckPath(root);
        if (!Directory.Exists(root)) return [];
        var claimed = Read().Catalog.Apps.Where(app => app.Storage == StorageArea.Legacy).Select(app => app.Definition.Id).ToHashSet(StringComparer.Ordinal);
        var result = new List<LegacyInventory>();
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            var id = Path.GetFileName(directory);
            if (!Identity.IsId(id) || claimed.Contains(id)) continue;
            try
            {
                var manifestPath = layout.Resolve(new(StorageArea.Legacy, $"Apps/{id}/app.json"));
                if (!File.Exists(manifestPath)) { result.Add(new(id, "Retained data; ownership or removal intent unknown", null)); continue; }
                result.Add(new(id, "Legacy; explicit migration required", ManifestCodec.ReadLegacy(SafeFiles.Read(manifestPath, 32768), id)));
            }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or ValidationException or JsonException)
            { result.Add(new(id, "Conflict; saved ownership could not be verified", null)); }
        }
        return result;
    }

    public AppRecord Save(AppDefinition definition, string expectedCatalogHash, byte[]? iconBytes = null, bool regenerateIcon = false)
    {
        using var lease = Acquire();
        var snapshot = RequireSnapshot(expectedCatalogHash);
        return SaveLocked(snapshot, definition, iconBytes, regenerateIcon);
    }

    private AppRecord SaveLocked(CatalogSnapshot snapshot, AppDefinition definition, byte[]? iconBytes, bool regenerateIcon)
    {
        definition = definition.Normalize();
        var previous = snapshot.Catalog.Apps.SingleOrDefault(app => app.Definition.Id == definition.Id);
        if (previous?.Removed == true) throw new ValidationException("This identity was removed. Retained browser data cannot be silently adopted.");
        if (previous is not null)
        {
            if (iconBytes is not null && previous.Files.ContainsKey("Icon") && SafeFiles.Hash(layout.Resolve(Address(previous, "Icon"))) == SafeFiles.Missing)
                previous = previous with { Files = previous.Files.Where(file => file.Key != "Icon").ToDictionary() };
            CheckOwned(previous);
            definition = definition with { Aliases = previous.Definition.Aliases.Append(previous.Definition.DisplayName).Concat(definition.Aliases).Distinct(StringComparer.Ordinal).ToArray() };
        }
        else RequireEmptyAppFolder(StorageArea.Data, definition.Id);
        CheckNames(snapshot.Catalog, definition);
        var record = (previous ?? new AppRecord { ShortcutName = definition.DisplayName }) with { Definition = definition, Revision = (previous?.Revision ?? 0) + 1 };
        var built = artifacts.Build(record, layout, iconBytes, regenerateIcon);
        ValidateArtifacts(record, built);
        var changes = FileChanges(previous, record, built);
        record = record with { Files = built.Files.ToDictionary(file => file.Key, file => Identity.Hash(file.Value), StringComparer.Ordinal), EdgePath = built.EdgePath, LauncherVersion = built.LauncherVersion };
        AddReservations(snapshot.Catalog, record, changes);
        Commit(snapshot, record, changes);
        return record;
    }

    public AppRecord Rename(string id, string name, string expectedCatalogHash)
    {
        var snapshot = Read();
        var current = Find(snapshot.Catalog, id);
        return Save(current.Definition with { DisplayName = Identity.Name(name) }, expectedCatalogHash);
    }

    public void Remove(string id, string expectedCatalogHash)
    {
        using var lease = Acquire();
        var snapshot = RequireSnapshot(expectedCatalogHash);
        var record = Find(snapshot.Catalog, id);
        if (record.Removed) return;
        CheckOwned(record);
        var changes = record.Files.Select(file => new FileChange(Address(record, file.Key), file.Value, null)).ToList();
        Commit(snapshot, record with { Removed = true, Files = new(), Revision = record.Revision + 1 }, changes);
    }

    public AppRecord Repair(string id, string expectedCatalogHash)
    {
        using var lease = Acquire();
        var snapshot = RequireSnapshot(expectedCatalogHash);
        var record = Find(snapshot.Catalog, id);
        CheckOwned(record, true);
        if (record.Definition.IconKind == "Custom" && SafeFiles.Hash(layout.Resolve(Address(record, "Icon"))) == SafeFiles.Missing)
            throw new ValidationException("The custom icon is missing. Choose a replacement icon or explicitly select an automatic icon before saving.");
        var missingAdjusted = record with { Files = record.Files.Where(file => SafeFiles.Hash(layout.Resolve(Address(record, file.Key))) != SafeFiles.Missing).ToDictionary() };
        return SaveLocked(snapshot with { Catalog = snapshot.Catalog with { Apps = snapshot.Catalog.Apps.Select(app => app.Definition.Id == id ? missingAdjusted : app).ToArray() } }, record.Definition, null, false);
    }

    public ImportPlan Preview(AppKit kit) => Preview(kit, false);

    public ImportPlan Preview(AppKit kit, bool newOnly)
    {
        kit = KitCodec.Read(KitCodec.Write(kit));
        var snapshot = Read();
        var rows = KitPlanner.Preview(kit, snapshot.Catalog.Apps.Where(app => !app.Removed).Select(app => app.Definition).ToArray());
        var defaultProfile = rows.Any(row => row.Current is null && row.Effective is not null) ? new PreferenceStore(layout).Read().DefaultProfile : null;
        for (var index = 0; index < rows.Length; index++)
        {
            if (rows[index].Effective is null) continue;
            if (newOnly && (rows[index].Current is not null || snapshot.Catalog.Apps.Any(app => !app.Removed && app.Definition.Url == rows[index].Effective!.Url)))
            {
                rows[index] = rows[index] with { Action = "Conflict", Effective = null, Detail = "This Favorite now matches a saved website. Refresh Favorites before importing." };
                continue;
            }
            if (rows[index].Current is null) rows[index] = rows[index] with { Effective = rows[index].Effective! with { EdgeProfile = defaultProfile! } };
            try
            {
                CheckNames(snapshot.Catalog, rows[index].Effective!);
                var current = snapshot.Catalog.Apps.SingleOrDefault(app => app.Definition.Id == rows[index].Effective!.Id);
                if (current is null) RequireEmptyAppFolder(StorageArea.Data, rows[index].Effective!.Id);
                else CheckOwned(current, true);
                var proposed = (current ?? new AppRecord { ShortcutName = rows[index].Effective!.DisplayName }) with { Definition = rows[index].Effective! };
                foreach (var slot in new[] { "Desktop", "StartMenu" })
                {
                    if (!(slot == "Desktop" ? proposed.Definition.Desktop : proposed.Definition.StartMenu) || current?.Files.ContainsKey(slot) == true) continue;
                    if (SafeFiles.Hash(layout.Resolve(Address(proposed, slot))) != SafeFiles.Missing) throw new ValidationException("An unowned shortcut occupies the selected destination.");
                }
            }
            catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException)
            { rows[index] = rows[index] with { Action = "Conflict", Effective = null, Detail = "Local ownership or settings conflict. Resolve it before import." }; }
        }
        return new(kit, snapshot.Hash, rows, PlanFingerprint(kit, snapshot, defaultProfile, newOnly)) { NewOnly = newOnly };
    }

    public ImportResult Import(ImportPlan approved)
    {
        using var lease = Acquire();
        var snapshot = RequireSnapshot(approved.CatalogHash);
        var refreshed = Preview(approved.Kit, approved.NewOnly);
        if (refreshed.CatalogHash != snapshot.Hash || refreshed.Fingerprint != approved.Fingerprint) throw new ValidationException("The complete kit or destination changed after preview.");
        var rows = refreshed.Rows;
        if (rows.Any(row => row.Action == "Conflict")) return new(false, rows.Select(row => new OperationRow(row.Source.Name, row.Action == "Conflict" ? "Conflict" : "Not attempted", row.Detail)).ToArray());
        var results = new List<OperationRow>();
        var failed = false;
        foreach (var row in rows)
        {
            if (failed) { results.Add(new(row.Source.Name, "Not attempted", "An earlier unexpected failure occurred; completed apps remain.")); continue; }
            try
            {
                var currentSnapshot = Read();
                var current = row.Current is null ? null : Find(currentSnapshot.Catalog, row.Current.Id);
                var definition = KitPlanner.Apply(row.Source, approved.Kit.SchemaVersion, current?.Definition ?? row.Effective);
                var icon = row.Source.Icon?.Kind == "Embedded" ? StrictJson.Base64(row.Source.Icon.Data!, 1024 * 1024) : null;
                var desired = definition with { Id = row.Effective!.Id };
                var unchanged = current is not null && JsonSerializer.Serialize(desired, StrictJson.Options) == JsonSerializer.Serialize(current.Definition, StrictJson.Options) &&
                    (row.Source.Icon?.Kind != "Embedded" || current.Files.GetValueOrDefault("Icon") == row.Source.Icon.Sha256) && current.Files.All(file => SafeFiles.Hash(layout.Resolve(Address(current, file.Key))) == file.Value);
                if (!unchanged)
                {
                    if (current is not null)
                    {
                        CheckOwned(current, true);
                        var present = current with { Files = current.Files.Where(file => SafeFiles.Hash(layout.Resolve(Address(current, file.Key))) != SafeFiles.Missing).ToDictionary() };
                        currentSnapshot = currentSnapshot with { Catalog = currentSnapshot.Catalog with { Apps = currentSnapshot.Catalog.Apps.Select(app => app.Definition.Id == current.Definition.Id ? present : app).ToArray() } };
                    }
                    SaveLocked(currentSnapshot, desired, icon, row.Source.Icon?.Kind != "Embedded");
                }
                results.Add(new(row.Source.Name, unchanged ? "Unchanged" : current is null ? "Added" : "Updated", "Saved locally. Website access was not tested."));
            }
            catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException)
            { failed = true; results.Add(new(row.Source.Name, "Failed", "An unexpected local failure occurred. Completed apps remain; recovery details are retained locally.")); }
        }
        return new(!failed, results.ToArray());
    }

    public MigrationPlan PreviewMigration(string id)
    {
        if (!Identity.IsId(id)) throw new ValidationException("Invalid legacy identity.");
        var snapshot = Read();
        var manifestPath = layout.Resolve(new(StorageArea.Legacy, $"Apps/{id}/app.json"));
        var manifest = ManifestCodec.ReadLegacy(SafeFiles.Read(manifestPath, 32768), id);
        artifacts.ValidateLegacy(manifest, layout);
        CheckNames(snapshot.Catalog, manifest.App, true);
        var record = new AppRecord { Definition = manifest.App, Storage = StorageArea.Legacy, ShortcutName = manifest.App.DisplayName };
        var hashes = Slots.ToDictionary(slot => slot, slot => SafeFiles.Hash(layout.Resolve(Address(record, slot))), StringComparer.Ordinal);
        if (hashes["Configuration"] != SafeFiles.Missing) throw new ValidationException("A retained configuration already occupies this legacy folder.");
        if (hashes["Icon"] != manifest.IconHash || (manifest.App.Window.Owned && hashes["Launcher"] != manifest.LauncherHash)) throw new ValidationException("Legacy owned file identity mismatch.");
        var hash = Identity.Hash(manifest.OriginalBytes);
        return new(id, snapshot.Hash, hash, hashes, Identity.Hash(JsonSerializer.SerializeToUtf8Bytes(new { id, snapshot.Hash, Manifest = hash, Files = hashes })));
    }

    public AppRecord Migrate(MigrationPlan approved)
    {
        if (!AllowExperimentalMigration) throw new ValidationException(MigrationAcceptanceRequired);
        using var lease = Acquire();
        var snapshot = Read();
        var already = snapshot.Catalog.Apps.SingleOrDefault(app => app.Definition.Id == approved.Id);
        if (already is not null && already.Storage == StorageArea.Legacy) { CheckOwned(already); return already; }
        snapshot = RequireSnapshot(approved.CatalogHash);
        var refreshed = PreviewMigration(approved.Id);
        if (refreshed.Fingerprint != approved.Fingerprint) throw new ValidationException("Legacy source changed after migration preview.");
        var manifestAddress = new FileAddress(StorageArea.Legacy, $"Apps/{approved.Id}/app.json");
        var manifest = ManifestCodec.ReadLegacy(SafeFiles.Read(layout.Resolve(manifestAddress), 32768), approved.Id);
        var transactionId = Guid.NewGuid().ToString("N");
        var record = new AppRecord { Definition = manifest.App, ShortcutName = manifest.App.DisplayName, Storage = StorageArea.Legacy, MigrationTransaction = transactionId, Revision = 1 };
        var built = artifacts.Build(record, layout, SafeFiles.Read(layout.Resolve(Address(record, "Icon")), 1024 * 1024), false);
        ValidateArtifacts(record, built);
        var changes = Slots.Where(slot => built.Files.ContainsKey(slot) || approved.Files[slot] != SafeFiles.Missing)
            .Select(slot => new FileChange(Address(record, slot), approved.Files[slot], built.Files.GetValueOrDefault(slot))).ToList();
        var receipt = new FileAddress(StorageArea.Legacy, $"Apps/{approved.Id}/.eea-owner.json");
        changes.Insert(0, new(receipt, SafeFiles.Missing, Reservation(snapshot.Catalog, record.Definition.Id)));
        changes.Insert(1, new(manifestAddress, approved.ManifestHash, null));
        record = record with { Files = built.Files.ToDictionary(file => file.Key, file => Identity.Hash(file.Value)), EdgePath = built.EdgePath, LauncherVersion = built.LauncherVersion };
        Commit(snapshot, record, changes, transactionId);
        return record;
    }

    public void RollbackMigration(string id, string expectedCatalogHash)
    {
        if (!AllowExperimentalMigration) throw new ValidationException(MigrationAcceptanceRequired);
        using var lease = Acquire();
        var snapshot = RequireSnapshot(expectedCatalogHash);
        var record = Find(snapshot.Catalog, id);
        if (record.MigrationTransaction is null || !Guid.TryParseExact(record.MigrationTransaction, "N", out _)) throw new ValidationException("No trusted migration backup is recorded.");
        CheckOwned(record);
        var backupRoot = Path.Combine(layout.Root(StorageArea.Data), ".transactions", record.MigrationTransaction);
        var journal = new FileTransaction(layout).ReadJournal(backupRoot);
        if (journal.SchemaVersion != 1 || journal.State != "Committed") throw new ValidationException("Migration backup is not committed.");
        var changes = new List<FileChange>();
        foreach (var entry in journal.Entries.Where(entry => entry.Address != CatalogAddress))
        {
            var slot = Slots.SingleOrDefault(candidate => Address(record, candidate) == entry.Address);
            string expected;
            if (slot is not null) expected = record.Files.GetValueOrDefault(slot) ?? SafeFiles.Missing;
            else if (entry.Address == new FileAddress(StorageArea.Legacy, $"Apps/{id}/app.json")) expected = SafeFiles.Missing;
            else if (entry.Address == new FileAddress(StorageArea.Legacy, $"Apps/{id}/.eea-owner.json")) expected = Identity.Hash(Reservation(snapshot.Catalog, id));
            else throw new ValidationException("Migration journal contains an unrelated file address.");
            if (SafeFiles.Hash(layout.Resolve(entry.Address)) != expected) throw new ValidationException("An externally changed legacy file prevents rollback.");
            var content = entry.BeforeHash == SafeFiles.Missing ? null : SafeFiles.Read(Path.Combine(backupRoot, entry.Index + ".before"));
            if (content is not null && Identity.Hash(content) != entry.BeforeHash) throw new ValidationException("Migration backup was changed.");
            changes.Add(new(entry.Address, expected, content));
        }
        var archivedAddresses = journal.Entries.Select(entry => entry.Address).ToHashSet();
        foreach (var file in record.Files)
        {
            var address = Address(record, file.Key);
            if (!archivedAddresses.Contains(address)) changes.Add(new(address, file.Value, null));
        }
        foreach (var alias in record.Definition.Aliases.Append(record.Definition.DisplayName).Select(Identity.LegacyId).Distinct())
        {
            if (alias == id || layout.LegacyRoot is null) continue;
            var address = new FileAddress(StorageArea.Legacy, $"Apps/{alias}/.eea-reservation");
            var hash = SafeFiles.Hash(layout.Resolve(address));
            if (hash != Identity.Hash(Reservation(snapshot.Catalog, id))) throw new ValidationException("An alias reservation was changed; rollback stopped.");
            changes.Add(new(address, hash, null));
        }
        var next = snapshot.Catalog with { Revision = snapshot.Catalog.Revision + 1, Apps = snapshot.Catalog.Apps.Where(app => app.Definition.Id != id).ToArray() };
        changes = changes.OrderBy(change => change.Address.RelativePath.EndsWith("/app.json", StringComparison.Ordinal) ? 1 : 0).ToList();
        changes.Add(new(CatalogAddress, snapshot.Hash, JsonSerializer.SerializeToUtf8Bytes(next, StrictJson.Options)));
        new FileTransaction(layout, transactionFault).Execute(changes);
    }

    public void Recover(string transactionId) { using var lease = Acquire(true); new FileTransaction(layout).Recover(transactionId); }

    public void CheckOwned(AppRecord record, bool allowMissing = false)
    {
        foreach (var file in record.Files)
        {
            var hash = SafeFiles.Hash(layout.Resolve(Address(record, file.Key)));
            if (hash != file.Value && !(allowMissing && hash == SafeFiles.Missing)) throw new ValidationException("An owned file was changed outside this manager. Nothing was changed.");
        }
    }

    public AppCheck Check(AppRecord record)
    {
        var issues = new List<string>();
        var canRepair = !record.Removed;
        foreach (var file in record.Files)
        {
            try
            {
                var hash = SafeFiles.Hash(layout.Resolve(Address(record, file.Key)));
                if (hash == file.Value) continue;
                if (hash == SafeFiles.Missing)
                {
                    issues.Add(file.Key + " is missing.");
                    if (file.Key == "Icon" && record.Definition.IconKind == "Custom")
                    { canRepair = false; issues.Add("Choose a replacement for the missing custom icon."); }
                }
                else { canRepair = false; issues.Add(file.Key + " was changed outside this manager."); }
            }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or ValidationException)
            { canRepair = false; issues.Add(file.Key + " could not be verified."); }
        }
        return new(record.Definition.Id, record.Definition.DisplayName, record.Removed ? "Removed" : issues.Count == 0 ? "Healthy" : canRepair ? "Repairable" : "Conflict", canRepair, issues.ToArray());
    }

    private string PlanFingerprint(AppKit kit, CatalogSnapshot snapshot, string? defaultProfile, bool newOnly)
    {
        var files = snapshot.Catalog.Apps.SelectMany(record => record.Files.Keys.Select(slot => new { record.Definition.Id, Slot = slot, Hash = SafeFiles.Hash(layout.Resolve(Address(record, slot))) })).ToArray();
        return Identity.Hash(JsonSerializer.SerializeToUtf8Bytes(new { Root = Identity.Hash(Encoding.UTF8.GetBytes(layout.Root(StorageArea.Data))), snapshot.Hash, Kit = Identity.Hash(KitCodec.Write(kit)), DefaultProfile = defaultProfile, NewOnly = newOnly, Files = files }));
    }

    private List<FileChange> FileChanges(AppRecord? previous, AppRecord next, AppArtifacts built) => Slots.Where(slot => built.Files.ContainsKey(slot) || previous?.Files.ContainsKey(slot) == true)
        .Select(slot => new FileChange(Address(next, slot), previous?.Files.GetValueOrDefault(slot) ?? SafeFiles.Missing, built.Files.GetValueOrDefault(slot))).ToList();

    private static void ValidateArtifacts(AppRecord record, AppArtifacts built)
    {
        if (built.Files.Keys.Any(slot => !Slots.Contains(slot)) || !built.Files.ContainsKey("Icon") || built.Files.ContainsKey("Desktop") != record.Definition.Desktop || built.Files.ContainsKey("StartMenu") != record.Definition.StartMenu ||
            !built.Files.ContainsKey("Launcher") || !built.Files.ContainsKey("Configuration")) throw new ValidationException("Incomplete compiled website artifacts.");
    }

    private void CheckNames(Catalog catalog, AppDefinition definition, bool migrating = false)
    {
        var keys = definition.Aliases.Append(definition.DisplayName).Select(Identity.NameKey).ToHashSet(StringComparer.Ordinal);
        if (catalog.Apps.Any(app => app.Definition.Id != definition.Id && app.Definition.Aliases.Append(app.Definition.DisplayName).Any(name => keys.Contains(Identity.NameKey(name)))))
            throw new ValidationException("This name is reserved by another permanent website identity.");
        if (layout.LegacyRoot is null || migrating) return;
        foreach (var name in definition.Aliases.Append(definition.DisplayName))
        {
            var legacyId = Identity.LegacyId(name);
            if (catalog.Apps.Any(app => app.Definition.Id == definition.Id && app.Storage == StorageArea.Legacy && legacyId == definition.Id)) continue;
            var folder = Path.Combine(layout.Root(StorageArea.Legacy), "Apps", legacyId);
            SafeFiles.CheckPath(folder);
            if (!Directory.Exists(folder) || !Directory.EnumerateFileSystemEntries(folder).Any()) continue;
            var marker = Path.Combine(folder, ".eea-reservation");
            if (SafeFiles.Hash(marker) != Identity.Hash(Reservation(catalog, definition.Id)) || Directory.EnumerateFileSystemEntries(folder).Count() != 1)
                throw new ValidationException("A legacy or retained app folder reserves this name. Migrate trusted settings explicitly; do not adopt retained data.");
        }
    }

    private void AddReservations(Catalog catalog, AppRecord record, List<FileChange> changes)
    {
        if (layout.LegacyRoot is null) return;
        foreach (var alias in record.Definition.Aliases.Append(record.Definition.DisplayName).Select(Identity.LegacyId).Distinct())
        {
            if (record.Storage == StorageArea.Legacy && alias == record.Definition.Id) continue;
            var address = new FileAddress(StorageArea.Legacy, $"Apps/{alias}/.eea-reservation");
            var hash = SafeFiles.Hash(layout.Resolve(address));
            if (hash == SafeFiles.Missing) changes.Add(new(address, hash, Reservation(catalog, record.Definition.Id)));
            else if (hash != Identity.Hash(Reservation(catalog, record.Definition.Id))) throw new ValidationException("Name reservation ownership conflict.");
        }
    }

    private static byte[] Reservation(Catalog catalog, string id) => JsonSerializer.SerializeToUtf8Bytes(new { Product = "EasyEdgeApps.Ownership", SchemaVersion = 1, catalog.StoreId, Id = id });

    private void RequireEmptyAppFolder(StorageArea area, string id)
    {
        var path = Path.Combine(layout.Root(area), "Apps", id);
        SafeFiles.CheckPath(path);
        if (Directory.Exists(path) && Directory.EnumerateFileSystemEntries(path).Any()) throw new ValidationException("A nonempty retained folder cannot be adopted without trusted settings.");
    }

    private void Commit(CatalogSnapshot snapshot, AppRecord record, List<FileChange> changes, string? transactionId = null)
    {
        var next = snapshot.Catalog with { Revision = snapshot.Catalog.Revision + 1, Apps = snapshot.Catalog.Apps.Where(app => app.Definition.Id != record.Definition.Id).Append(record).OrderBy(app => app.Definition.Id, StringComparer.Ordinal).ToArray() };
        if (next.Apps.Length > MaximumCatalogApps) throw new ValidationException("The catalog has reached its retained website identity limit. No websites were changed.");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(next, StrictJson.Options);
        using var validated = StrictJson.Parse(bytes, MaximumCatalogBytes, MaximumCatalogDepth, MaximumCatalogValues);
        changes.Add(new(CatalogAddress, snapshot.Hash, bytes));
        new FileTransaction(layout, transactionFault).Execute(changes, transactionId, archiveUnchanged: record.MigrationTransaction == transactionId && transactionId is not null);
    }

    private CatalogSnapshot RequireSnapshot(string expected)
    {
        var snapshot = Read();
        if (snapshot.Hash != expected) throw new ValidationException("The catalog changed after preview. Refresh before applying.");
        return snapshot;
    }

    private IDisposable Acquire(bool recovering = false)
    {
        var compatibleLease = artifacts.AcquireWriterLease();
        var path = layout.Resolve(new(StorageArea.Data, ".writer.lock"));
        FileStream? lease = null;
        try
        {
            Directory.CreateDirectory(layout.Root(StorageArea.Data));
            lease = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            if (!recovering) new FileTransaction(layout).RequireRecovered();
            return new WriterLease(lease, compatibleLease);
        }
        catch { lease?.Dispose(); compatibleLease.Dispose(); throw; }
    }

    private sealed class WriterLease(IDisposable file, IDisposable compatibility) : IDisposable
    {
        public void Dispose() { try { file.Dispose(); } finally { compatibility.Dispose(); } }
    }

    private static AppRecord Find(Catalog catalog, string id) => catalog.Apps.SingleOrDefault(app => app.Definition.Id == id) ?? throw new ValidationException("Website identity was not found.");
}