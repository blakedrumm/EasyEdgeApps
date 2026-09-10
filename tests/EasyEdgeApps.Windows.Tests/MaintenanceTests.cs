using System.Diagnostics;
using EasyEdgeApps.Core;
using EasyEdgeApps.Core.Tests;
using EasyEdgeApps.Persistence;
using EasyEdgeApps.Windows;

namespace EasyEdgeApps.Windows.Tests;

public sealed class MaintenanceTests
{
    [Fact]
    public async Task PinCancellationFinishesOnlyAfterItsSyntheticHelperExits()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var fixtureDirectory = Path.Combine(repository, "tests", "EasyEdgeApps.NativeFixture", "bin", configuration, "net10.0-windows10.0.19041.0");
        var record = new AppRecord { Definition = new() { DisplayName = "Synthetic cancellation", Url = "https://example.com/", Window = new() { Taskbar = true } }, ShortcutName = "Synthetic cancellation" };
        var launcher = fixture.Layout.Resolve(CatalogStore.Address(record, "Launcher"));
        var directory = Path.GetDirectoryName(launcher)!;
        Directory.CreateDirectory(directory);
        foreach (var file in Directory.EnumerateFiles(fixtureDirectory).Where(path => Path.GetExtension(path) is ".dll" or ".json"))
            File.Copy(file, Path.Combine(directory, Path.GetFileName(file)));
        File.Copy(Path.Combine(fixtureDirectory, "EasyEdgeApps.NativeFixture.exe"), launcher);
        record = record with { Files = new() { ["Launcher"] = SafeFiles.Hash(launcher) } };
        var store = new CatalogStore(fixture.Layout, new DesktopArtifacts(launcher));
        var eventName = "Local\\EasyEdgeApps-Synthetic-Pin-" + Guid.NewGuid().ToString("N");
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, eventName);
        File.WriteAllText(Path.Combine(directory, "pin-ready.txt"), eventName);
        using var cancellation = new CancellationTokenSource();
        Process? helper = null;
        var request = TaskbarAssistance.RequestAsync(store, record, cancellation.Token);
        try
        {
            Assert.True(await Task.Run(() => ready.WaitOne(TimeSpan.FromSeconds(15))), "The synthetic consent helper did not become ready.");
            helper = Process.GetProcessById(int.Parse(File.ReadAllText(Path.Combine(directory, "pin-helper.pid"))));
            cancellation.Cancel();

            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => request.WaitAsync(TimeSpan.FromSeconds(10)));

            Assert.True(helper.HasExited, "Cancellation returned while the owned helper was still running.");
        }
        finally
        {
            cancellation.Cancel();
            if (helper is { HasExited: false }) { helper.Kill(true); await helper.WaitForExitAsync(); }
            helper?.Dispose();
            try { await request.WaitAsync(TimeSpan.FromSeconds(10)); }
            catch (OperationCanceledException) { }
        }
    }

    [Fact]
    public async Task UnconfiguredUpdaterCannotDownloadOrApproveAnInstaller()
    {
        using var fixture = new TestDirectory();
        Assert.False(InstallerUpdate.IsConfigured);
        Assert.False(InstallerUpdate.IsNewerRelease("v1.4.0"));
        Assert.True(InstallerUpdate.IsNewerRelease("v2.0.0"));
        using var client = new UpdateClient();
        var asset = new ReleaseAsset("EasyEdgeApps-2.0.0-x64.msi", "https://example.invalid/no-request", 1);
        var destination = Path.Combine(fixture.Root, "Downloads");
        await Assert.ThrowsAsync<ValidationException>(() => InstallerUpdate.DownloadAsync(client, new("v2.0.0", "", [asset]), asset, destination, new Progress<long>(), default));
        Assert.False(Directory.Exists(destination));
    }

    [Fact]
    public void InstallerProductMetadataIsReadWithoutInstallation()
    {
        using var fixture = new TestDirectory();
        var msi = PublishedPackageTests.ReadPaths(fixture).Msi;
        Assert.True(File.Exists(msi), "Build the compiled unsigned MSI and select its build-result.json before package integration tests.");
        InstallerUpdate.ValidateProduct(msi, "2.0.0");
        Assert.Throws<ValidationException>(() => InstallerUpdate.ValidateProduct(msi, "3.0.0"));
    }

    [Fact]
    public void PinRequestContainsOnlyTheOwnedLauncherConsentArgument()
    {
        using var fixture = new TestDirectory();
        var record = new AppRecord { Definition = new() { DisplayName = "Synthetic pin", Url = "https://example.com/", Window = new() { Taskbar = true } }, ShortcutName = "Synthetic pin" };
        var path = fixture.Layout.Resolve(CatalogStore.Address(record, "Launcher"));
        SafeFiles.AtomicWrite(path, "synthetic image, never execute"u8.ToArray());
        record = record with { Files = new() { ["Launcher"] = SafeFiles.Hash(path) } };
        var store = new CatalogStore(fixture.Layout, new DesktopArtifacts(path));
        var request = TaskbarAssistance.CreateRequest(store, record);
        Assert.Equal(path, request.FileName);
        Assert.Equal(new[] { "--pin" }, request.ArgumentList);
        Assert.False(request.UseShellExecute);
        Assert.Throws<ValidationException>(() => TaskbarAssistance.CreateRequest(store, record with { Definition = record.Definition with { Window = new() } }));
    }
}