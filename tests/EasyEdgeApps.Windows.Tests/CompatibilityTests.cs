using System.Diagnostics;
using System.Text.Json;
using EasyEdgeApps.Core;
using EasyEdgeApps.Core.Tests;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Windows.Tests;

public sealed class CompatibilityTests(Xunit.Abstractions.ITestOutputHelper testOutput)
{
    [Theory]
    [InlineData("powershell.exe", 1)]
    [InlineData("powershell.exe", 2)]
    [InlineData("pwsh.exe", 1)]
    [InlineData("pwsh.exe", 2)]
    public async Task EncryptedKitsInteroperateWithBothLegacyHosts(string host, int schema)
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        const string password = "Synthetic interop \u00e9 \ud83d\ude00 123!";
        var icon = IconService.Generate("Unicode");
        var kit = new AppKit(schema, "Unicode \u00e9", [new("Website \u00e9", "https://example.com/?encoded=%26%22", Notes: "2026-09-09T00:00:00Z",
            Icon: new("Embedded", Data: Convert.ToBase64String(icon), Sha256: Identity.Hash(icon)), FreshSession: schema == 2)], "true\n123\n\u00e9");
        File.WriteAllBytes(Path.Combine(fixture.Root, "input.json"), KitCodec.Write(kit));
        File.WriteAllBytes(Path.Combine(fixture.Root, "input.encrypted.json"), KitEncryption.Protect(kit, password, password));
        var result = await Execute(host, ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(repository, "tests", "fixtures", "KitInterop.ps1"), "-FixtureRoot", fixture.Root], TimeSpan.FromMinutes(3));
        testOutput.WriteLine(result.Output);
        Assert.True(result.ExitCode == 0, result.Output);
        var opened = KitCodec.Read(File.ReadAllBytes(Path.Combine(fixture.Root, "opened.json")));
        var fromLegacy = KitEncryption.Unlock(File.ReadAllBytes(Path.Combine(fixture.Root, "output.encrypted.json")), password);
        Assert.Equal(KitCodec.Write(kit), KitCodec.Write(opened));
        Assert.Equal(KitCodec.Write(kit), KitCodec.Write(fromLegacy));
    }

    [Fact]
    public async Task CompiledCliPreviewRenameExportAndRemoveKeepPermanentIdentityAndData()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        Assert.True(File.Exists(cli), "Build the compiled CLI before running compatibility tests.");
        async Task<(int ExitCode, string Output)> Command(params string[] arguments) => await Execute(cli, [.. arguments, "--isolated-root", fixture.Root]);
        var definition = new AppDefinition { DisplayName = "Synthetic CLI", Url = "https://example.com/", Notes = "2026-09-09T00:00:00Z" };
        var definitionPath = Path.Combine(fixture.Root, "definition.json");
        File.WriteAllBytes(definitionPath, JsonSerializer.SerializeToUtf8Bytes(definition, StrictJson.Options));
        var preview = await Command("save", "--file", definitionPath, "--preview");
        Assert.True(preview.ExitCode == 0, preview.Output);
        Assert.False(Directory.Exists(fixture.Layout.DataRoot));
        foreach (var forbidden in new[] { new[] { "launch", "--id", definition.Id, "--yes" }, new[] { "check-updates" } })
        {
            var blocked = await Command(forbidden);
            Assert.Equal(3, blocked.ExitCode);
            Assert.Contains("disabled in isolated test mode", blocked.Output);
        }
        Assert.False(Directory.Exists(fixture.Layout.DataRoot));
        Directory.CreateDirectory(fixture.Layout.DataRoot);
        File.WriteAllText(Path.Combine(fixture.Layout.DataRoot, "preferences.json"), "{\"Diagnostics\":true}");
        var saved = await Command("save", "--file", definitionPath, "--yes");
        Assert.True(saved.ExitCode == 0, saved.Output);
        var logPath = Path.Combine(fixture.Layout.DataRoot, "Logs", "events.jsonl");
        Assert.True(File.Exists(logPath), "Opted-in compiled writes did not record diagnostic categories.");
        var marker = Path.Combine(fixture.Layout.DataRoot, "Apps", definition.Id, "retained-data");
        File.WriteAllText(marker, "Never delete this");
        var renamed = await Command("rename", "--id", definition.Id, "--name", "Renamed CLI", "--yes");
        Assert.True(renamed.ExitCode == 0, renamed.Output);
        Assert.Contains(definition.Id, renamed.Output);
        Assert.True(File.Exists(Path.Combine(fixture.Layout.DesktopRoot, "Synthetic CLI.lnk")));
        Assert.False(File.Exists(Path.Combine(fixture.Layout.DesktopRoot, "Renamed CLI.lnk")));
        var outputPath = Path.Combine(fixture.Root, "export.json");
        var exported = await Command("kit-export", "--output", outputPath);
        Assert.True(exported.ExitCode == 0, exported.Output);
        var exportedKit = KitCodec.Read(File.ReadAllBytes(outputPath));
        Assert.Equal("Renamed CLI", Assert.Single(exportedKit.Apps).Name);
        Assert.Equal(definition.Notes, exportedKit.Apps[0].Notes);
        using var lockedLog = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.None);
        var removed = await Command("remove", "--id", definition.Id, "--yes");
        Assert.True(removed.ExitCode == 0, removed.Output);
        lockedLog.Dispose();
        var diagnosticLines = File.ReadAllLines(logPath);
        Assert.Equal(2, diagnosticLines.Length);
        foreach (var line in diagnosticLines)
        {
            using var diagnostic = JsonDocument.Parse(line);
            Assert.Equal(new[] { "Utc", "Operation", "Outcome" }, diagnostic.RootElement.EnumerateObject().Select(field => field.Name));
            Assert.Equal("Save", diagnostic.RootElement.GetProperty("Operation").GetString());
            Assert.Equal("Success", diagnostic.RootElement.GetProperty("Outcome").GetString());
            foreach (var privateValue in new[] { definition.DisplayName, definition.Url, definition.Notes, definition.Id, fixture.Root }) Assert.DoesNotContain(privateValue, line);
        }
        Assert.Equal("Never delete this", File.ReadAllText(marker));
        Assert.False(File.Exists(Path.Combine(fixture.Layout.DesktopRoot, "Synthetic CLI.lnk")));
        var listed = await Command("list");
        Assert.True(listed.ExitCode == 0, listed.Output);
        using var list = JsonDocument.Parse(listed.Output);
        Assert.Equal(0, list.RootElement.GetArrayLength());
    }

    [Fact]
    public async Task CompiledCliNamedSubsetsBindApprovalAndCheckWithoutWrites()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        async Task<(int ExitCode, string Output)> Command(params string[] arguments) => await Execute(cli, [.. arguments, "--isolated-root", fixture.Root]);
        var kitPath = Path.Combine(fixture.Root, "subset-kit.json");
        var kit = new AppKit(2, "Subset kit", [new("Alpha, Work", "https://example.com/", Notes: "Keep selected notes"), new("Bravo", "https://example.org/")]);
        File.WriteAllBytes(kitPath, KitCodec.Write(kit));
        const string selection = "[\"  alpha, work  \"]";
        var preview = await Command("kit-preview", "--file", kitPath, "--app-names", selection);
        Assert.True(preview.ExitCode == 0, preview.Output);
        using var plan = JsonDocument.Parse(preview.Output);
        Assert.Equal("Alpha, Work", Assert.Single(plan.RootElement.GetProperty("Rows").EnumerateArray()).GetProperty("Source").GetProperty("Name").GetString());
        var approval = plan.RootElement.GetProperty("Fingerprint").GetString()!;
        Assert.False(Directory.Exists(fixture.Layout.DataRoot));
        foreach (var invalid in new[] { "[]", "[\"Missing\"]", "[\"Alpha, Work\",\"alpha, work\"]", "[null]", "{}", "[\"\"]" })
        {
            var rejected = await Command("kit-preview", "--file", kitPath, "--app-names", invalid);
            Assert.Equal(3, rejected.ExitCode);
        }
        var changedSelection = await Command("kit-import", "--file", kitPath, "--app-names", "[\"Bravo\"]", "--approval", approval, "--yes");
        Assert.Equal(3, changedSelection.ExitCode);
        Assert.False(Directory.Exists(fixture.Layout.DataRoot));
        var malformed = System.Text.Json.Nodes.JsonNode.Parse(KitCodec.Write(kit))!;
        malformed["Apps"]![1]!["Url"] = "file:///C:/unselected";
        var malformedPath = Path.Combine(fixture.Root, "invalid-unselected.json");
        File.WriteAllText(malformedPath, malformed.ToJsonString());
        Assert.Equal(3, (await Command("kit-preview", "--file", malformedPath, "--app-names", selection)).ExitCode);
        Assert.False(Directory.Exists(fixture.Layout.DataRoot));

        var imported = await Command("kit-import", "--file", kitPath, "--app-names", selection, "--approval", approval, "--yes");
        Assert.True(imported.ExitCode == 0, imported.Output);
        var catalogPath = Path.Combine(fixture.Layout.DataRoot, "catalog.json");
        var catalogBytes = File.ReadAllBytes(catalogPath);
        using var catalog = JsonDocument.Parse(catalogBytes);
        var stored = Assert.Single(catalog.RootElement.GetProperty("Apps").EnumerateArray());
        var permanentId = stored.GetProperty("Definition").GetProperty("Id").GetString()!;
        Assert.Equal("Alpha, Work", stored.GetProperty("Definition").GetProperty("DisplayName").GetString());
        var checkedApps = await Command("check", "--app-names", selection);
        Assert.True(checkedApps.ExitCode == 0, checkedApps.Output);
        using var checkedRows = JsonDocument.Parse(checkedApps.Output);
        var healthy = Assert.Single(checkedRows.RootElement.EnumerateArray());
        Assert.Equal("Healthy", healthy.GetProperty("Status").GetString());
        Assert.Equal(permanentId, healthy.GetProperty("Id").GetString());
        Assert.Equal(catalogBytes, File.ReadAllBytes(catalogPath));
        Assert.False(File.Exists(Path.Combine(fixture.Layout.DesktopRoot, "Bravo.lnk")));
        var exportedPath = Path.Combine(fixture.Root, "selected-export.json");
        var exported = await Command("kit-export", "--output", exportedPath, "--app-names", selection);
        Assert.True(exported.ExitCode == 0, exported.Output);
        Assert.Equal("Keep selected notes", Assert.Single(KitCodec.Read(File.ReadAllBytes(exportedPath)).Apps).Notes);
        var shortcut = Path.Combine(fixture.Layout.DesktopRoot, "Alpha, Work.lnk");
        File.Delete(shortcut);
        var missing = await Command("check", "--app-names", selection);
        Assert.True(missing.ExitCode == 0, missing.Output);
        using var missingRows = JsonDocument.Parse(missing.Output);
        Assert.True(Assert.Single(missingRows.RootElement.EnumerateArray()).GetProperty("CanRepair").GetBoolean());
        var repairPreview = await Command("repair", "--app-names", selection, "--preview");
        Assert.True(repairPreview.ExitCode == 0, repairPreview.Output);
        Assert.False(File.Exists(shortcut));
        Assert.Equal(catalogBytes, File.ReadAllBytes(catalogPath));
        var repaired = await Command("repair", "--app-names", selection, "--yes");
        Assert.True(repaired.ExitCode == 0, repaired.Output);
        using var repairRows = JsonDocument.Parse(repaired.Output);
        Assert.Equal("Repaired", Assert.Single(repairRows.RootElement.EnumerateArray()).GetProperty("Status").GetString());
        Assert.True(File.Exists(shortcut));
        Assert.Contains(permanentId, (await Command("list")).Output);
        Assert.Equal(3, (await Command("check", "--id", permanentId, "--app-names", selection)).ExitCode);
        Assert.Equal(3, (await Command("repair", "--yes")).ExitCode);
    }

    [Fact]
    public async Task CompiledCliNamedSavePreservesOmittedLocalChoicesAndSupportsExplicitChanges()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        async Task<(int ExitCode, string Output)> Command(params string[] arguments) => await Execute(cli, [.. arguments, "--isolated-root", fixture.Root]);
        Directory.CreateDirectory(fixture.Layout.DataRoot);
        File.WriteAllText(Path.Combine(fixture.Layout.DataRoot, "preferences.json"), "{\"DefaultProfile\":\"Profile 3\",\"DefaultDesktop\":false}");
        var preview = await Command("save", "--name", "Named CLI", "--url", "https://example.com/", "--preview");
        Assert.True(preview.ExitCode == 0, preview.Output);
        using var proposed = JsonDocument.Parse(preview.Output);
        Assert.Equal("Profile 3", proposed.RootElement.GetProperty("EdgeProfile").GetString());
        Assert.True(proposed.RootElement.GetProperty("Desktop").GetBoolean());
        Assert.False(File.Exists(Path.Combine(fixture.Layout.DataRoot, "catalog.json")));
        var saved = await Command("save", "--name", "Named CLI", "--url", "https://example.com/", "--notes", "Retained notes", "--profile-mode", "Dedicated", "--session-mode", "Fresh", "--launch-mode", "Maximized", "--always-on-top", "true", "--desktop", "false", "--yes");
        Assert.True(saved.ExitCode == 0, saved.Output);
        using var savedRecord = JsonDocument.Parse(saved.Output);
        var id = savedRecord.RootElement.GetProperty("Definition").GetProperty("Id").GetString()!;
        var updated = await Command("save", "--name", "named cli", "--url", "http://example.com/changed", "--yes");
        Assert.True(updated.ExitCode == 0, updated.Output);
        using var updatedRecord = JsonDocument.Parse(updated.Output);
        var definition = updatedRecord.RootElement.GetProperty("Definition");
        Assert.Equal(id, definition.GetProperty("Id").GetString());
        Assert.Equal("Named CLI", definition.GetProperty("DisplayName").GetString());
        Assert.Equal("Retained notes", definition.GetProperty("Notes").GetString());
        Assert.Equal("Profile 3", definition.GetProperty("EdgeProfile").GetString());
        Assert.False(definition.GetProperty("Desktop").GetBoolean());
        Assert.Equal("Maximized", definition.GetProperty("Window").GetProperty("LaunchMode").GetString());
        Assert.True(definition.GetProperty("Window").GetProperty("FreshSession").GetBoolean());
        Assert.True(definition.GetProperty("Window").GetProperty("AlwaysOnTop").GetBoolean());
        var path = Path.Combine(fixture.Layout.DataRoot, "catalog.json");
        var beforeInvalid = File.ReadAllBytes(path);
        foreach (var invalid in new[] { new[] { "--profile-mode", "Shared", "--session-mode", "Normal" }, new[] { "--always-on-top", "maybe" }, new[] { "--launch-mode", "1" } })
        {
            var failed = await Command(["save", "--name", "Named CLI", .. invalid, "--yes"]);
            Assert.Equal(3, failed.ExitCode);
            Assert.Equal(beforeInvalid, File.ReadAllBytes(path));
        }
        var shared = await Command("save", "--name", "Named CLI", "--profile-mode", "Shared", "--session-mode", "Normal", "--always-on-top", "false", "--edge-profile", "", "--desktop", "true", "--yes");
        Assert.True(shared.ExitCode == 0, shared.Output);
        using var sharedRecord = JsonDocument.Parse(shared.Output);
        var sharedDefinition = sharedRecord.RootElement.GetProperty("Definition");
        Assert.Equal("", sharedDefinition.GetProperty("EdgeProfile").GetString());
        Assert.False(sharedDefinition.GetProperty("Window").GetProperty("DedicatedProfile").GetBoolean());
        Assert.Equal(id, sharedDefinition.GetProperty("Id").GetString());
        Assert.Equal(0, (await Command("launch", "--name", "named cli", "--preview")).ExitCode);
        var priorLaunch = File.ReadAllBytes(path);
        Assert.Equal(3, (await Command("save", "--name", "Named CLI", "--launch", "--yes")).ExitCode);
        Assert.Equal(priorLaunch, File.ReadAllBytes(path));
        Assert.Equal(3, (await Command("settings", "--url", "https://example.org/")).ExitCode);
        var removed = await Command("remove", "--name", "Named CLI", "--yes");
        Assert.True(removed.ExitCode == 0, removed.Output);
    }

    [Fact]
    public async Task CompiledCliIconChoicesAndTaskbarRequestsRemainExplicit()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        async Task<(int ExitCode, string Output)> Command(params string[] arguments) => await Execute(cli, [.. arguments, "--isolated-root", fixture.Root]);
        var preview = await Command("save", "--name", "CLI tools", "--url", "https://example.com/", "--taskbar", "true", "--fetch-icon", "--preview");
        Assert.True(preview.ExitCode == 0, preview.Output);
        using var proposed = JsonDocument.Parse(preview.Output);
        Assert.True(proposed.RootElement.GetProperty("Window").GetProperty("Taskbar").GetBoolean());
        Assert.True(proposed.RootElement.GetProperty("Window").GetProperty("DedicatedProfile").GetBoolean());
        Assert.True(proposed.RootElement.GetProperty("StartMenu").GetBoolean());
        Assert.Equal("Custom", proposed.RootElement.GetProperty("IconKind").GetString());
        Assert.False(Directory.Exists(fixture.Layout.DataRoot));
        var blockedFetch = await Command("save", "--name", "CLI tools", "--url", "https://example.com/", "--fetch-icon", "--yes");
        Assert.Equal(3, blockedFetch.ExitCode);
        Assert.Contains("disabled in isolated test mode", blockedFetch.Output);
        Assert.False(Directory.Exists(fixture.Layout.DataRoot));
        var iconPath = Path.Combine(fixture.Root, "custom.ico");
        var customIcon = IconService.Generate("Different");
        File.WriteAllBytes(iconPath, customIcon);
        var saved = await Command("save", "--name", "CLI tools", "--url", "https://example.com/", "--icon", iconPath, "--yes");
        Assert.True(saved.ExitCode == 0, saved.Output);
        using var savedRecord = JsonDocument.Parse(saved.Output);
        var id = savedRecord.RootElement.GetProperty("Definition").GetProperty("Id").GetString()!;
        var catalogPath = Path.Combine(fixture.Layout.DataRoot, "catalog.json");
        var beforeInvalid = File.ReadAllBytes(catalogPath);
        foreach (var choices in new[] { new[] { "--icon", iconPath, "--fetch-icon" }, new[] { "--fetch-icon", "--reset-icon" }, new[] { "--icon", iconPath, "--reset-icon" }, new[] { "--taskbar", "true", "--profile-mode", "Shared" }, new[] { "--taskbar", "true", "--start-menu", "false" } })
        {
            Assert.Equal(3, (await Command(["save", "--name", "CLI tools", .. choices, "--yes"])).ExitCode);
            Assert.Equal(beforeInvalid, File.ReadAllBytes(catalogPath));
        }
        var reset = await Command("save", "--name", "CLI tools", "--reset-icon", "--yes");
        Assert.True(reset.ExitCode == 0, reset.Output);
        using var resetRecord = JsonDocument.Parse(reset.Output);
        Assert.Equal(id, resetRecord.RootElement.GetProperty("Definition").GetProperty("Id").GetString());
        Assert.Equal("Generated", resetRecord.RootElement.GetProperty("Definition").GetProperty("IconKind").GetString());
        Assert.NotEqual(savedRecord.RootElement.GetProperty("Files").GetProperty("Icon").GetString(), resetRecord.RootElement.GetProperty("Files").GetProperty("Icon").GetString());
        var taskbarSave = await Command("save", "--name", "CLI tools", "--taskbar", "true", "--yes");
        Assert.True(taskbarSave.ExitCode == 0, taskbarSave.Output);
        Assert.Contains("Pin requests are disabled in isolated test mode.", taskbarSave.Output);
        var pinPreview = await Command("pin", "--name", "CLI tools", "--preview");
        Assert.True(pinPreview.ExitCode == 0, pinPreview.Output);
        Assert.Contains("Would request a Windows taskbar pin", pinPreview.Output);
        var beforePin = File.ReadAllBytes(catalogPath);
        var blockedPin = await Command("pin", "--id", id, "--yes");
        Assert.Equal(3, blockedPin.ExitCode);
        Assert.Contains("disabled in isolated test mode", blockedPin.Output);
        Assert.Equal(beforePin, File.ReadAllBytes(catalogPath));
        var cleared = await Command("save", "--name", "CLI tools", "--taskbar", "false", "--yes");
        Assert.True(cleared.ExitCode == 0, cleared.Output);
        using var clearedRecord = JsonDocument.Parse(cleared.Output);
        Assert.False(clearedRecord.RootElement.GetProperty("Definition").GetProperty("Window").GetProperty("Taskbar").GetBoolean());
        Assert.True(clearedRecord.RootElement.GetProperty("Definition").GetProperty("Window").GetProperty("DedicatedProfile").GetBoolean());
        Assert.True(clearedRecord.RootElement.GetProperty("Definition").GetProperty("StartMenu").GetBoolean());
        Assert.Equal(3, (await Command("pin", "--name", "CLI tools", "--preview")).ExitCode);
    }

    [Theory]
    [InlineData("")]
    [InlineData("Invalid/name")]
    [InlineData("NUL")]
    public async Task FavoritesNameSelectionIgnoresUnrelatedUnusableTitles(string unusableName)
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        var bookmarks = Path.Combine(fixture.Root, "Bookmarks");
        var source = JsonSerializer.SerializeToUtf8Bytes(new
        {
            roots = new
            {
                bookmark_bar = new
                {
                    type = "folder",
                    children = new[]
                    {
                        new { type = "url", name = unusableName, url = "http://intranet.example/" },
                        new { type = "url", name = "Mail", url = "https://mail.example/" }
                    }
                }
            }
        });
        File.WriteAllBytes(bookmarks, source);

        var result = await Execute(cli, ["favorites-preview", "--file", bookmarks, "--app-names", "[\"Mail\"]", "--isolated-root", fixture.Root]);

        Assert.True(result.ExitCode == 0, result.Output);
        using var selected = JsonDocument.Parse(result.Output);
        Assert.Equal("Mail", Assert.Single(selected.RootElement.EnumerateArray()).GetProperty("Name").GetString());
        Assert.Equal(source, File.ReadAllBytes(bookmarks));
        Assert.False(File.Exists(Path.Combine(fixture.Layout.DataRoot, "catalog.json")));
    }

    [Fact]
    public async Task CompiledCliFavoritesPreviewImportAndExportStayExplicitAndReadOnlyUntilApproval()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        async Task<(int ExitCode, string Output)> Command(params string[] arguments) => await Execute(cli, [.. arguments, "--isolated-root", fixture.Root]);
        var profileRoot = Path.Combine(fixture.Layout.DataRoot, "EdgeProfiles");
        var bookmarks = Path.Combine(profileRoot, "Profile 3", "Bookmarks");
        Directory.CreateDirectory(Path.GetDirectoryName(bookmarks)!);
        Directory.CreateDirectory(Path.Combine(profileRoot, "Default"));
        var source = """
            {"roots":{"bookmark_bar":{"type":"folder","name":"Favorites bar","children":[
              {"type":"url","name":"Work","url":"https://example.com/"},
              {"type":"url","name":"Second","url":"https://example.org/"},
              {"type":"url","name":"HTTP","url":"http://example.net/"}
            ]}}}
            """;
        File.WriteAllText(bookmarks, source);
        File.WriteAllText(Path.Combine(profileRoot, "Default", "Bookmarks"), source);
        File.WriteAllText(Path.Combine(profileRoot, "Local State"), "{\"profile\":{\"info_cache\":{\"Profile 3\":{\"name\":\"Work profile\"}}}}");
        var originalBytes = File.ReadAllBytes(bookmarks);
        var profiles = await Command("profiles");
        Assert.True(profiles.ExitCode == 0, profiles.Output);
        using var profileList = JsonDocument.Parse(profiles.Output);
        Assert.Equal(2, profileList.RootElement.GetArrayLength());
        Assert.Contains("Work profile", profiles.Output);
        Assert.Equal(3, (await Command("favorites-preview")).ExitCode);
        File.WriteAllText(Path.Combine(fixture.Layout.DataRoot, "preferences.json"), "{\"DefaultProfile\":\"Profile 3\"}");
        var candidates = await Command("favorites-preview");
        Assert.True(candidates.ExitCode == 0, candidates.Output);
        using var candidateList = JsonDocument.Parse(candidates.Output);
        Assert.Equal(3, candidateList.RootElement.GetArrayLength());
        Assert.False(candidateList.RootElement[2].GetProperty("CanImport").GetBoolean());
        Assert.Equal(3, (await Command("favorites-preview", "--file", bookmarks, "--edge-profile", "Profile 3")).ExitCode);
        Assert.Equal(3, (await Command("favorites-preview", "--edge-profile", "../Default")).ExitCode);
        const string selection = "[\"Work\"]";
        var preview = await Command("favorites-import", "--edge-profile", "Profile 3", "--app-names", selection, "--desktop", "false", "--preview");
        Assert.True(preview.ExitCode == 0, preview.Output);
        using var plan = JsonDocument.Parse(preview.Output);
        Assert.True(plan.RootElement.GetProperty("NewOnly").GetBoolean());
        var effective = Assert.Single(plan.RootElement.GetProperty("Rows").EnumerateArray()).GetProperty("Effective");
        Assert.Equal("Profile 3", effective.GetProperty("EdgeProfile").GetString());
        Assert.False(effective.GetProperty("Desktop").GetBoolean());
        var approval = plan.RootElement.GetProperty("Fingerprint").GetString()!;
        var catalogPath = Path.Combine(fixture.Layout.DataRoot, "catalog.json");
        Assert.False(File.Exists(catalogPath));
        File.WriteAllText(bookmarks, source.Replace("https://example.com/", "https://example.com/changed"));
        Assert.Equal(3, (await Command("favorites-import", "--edge-profile", "Profile 3", "--app-names", selection, "--desktop", "false", "--approval", approval, "--yes")).ExitCode);
        Assert.False(File.Exists(catalogPath));
        File.WriteAllBytes(bookmarks, originalBytes);
        Assert.Equal(3, (await Command("favorites-import", "--file", bookmarks, "--app-names", "[\"HTTP\"]", "--preview")).ExitCode);
        Assert.Equal(3, (await Command("favorites-import", "--file", bookmarks, "--app-names", selection, "--approval", approval, "--yes")).ExitCode);
        Assert.False(File.Exists(catalogPath));
        var imported = await Command("favorites-import", "--file", bookmarks, "--app-names", selection, "--desktop", "false", "--approval", approval, "--yes");
        Assert.True(imported.ExitCode == 0, imported.Output);
        using var catalog = JsonDocument.Parse(File.ReadAllBytes(catalogPath));
        Assert.Equal("Work", Assert.Single(catalog.RootElement.GetProperty("Apps").EnumerateArray()).GetProperty("Definition").GetProperty("DisplayName").GetString());
        Assert.False(File.Exists(Path.Combine(fixture.Layout.DesktopRoot, "Work.lnk")));
        Assert.True(File.Exists(Path.Combine(fixture.Layout.ProgramsRoot, "Work.lnk")));
        Assert.Equal(originalBytes, File.ReadAllBytes(bookmarks));
        var outputPath = Path.Combine(fixture.Root, "export.json");
        File.WriteAllText(outputPath, "Keep existing export until explicitly replaced");
        var originalExport = File.ReadAllBytes(outputPath);
        var refused = await Command("kit-export", "--output", outputPath, "--notes", "Kit-level notes");
        Assert.Equal(3, refused.ExitCode);
        Assert.Equal(originalExport, File.ReadAllBytes(outputPath));
        var exported = await Command("kit-export", "--output", outputPath, "--name", "Selected sites", "--notes", "Kit-level notes", "--force");
        Assert.True(exported.ExitCode == 0, exported.Output);
        var exportedKit = KitCodec.Read(File.ReadAllBytes(outputPath));
        Assert.Equal("Selected sites", exportedKit.Name);
        Assert.Equal("Kit-level notes", exportedKit.Notes);
        var favoriteKit = await Command("favorites-kit", "--file", bookmarks, "--app-names", "[\"Second\"]", "--output", outputPath, "--force");
        Assert.True(favoriteKit.ExitCode == 0, favoriteKit.Output);
        Assert.Equal("Second", Assert.Single(KitCodec.Read(File.ReadAllBytes(outputPath)).Apps).Name);
        Assert.Equal(originalBytes, File.ReadAllBytes(bookmarks));
    }

    [Theory]
    [InlineData("source")]
    [InlineData("catalog")]
    [InlineData("profile")]
    [InlineData("shortcut")]
    public async Task CompiledCliExportsNeverReplaceSourcesOrManagedState(string destination)
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        var bookmarks = Path.Combine(fixture.Root, "Bookmarks");
        var source = """
            {"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"url","name":"Synthetic","url":"https://example.com/"}]}}}
            """u8.ToArray();
        File.WriteAllBytes(bookmarks, source);
        var output = destination switch
        {
            "source" => bookmarks,
            "catalog" => Path.Combine(fixture.Layout.DataRoot, "catalog.json"),
            "profile" => Path.Combine(fixture.Layout.LegacyRoot!, "Apps", Identity.LegacyId("Retained"), "AppProfile", "Cookies"),
            _ => Path.Combine(fixture.Layout.ProgramsRoot, "Protected.lnk")
        };
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        if (destination != "source") File.WriteAllBytes(output, destination == "catalog" ? JsonSerializer.SerializeToUtf8Bytes(new Catalog(), StrictJson.Options) : "synthetic retained bytes"u8.ToArray());
        var original = File.ReadAllBytes(output);
        var result = await Execute(cli, ["favorites-kit", "--file", bookmarks, "--output", output, "--force", "--isolated-root", fixture.Root]);
        Assert.Equal(3, result.ExitCode);
        Assert.Equal(original, File.ReadAllBytes(output));
        Assert.Equal(source, File.ReadAllBytes(bookmarks));
    }

    [Fact]
    public async Task CompiledPortableCommandsRejectUnsignedPayloadsAndRequireExplicitWrites()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        async Task<(int ExitCode, string Output)> Command(params string[] arguments) => await Execute(cli, [.. arguments, "--isolated-root", fixture.Root]);
        var current = Path.Combine(fixture.Root, "Portable");
        var stage = Path.Combine(fixture.Root, "Staged");
        Directory.CreateDirectory(current);
        Directory.CreateDirectory(stage);
        var original = "Unsigned synthetic release index"u8.ToArray();
        File.WriteAllBytes(Path.Combine(current, "EasyEdgeApps.PackageIndex.dll"), original);
        File.WriteAllBytes(Path.Combine(stage, "EasyEdgeApps.PackageIndex.dll"), original);
        var next = new StagedPackage(stage, "2.0.0", new string('a', 64), "1.4.0");
        var previous = new StagedPackage(current, "1.4.0", new string('b', 64), "1.4.0");
        var publisher = new string('a', 40);
        var stagePath = Path.Combine(fixture.Root, "staged.json");
        File.WriteAllBytes(stagePath, JsonSerializer.SerializeToUtf8Bytes(next, StrictJson.Options));
        var help = await Execute(cli, ["--help"]);
        Assert.Contains("portable-preview", help.Output);
        var preview = await Command("portable-preview", "--file", stagePath, "--directory", current, "--publisher", publisher);
        Assert.Equal(3, preview.ExitCode);
        Assert.DoesNotContain("Unknown", preview.Output);
        Assert.False(Directory.Exists(Path.Combine(fixture.Root, ".Portable.updates")));
        var plan = new PortablePlan(current, previous, next, publisher, "");
        plan = plan with { Fingerprint = Identity.Hash(JsonSerializer.SerializeToUtf8Bytes(new { plan.Directory, plan.Previous, plan.Next, plan.Publisher }, StrictJson.Options)) };
        var planPath = Path.Combine(fixture.Root, "approved.json");
        File.WriteAllBytes(planPath, JsonSerializer.SerializeToUtf8Bytes(plan, StrictJson.Options));
        var unapproved = await Command("portable-activate", "--file", planPath, "--publisher", publisher);
        Assert.Equal(3, unapproved.ExitCode);
        Assert.Contains("--yes", unapproved.Output);
        Assert.False(Directory.Exists(Path.Combine(fixture.Root, ".Portable.updates")));
        Assert.Equal(3, (await Command("portable-activate", "--file", planPath, "--publisher", publisher, "--yes")).ExitCode);
        foreach (var command in new[] { "portable-rollback", "portable-recover" })
        {
            var unapprovedRecovery = await Command(command, "--directory", current, "--receipt", Path.Combine(fixture.Root, "receipt.json"), "--publisher", publisher);
            Assert.Equal(3, unapprovedRecovery.ExitCode);
            Assert.Contains("--yes", unapprovedRecovery.Output);
        }
        Assert.Equal(original, File.ReadAllBytes(Path.Combine(current, "EasyEdgeApps.PackageIndex.dll")));
        Assert.Equal(original, File.ReadAllBytes(Path.Combine(stage, "EasyEdgeApps.PackageIndex.dll")));
        Assert.False(File.Exists(Path.Combine(fixture.Layout.DataRoot, "catalog.json")));
    }

    [Fact]
    public async Task CompiledPortableRecordsAreStrictAndConfinedBeforeInspection()
    {
        using var fixture = new TestDirectory();
        using var outside = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        async Task<(int ExitCode, string Output)> Command(params string[] arguments) => await Execute(cli, [.. arguments, "--isolated-root", fixture.Root]);
        var current = Path.Combine(fixture.Root, "Portable");
        var staged = Path.Combine(fixture.Root, "Staged");
        var publisher = new string('a', 40);
        var recordPath = Path.Combine(fixture.Root, "record.json");
        Directory.CreateDirectory(current);
        Directory.CreateDirectory(staged);
        File.WriteAllBytes(recordPath, JsonSerializer.SerializeToUtf8Bytes(new { Directory = staged, IndexHash = new string('a', 64), SourceVersion = "1.4.0" }));
        var missing = await Command("portable-preview", "--file", recordPath, "--directory", current, "--publisher", publisher);
        Assert.Equal(3, missing.ExitCode);
        Assert.Contains("Version", missing.Output);
        File.WriteAllBytes(recordPath, JsonSerializer.SerializeToUtf8Bytes(new
        {
            Directory = current,
            Previous = new StagedPackage(current, "1.4.0", new string('b', 64), "1.4.0"),
            Next = new { Directory = staged, Version = "2.0.0", IndexHash = new string('a', 64) },
            Publisher = publisher,
            Fingerprint = new string('c', 64)
        }));
        var nested = await Command("portable-activate", "--file", recordPath, "--publisher", publisher, "--yes");
        Assert.Equal(3, nested.ExitCode);
        Assert.Contains("SourceVersion", nested.Output);
        var externalRecord = Path.Combine(outside.Root, "record.json");
        File.WriteAllText(externalRecord, "Synthetic outside-fixture input must not be parsed");
        var confined = await Command("portable-preview", "--file", externalRecord, "--directory", current, "--publisher", publisher);
        Assert.Equal(3, confined.ExitCode);
        Assert.Contains("fixture root", confined.Output);
        File.WriteAllBytes(recordPath, JsonSerializer.SerializeToUtf8Bytes(new StagedPackage(outside.Root, "2.0.0", new string('a', 64), "1.4.0"), StrictJson.Options));
        var outsideStage = await Command("portable-preview", "--file", recordPath, "--directory", current, "--publisher", publisher);
        Assert.Equal(3, outsideStage.ExitCode);
        Assert.Contains("fixture root", outsideStage.Output);
        Assert.False(Directory.Exists(Path.Combine(fixture.Root, ".Portable.updates")));
        Assert.Equal("Synthetic outside-fixture input must not be parsed", File.ReadAllText(externalRecord));
        Assert.Empty(Directory.EnumerateFileSystemEntries(current));
        Assert.Empty(Directory.EnumerateFileSystemEntries(staged));
    }

    [Fact]
    public async Task RecoveryAndSupportRemainAvailableWithACorruptCatalog()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var cli = Path.Combine(repository, "src", "EasyEdgeApps.Cli", "bin", configuration, "net10.0-windows10.0.19041.0", "eea.exe");
        Directory.CreateDirectory(fixture.Layout.DataRoot);
        File.WriteAllText(Path.Combine(fixture.Layout.DataRoot, "catalog.json"), "corrupt synthetic private content");
        foreach (var command in new[] { "recovery-list", "support", "settings" })
        {
            var result = await Execute(cli, [command, "--isolated-root", fixture.Root]);
            Assert.True(result.ExitCode == 0, command + ": " + result.Output);
            Assert.DoesNotContain("private content", result.Output);
            using var document = JsonDocument.Parse(result.Output);
        }
    }

    private static async Task<(int ExitCode, string Output)> Execute(string executable, string[] arguments, TimeSpan? timeout = null)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileName(executable).Equals("powershell.exe", StringComparison.OrdinalIgnoreCase))
            start.Environment["PSModulePath"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "Modules");
        else if (Path.GetFileName(executable).Equals("pwsh.exe", StringComparison.OrdinalIgnoreCase)) start.Environment.Remove("PSModulePath");
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        using var deadline = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(90));
        try { await process.WaitForExitAsync(deadline.Token); }
        catch (OperationCanceledException) { process.Kill(true); await process.WaitForExitAsync(); throw new TimeoutException("Synthetic compatibility command exceeded its deadline.\n" + await output + await errors); }
        return (process.ExitCode, await output + await errors);
    }
}