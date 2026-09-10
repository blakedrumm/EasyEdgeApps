using System.IO.Compression;
using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;
using System.Text.Json;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Core.Tests;

public sealed class PackageTests
{
    [Fact]
    public async Task CompleteIndexIsVerifiedBeforeExtractionAndStagedBytesAreRechecked()
    {
        using var fixture = new TestDirectory();
        var verified = false;
        var maintenance = new PackageMaintenance((path, _) =>
        {
            Assert.Single(Directory.GetFiles(Path.GetDirectoryName(path)!));
            verified = true;
        });
        var package = Create(fixture.Root);
        var staged = await maintenance.StageAsync(package, Path.Combine(fixture.Root, "Updates"), "Synthetic verifier, not Authenticode", "1.4.0", default);
        Assert.True(verified);
        PackageMaintenance.VerifyStaged(staged, "1.4.0");
        File.WriteAllText(Path.Combine(staged.Directory, "EasyEdgeApps.Manager.exe"), "tampered");
        Assert.Throws<ValidationException>(() => PackageMaintenance.VerifyStaged(staged, "1.4.0"));
    }

    [Theory]
    [InlineData("../outside")]
    [InlineData("C:/outside")]
    [InlineData("folder\\outside")]
    [InlineData("CON.txt")]
    [InlineData("outside:stream")]
    public async Task UnsafePathsNeverReachPublisherVerification(string entry)
    {
        using var fixture = new TestDirectory();
        var calls = 0;
        var maintenance = new PackageMaintenance((_, _) => calls++);
        var package = Create(fixture.Root, extra: entry);
        await Assert.ThrowsAsync<ValidationException>(() => maintenance.StageAsync(package, Path.Combine(fixture.Root, "Updates"), "test", "1.4.0", default));
        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task UntrustedTamperedAndCancelledPackagesLeaveNoCommittedVersion()
    {
        using var fixture = new TestDirectory();
        var package = Create(fixture.Root, tamper: true);
        var updates = Path.Combine(fixture.Root, "Updates");
        await Assert.ThrowsAsync<ValidationException>(() => new PackageMaintenance((_, _) => { }).StageAsync(package, updates, "test", "1.4.0", default));
        await Assert.ThrowsAsync<ValidationException>(() => new PackageMaintenance((_, _) => throw new ValidationException("Unsigned fixture")).StageAsync(package, updates, "test", "1.4.0", default));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new PackageMaintenance((_, _) => { }).StageAsync(package, updates, "test", "1.4.0", new CancellationToken(true)));
        Assert.Empty(Directory.EnumerateFileSystemEntries(updates));
    }

    [Fact]
    public async Task ExtraStagedPayloadAndChangedApprovalAreRejected()
    {
        using var fixture = new TestDirectory();
        var staged = await new PackageMaintenance((_, _) => { }).StageAsync(Create(fixture.Root), Path.Combine(fixture.Root, "Updates"), "test", "1.4.0", default);
        Assert.Throws<ValidationException>(() => PackageMaintenance.VerifyStaged(staged, "1.5.0"));
        File.WriteAllText(Path.Combine(staged.Directory, "unapproved.dll"), "extra payload");
        Assert.Throws<ValidationException>(() => PackageMaintenance.VerifyStaged(staged, "1.4.0"));
    }

    [Fact]
    public async Task PortableActivationRetainsRollbackAndRejectsChangedApprovals()
    {
        using var fixture = new TestDirectory();
        var maintenance = new PackageMaintenance((_, _) => { });
        var previous = await maintenance.StageAsync(Create(fixture.Root, version: "1.4.0"), Path.Combine(fixture.Root, "Old"), "synthetic", "1.3.0", default);
        var current = Path.Combine(fixture.Root, "Portable");
        Directory.Move(previous.Directory, current);
        var staged = await maintenance.StageAsync(Create(fixture.Root), Path.Combine(fixture.Root, "Updates"), "synthetic", "1.4.0", default);
        var retainedData = Path.Combine(fixture.Root, "browser-profile");
        File.WriteAllText(retainedData, "Retained user data");
        var verified = 0;
        var deployment = new PortableDeployment((_, _) => verified++);
        var plan = deployment.Preview(staged, current, "synthetic");
        var original = File.ReadAllBytes(Path.Combine(current, "EasyEdgeApps.Manager.exe"));
        File.WriteAllText(Path.Combine(current, "EasyEdgeApps.Manager.exe"), "Outside change");
        Assert.Throws<ValidationException>(() => deployment.Apply(plan, "synthetic"));
        Assert.True(Directory.Exists(staged.Directory));
        File.WriteAllBytes(Path.Combine(current, "EasyEdgeApps.Manager.exe"), original);
        var activated = deployment.Apply(plan, "synthetic");
        Assert.Equal("2.0.0", activated.Version);
        Assert.True(File.Exists(activated.ReceiptPath));
        Assert.False(Directory.Exists(staged.Directory));
        PackageMaintenance.VerifyStaged(staged with { Directory = current }, "1.4.0");
        var updated = File.ReadAllBytes(Path.Combine(current, "EasyEdgeApps.Manager.exe"));
        File.WriteAllText(Path.Combine(current, "EasyEdgeApps.Manager.exe"), "New outside change");
        Assert.Throws<ValidationException>(() => deployment.Rollback(current, activated.ReceiptPath, "synthetic"));
        Assert.Equal("New outside change", File.ReadAllText(Path.Combine(current, "EasyEdgeApps.Manager.exe")));
        File.WriteAllBytes(Path.Combine(current, "EasyEdgeApps.Manager.exe"), updated);
        var rolledBack = deployment.Rollback(current, activated.ReceiptPath, "synthetic");
        Assert.Equal("1.4.0", rolledBack.Version);
        Assert.Equal(original, File.ReadAllBytes(Path.Combine(current, "EasyEdgeApps.Manager.exe")));
        Assert.Equal("Retained user data", File.ReadAllText(retainedData));
        Assert.True(verified >= 6);
        Assert.Equal("1.4.0", deployment.Recover(current, activated.ReceiptPath, "synthetic").Version);
    }

    [Theory]
    [InlineData("PreviousMoved")]
    [InlineData("Activated")]
    public async Task InterruptedPortableActivationRestoresTheVerifiedPriorVersion(string transition)
    {
        using var fixture = new TestDirectory();
        var maintenance = new PackageMaintenance((_, _) => { });
        var previous = await maintenance.StageAsync(Create(fixture.Root, version: "1.4.0"), Path.Combine(fixture.Root, "Old"), "synthetic", "1.3.0", default);
        var current = Path.Combine(fixture.Root, "Portable");
        Directory.Move(previous.Directory, current);
        var staged = await maintenance.StageAsync(Create(fixture.Root), Path.Combine(fixture.Root, "Updates"), "synthetic", "1.4.0", default);
        var deployment = new PortableDeployment((_, _) => { }, state => { if (state == transition) throw new IOException("Synthetic interruption"); });
        var plan = deployment.Preview(staged, current, "synthetic");
        Assert.Throws<IOException>(() => deployment.Apply(plan, "synthetic"));
        PackageMaintenance.VerifyStaged(previous with { Directory = current }, "1.3.0");
        var receipt = Assert.Single(Directory.GetFiles(Path.Combine(fixture.Root, ".Portable.updates"), "receipt.json", SearchOption.AllDirectories));
        Assert.Equal("1.4.0", new PortableDeployment((_, _) => { }).Recover(current, receipt, "synthetic").Version);
    }

    [Fact]
    public async Task PortableMaintenanceRejectsLocksPublishersAndTamperedReceipts()
    {
        using var fixture = new TestDirectory();
        var maintenance = new PackageMaintenance((_, _) => { });
        var previous = await maintenance.StageAsync(Create(fixture.Root, version: "1.4.0"), Path.Combine(fixture.Root, "Old"), "synthetic", "1.3.0", default);
        var current = Path.Combine(fixture.Root, "Portable");
        Directory.Move(previous.Directory, current);
        var staged = await maintenance.StageAsync(Create(fixture.Root), Path.Combine(fixture.Root, "Updates"), "synthetic", "1.4.0", default);
        var deployment = new PortableDeployment((_, _) => { });
        var plan = deployment.Preview(staged, current, "synthetic");
        Assert.Throws<ValidationException>(() => deployment.Preview(staged with { Directory = Path.Combine(current, "nested") }, current, "synthetic"));
        Assert.Throws<ValidationException>(() => deployment.Apply(plan, "other publisher"));
        Assert.Throws<ValidationException>(() => new PortableDeployment((_, _) => throw new ValidationException("Unsigned test index")).Apply(plan, "synthetic"));
        using (var locked = new FileStream(Path.Combine(current, "EasyEdgeApps.Manager.exe"), FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.Throws<ValidationException>(() => deployment.Apply(plan, "synthetic"));
        PackageMaintenance.VerifyStaged(previous with { Directory = current }, "1.3.0");
        Assert.Empty(Directory.GetFiles(Path.Combine(fixture.Root, ".Portable.updates"), "receipt.json", SearchOption.AllDirectories));
        var activated = deployment.Apply(plan, "synthetic");
        var receiptBytes = File.ReadAllBytes(activated.ReceiptPath);
        foreach (var field in new[] { "Product", "SchemaVersion", "State", "Plan" })
        {
            var malformed = System.Text.Json.Nodes.JsonNode.Parse(receiptBytes)!.AsObject();
            malformed.Remove(field);
            File.WriteAllText(activated.ReceiptPath, malformed.ToJsonString());
            Assert.Throws<ValidationException>(() => deployment.Rollback(current, activated.ReceiptPath, "synthetic"));
            PackageMaintenance.VerifyStaged(staged with { Directory = current }, "1.4.0");
        }
        var unexpected = System.Text.Json.Nodes.JsonNode.Parse(receiptBytes)!;
        unexpected["SilentOverride"] = true;
        File.WriteAllText(activated.ReceiptPath, unexpected.ToJsonString());
        Assert.Throws<ValidationException>(() => deployment.Rollback(current, activated.ReceiptPath, "synthetic"));
        File.WriteAllBytes(activated.ReceiptPath, receiptBytes);
        Assert.Equal("1.4.0", deployment.Rollback(current, activated.ReceiptPath, "synthetic").Version);
    }

    [Theory]
    [InlineData("Prepared", false, false)]
    [InlineData("PreviousMoved", true, false)]
    [InlineData("RollbackPrepared", true, true)]
    public async Task PortableRecoveryUsesVerifiedDiskStateWhenTheReceiptLagsAMove(string state, bool activate, bool moveNext)
    {
        using var fixture = new TestDirectory();
        var maintenance = new PackageMaintenance((_, _) => { });
        var previous = await maintenance.StageAsync(Create(fixture.Root, version: "1.4.0"), Path.Combine(fixture.Root, "Old"), "synthetic", "1.3.0", default);
        var current = Path.Combine(fixture.Root, "Portable");
        Directory.Move(previous.Directory, current);
        var staged = await maintenance.StageAsync(Create(fixture.Root), Path.Combine(fixture.Root, "Updates"), "synthetic", "1.4.0", default);
        var deployment = new PortableDeployment((_, _) => { });
        var plan = deployment.Preview(staged, current, "synthetic");
        var transaction = Path.Combine(fixture.Root, ".Portable.updates", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(transaction);
        var receiptPath = Path.Combine(transaction, "receipt.json");
        File.WriteAllBytes(receiptPath, JsonSerializer.SerializeToUtf8Bytes(new PortableReceipt("EasyEdgeApps.PortableUpdate", 1, state, plan), StrictJson.Options));
        Directory.Move(current, Path.Combine(transaction, "previous"));
        if (activate) Directory.Move(staged.Directory, current);
        if (moveNext) Directory.Move(current, Path.Combine(transaction, "next"));
        Assert.Equal("1.4.0", deployment.Recover(current, receiptPath, "synthetic").Version);
        PackageMaintenance.VerifyStaged(previous with { Directory = current }, "1.3.0");
        Assert.Equal("1.4.0", deployment.Recover(current, receiptPath, "synthetic").Version);
        if (activate) PackageMaintenance.VerifyStaged(staged with { Directory = Path.Combine(transaction, "next") }, "1.4.0");
        else PackageMaintenance.VerifyStaged(staged, "1.4.0");
    }

    private static string Create(string root, string? extra = null, bool tamper = false, string version = "2.0.0")
    {
        var files = new Dictionary<string, byte[]> { ["EasyEdgeApps.Manager.exe"] = System.Text.Encoding.UTF8.GetBytes("synthetic manager " + version), ["WebsiteLauncher/fresh-session.exe"] = "synthetic launcher"u8.ToArray() };
        var index = new PackageIndex("EasyEdgeApps.Package", 1, version, "x64", files.Select(file => new PackageFile(file.Key, file.Value.Length, Identity.Hash(file.Value))).ToArray());
        var metadata = new MetadataBuilder();
        metadata.AddModule(0, metadata.GetOrAddString("PackageFixture"), metadata.GetOrAddGuid(Guid.NewGuid()), default, default);
        metadata.AddAssembly(metadata.GetOrAddString("PackageFixture"), new Version(1, 0, 0, 0), default, default, (AssemblyFlags)0, AssemblyHashAlgorithm.Sha256);
        metadata.AddTypeDefinition(TypeAttributes.NotPublic, default, metadata.GetOrAddString("<Module>"), default, MetadataTokens.FieldDefinitionHandle(1), MetadataTokens.MethodDefinitionHandle(1));
        var resource = new BlobBuilder();
        var bytes = JsonSerializer.SerializeToUtf8Bytes(index, StrictJson.Options);
        resource.WriteInt32(bytes.Length); resource.WriteBytes(bytes);
        metadata.AddManifestResource(ManifestResourceAttributes.Public, metadata.GetOrAddString("EasyEdgeApps.ReleaseIndex.json"), default, 0);
        var image = new BlobBuilder();
        new ManagedPEBuilder(new PEHeaderBuilder(imageCharacteristics: Characteristics.Dll | Characteristics.ExecutableImage), new MetadataRootBuilder(metadata), new BlobBuilder(), managedResources: resource).Serialize(image);
        files["EasyEdgeApps.PackageIndex.dll"] = image.ToArray();
        if (tamper) files["EasyEdgeApps.Manager.exe"][0] ^= 1;
        if (extra is not null) files.Add(extra, [1]);
        var path = Path.Combine(root, Guid.NewGuid().ToString("N") + ".zip");
        using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var file in files) { using var output = archive.CreateEntry(file.Key).Open(); output.Write(file.Value); }
        return path;
    }
}