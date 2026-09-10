using System.Diagnostics;
using System.Drawing.Imaging;
using EasyEdgeApps.Core;
using EasyEdgeApps.Core.Tests;
using EasyEdgeApps.Persistence;
using EasyEdgeApps.SiteLauncher;
using EasyEdgeApps.Windows;

namespace EasyEdgeApps.Windows.Tests;

public sealed class DesktopTests
{
    [Fact]
    public void InspectionDistinguishesOutdatedLaunchersMissingEdgeAndForeignChanges()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(Path.GetDirectoryName(fixture.Root)!)!.FullName;
        var originalTemplate = Path.Combine(repository, "src", "EasyEdgeApps.SiteLauncher", "bin", "Release", "net48", "fresh-session.exe");
        var template = Path.Combine(fixture.Root, "template.exe");
        File.Copy(originalTemplate, template);
        var edge = Path.Combine(fixture.Root, "Edge", "msedge.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(edge)!);
        File.WriteAllBytes(edge, "MZ synthetic Edge; never execute"u8.ToArray());
        var store = new CatalogStore(fixture.Layout, new DesktopArtifacts(template, () => edge));
        var saved = store.Save(new() { DisplayName = "Inspection", Url = "https://example.com/" }, SafeFiles.Missing);
        var before = store.Read().Hash;
        var healthy = new DesktopInspection(store, template, () => edge).Check(saved);
        Assert.Equal("Healthy", healthy.Status);
        Assert.False(healthy.CanRepair);
        Assert.Equal("Dedicated app profile (persistent)", healthy.BrowsingMode);
        using (var changed = new FileStream(template, FileMode.Append)) changed.WriteByte(0);
        var outdated = new DesktopInspection(store, template, () => edge).Check(saved);
        Assert.Equal("Repairable", outdated.Status);
        Assert.True(outdated.CanRepair);
        Assert.Contains(outdated.Issues, issue => issue.Contains("launcher", StringComparison.OrdinalIgnoreCase));
        File.Copy(originalTemplate, template, true);
        var relocatedEdge = Path.Combine(fixture.Root, "New Edge", "msedge.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(relocatedEdge)!);
        File.Copy(edge, relocatedEdge);
        var moved = new DesktopInspection(store, template, () => relocatedEdge).Check(saved);
        Assert.Equal("Repairable", moved.Status);
        Assert.Contains(moved.Issues, issue => issue.Contains("Edge executable", StringComparison.Ordinal));
        File.Delete(edge);
        var blocked = new DesktopInspection(store, template, () => edge).Check(saved);
        Assert.Equal("Blocked", blocked.Status);
        Assert.False(blocked.CanRepair);
        var icon = fixture.Layout.Resolve(CatalogStore.Address(saved, "Icon"));
        File.WriteAllText(icon, "foreign icon bytes");
        var foreign = new DesktopInspection(store, template, () => edge).Check(saved);
        Assert.Equal("Conflict", foreign.Status);
        Assert.False(foreign.CanRepair);
        Assert.Equal("foreign icon bytes", File.ReadAllText(icon));
        Assert.Equal(before, store.Read().Hash);
    }

    [Fact]
    public void InspectionReportsUnownedFoldersAndMissingRuntimeWithoutAdoption()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(Path.GetDirectoryName(fixture.Root)!)!.FullName;
        var template = Path.Combine(repository, "src", "EasyEdgeApps.SiteLauncher", "bin", "Release", "net48", "fresh-session.exe");
        var id = Identity.NewId();
        var retained = fixture.Layout.Resolve(new(StorageArea.Data, $"Apps/{id}/AppProfile/Cookies"));
        SafeFiles.AtomicWrite(retained, "synthetic unowned data"u8.ToArray());
        var store = new CatalogStore(fixture.Layout, new DesktopArtifacts(template));
        var inspection = new DesktopInspection(store, template, () => throw new ValidationException("Synthetic missing Edge"));
        var results = inspection.ReadAll(store.Read());
        var orphan = Assert.Single(results, result => result.Id == id);
        Assert.Equal("Conflict", orphan.Status);
        Assert.False(orphan.CanRepair);
        Assert.Contains(results, result => result.Name == "Microsoft Edge" && result.Status == "Blocked" && !result.CanRepair);
        Assert.Equal("synthetic unowned data", File.ReadAllText(retained));
        Assert.False(File.Exists(Path.Combine(fixture.Layout.DataRoot, "catalog.json")));
        Assert.False(Directory.Exists(Path.Combine(fixture.Layout.DataRoot, ".transactions")));
    }

    [Theory]
    [InlineData(ApartmentState.STA)]
    [InlineData(ApartmentState.MTA)]
    public void RepeatedShortcutCreationReleasesWritersAndPreservesIdentity(ApartmentState apartment)
    {
        using var fixture = new TestDirectory();
        Exception? failure = null;
        var worker = new Thread(() =>
        {
            try
            {
                var target = Path.Combine(fixture.Root, "fresh-session.exe");
                var icon = Path.Combine(fixture.Root, "website.ico");
                for (var iteration = 0; iteration < 16; iteration++)
                {
                    var id = Identity.NewId();
                    var path = Path.Combine(fixture.Root, "shortcut-" + iteration + ".lnk");
                    var bytes = Shortcuts.Create(path, target, icon, id);
                    Assert.Equal(bytes, File.ReadAllBytes(path));
                    var metadata = Shortcuts.Read(path);
                    Assert.Equal(target, metadata.Target);
                    Assert.Equal("EasyEdgeApps.Website." + id, metadata.AppId);
                    Assert.Equal("EasyEdgeApps:" + id, metadata.Description);
                    Assert.Equal(icon + ",0", metadata.Icon);
                    Assert.Equal("", metadata.Arguments);
                    Assert.Equal(1, metadata.WindowStyle);
                    using var exclusive = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
                }
            }
            catch (Exception caught) { failure = caught; }
        }) { IsBackground = true };
        worker.SetApartmentState(apartment);
        worker.Start();
        Assert.True(worker.Join(TimeSpan.FromSeconds(15)), "Shortcut creation exceeded its bounded fixture deadline.");
        if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
    }

    [Theory]
    [InlineData(ApartmentState.STA)]
    [InlineData(ApartmentState.MTA)]
    public void ArtifactPreparationDoesNotRequireTemporaryShortcutFiles(ApartmentState apartment)
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(Path.GetDirectoryName(fixture.Root)!)!.FullName;
        var template = Path.Combine(repository, "src", "EasyEdgeApps.SiteLauncher", "bin", "Release", "net48", "fresh-session.exe");
        Directory.CreateDirectory(fixture.Layout.DataRoot);
        var unrelated = Path.Combine(fixture.Layout.DataRoot, ".artifact-stage");
        File.WriteAllText(unrelated, "Artifact preparation must not touch this path");
        Exception? failure = null;
        var worker = new Thread(() =>
        {
            try
            {
                var record = new AppRecord { Definition = new() { DisplayName = "In-memory link", Url = "https://example.com/" }, ShortcutName = "In-memory link" };
                var artifacts = new DesktopArtifacts(template, () => @"C:\Synthetic\msedge.exe").Build(record, fixture.Layout, IconService.Generate(record.Definition.DisplayName), false);
                foreach (var slot in new[] { "Desktop", "StartMenu" })
                {
                    var path = Path.Combine(fixture.Root, slot + ".lnk");
                    File.WriteAllBytes(path, artifacts.Files[slot]);
                    var shortcut = Shortcuts.Read(path);
                    Assert.Equal(fixture.Layout.Resolve(CatalogStore.Address(record, "Launcher")), shortcut.Target);
                    Assert.Equal("EasyEdgeApps.Website." + record.Definition.Id, shortcut.AppId);
                    Assert.Equal("EasyEdgeApps:" + record.Definition.Id, shortcut.Description);
                    Assert.Equal(fixture.Layout.Resolve(CatalogStore.Address(record, "Icon")) + ",0", shortcut.Icon);
                    Assert.Equal("", shortcut.Arguments);
                    Assert.Equal(1, shortcut.WindowStyle);
                    using var exclusive = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
                }
                Assert.Equal("Artifact preparation must not touch this path", File.ReadAllText(unrelated));
            }
            catch (Exception caught) { failure = caught; }
        }) { IsBackground = true };
        worker.SetApartmentState(apartment);
        worker.Start();
        Assert.True(worker.Join(TimeSpan.FromSeconds(15)), "In-memory artifact preparation exceeded its deadline.");
        if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
    }

    [Theory]
    [InlineData(".png")]
    [InlineData(".jpg")]
    public void RasterIconsConvertToLegacyRenderableBoundedIco(string extension)
    {
        using var source = new Bitmap(512, 256);
        using (var drawing = Graphics.FromImage(source)) drawing.Clear(Color.Coral);
        using var stream = new MemoryStream();
        source.Save(stream, extension == ".png" ? ImageFormat.Png : ImageFormat.Jpeg);
        var converted = IconService.Convert(stream.ToArray(), extension);
        IconService.Validate(converted);
        Assert.InRange(converted.Length, 22, 1048576);
        using var icon = new Icon(new MemoryStream(converted));
        using var bitmap = icon.ToBitmap();
        Assert.True(bitmap.GetPixel(128, 128).R > 150);
    }

    [Fact]
    public void OversizedIconsAndCancellationRejectBeforeChangingPriorIcon()
    {
        var prior = IconService.Generate("News");
        var hash = Identity.Hash(prior);
        Assert.Throws<ValidationException>(() => IconService.Convert(new byte[IconService.MaximumInputBytes + 1], ".png"));
        Assert.Throws<OperationCanceledException>(() => IconService.Convert(prior, ".ico", new CancellationToken(true)));
        Assert.Equal(hash, Identity.Hash(prior));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void PrebuiltSitesUseIdenticalBytesDistinctIdentityAndNoBrowserForHealth(bool lts)
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(Path.GetDirectoryName(fixture.Root)!)!.FullName;
        var template = lts ? Path.Combine(repository, "artifacts", "launcher-net10-comparison", "fresh-session.exe") : Path.Combine(repository, "src", "EasyEdgeApps.SiteLauncher", "bin", "Release", "net48", "fresh-session.exe");
        Assert.True(File.Exists(template), "Build the prebuilt launcher before the Windows tests.");
        var store = new CatalogStore(fixture.Layout, new DesktopArtifacts(template, () => @"C:\Synthetic\msedge.exe"));
        var first = store.Save(new() { DisplayName = "First", Url = "https://example.com/" }, SafeFiles.Missing);
        var second = store.Save(new() { DisplayName = "Second", Url = "https://example.org/" }, store.Read().Hash);
        Assert.Equal(first.Files["Launcher"], second.Files["Launcher"]);
        Assert.Equal(SafeFiles.Hash(template), first.Files["Launcher"]);
        foreach (var record in new[] { first, second })
        {
            var link = Shortcuts.Read(fixture.Layout.Resolve(CatalogStore.Address(record, "StartMenu")));
            Assert.Equal("EasyEdgeApps.Website." + record.Definition.Id, link.AppId);
            Assert.Equal("", link.Arguments);
            var launcher = fixture.Layout.Resolve(CatalogStore.Address(record, "Launcher"));
            var configuration = LaunchConfiguration.Read(Path.GetDirectoryName(launcher), true);
            Assert.Equal(record.Definition.Id, configuration.Id);
            var start = new ProcessStartInfo(launcher) { UseShellExecute = false, ArgumentList = { "--health" } };
            start.Environment["DOTNET_BUNDLE_EXTRACT_BASE_DIR"] = Path.Combine(fixture.Root, "bundle-cache");
            using var health = Process.Start(start)!;
            Assert.True(health.WaitForExit(10000));
            Assert.Equal(0, health.ExitCode);
        }
    }

    [Fact]
    public void LauncherRejectsNoncanonicalNetworkAndStreamEdgePaths()
    {
        using var fixture = new TestDirectory();
        var app = new AppDefinition { DisplayName = "Local Edge", Url = "https://example.com/" };
        var path = fixture.Layout.Resolve(new(StorageArea.Data, $"Apps/{app.Id}/eea-launch.xml"));
        foreach (var edgePath in new[] { @"\\server\share\msedge.exe", @"\Edge\msedge.exe", @"C:msedge.exe", @"C:\Edge\..\Other\msedge.exe", @"C:\Edge\stream:payload\msedge.exe", @"\\?\C:\Edge\msedge.exe", "C:\\Edge\\bad\tpath\\msedge.exe" })
        {
            SafeFiles.AtomicWrite(path, DesktopArtifacts.Configuration(app, edgePath, new string('a', 64), "2.0.0-preview.1"));
            Assert.Throws<InvalidDataException>(() => LaunchConfiguration.Read(Path.GetDirectoryName(path), false));
        }
        SafeFiles.AtomicWrite(path, DesktopArtifacts.Configuration(app, @"C:\Synthetic\Microsoft Edge\msedge.exe", new string('a', 64), "2.0.0-preview.1"));
        Assert.Equal(@"C:\Synthetic\Microsoft Edge\msedge.exe", LaunchConfiguration.Read(Path.GetDirectoryName(path), false).EdgePath);
    }

    [Fact]
    public void ConfigurationRejectsIdentityChangesAndXmlEntities()
    {
        using var fixture = new TestDirectory();
        var app = new AppDefinition { DisplayName = "News", Url = "https://example.com/" };
        var path = fixture.Layout.Resolve(new(StorageArea.Data, $"Apps/{app.Id}/eea-launch.xml"));
        SafeFiles.AtomicWrite(path, DesktopArtifacts.Configuration(app, @"C:\Synthetic\msedge.exe", new string('a', 64), "2.0.0-preview.1"));
        Assert.Equal(app.Id, LaunchConfiguration.Read(Path.GetDirectoryName(path), false).Id);
        var xml = File.ReadAllText(path).Replace(app.Id, new string('b', 64), StringComparison.Ordinal);
        File.WriteAllText(path, xml);
        Assert.Throws<InvalidDataException>(() => LaunchConfiguration.Read(Path.GetDirectoryName(path), false));
        File.WriteAllText(path, "<!DOCTYPE root [<!ENTITY private SYSTEM 'file:///not-allowed'>]><root>&private;</root>");
        Assert.ThrowsAny<Exception>(() => LaunchConfiguration.Read(Path.GetDirectoryName(path), false));
    }
}