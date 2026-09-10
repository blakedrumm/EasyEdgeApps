using System.Text.Json;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Persistence;

public sealed record PortablePlan(string Directory, StagedPackage Previous, StagedPackage Next, string Publisher, string Fingerprint);
public sealed record PortableResult(string Directory, string Version, string ReceiptPath);
public sealed record PortableReceipt(string Product, int SchemaVersion, string State, PortablePlan Plan);

public sealed class PortableDeployment(Action<string, string> verifyPublisher, Action<string>? fault = null)
{
    public PortablePlan Preview(StagedPackage staged, string currentDirectory, string expectedPublisher)
    {
        var current = Canonical(currentDirectory);
        var next = staged with { Directory = Canonical(staged.Directory) };
        ValidateLocations(current, next.Directory);
        if (string.IsNullOrWhiteSpace(expectedPublisher)) throw new ValidationException("An expected publisher is required for portable updates.");
        var previous = Inspect(current, expectedPublisher);
        if (next.SourceVersion != previous.Version || ParseVersion(next.Version) <= ParseVersion(previous.Version))
            throw new ValidationException("The staged update does not upgrade this portable version.");
        VerifyAt(next, next.Directory, expectedPublisher);
        var plan = new PortablePlan(current, previous, next, expectedPublisher, "");
        return plan with { Fingerprint = Fingerprint(plan) };
    }

    public PortableResult Apply(PortablePlan approved, string expectedPublisher)
    {
        ValidatePlan(approved, expectedPublisher);
        using var lease = Acquire(approved.Directory);
        var refreshed = Preview(approved.Next, approved.Directory, expectedPublisher);
        if (refreshed.Fingerprint != approved.Fingerprint) throw new ValidationException("The portable deployment changed after preview.");
        EnsureStopped(approved.Directory);
        EnsureStopped(approved.Next.Directory);
        var transaction = Path.Combine(ReceiptRoot(approved.Directory), Guid.NewGuid().ToString("N"));
        SafeFiles.CheckPath(transaction);
        Directory.CreateDirectory(transaction);
        var path = Path.Combine(transaction, "receipt.json");
        var receipt = new PortableReceipt("EasyEdgeApps.PortableUpdate", 1, "Prepared", approved);
        Write(path, receipt);
        try
        {
            Directory.Move(approved.Directory, Path.Combine(transaction, "previous"));
            receipt = receipt with { State = "PreviousMoved" };
            Write(path, receipt);
            fault?.Invoke(receipt.State);
            VerifyAt(approved.Next, approved.Next.Directory, expectedPublisher);
            Directory.Move(approved.Next.Directory, approved.Directory);
            receipt = receipt with { State = "Activated" };
            Write(path, receipt);
            fault?.Invoke(receipt.State);
            VerifyAt(approved.Next, approved.Directory, expectedPublisher);
            Write(path, receipt with { State = "Committed" });
            return new(approved.Directory, approved.Next.Version, path);
        }
        catch (Exception failure)
        {
            try { RecoverCore(Read(approved.Directory, path, expectedPublisher), path, expectedPublisher); }
            catch (Exception recovery)
            { throw new IOException("Portable activation failed and recovery could not finish. Retain the receipt and recover before retrying.", new AggregateException(failure, recovery)); }
            throw;
        }
    }

    public PortableResult Rollback(string currentDirectory, string receiptPath, string expectedPublisher)
    {
        var current = Canonical(currentDirectory);
        using var lease = Acquire(current);
        var receipt = Read(current, receiptPath, expectedPublisher);
        if (receipt.State == "RolledBack") return RecoverCore(receipt, receiptPath, expectedPublisher);
        if (receipt.State != "Committed") throw new ValidationException("Recover the interrupted portable operation before requesting rollback.");
        VerifyAt(receipt.Plan.Next, current, expectedPublisher);
        VerifyAt(receipt.Plan.Previous, Path.Combine(Path.GetDirectoryName(receiptPath)!, "previous"), expectedPublisher);
        EnsureStopped(current);
        receipt = receipt with { State = "RollbackPrepared" };
        Write(receiptPath, receipt);
        return RecoverCore(receipt, receiptPath, expectedPublisher);
    }

    public PortableResult Recover(string currentDirectory, string receiptPath, string expectedPublisher)
    {
        var current = Canonical(currentDirectory);
        using var lease = Acquire(current);
        return RecoverCore(Read(current, receiptPath, expectedPublisher), receiptPath, expectedPublisher);
    }

    private PortableResult RecoverCore(PortableReceipt receipt, string path, string publisher)
    {
        var plan = receipt.Plan;
        var previous = Path.Combine(Path.GetDirectoryName(path)!, "previous");
        var retainedNext = Path.Combine(Path.GetDirectoryName(path)!, "next");
        foreach (var directory in new[] { plan.Directory, plan.Next.Directory, previous, retainedNext }) SafeFiles.CheckPath(directory);
        if (receipt.State == "Committed")
        {
            VerifyAt(plan.Next, plan.Directory, publisher);
            VerifyAt(plan.Previous, previous, publisher);
            return new(plan.Directory, plan.Next.Version, path);
        }
        var current = Directory.Exists(plan.Directory) ? Inspect(plan.Directory, publisher) : null;
        if (current is not null && !Matches(current, plan.Previous) && !Matches(current, plan.Next))
            throw new ValidationException("The current portable directory contains outside changes. Recovery will not overwrite it.");
        if (Directory.Exists(previous)) VerifyAt(plan.Previous, previous, publisher);
        if (Directory.Exists(plan.Next.Directory)) VerifyAt(plan.Next, plan.Next.Directory, publisher);
        if (Directory.Exists(retainedNext)) VerifyAt(plan.Next, retainedNext, publisher);
        if (current is not null && Matches(current, plan.Previous))
        {
            if (Directory.Exists(previous)) throw new ValidationException("An unexpected duplicate previous deployment needs manual investigation.");
            if (receipt.State != "RolledBack") Write(path, receipt with { State = "RolledBack" });
            return new(plan.Directory, plan.Previous.Version, path);
        }
        if (!Directory.Exists(previous)) throw new ValidationException("The verified previous portable version is missing. Recovery cannot continue.");
        EnsureStopped(previous);
        if (current is not null)
        {
            if (Directory.Exists(retainedNext) || File.Exists(retainedNext)) throw new ValidationException("The retained update destination is already occupied.");
            EnsureStopped(plan.Directory);
            Directory.Move(plan.Directory, retainedNext);
            receipt = receipt with { State = "NextMoved" };
            Write(path, receipt);
        }
        Directory.Move(previous, plan.Directory);
        VerifyAt(plan.Previous, plan.Directory, publisher);
        Write(path, receipt with { State = "RolledBack" });
        return new(plan.Directory, plan.Previous.Version, path);
    }

    private StagedPackage Inspect(string directory, string publisher)
    {
        var indexPath = Path.Combine(directory, "EasyEdgeApps.PackageIndex.dll");
        SafeFiles.CheckPath(indexPath);
        verifyPublisher(indexPath, publisher);
        var bytes = PackageMaintenance.ReadIndex(indexPath);
        using var document = StrictJson.Parse(bytes, 2 * 1024 * 1024, 16, 32768);
        var index = document.RootElement.Deserialize<PackageIndex>(StrictJson.Options) ?? throw new ValidationException("Invalid portable release index.");
        _ = ParseVersion(index.Version);
        if (index.Files is null || !index.Files.Any(file => file?.Path == "EasyEdgeApps.Manager.exe") || !index.Files.Any(file => file?.Path == "WebsiteLauncher/fresh-session.exe"))
            throw new ValidationException("The portable deployment lacks its required manager and launcher.");
        var inspected = new StagedPackage(directory, index.Version, Identity.Hash(bytes), index.Version);
        PackageMaintenance.VerifyStaged(inspected, inspected.SourceVersion);
        return inspected;
    }

    private void VerifyAt(StagedPackage expected, string directory, string publisher)
    {
        var actual = Inspect(directory, publisher);
        if (!Matches(actual, expected)) throw new ValidationException("The portable release identity changed after approval.");
    }

    private static bool Matches(StagedPackage actual, StagedPackage expected) => actual.Version == expected.Version && actual.IndexHash == expected.IndexHash;

    private static void EnsureStopped(string directory)
    {
        var running = Environment.ProcessPath;
        if (running is not null && Within(Canonical(running), directory)) throw new ValidationException("Run portable maintenance from a separate trusted helper directory after closing this deployment.");
        var pending = new Stack<string>();
        pending.Push(directory);
        var count = 0;
        while (pending.TryPop(out var current))
        {
            SafeFiles.CheckPath(current);
            foreach (var path in Directory.EnumerateFileSystemEntries(current))
            {
                if (++count > 8192) throw new ValidationException("Portable deployment exceeds its file bound.");
                SafeFiles.CheckPath(path);
                if (Directory.Exists(path)) pending.Push(path);
                else
                {
                    try { using var exclusive = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None); }
                    catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
                    { throw new ValidationException("Close programs using this portable deployment and check its file permissions before maintenance."); }
                }
            }
        }
    }

    private static PortableReceipt Read(string current, string path, string publisher)
    {
        path = Canonical(path);
        var transaction = Path.GetDirectoryName(path)!;
        if (!Guid.TryParseExact(Path.GetFileName(transaction), "N", out _) || !Path.GetDirectoryName(transaction)!.Equals(ReceiptRoot(current), StringComparison.OrdinalIgnoreCase) || Path.GetFileName(path) != "receipt.json")
            throw new ValidationException("Select an owned portable-update receipt beside this deployment.");
        using var document = StrictJson.Parse(SafeFiles.Read(path, 32768), 32768, 8, 128);
        var root = document.RootElement;
        StrictJson.Fields(root, ["Product", "SchemaVersion", "State", "Plan"]);
        var plan = root.GetProperty("Plan");
        StrictJson.Fields(plan, ["Directory", "Previous", "Next", "Publisher", "Fingerprint"]);
        foreach (var version in new[] { "Previous", "Next" }) StrictJson.Fields(plan.GetProperty(version), ["Directory", "Version", "IndexHash", "SourceVersion"]);
        PortableReceipt receipt;
        try { receipt = root.Deserialize<PortableReceipt>(StrictJson.Options) ?? throw new ValidationException("Invalid portable-update receipt."); }
        catch (JsonException) { throw new ValidationException("Invalid portable-update receipt field types."); }
        if (receipt.Product != "EasyEdgeApps.PortableUpdate" || receipt.SchemaVersion != 1 || receipt.State is not ("Prepared" or "PreviousMoved" or "Activated" or "Committed" or "RollbackPrepared" or "NextMoved" or "RolledBack"))
            throw new ValidationException("Invalid portable-update receipt state.");
        ValidatePlan(receipt.Plan, publisher);
        if (!receipt.Plan.Directory.Equals(current, StringComparison.OrdinalIgnoreCase)) throw new ValidationException("The portable-update receipt belongs to another deployment.");
        return receipt;
    }

    private static void ValidatePlan(PortablePlan plan, string publisher)
    {
        if (plan is null || plan.Previous is null || plan.Next is null || string.IsNullOrWhiteSpace(publisher) || plan.Publisher != publisher || !Identity.IsId(plan.Fingerprint))
            throw new ValidationException("Invalid portable update approval.");
        var current = Canonical(plan.Directory);
        if (plan.Directory != current || plan.Previous.Directory != current || plan.Next.Directory != Canonical(plan.Next.Directory)) throw new ValidationException("Portable approval paths are not canonical.");
        ValidateLocations(current, plan.Next.Directory);
        if (!Identity.IsId(plan.Previous.IndexHash) || !Identity.IsId(plan.Next.IndexHash) || plan.Previous.SourceVersion != plan.Previous.Version || plan.Next.SourceVersion != plan.Previous.Version ||
            ParseVersion(plan.Next.Version) <= ParseVersion(plan.Previous.Version) || Fingerprint(plan) != plan.Fingerprint)
            throw new ValidationException("Portable update approval or version identity changed.");
    }

    private static string Fingerprint(PortablePlan plan) => Identity.Hash(JsonSerializer.SerializeToUtf8Bytes(new { plan.Directory, plan.Previous, plan.Next, plan.Publisher }, StrictJson.Options));
    private static void Write(string path, PortableReceipt receipt) => SafeFiles.AtomicWrite(path, JsonSerializer.SerializeToUtf8Bytes(receipt, StrictJson.Options));

    private static string Canonical(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new ValidationException("An absolute portable deployment path is required.");
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        SafeFiles.CheckPath(full);
        return full;
    }

    private static void ValidateLocations(string current, string next)
    {
        if (Path.GetDirectoryName(current) is null || Path.GetDirectoryName(next) is null || current.Equals(next, StringComparison.OrdinalIgnoreCase) || Within(current, next) || Within(next, current) ||
            !string.Equals(Path.GetPathRoot(current), Path.GetPathRoot(next), StringComparison.OrdinalIgnoreCase) || Within(next, ReceiptRoot(current)) || next.Equals(ReceiptRoot(current), StringComparison.OrdinalIgnoreCase))
            throw new ValidationException("Use separate portable and staged directories on the same local volume, outside the deployment and its receipts.");
    }

    private static bool Within(string path, string directory) => path.StartsWith(Path.TrimEndingDirectorySeparator(directory) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    private static string ReceiptRoot(string current) => Path.Combine(Path.GetDirectoryName(current)!, "." + Path.GetFileName(current) + ".updates");

    private static FileStream Acquire(string current)
    {
        var root = ReceiptRoot(current);
        SafeFiles.CheckPath(root);
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, ".writer.lock");
        SafeFiles.CheckPath(path);
        try { return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw new ValidationException("Another portable maintenance operation is running."); }
    }

    private static Version ParseVersion(string value)
    {
        if (!Version.TryParse(value, out var version) || version.Build < 0 || version.Revision != -1 || version.ToString(3) != value)
            throw new ValidationException("Use a canonical three-part portable version.");
        return version;
    }
}