using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using EasyEdgeApps.Core;
using EasyEdgeApps.Core.Tests;
using EasyEdgeApps.Persistence;
using EasyEdgeApps.Windows;

namespace EasyEdgeApps.Windows.Tests;

public sealed class PublishedPackageTests
{
    [Fact]
    public void SelectedBuildRejectsAConflictingMsiOverride()
    {
        using var fixture = new TestDirectory();
        var resultPath = Path.Combine(fixture.Root, "build-result.json");
        File.WriteAllBytes(resultPath, JsonSerializer.SerializeToUtf8Bytes(new
        {
            PortableDirectory = Path.Combine(fixture.Root, "portable"),
            Zip = Path.Combine(fixture.Root, "selected.zip"),
            Msi = Path.Combine(fixture.Root, "selected.msi")
        }));
        var previousResult = Environment.GetEnvironmentVariable("EEA_COMPILED_BUILD_RESULT");
        var previousMsi = Environment.GetEnvironmentVariable("EEA_COMPILED_MSI");
        try
        {
            Environment.SetEnvironmentVariable("EEA_COMPILED_BUILD_RESULT", resultPath);
            Environment.SetEnvironmentVariable("EEA_COMPILED_MSI", Path.Combine(fixture.Root, "old.msi"));

            Assert.Throws<ValidationException>(() => ReadPaths(fixture));
        }
        finally
        {
            Environment.SetEnvironmentVariable("EEA_COMPILED_BUILD_RESULT", previousResult);
            Environment.SetEnvironmentVariable("EEA_COMPILED_MSI", previousMsi);
        }
    }

    [Fact]
    public void PublishedFolderAndZipRetainResourcesAndMatchTheCompleteIndex()
    {
        using var fixture = new TestDirectory();
        var paths = ReadPaths(fixture);
        var bytes = PackageMaintenance.ReadIndex(Path.Combine(paths.Payload, "EasyEdgeApps.PackageIndex.dll"));
        var index = JsonSerializer.Deserialize<PackageIndex>(bytes, StrictJson.Options)!;
        foreach (var required in new[] { "App.xbf", "MainWindow.xbf", "EasyEdgeApps.Manager.pri", "Assets/Brand.png", "EasyEdgeApps.Manager.exe", "eea.exe", "EasyEdgeApps.ImageWorker.exe", "WebsiteLauncher/fresh-session.exe", "EasyEdgeApps.exe", "EasyEdgeApps.ps1", "LICENSE", "Licenses/packages.json" })
            Assert.Contains(index.Files, file => file.Path.Equals(required, StringComparison.Ordinal));
        PackageMaintenance.VerifyStaged(new(paths.Payload, index.Version, Identity.Hash(bytes), "1.4.0"), "1.4.0");
        using var archive = ZipFile.OpenRead(paths.Zip);
        Assert.Equal(index.Files.Length + 1, archive.Entries.Count);
        foreach (var file in index.Files)
        {
            var entry = Assert.Single(archive.Entries, entry => entry.FullName == file.Path);
            Assert.Equal(file.Size, entry.Length);
            using var input = entry.Open();
            Assert.Equal(file.Sha256, Convert.ToHexStringLower(SHA256.HashData(input)));
        }
        using var licenses = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(paths.Payload, "Licenses", "packages.json")));
        var packages = licenses.RootElement.EnumerateArray().ToArray();
        foreach (var name in new[] { "AngleSharp", "Svg", "ExCSS", "Microsoft.NETCore.App.Runtime.win-x64", "Microsoft.WindowsDesktop.App.Runtime.win-x64", "Microsoft.WindowsAppSDK" })
            Assert.Single(packages, package => package.GetProperty("Id").GetString() == name);
        InstallerUpdate.ValidateProduct(paths.Msi, index.Version);
    }

    [Fact]
    public async Task UnsignedReleaseCannotBecomeAnAuthenticatedStagedUpdate()
    {
        using var fixture = new TestDirectory();
        var paths = ReadPaths(fixture);
        var destination = Path.Combine(fixture.Root, "Updates");
        var maintenance = new PackageMaintenance((path, publisher) => PublisherTrust.Verify(path, publisher));
        var failure = await Assert.ThrowsAsync<ValidationException>(() => maintenance.StageAsync(paths.Zip, destination, new string('0', 40), "1.4.0", default));
        Assert.Contains("trusted publisher signature", failure.Message);
        Assert.Empty(Directory.EnumerateFileSystemEntries(destination));
        Assert.Throws<ValidationException>(() => PublisherTrust.Verify(paths.Msi, new string('0', 40)));
    }

    internal static (string Payload, string Zip, string Msi) ReadPaths(TestDirectory fixture)
    {
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var resultPath = Environment.GetEnvironmentVariable("EEA_COMPILED_BUILD_RESULT") ?? Path.Combine(repository, "artifacts", "compiled", "build-result.json");
        Assert.True(File.Exists(resultPath), "Build the current compiled ZIP/MSI and set EEA_COMPILED_BUILD_RESULT to its build-result.json.");
        using var document = JsonDocument.Parse(File.ReadAllBytes(resultPath));
        var root = document.RootElement;
        var paths = (Payload: root.GetProperty("PortableDirectory").GetString()!, Zip: root.GetProperty("Zip").GetString()!, Msi: root.GetProperty("Msi").GetString()!);
        foreach (var path in new[] { paths.Payload, paths.Zip, paths.Msi })
            Assert.StartsWith(Path.Combine(repository, "artifacts") + Path.DirectorySeparatorChar, Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase);
        var msiOverride = Environment.GetEnvironmentVariable("EEA_COMPILED_MSI");
        if (msiOverride is not null && !Path.GetFullPath(msiOverride).Equals(Path.GetFullPath(paths.Msi), StringComparison.OrdinalIgnoreCase))
            throw new ValidationException("EEA_COMPILED_MSI does not match the selected compiled build record.");
        return paths;
    }
}