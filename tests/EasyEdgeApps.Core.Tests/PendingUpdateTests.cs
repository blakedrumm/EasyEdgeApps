using System.Text.Json;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Core.Tests;

public sealed class PendingUpdateTests
{
    [Fact]
    public void LaterRecordSurvivesReopeningWithoutBeingTreatedAsPublisherTrust()
    {
        using var fixture = new TestDirectory();
        var store = new PendingUpdateStore(fixture.Layout);
        Assert.Null(store.Read());
        var bytes = "unsigned synthetic installer bytes"u8.ToArray();
        var pending = new PendingUpdate("Updates/Downloads/" + Guid.NewGuid().ToString("N") + ".msi", Identity.Hash(bytes), "2.1.0");
        var path = store.Resolve(pending);
        SafeFiles.AtomicWrite(path, bytes);
        store.Save(pending);
        Assert.Equal(pending, new PendingUpdateStore(fixture.Layout).Read());
        Assert.Equal(bytes, File.ReadAllBytes(path));
        SafeFiles.AtomicWrite(path, "changed"u8.ToArray());
        Assert.Equal(pending, store.Read());
        Assert.NotEqual(pending.Sha256, SafeFiles.Hash(path));
        Assert.Throws<ValidationException>(() => store.Save(pending));
    }

    [Theory]
    [InlineData("../foreign.msi", "2.1.0")]
    [InlineData("Updates/Downloads/../foreign.msi", "2.1.0")]
    [InlineData("Updates/Downloads/00000000000000000000000000000000.exe", "2.1.0")]
    [InlineData("Updates/Downloads/00000000000000000000000000000000.msi", "2.1.0.1")]
    [InlineData("Updates/Downloads/00000000000000000000000000000000.msi", "02.1.0")]
    public void InvalidPendingReferencesFailClosedWithoutChangingTheRecord(string relativePath, string version)
    {
        using var fixture = new TestDirectory();
        var path = fixture.Layout.Resolve(new(StorageArea.Data, "Updates/pending-installer.json"));
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { Product = "EasyEdgeApps.PendingInstaller", SchemaVersion = 1, RelativePath = relativePath, Sha256 = new string('a', 64), Version = version });
        SafeFiles.AtomicWrite(path, bytes);
        Assert.Throws<ValidationException>(() => new PendingUpdateStore(fixture.Layout).Read());
        Assert.Equal(bytes, File.ReadAllBytes(path));
    }

    [Fact]
    public void MissingRequiredPendingFieldsDoNotBecomeAnApproval()
    {
        using var fixture = new TestDirectory();
        var path = fixture.Layout.Resolve(new(StorageArea.Data, "Updates/pending-installer.json"));
        SafeFiles.AtomicWrite(path, "{\"Product\":\"EasyEdgeApps.PendingInstaller\",\"SchemaVersion\":1}"u8.ToArray());
        Assert.Throws<ValidationException>(() => new PendingUpdateStore(fixture.Layout).Read());
    }
}