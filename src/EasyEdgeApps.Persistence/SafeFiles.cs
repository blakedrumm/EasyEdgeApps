using System.Text.Json;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Persistence;

public enum StorageArea { Data, Legacy, Desktop, Programs }
public sealed record FileAddress(StorageArea Area, string RelativePath);
public sealed record FileChange(FileAddress Address, string ExpectedHash, byte[]? Content);
public sealed record StoreLayout(string DataRoot, string DesktopRoot, string ProgramsRoot, string? LegacyRoot = null)
{
    public string Root(StorageArea area) => Path.GetFullPath(area switch
    {
        StorageArea.Data => DataRoot, StorageArea.Legacy => LegacyRoot ?? throw new ValidationException("A legacy root must be explicitly configured."),
        StorageArea.Desktop => DesktopRoot, StorageArea.Programs => ProgramsRoot, _ => throw new ValidationException("Unsupported storage area.")
    });

    public string Resolve(FileAddress address)
    {
        if (address is null || string.IsNullOrEmpty(address.RelativePath) || Path.IsPathRooted(address.RelativePath) || address.RelativePath.Split(['/', '\\']).Any(segment => segment is "" or "." or ".." || segment.Contains(':')))
            throw new ValidationException("An owned file address is not a safe relative path.");
        var root = Root(address.Area);
        var path = Path.GetFullPath(Path.Combine(root, address.RelativePath));
        if (!path.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new ValidationException("File address escapes its owned root.");
        SafeFiles.CheckPath(path);
        return path;
    }
}

public static class SafeFiles
{
    public const string Missing = "Missing";

    public static string ExportPath(StoreLayout layout, string path, string? sourcePath = null)
    {
        var full = Path.GetFullPath(path);
        CheckPath(full);
        if (full.Split(['/', '\\']).Any(segment => segment.EndsWith('.') || segment.EndsWith(' '))) throw new ValidationException("Choose an export path without trailing dots or spaces.");
        if (sourcePath is not null && string.Equals(full, Path.GetFullPath(sourcePath), StringComparison.OrdinalIgnoreCase)) throw new ValidationException("An export cannot replace its source file.");
        if (Path.GetExtension(full).Equals(".lnk", StringComparison.OrdinalIgnoreCase)) throw new ValidationException("An export cannot replace a Windows shortcut.");
        foreach (var root in new[] { layout.DataRoot, layout.LegacyRoot }.Where(root => root is not null))
        {
            var protectedRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root!));
            if (full.Equals(protectedRoot, StringComparison.OrdinalIgnoreCase) || full.StartsWith(protectedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new ValidationException("Choose an export destination outside managed application and browser data.");
        }
        return full;
    }

    public static void CheckPath(string path)
    {
        if (!Path.IsPathFullyQualified(path)) throw new ValidationException("An absolute local path is required.");
        var full = Path.GetFullPath(path);
        if (full.StartsWith("\\\\", StringComparison.Ordinal) || full.IndexOf(':', 2) >= 0) throw new ValidationException("Network and alternate-stream paths are not supported.");
        for (var current = full; current is not null; current = Path.GetDirectoryName(current))
        {
            try
            {
                var attributes = File.GetAttributes(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0) throw new ValidationException("Reparse-point storage is not supported.");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }

    public static byte[] Read(string path, int maximumBytes = 256 * 1024 * 1024)
    {
        CheckPath(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
        if (stream.Length > maximumBytes) throw new ValidationException("Owned file exceeds its size bound.");
        var result = new byte[checked((int)stream.Length)];
        stream.ReadExactly(result);
        if (stream.ReadByte() != -1) throw new IOException("File changed while being read.");
        return result;
    }

    public static string Hash(string path)
    {
        CheckPath(path);
        if (Directory.Exists(path)) throw new ValidationException("A directory occupies an owned file path.");
        if (!File.Exists(path)) return Missing;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
        if (stream.Length > 512L * 1024 * 1024) throw new ValidationException("Owned file exceeds its hash-size bound.");
        return Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(stream));
    }

    public static void AtomicWrite(string path, byte[] bytes) => AtomicWrite(path, stream => stream.Write(bytes));

    public static void AtomicCopy(string source, string destination, string expectedHash) => AtomicCopy(source, destination, expectedHash, null);

    internal static void AtomicCopy(string source, string destination, string expectedHash, string? expectedDestinationHash)
    {
        CheckPath(source);
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete, 65536, FileOptions.SequentialScan);
        if (input.Length > 256L * 1024 * 1024) throw new ValidationException("Staged file exceeds its size bound.");
        AtomicWrite(destination, output =>
        {
            using var checksum = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
            var buffer = new byte[65536];
            int count;
            long length = 0;
            while ((count = input.Read(buffer, 0, buffer.Length)) != 0)
            {
                length += count;
                if (length > 256L * 1024 * 1024) throw new ValidationException("Staged file exceeds its size bound.");
                checksum.AppendData(buffer, 0, count);
                output.Write(buffer, 0, count);
            }
            if (Convert.ToHexStringLower(checksum.GetHashAndReset()) != expectedHash) throw new ValidationException("Staged file identity does not match.");
        }, expectedDestinationHash);
    }

    private static void AtomicWrite(string path, Action<FileStream> write, string? expectedHash = null)
    {
        CheckPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var currentHash = Hash(path);
        var originalHash = expectedHash ?? currentHash;
        if (currentHash != originalHash) throw new ValidationException("A destination changed before its atomic replacement.");
        var stage = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(stage, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { write(stream); stream.Flush(true); }
            CheckPath(path);
            if (Hash(path) != originalHash) throw new ValidationException("A destination changed while staging its atomic replacement.");
            if (originalHash == Missing) File.Move(stage, path, false);
            else
            {
                for (var attempt = 0; ; attempt++)
                {
                    CheckPath(path);
                    if (Hash(path) != originalHash) throw new ValidationException("A destination changed before its atomic replacement.");
                    try { File.Replace(stage, path, null); break; }
                    catch (IOException failure) when (OperatingSystem.IsWindows() && (failure.HResult & 0xffff) is 32 or 33 or 1175 && attempt < 15 && File.Exists(stage))
                    {
                        if (Hash(path) != originalHash) throw new ValidationException("A destination changed while waiting for an atomic replacement.");
                        Thread.Sleep(20);
                        CheckPath(path);
                        if (Hash(path) != originalHash) throw new ValidationException("A destination changed while waiting for an atomic replacement.");
                    }
                }
            }
        }
        finally { if (File.Exists(stage)) File.Delete(stage); }
    }
}

public sealed record JournalEntry(FileAddress Address, string BeforeHash, string AfterHash, int Index);
public sealed record FileJournal(int SchemaVersion, string State, JournalEntry[] Entries);

public sealed class FileTransaction(StoreLayout layout, Action<int>? fault = null)
{
    private const int MaximumJournalBytes = 1024 * 1024;
    private const int MaximumJournalEntries = 1024;
    private const int MaximumJournalDepth = 16;
    private const int MaximumJournalValues = 16384;

    public string Execute(IReadOnlyList<FileChange> changes, string? preparedId = null, bool archiveUnchanged = false)
    {
        var targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var change in changes)
        {
            var path = layout.Resolve(change.Address);
            if (!targets.Add(path)) throw new ValidationException("A transaction contains duplicate file destinations.");
            if (SafeFiles.Hash(path) != change.ExpectedHash) throw new ValidationException("Owned files changed after preview. Refresh before applying.");
        }
        if (!archiveUnchanged)
            changes = changes.Where(change => (change.Content is null ? SafeFiles.Missing : Identity.Hash(change.Content)) != change.ExpectedHash).ToArray();
        var transactionId = preparedId ?? Guid.NewGuid().ToString("N");
        if (!Guid.TryParseExact(transactionId, "N", out _)) throw new ValidationException("Invalid transaction identity.");
        var transactionRoot = Path.Combine(layout.Root(StorageArea.Data), ".transactions", transactionId);
        SafeFiles.CheckPath(transactionRoot);
        if (Directory.Exists(transactionRoot)) throw new ValidationException("Transaction identity is already present.");
        var entries = changes.Select((change, index) => new JournalEntry(change.Address, change.ExpectedHash, change.Content is null ? SafeFiles.Missing : Identity.Hash(change.Content), index)).ToArray();
        var journal = new FileJournal(1, "Preparing", entries);
        var journalBytes = SerializeJournal(journal);
        Directory.CreateDirectory(transactionRoot);
        SafeFiles.AtomicWrite(Path.Combine(transactionRoot, "journal.json"), journalBytes);
        for (var index = 0; index < changes.Count; index++)
        {
            if (entries[index].BeforeHash != SafeFiles.Missing) SafeFiles.AtomicCopy(layout.Resolve(changes[index].Address), Path.Combine(transactionRoot, index + ".before"), entries[index].BeforeHash);
            if (changes[index].Content is not null) SafeFiles.AtomicWrite(Path.Combine(transactionRoot, index + ".after"), changes[index].Content!);
        }
        journal = journal with { State = "Prepared" };
        WriteJournal(transactionRoot, journal);
        try
        {
            WriteJournal(transactionRoot, journal with { State = "Applying" });
            foreach (var entry in entries)
            {
                if (SafeFiles.Hash(layout.Resolve(entry.Address)) != entry.BeforeHash) throw new ValidationException("A destination changed during the transaction.");
                Apply(transactionRoot, entry, false);
                fault?.Invoke(entry.Index);
            }
            WriteJournal(transactionRoot, journal with { State = "Committed" });
            return transactionId;
        }
        catch
        {
            try { Recover(transactionId); }
            catch { throw new IOException("Rollback could not complete. Recovery files were retained; recover this transaction before further changes."); }
            throw;
        }
    }

    public void Recover(string transactionId)
    {
        if (!Guid.TryParseExact(transactionId, "N", out _)) throw new ValidationException("Invalid transaction identity.");
        var root = Path.Combine(layout.Root(StorageArea.Data), ".transactions", transactionId);
        var journal = ReadJournal(root);
        if (journal.State is "Committed" or "RolledBack") return;
        if (journal.State == "Preparing")
        {
            if (journal.Entries.Any(entry => SafeFiles.Hash(layout.Resolve(entry.Address)) != entry.BeforeHash))
                throw new ValidationException("Preparation recovery stopped because a destination changed externally.");
            WriteJournal(root, journal with { State = "RolledBack" });
            return;
        }
        foreach (var entry in journal.Entries)
        {
            var hash = SafeFiles.Hash(layout.Resolve(entry.Address));
            if (hash != entry.BeforeHash && hash != entry.AfterHash) throw new ValidationException("Recovery stopped because an owned file was changed externally.");
            if (entry.BeforeHash != SafeFiles.Missing && SafeFiles.Hash(Path.Combine(root, entry.Index + ".before")) != entry.BeforeHash)
                throw new ValidationException("Recovery backup identity does not match.");
        }
        foreach (var entry in journal.Entries.Reverse())
        {
            var hash = SafeFiles.Hash(layout.Resolve(entry.Address));
            if (hash == entry.BeforeHash) continue;
            if (hash != entry.AfterHash) throw new ValidationException("Recovery stopped because an owned file was changed externally.");
            Apply(root, entry, true);
        }
        WriteJournal(root, journal with { State = "RolledBack" });
    }

    public void RequireRecovered()
    {
        var root = Path.Combine(layout.Root(StorageArea.Data), ".transactions");
        SafeFiles.CheckPath(root);
        if (!Directory.Exists(root)) return;
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            SafeFiles.CheckPath(directory);
            var path = Path.Combine(directory, "journal.json");
            if (!File.Exists(path)) throw new ValidationException("An incomplete preparation is retained. Inspect recovery data before making changes.");
            if (ReadJournal(directory).State is not ("Committed" or "RolledBack")) throw new ValidationException("An interrupted transaction needs explicit recovery before changes.");
        }
    }

    internal FileJournal ReadJournal(string root)
    {
        using var document = StrictJson.Parse(SafeFiles.Read(Path.Combine(root, "journal.json"), MaximumJournalBytes), MaximumJournalBytes, MaximumJournalDepth, MaximumJournalValues);
        RequireJournalFields(document.RootElement, "SchemaVersion", "State", "Entries");
        var storedEntries = document.RootElement.GetProperty("Entries");
        if (storedEntries.ValueKind != JsonValueKind.Array || storedEntries.GetArrayLength() > MaximumJournalEntries) throw new ValidationException("Invalid recovery journal entries.");
        foreach (var entry in storedEntries.EnumerateArray())
        {
            RequireJournalFields(entry, "Address", "BeforeHash", "AfterHash", "Index");
            RequireJournalFields(entry.GetProperty("Address"), "Area", "RelativePath");
        }
        FileJournal journal;
        try { journal = document.RootElement.Deserialize<FileJournal>(StrictJson.Options) ?? throw new ValidationException("Invalid recovery journal."); }
        catch (JsonException) { throw new ValidationException("Recovery journal fields are invalid."); }
        if (journal.SchemaVersion != 1 || journal.State is not ("Preparing" or "Prepared" or "Applying" or "Committed" or "RolledBack") || journal.Entries is null || journal.Entries.Length > MaximumJournalEntries)
            throw new ValidationException("Unsupported recovery journal.");
        var destinations = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < journal.Entries.Length; index++)
        {
            var entry = journal.Entries[index];
            if (entry is null || entry.Index != index || (entry.BeforeHash != SafeFiles.Missing && !Identity.IsId(entry.BeforeHash)) || (entry.AfterHash != SafeFiles.Missing && !Identity.IsId(entry.AfterHash)) || !destinations.Add(layout.Resolve(entry.Address)))
                throw new ValidationException("Recovery journal entries or destinations are invalid.");
        }
        return journal;
    }

    private static void RequireJournalFields(JsonElement value, params string[] fields)
    {
        if (value.ValueKind != JsonValueKind.Object || fields.Any(field => !value.TryGetProperty(field, out _)))
            throw new ValidationException("Recovery journal fields are missing or invalid.");
    }

    private void Apply(string root, JournalEntry entry, bool restore)
    {
        var path = layout.Resolve(entry.Address);
        var hash = restore ? entry.BeforeHash : entry.AfterHash;
        var expectedHash = restore ? entry.AfterHash : entry.BeforeHash;
        if (SafeFiles.Hash(path) != expectedHash) throw new ValidationException("A destination changed before its transaction write.");
        if (hash == SafeFiles.Missing) { if (expectedHash != SafeFiles.Missing) File.Delete(path); }
        else
        {
            SafeFiles.AtomicCopy(Path.Combine(root, entry.Index + (restore ? ".before" : ".after")), path, hash, expectedHash);
        }
        if (SafeFiles.Hash(path) != hash) throw new IOException("An owned file failed post-write verification.");
    }

    private static byte[] SerializeJournal(FileJournal journal)
    {
        if (journal.Entries.Length > MaximumJournalEntries) throw new ValidationException("The transaction exceeds the supported recovery entry limit.");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(journal, StrictJson.Options);
        using var validated = StrictJson.Parse(bytes, MaximumJournalBytes, MaximumJournalDepth, MaximumJournalValues);
        return bytes;
    }

    private static void WriteJournal(string root, FileJournal journal) => SafeFiles.AtomicWrite(Path.Combine(root, "journal.json"), SerializeJournal(journal));
}