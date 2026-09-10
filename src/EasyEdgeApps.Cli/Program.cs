using System.Diagnostics;
using System.Text;
using System.Text.Json;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;
using EasyEdgeApps.Windows;

namespace EasyEdgeApps.Cli;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        PreferenceStore? diagnosticStore = null;
        string? diagnosticOperation = null;
        var diagnosticOutcome = "Success";
        using var cancellation = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };
        try
        {
            if (args.Length == 0 || args[0] is "help" or "--help" or "-h" or "-?" or "--version")
            {
                Console.WriteLine(args.FirstOrDefault() == "--version" ? "Easy Edge Apps 2.0.0-preview.1" : Help);
                return 0;
            }
            var options = Arguments.Parse(args);
            var command = options.Command;
            var layout = Layout(options);
            var isolated = options.Has("isolated-root");
            var store = new CatalogStore(layout, new DesktopArtifacts(Path.Combine(AppContext.BaseDirectory, "WebsiteLauncher", "fresh-session.exe"))) { AllowExperimentalMigration = isolated };
            var inspection = new DesktopInspection(store, Path.Combine(AppContext.BaseDirectory, "WebsiteLauncher", "fresh-session.exe"));
            var preferences = new PreferenceStore(layout);
            diagnosticStore = preferences;
            if (options.Has("yes")) diagnosticOperation = command switch
            {
                "save" or "rename" => "Save", "remove" => "Remove", "repair" => "Repair", "kit-import" or "favorites-import" => "Import",
                "migrate" or "rollback-migration" => "Migration", "recover" => "Recovery", "stage-update" or "portable-activate" or "portable-rollback" or "portable-recover" => "Update", _ => null
            };
            var current = new Lazy<CatalogSnapshot>(store.Read);
            AppRecord Select()
            {
                var apps = current.Value.Catalog.Apps.Where(app => !app.Removed);
                var selected = options.Has("id") ? apps.SingleOrDefault(app => app.Definition.Id == options.Required("id")) : FindName(apps, options.Required("name"));
                return selected ?? throw new ValidationException("Select an existing permanent website ID or name from list.");
            }
            EdgeProfileInfo[] DiscoverProfiles() => EdgeProfiles.Discover(isolated ? layout.Resolve(new(StorageArea.Data, "EdgeProfiles")) : EdgeProfiles.DefaultRoot);
            string? favoritesSource = null;
            FavoriteCandidate[] ReadFavorites()
            {
                string path;
                if (options.Has("file")) path = options.Required("file");
                else
                {
                    var profiles = DiscoverProfiles().Where(profile => profile.HasBookmarks).ToArray();
                    var selected = options.Has("edge-profile") ? Identity.Profile(options.Required("edge-profile")) : preferences.Read().DefaultProfile;
                    var profile = selected.Length != 0 ? profiles.SingleOrDefault(candidate => candidate.DirectoryName == selected) : profiles.Length == 1 ? profiles[0] : null;
                    path = profile?.BookmarksPath ?? throw new ValidationException("Choose an available --edge-profile from profiles or an explicit --file Bookmarks path.");
                }
                favoritesSource = Path.GetFullPath(path);
                return store.ReadFavorites(SafeFiles.Read(favoritesSource, 16 * 1024 * 1024));
            }
            void ConfirmWrite() { if (!options.Has("yes")) throw new ValidationException("Review the preview, then explicitly pass --yes to apply this operation."); }
            var token = cancellation.Token;
            switch (command)
            {
                case "list":
                    Print(current.Value.Catalog.Apps.Where(app => !app.Removed).Select(app => app.Definition)); return 0;
                case "profiles": Print(DiscoverProfiles()); return 0;
                case "check":
                {
                    if (!options.Has("id") && !options.Has("name") && !options.Has("app-names")) { Print(inspection.ReadAll(current.Value)); return 0; }
                    var selected = options.Has("id") || options.Has("name") ? [Select()] : options.SelectNames(current.Value.Catalog.Apps.Where(app => !app.Removed), app => app.Definition.DisplayName);
                    Print(selected.Select(inspection.Check).ToArray()); return 0;
                }
                case "save":
                {
                    if (isolated && options.Has("launch") && !options.Has("preview")) throw new ValidationException("Browser launches are disabled in isolated test mode.");
                    if (isolated && options.Has("fetch-icon") && !options.Has("preview")) throw new ValidationException("Network icon requests are disabled in isolated test mode.");
                    var definition = options.Has("file") ? ReadDefinition(options.Required("file")) : NamedDefinition(options, current.Value.Catalog, preferences);
                    if (options.Has("icon") || options.Has("fetch-icon")) definition = definition with { IconKind = "Custom" };
                    if (options.Has("reset-icon")) definition = definition with { IconKind = "Generated" };
                    if (options.Has("preview")) { Print(definition); return 0; }
                    ConfirmWrite();
                    var iconWorker = new IconWorkerClient(Path.Combine(AppContext.BaseDirectory, "EasyEdgeApps.ImageWorker.exe"));
                    var icon = options.Has("icon") ? await iconWorker.FromFileAsync(options.Required("icon"), token) : null;
                    if (options.Has("fetch-icon"))
                    {
                        using var client = new WebsiteIconClient();
                        var downloaded = await client.FetchAsync(definition.Url, (image, conversionToken) => iconWorker.ConvertAsync(image.Bytes, image.Format, conversionToken), token);
                        icon = downloaded.Bytes;
                        definition = (definition with { Url = downloaded.Website }).Normalize();
                    }
                    token.ThrowIfCancellationRequested();
                    var saved = store.Save(definition, current.Value.Hash, icon, options.Has("reset-icon"));
                    Print(saved);
                    if (saved.Definition.Window.Taskbar)
                    {
                        try { Console.Error.WriteLine(isolated ? "Pin requests are disabled in isolated test mode." : await TaskbarAssistance.RequestAsync(store, saved, token)); }
                        catch (Exception) { Console.Error.WriteLine("The website was saved, but Windows did not confirm a taskbar pin. Existing pins were not removed."); }
                    }
                    if (options.Has("launch"))
                    {
                        token.ThrowIfCancellationRequested();
                        store.CheckOwned(saved);
                        using var process = Process.Start(new ProcessStartInfo(layout.Resolve(CatalogStore.Address(saved, "Launcher"))) { UseShellExecute = false });
                    }
                    return 0;
                }
                case "rename":
                {
                    _ = options.Required("id");
                    var selected = Select(); var name = Identity.Name(options.Required("name"));
                    if (options.Has("preview")) { Print(new { selected.Definition.Id, OldName = selected.Definition.DisplayName, NewName = name, Preserved = "Profile, folder, launcher, icon, shortcut filenames and taskbar identity" }); return 0; }
                    ConfirmWrite(); Print(store.Rename(selected.Definition.Id, name, current.Value.Hash)); return 0;
                }
                case "remove":
                {
                    var selected = Select(); store.CheckOwned(selected, true);
                    if (options.Has("preview")) { Print(new { selected.Definition.Id, OwnedFiles = selected.Files.Keys, BrowserData = "Retained", WindowsPins = "Not changed" }); return 0; }
                    ConfirmWrite(); store.Remove(selected.Definition.Id, current.Value.Hash); Print(new { Status = "Removed", BrowserData = "Retained" }); return 0;
                }
                case "repair":
                {
                    if (options.Has("app-names"))
                    {
                        var selectedApps = options.SelectNames(current.Value.Catalog.Apps.Where(app => !app.Removed), app => app.Definition.DisplayName);
                        if (options.Has("preview")) { Print(selectedApps.Select(inspection.Check).ToArray()); return 0; }
                        ConfirmWrite();
                        var results = new List<OperationRow>();
                        var expected = current.Value.Hash;
                        foreach (var app in selectedApps)
                        {
                            token.ThrowIfCancellationRequested();
                            try
                            {
                                store.Repair(app.Definition.Id, expected);
                                expected = store.Read().Hash;
                                results.Add(new(app.Definition.DisplayName, "Repaired", "Browser data, permanent identity and window choices retained."));
                            }
                            catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException)
                            { results.Add(new(app.Definition.DisplayName, "Failed", "Repair could not complete safely. Check ownership, running windows and recovery status.")); }
                        }
                        var failed = results.Any(row => row.Status == "Failed");
                        diagnosticOutcome = failed ? "Failed" : "Success";
                        Print(results); return failed ? 3 : 0;
                    }
                    var selected = Select(); store.CheckOwned(selected, true);
                    if (options.Has("preview"))
                    {
                        var check = inspection.Check(selected);
                        Print(new { selected.Definition.Id, check.Status, check.CanRepair, check.Issues, check.BrowsingMode, WindowSettings = selected.Definition.Window }); return 0;
                    }
                    ConfirmWrite(); Print(store.Repair(selected.Definition.Id, current.Value.Hash)); return 0;
                }
                case "launch":
                {
                    if (isolated && !options.Has("preview")) throw new ValidationException("Browser launches are disabled in isolated test mode.");
                    var selected = Select(); store.CheckOwned(selected);
                    if (options.Has("preview")) { Print(new { selected.Definition.Id, Status = "Would open owned launcher" }); return 0; }
                    ConfirmWrite(); Process.Start(new ProcessStartInfo(layout.Resolve(CatalogStore.Address(selected, "Launcher"))) { UseShellExecute = false }); return 0;
                }
                case "pin":
                {
                    if (isolated && !options.Has("preview")) throw new ValidationException("Pin requests are disabled in isolated test mode.");
                    var selected = Select();
                    _ = TaskbarAssistance.CreateRequest(store, selected);
                    if (options.Has("preview")) { Print(new { selected.Definition.Id, Status = "Would request a Windows taskbar pin", ExistingPins = "Retained" }); return 0; }
                    ConfirmWrite();
                    Print(new { selected.Definition.Id, Status = await TaskbarAssistance.RequestAsync(store, selected, token) }); return 0;
                }
                case "kit-preview":
                case "kit-import":
                case "favorites-import":
                {
                    var kit = command == "favorites-import"
                        ? Favorites.ToKit(options.SelectNames(ReadFavorites().Where(item => item.CanImport), item => item.Name), options.Boolean("desktop", true), options.Boolean("start-menu", true))
                        : ReadKit(options.Required("file"), token);
                    if (command != "favorites-import") kit = kit with { Apps = options.SelectNames(kit.Apps, app => app.Name) };
                    var plan = store.Preview(kit, command == "favorites-import");
                    if (command == "kit-preview" || options.Has("preview")) { Print(plan); return plan.Rows.Any(row => row.Action == "Conflict") ? 3 : 0; }
                    ConfirmWrite();
                    if (options.Required("approval") != plan.Fingerprint) throw new ValidationException("The approved kit, destination or owned files changed. Preview again.");
                    var result = store.Import(plan);
                    diagnosticOutcome = result.Completed ? "Success" : "Conflict";
                    Print(result); return result.Results.Any(row => row.Status is "Conflict" or "Failed") ? 3 : 0;
                }
                case "kit-export":
                {
                    var selected = options.Has("id") ? [Select()] : options.SelectNames(current.Value.Catalog.Apps.Where(app => !app.Removed), app => app.Definition.DisplayName);
                    var kit = new AppKit(2, options.Get("name", "My websites"), selected.Select(app =>
                    {
                        store.CheckOwned(app);
                        var iconBytes = app.Definition.IconKind == "Custom" ? SafeFiles.Read(layout.Resolve(CatalogStore.Address(app, "Icon")), 1024 * 1024) : null;
                        var icon = iconBytes is null ? new PortableIcon() : new PortableIcon("Embedded", Data: Convert.ToBase64String(iconBytes), Sha256: Identity.Hash(iconBytes));
                        return new KitApp(app.Definition.DisplayName, app.Definition.Url, app.Definition.Desktop, app.Definition.StartMenu, app.Definition.Notes, Icon: icon, FreshSession: app.Definition.Window.FreshSession);
                    }).ToArray(), options.Get("notes", ""));
                    var bytes = KitCodec.Write(kit);
                    if (options.Has("encrypted"))
                    {
                        Console.Error.WriteLine(KitEncryption.Warning);
                        var password = ReadPassword("Passphrase: "); var confirmation = ReadPassword("Confirm: ");
                        try { bytes = KitEncryption.Protect(kit, password, confirmation, token); }
                        finally { Array.Clear(password); Array.Clear(confirmation); }
                    }
                    WriteNew(SafeFiles.ExportPath(layout, options.Required("output")), bytes, options.Has("force")); Print(new { Status = "Exported", Count = selected.Length, ExperimentalEncryption = options.Has("encrypted") }); return 0;
                }
                case "favorites-preview": Print(options.SelectNames(ReadFavorites(), item => item.Name)); return 0;
                case "favorites-kit":
                {
                    var selected = options.SelectNames(ReadFavorites().Where(item => item.CanImport), item => item.Name);
                    WriteNew(SafeFiles.ExportPath(layout, options.Required("output"), favoritesSource), KitCodec.Write(Favorites.ToKit(selected, options.Boolean("desktop", true), options.Boolean("start-menu", true))), options.Has("force")); Print(new { Status = "Kit created; preview it before import" }); return 0;
                }
                case "migration-list": Print(store.LegacyApps()); return 0;
                case "migration-preview": Print(store.PreviewMigration(options.Required("id"))); return 0;
                case "migrate":
                {
                    if (!isolated) throw new ValidationException(CatalogStore.MigrationAcceptanceRequired);
                    ConfirmWrite(); var plan = store.PreviewMigration(options.Required("id"));
                    if (plan.Fingerprint != options.Required("approval")) throw new ValidationException("Migration preview is stale.");
                    Print(store.Migrate(plan)); return 0;
                }
                case "rollback-migration": ConfirmWrite(); store.RollbackMigration(options.Required("id"), current.Value.Hash); Print(new { Status = "Legacy owned bytes restored; browser data retained" }); return 0;
                case "recovery-list":
                {
                    var root = layout.Resolve(new(StorageArea.Data, ".transactions"));
                    Print(Directory.Exists(root) ? Directory.EnumerateDirectories(root).Select(Path.GetFileName).ToArray() : []); return 0;
                }
                case "recover":
                {
                    ConfirmWrite(); store.Recover(options.Required("transaction")); Print(new { Status = "Recovered" }); return 0;
                }
                case "support":
                {
                    var report = SupportReport.Create(store, Environment.ProcessPath!);
                    if (options.Has("output")) { ConfirmWrite(); WriteNew(SafeFiles.ExportPath(layout, options.Required("output")), Encoding.UTF8.GetBytes(report)); }
                    else Console.WriteLine(report);
                    return 0;
                }
                case "settings":
                {
                    if (!options.Has("file")) { Print(preferences.Read()); return 0; }
                    using var document = StrictJson.Parse(SafeFiles.Read(options.Required("file"), 16384), 16384);
                    var next = (document.RootElement.Deserialize<UserPreferences>(StrictJson.Options) ?? throw new ValidationException("Invalid preferences.")).Validate();
                    if (options.Has("preview")) { Print(next); return 0; }
                    ConfirmWrite(); preferences.Save(next); Print(next); return 0;
                }
                case "clear-logs": ConfirmWrite(); preferences.ClearLogs(); Print(new { Status = "Diagnostic category logs cleared" }); return 0;
                case "check-updates":
                {
                    if (isolated) throw new ValidationException("Network update checks are disabled in isolated test mode.");
                    using var client = new UpdateClient(); Print(await client.CheckAsync(token)); return 0;
                }
                case "verify-publisher": Print(PublisherTrust.Verify(options.Required("file"), options.Required("publisher"))); return 0;
                case "portable-preview":
                case "portable-activate":
                {
                    if (command == "portable-activate") ConfirmWrite();
                    var deployment = new PortableDeployment((path, thumbprint) => PublisherTrust.Verify(path, thumbprint));
                    var publisher = options.Required("publisher");
                    var inputPath = Path.GetFullPath(options.Required("file"));
                    ValidatePortableScope(options, inputPath);
                    if (command == "portable-preview")
                    {
                        ValidatePortableScope(options, options.Required("directory"));
                        var staged = ReadPortableRecord<StagedPackage>(inputPath);
                        ValidatePortableScope(options, options.Required("directory"), staged.Directory);
                        Print(deployment.Preview(staged, options.Required("directory"), publisher));
                    }
                    else
                    {
                        var plan = ReadPortableRecord<PortablePlan>(inputPath);
                        if (plan.Previous is null || plan.Next is null) throw new ValidationException("Incomplete portable approval.");
                        ValidatePortableScope(options, plan.Directory, plan.Previous.Directory, plan.Next.Directory);
                        token.ThrowIfCancellationRequested();
                        Print(deployment.Apply(plan, publisher));
                    }
                    return 0;
                }
                case "portable-rollback":
                case "portable-recover":
                {
                    ConfirmWrite();
                    var directory = options.Required("directory");
                    var receipt = Path.GetFullPath(options.Required("receipt"));
                    ValidatePortableScope(options, directory, receipt);
                    var record = ReadPortableRecord<PortableReceipt>(receipt);
                    if (record.Plan?.Previous is null || record.Plan.Next is null) throw new ValidationException("Incomplete portable receipt.");
                    ValidatePortableScope(options, record.Plan.Directory, record.Plan.Previous.Directory, record.Plan.Next.Directory);
                    var deployment = new PortableDeployment((path, thumbprint) => PublisherTrust.Verify(path, thumbprint));
                    token.ThrowIfCancellationRequested();
                    Print(command == "portable-rollback" ? deployment.Rollback(directory, receipt, options.Required("publisher")) : deployment.Recover(directory, receipt, options.Required("publisher")));
                    return 0;
                }
                case "stage-update":
                {
                    ConfirmWrite();
                    var maintenance = new PackageMaintenance((path, thumbprint) => PublisherTrust.Verify(path, thumbprint));
                    Print(await maintenance.StageAsync(options.Required("file"), layout.Resolve(new(StorageArea.Data, "Updates")), options.Required("publisher"), options.Required("current-version"), token)); return 0;
                }
                default: throw new ValidationException("Unknown command. Run eea --help.");
            }
        }
        catch (OperationCanceledException) { diagnosticOutcome = "Cancelled"; Console.Error.WriteLine("Cancelled. Previously completed per-app changes are retained."); return 2; }
        catch (ValidationException failure) { diagnosticOutcome = "Conflict"; Console.Error.WriteLine(failure.Message); return 3; }
        catch (Exception) { diagnosticOutcome = "Failed"; Console.Error.WriteLine("The operation could not finish safely. Check file ownership, locks and recovery status. No private details were logged."); return 4; }
        finally
        {
            if (diagnosticStore is not null && diagnosticOperation is not null)
                try { diagnosticStore.Record(diagnosticOperation, diagnosticOutcome); }
                catch { }
        }
    }

    public static AppDefinition ReadDefinition(string path)
    {
        using var document = StrictJson.Parse(SafeFiles.Read(path, 16384), 16384);
        return (document.RootElement.Deserialize<AppDefinition>(StrictJson.Options) ?? throw new ValidationException("Invalid website definition.")).Normalize();
    }

    private static AppRecord? FindName(IEnumerable<AppRecord> apps, string name)
    {
        var key = Identity.NameKey(name);
        return apps.SingleOrDefault(app => Identity.NameKey(app.Definition.DisplayName) == key || app.Definition.Aliases.Any(alias => Identity.NameKey(alias) == key));
    }

    private static AppDefinition NamedDefinition(Arguments options, Catalog catalog, PreferenceStore preferences)
    {
        var name = Identity.Name(options.Required("name"));
        var previous = FindName(catalog.Apps.Where(app => !app.Removed), name)?.Definition;
        var baseline = previous ?? new AppDefinition { DisplayName = name, EdgeProfile = preferences.Read().DefaultProfile };
        var taskbar = options.Boolean("taskbar", baseline.Window.Taskbar);
        var profileMode = options.Choice("profile-mode", taskbar || baseline.Window.DedicatedProfile ? "Dedicated" : "Shared", "Dedicated", "Shared");
        var sessionMode = options.Choice("session-mode", baseline.Window.FreshSession ? "Fresh" : "Normal", "Fresh", "Normal");
        var launchMode = options.Choice("launch-mode", baseline.Window.LaunchMode.ToString(), "RememberLast", "Maximized", "FullScreen");
        return (baseline with
        {
            Url = options.Get("url", baseline.Url), Notes = options.Get("notes", baseline.Notes), EdgeProfile = options.Get("edge-profile", baseline.EdgeProfile),
            Desktop = options.Boolean("desktop", baseline.Desktop), StartMenu = options.Boolean("start-menu", taskbar || baseline.StartMenu),
            Window = baseline.Window with
            {
                DedicatedProfile = profileMode == "Dedicated", FreshSession = sessionMode == "Fresh", LaunchMode = Enum.Parse<LaunchMode>(launchMode),
                AlwaysOnTop = options.Boolean("always-on-top", baseline.Window.AlwaysOnTop), Taskbar = taskbar
            }
        }).Normalize();
    }

    private static AppKit ReadKit(string path, CancellationToken token)
    {
        var bytes = SafeFiles.Read(path, 24 * 1024 * 1024);
        using var document = StrictJson.Parse(bytes, 24 * 1024 * 1024);
        if (StrictJson.Text(document.RootElement, "Product") != "EasyEdgeApps.EncryptedKit") return KitCodec.Read(bytes);
        _ = KitEncryption.ReadEnvelope(bytes);
        Console.Error.WriteLine(KitEncryption.Warning);
        var password = ReadPassword("Passphrase: ");
        try { return KitEncryption.Unlock(bytes, password, token); }
        finally { Array.Clear(password); }
    }

    private static char[] ReadPassword(string prompt)
    {
        if (Console.IsInputRedirected) throw new ValidationException("Encrypted-kit secrets must be entered directly at a local terminal, never supplied in command arguments or redirected input.");
        Console.Error.Write(prompt);
        var buffer = new char[1024]; var count = 0;
        try
        {
            while (true)
            {
                var key = Console.ReadKey(true);
                if (key.Key == ConsoleKey.Enter) { Console.Error.WriteLine(); return buffer[..count]; }
                if (key.Key == ConsoleKey.Escape) throw new OperationCanceledException();
                if (key.Key == ConsoleKey.Backspace) { if (count > 0) buffer[--count] = '\0'; continue; }
                if (!char.IsControl(key.KeyChar) && count < buffer.Length) buffer[count++] = key.KeyChar;
            }
        }
        finally { Array.Clear(buffer); }
    }

    private static void WriteNew(string path, byte[] bytes, bool replace = false)
    {
        path = Path.GetFullPath(path); SafeFiles.CheckPath(path);
        if (replace) { SafeFiles.AtomicWrite(path, bytes); return; }
        if (File.Exists(path)) throw new ValidationException("The output already exists. Choose a new path or explicitly pass --force for kit exports.");
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        output.Write(bytes); output.Flush(true);
    }

    private static T ReadPortableRecord<T>(string path)
    {
        using var document = StrictJson.Parse(SafeFiles.Read(Path.GetFullPath(path), 32768), 32768, 8, 128);
        static void PackageFields(JsonElement package)
        {
            var fields = new[] { "Directory", "Version", "IndexHash", "SourceVersion" };
            StrictJson.Fields(package, fields);
            foreach (var field in fields) _ = StrictJson.Text(package, field);
        }
        var root = document.RootElement;
        if (typeof(T) == typeof(StagedPackage)) PackageFields(root);
        else
        {
            var plan = root;
            if (typeof(T) == typeof(PortableReceipt))
            {
                StrictJson.Fields(root, ["Product", "SchemaVersion", "State", "Plan"]);
                _ = StrictJson.Text(root, "Product");
                _ = StrictJson.Integer(root, "SchemaVersion");
                _ = StrictJson.Text(root, "State");
                plan = root.GetProperty("Plan");
            }
            else if (typeof(T) != typeof(PortablePlan)) throw new ValidationException("Unsupported portable maintenance record.");
            StrictJson.Fields(plan, ["Directory", "Previous", "Next", "Publisher", "Fingerprint"]);
            foreach (var field in new[] { "Directory", "Publisher", "Fingerprint" }) _ = StrictJson.Text(plan, field);
            PackageFields(plan.GetProperty("Previous"));
            PackageFields(plan.GetProperty("Next"));
        }
        try { return root.Deserialize<T>(StrictJson.Options) ?? throw new ValidationException("Invalid portable maintenance record."); }
        catch (JsonException) { throw new ValidationException("Invalid portable maintenance fields."); }
    }

    private static void ValidatePortableScope(Arguments options, params string[] paths)
    {
        foreach (var path in paths)
        {
            if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new ValidationException("Portable maintenance requires absolute local paths.");
            var full = Path.GetFullPath(path);
            if (options.Has("isolated-root") && !full.StartsWith(Path.TrimEndingDirectorySeparator(Path.GetFullPath(options.Required("isolated-root"))) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new ValidationException("Isolated portable maintenance must stay inside its fixture root.");
            SafeFiles.CheckPath(full);
        }
    }

    private static StoreLayout Layout(Arguments options)
    {
        if (options.Has("isolated-root"))
        {
            var root = Path.GetFullPath(options.Required("isolated-root"));
            return new(Path.Combine(root, "Data"), Path.Combine(root, "Desktop"), Path.Combine(root, "Programs"), Path.Combine(root, "Legacy"));
        }
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return new(Path.Combine(local, "EasyEdgeApps.Next"), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Easy Edge Apps"), Path.Combine(local, "EasyEdgeApps"));
    }

    private static void Print(object value) => Console.WriteLine(JsonSerializer.Serialize(value, StrictJson.Options));

    public const string Help = """
        Easy Edge Apps 2.0.0-preview.1
        eea <command> [options]
                Read: list, profiles, check [--id ID | --name NAME | --app-names JSON_ARRAY], support, settings, migration-list, recovery-list, --version
        Websites: save --file definition.json [--icon IMAGE | --fetch-icon | --reset-icon] [--preview | --yes]
                                    save --name NAME [--url URL] [--notes TEXT] [--edge-profile PROFILE]
                                        [--profile-mode Dedicated|Shared] [--session-mode Normal|Fresh]
                                        [--launch-mode RememberLast|Maximized|FullScreen] [--always-on-top true|false]
                                        [--desktop true|false] [--start-menu true|false] [--taskbar true|false]
                                        [--icon IMAGE | --fetch-icon | --reset-icon] [--launch]
                                        [--preview | --yes]
                  rename --id ID --name NAME [--preview | --yes]
                                    remove|repair|launch|pin <--id ID | --name NAME> [--preview | --yes]
                  repair --app-names JSON_ARRAY [--preview | --yes]
        Kits: kit-preview --file kit.eea-kit.json
              kit-import --file KIT --approval FINGERPRINT --yes
              kit-export --output FILE [--name TITLE] [--notes TEXT] [--id ID] [--encrypted] [--force]
              favorites-preview [--file Bookmarks | --edge-profile PROFILE]
              favorites-kit [--file Bookmarks | --edge-profile PROFILE] --output FILE [--force]
              favorites-import [--file Bookmarks | --edge-profile PROFILE]
                  [--desktop true|false] [--start-menu true|false]
                  [--preview | --approval FINGERPRINT --yes]
              --app-names JSON_ARRAY selects normalized names for kit-preview, kit-import,
                  kit-export and Favorites commands; for example '["Mail","Work"]'.
              Favorites use the saved default profile or a single discovered profile when no source is supplied.
              Only HTTPS Favorites are importable. Sources are never modified; existing exports require --force.
        Migration: migration-preview --id ID
                   migrate --id ID --approval FINGERPRINT --yes
                   rollback-migration --id ID --yes
                   recover --transaction GUID --yes
        Settings: settings --file preferences.json [--preview | --yes]
                  clear-logs --yes
        Maintenance: check-updates
                     verify-publisher --file ARTIFACT --publisher THUMBPRINT
                     stage-update --file PACKAGE --publisher THUMBPRINT --current-version VERSION --yes
                     portable-preview --file STAGED_JSON --directory CURRENT --publisher THUMBPRINT
                     portable-activate --file APPROVED_PLAN_JSON --publisher THUMBPRINT --yes
                     portable-rollback|portable-recover --directory CURRENT --receipt RECEIPT_JSON
                         --publisher THUMBPRINT --yes
        Portable maintenance must run from a separate trusted helper directory with the target closed.
        Both versions require the expected publisher; unsigned previews cannot activate an update.
        Global: --isolated-root DIRECTORY routes application state and shortcut roots there;
            browser launches, website icon requests, pin requests and live update checks are disabled in isolated mode.
        Live legacy migration/rollback are gated pending disposable-Windows acceptance.
        support prints a privacy-safe preview; --output NEWFILE --yes saves exactly that report.
        JSON output. Exit 0 success, 2 cancelled, 3 conflict/input, 4 runtime failure.
        Named save requires a full URL for new websites and preserves omitted existing settings.
        It does not rename an existing website; use rename to change its display name.
        Taskbar selection requires Start and a dedicated profile and requests Windows approval after saving.
        Clearing taskbar selection never removes an existing pin. Pin failure does not undo a successful save.
        Icon previews do not access the network or decode files; apply validates the chosen image before saving.
        Encrypted kits are experimental. Secrets are accepted only through the local terminal.
        The original PowerShell entry point remains available with documented import and native cleanup fixes.
        """;
}

internal sealed record Arguments(string Command, Dictionary<string, string> Values)
{
    public bool Has(string name) => Values.ContainsKey(name);
    public string Required(string name) => Values.TryGetValue(name, out var value) && value.Length != 0 ? value : throw new ValidationException("Missing --" + name + ".");
    public string Get(string name, string fallback) => Values.GetValueOrDefault(name, fallback);
    public bool Boolean(string name, bool fallback) => !Has(name) ? fallback : bool.TryParse(Required(name), out var value) ? value : throw new ValidationException("--" + name + " requires true or false.");
    public string Choice(string name, string fallback, params string[] choices) => !Has(name) ? fallback : choices.SingleOrDefault(choice => choice.Equals(Required(name), StringComparison.OrdinalIgnoreCase)) ?? throw new ValidationException("Invalid --" + name + " choice.");
    public T[] SelectNames<T>(IEnumerable<T> items, Func<T, string> name)
    {
        var candidates = items.ToArray();
        if (!Has("app-names")) return candidates;
        using var document = StrictJson.Parse(Encoding.UTF8.GetBytes(Required("app-names")), 16384, 2, 128);
        var array = document.RootElement;
        if (array.ValueKind != JsonValueKind.Array || array.GetArrayLength() is < 1 or > 100) throw new ValidationException("--app-names requires a JSON array of 1 to 100 distinct website names.");
        var selected = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in array.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String || !selected.Add(Identity.NameKey(item.GetString()!))) throw new ValidationException("Selected website names must be valid, distinct strings.");
        }
        var result = candidates.Where(item => SelectionKey(name(item)) is string key && selected.Contains(key)).ToArray();
        if (result.Length != selected.Count) throw new ValidationException("One or more selected names are not available. Review the complete source and select again.");
        return result;
    }

    private static string? SelectionKey(string name)
    {
        try { return Identity.NameKey(name); }
        catch (ValidationException) { return null; }
    }

    public static Arguments Parse(string[] arguments)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var flags = new HashSet<string>(["yes", "preview", "encrypted", "launch", "force", "fetch-icon", "reset-icon"], StringComparer.Ordinal);
        string[] supported = arguments[0] switch
        {
            "list" or "profiles" or "migration-list" or "recovery-list" or "check-updates" => [],
            "check" => ["id", "name", "app-names"],
            "save" => ["file", "name", "url", "notes", "edge-profile", "profile-mode", "session-mode", "launch-mode", "always-on-top", "desktop", "start-menu", "taskbar", "icon", "fetch-icon", "reset-icon", "launch", "preview", "yes"],
            "rename" => ["id", "name", "preview", "yes"],
            "remove" or "launch" or "pin" => ["id", "name", "preview", "yes"],
            "repair" => ["id", "name", "app-names", "preview", "yes"],
            "kit-preview" => ["file", "app-names"],
            "kit-import" => ["file", "app-names", "approval", "yes"],
            "kit-export" => ["output", "name", "notes", "id", "app-names", "encrypted", "force"],
            "favorites-preview" => ["file", "edge-profile", "app-names"],
            "favorites-kit" => ["file", "edge-profile", "output", "app-names", "desktop", "start-menu", "force"],
            "favorites-import" => ["file", "edge-profile", "app-names", "desktop", "start-menu", "preview", "approval", "yes"],
            "migration-preview" => ["id"],
            "migrate" => ["id", "approval", "yes"],
            "rollback-migration" => ["id", "yes"],
            "recover" => ["transaction", "yes"],
            "support" => ["output", "yes"],
            "settings" => ["file", "preview", "yes"],
            "clear-logs" => ["yes"],
            "verify-publisher" => ["file", "publisher"],
            "stage-update" => ["file", "publisher", "current-version", "yes"],
            "portable-preview" => ["file", "directory", "publisher"],
            "portable-activate" => ["file", "publisher", "yes"],
            "portable-rollback" or "portable-recover" => ["directory", "receipt", "publisher", "yes"],
            _ => throw new ValidationException("Unknown command. Run eea --help.")
        };
        var known = supported.Append("isolated-root").ToHashSet(StringComparer.Ordinal);
        for (var index = 1; index < arguments.Length; index++)
        {
            if (!arguments[index].StartsWith("--", StringComparison.Ordinal)) throw new ValidationException("Options must start with --.");
            var name = arguments[index][2..];
            if (!known.Contains(name) || values.ContainsKey(name)) throw new ValidationException("Unknown or duplicate option --" + name + ".");
            if (flags.Contains(name)) values.Add(name, "true");
            else if (++index < arguments.Length && !arguments[index].StartsWith("--", StringComparison.Ordinal)) values.Add(name, arguments[index]);
            else throw new ValidationException("Missing option value.");
        }
        if (values.ContainsKey("yes") && values.ContainsKey("preview")) throw new ValidationException("Choose preview or apply, not both.");
        if (arguments[0] is "check" or "repair" or "remove" or "launch" or "pin" && new[] { "id", "name", "app-names" }.Count(values.ContainsKey) > 1)
            throw new ValidationException("Choose one website selection: --id, --name or --app-names.");
        if (arguments[0] == "save" && values.ContainsKey("file") && new[] { "name", "url", "notes", "edge-profile", "profile-mode", "session-mode", "launch-mode", "always-on-top", "desktop", "start-menu", "taskbar" }.Any(values.ContainsKey))
            throw new ValidationException("Choose a complete definition file or named website settings, not both.");
        if (arguments[0] == "save" && new[] { "icon", "fetch-icon", "reset-icon" }.Count(values.ContainsKey) > 1)
            throw new ValidationException("Choose one icon source: --icon, --fetch-icon or --reset-icon.");
        if (arguments[0] is "favorites-preview" or "favorites-kit" or "favorites-import" && values.ContainsKey("file") && values.ContainsKey("edge-profile"))
            throw new ValidationException("Choose one Favorites source: --file or --edge-profile.");
        if (values.ContainsKey("app-names") && (values.ContainsKey("id") || arguments[0] is not ("check" or "repair" or "kit-preview" or "kit-import" or "kit-export" or "favorites-preview" or "favorites-kit" or "favorites-import")))
            throw new ValidationException("--app-names is a subset selection for check, repair, kits and Favorites; do not combine it with --id.");
        return new(arguments[0], values);
    }
}