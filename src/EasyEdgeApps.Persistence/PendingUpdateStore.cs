using System.Text.Json;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Persistence;

public sealed record PendingUpdate(string RelativePath, string Sha256, string Version);

public sealed class PendingUpdateStore(StoreLayout layout)
{
    public PendingUpdate? Read()
    {
        var path = layout.Resolve(new(StorageArea.Data, "Updates/pending-installer.json"));
        if (!File.Exists(path)) return null;
        using var document = StrictJson.Parse(SafeFiles.Read(path, 4096), 4096, 4, 16);
        var root = document.RootElement;
        StrictJson.Fields(root, ["Product", "SchemaVersion", "RelativePath", "Sha256", "Version"]);
        if (StrictJson.Text(root, "Product") != "EasyEdgeApps.PendingInstaller" || StrictJson.Integer(root, "SchemaVersion") != 1)
            throw new ValidationException("The retained update record is not supported.");
        var pending = new PendingUpdate(StrictJson.Text(root, "RelativePath"), StrictJson.Text(root, "Sha256"), StrictJson.Text(root, "Version"));
        _ = Resolve(pending);
        return pending;
    }

    public void Save(PendingUpdate pending)
    {
        var installer = Resolve(pending);
        if (SafeFiles.Hash(installer) != pending.Sha256) throw new ValidationException("The downloaded installer changed before it could be retained.");
        SafeFiles.AtomicWrite(layout.Resolve(new(StorageArea.Data, "Updates/pending-installer.json")), JsonSerializer.SerializeToUtf8Bytes(new
        {
            Product = "EasyEdgeApps.PendingInstaller", SchemaVersion = 1, pending.RelativePath, pending.Sha256, pending.Version
        }, StrictJson.Options));
    }

    public string Resolve(PendingUpdate pending)
    {
        if (pending is null || pending.RelativePath is null || !Identity.IsId(pending.Sha256) ||
            !Version.TryParse(pending.Version, out var version) || version.Build < 0 || version.Revision >= 0 || version.ToString(3) != pending.Version)
            throw new ValidationException("The retained update metadata is invalid.");
        var parts = pending.RelativePath.Split('/');
        if (parts.Length != 3 || parts[0] != "Updates" || parts[1] != "Downloads" || parts[2].Length != 36 ||
            !parts[2].EndsWith(".msi", StringComparison.Ordinal) || !Guid.TryParseExact(parts[2][..32], "N", out _))
            throw new ValidationException("A retained installer must remain in its owned download directory.");
        return layout.Resolve(new(StorageArea.Data, pending.RelativePath));
    }
}