using System.IO.Compression;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Text.Json;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Persistence;

public sealed record PackageFile(string Path, long Size, string Sha256);
public sealed record PackageIndex(string Product, int SchemaVersion, string Version, string Architecture, PackageFile[] Files);
public sealed record StagedPackage(string Directory, string Version, string IndexHash, string SourceVersion);

public sealed class PackageMaintenance(Action<string, string> verifyPublisher)
{
    public async Task<StagedPackage> StageAsync(string packagePath, string destinationRoot, string expectedPublisher, string sourceVersion, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        SafeFiles.CheckPath(packagePath);
        destinationRoot = Path.GetFullPath(destinationRoot);
        SafeFiles.CheckPath(destinationRoot);
        if (new FileInfo(packagePath).Length > 1024L * 1024 * 1024) throw new ValidationException("Update package exceeds 1 GiB.");
        using var stream = new FileStream(packagePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read, false);
        if (archive.Entries.Count is < 2 or > 4096) throw new ValidationException("Invalid update package entry count.");
        var entries = new Dictionary<string, ZipArchiveEntry>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in archive.Entries)
        {
            ValidateRelative(entry.FullName);
            if (!entries.TryAdd(entry.FullName, entry) || entry.Length > 512L * 1024 * 1024 || ((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000)
                throw new ValidationException("Duplicate, oversized or linked package entry.");
        }
        if (!entries.TryGetValue("EasyEdgeApps.PackageIndex.dll", out var indexEntry) || indexEntry.Length > 2 * 1024 * 1024) throw new ValidationException("The signed package index is missing.");
        var stage = Path.Combine(destinationRoot, ".staging-" + Guid.NewGuid().ToString("N"));
        SafeFiles.CheckPath(stage);
        Directory.CreateDirectory(stage);
        var committed = false;
        try
        {
            var indexPath = Path.Combine(stage, "EasyEdgeApps.PackageIndex.dll");
            await Extract(indexEntry, indexPath, 2 * 1024 * 1024, token);
            verifyPublisher(indexPath, expectedPublisher);
            var indexBytes = ReadIndex(indexPath);
            using var document = StrictJson.Parse(indexBytes, 2 * 1024 * 1024, 16, 32768);
            var index = document.RootElement.Deserialize<PackageIndex>(StrictJson.Options) ?? throw new ValidationException("Invalid signed release index.");
            if (index.Product != "EasyEdgeApps.Package" || index.SchemaVersion != 1 || index.Architecture != "x64" || !Version.TryParse(index.Version, out var targetVersion) || !Version.TryParse(sourceVersion, out var currentVersion) || targetVersion <= currentVersion || index.Files is null || index.Files.Length != entries.Count - 1)
                throw new ValidationException("Package version, architecture or complete-file manifest is invalid.");
            var included = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            long total = 0;
            foreach (var file in index.Files)
            {
                if (file is null) throw new ValidationException("Invalid package file record.");
                ValidateRelative(file.Path);
                if (!included.Add(file.Path) || file.Path.Equals("EasyEdgeApps.PackageIndex.dll", StringComparison.OrdinalIgnoreCase) || !Identity.IsId(file.Sha256) || file.Size is < 0 or > 536870912 || !entries.TryGetValue(file.Path, out var entry) || entry.Length != file.Size || (total += file.Size) > 2L * 1024 * 1024 * 1024)
                    throw new ValidationException("The package does not match its complete signed index.");
                var path = Path.GetFullPath(Path.Combine(stage, file.Path));
                SafeFiles.CheckPath(path);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                await Extract(entry, path, file.Size, token);
                if (SafeFiles.Hash(path) != file.Sha256) throw new ValidationException("An update payload hash does not match its signed index.");
            }
            if (!included.Contains("EasyEdgeApps.Manager.exe") || !included.Contains("WebsiteLauncher/fresh-session.exe")) throw new ValidationException("The update lacks required manager and launcher binaries.");
            token.ThrowIfCancellationRequested();
            var destination = Path.Combine(destinationRoot, "Versions", index.Version);
            SafeFiles.CheckPath(destination);
            if (Directory.Exists(destination)) throw new ValidationException("This staged version already exists. Verify it rather than overwriting it.");
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            Directory.Move(stage, destination);
            committed = true;
            return new(destination, index.Version, Identity.Hash(indexBytes), sourceVersion);
        }
        finally { if (!committed && Directory.Exists(stage)) Directory.Delete(stage, true); }
    }

    public static void VerifyStaged(StagedPackage staged, string currentVersion)
    {
        if (staged.SourceVersion != currentVersion) throw new ValidationException("The source version changed after update approval.");
        var bytes = ReadIndex(Path.Combine(staged.Directory, "EasyEdgeApps.PackageIndex.dll"));
        if (Identity.Hash(bytes) != staged.IndexHash) throw new ValidationException("The staged index changed after approval.");
        using var document = StrictJson.Parse(bytes, 2 * 1024 * 1024, 16, 32768);
        var index = document.RootElement.Deserialize<PackageIndex>(StrictJson.Options)!;
        if (index is null || index.Product != "EasyEdgeApps.Package" || index.SchemaVersion != 1 || index.Architecture != "x64" || index.Version != staged.Version || index.Files is null || index.Files.Length > 4095)
            throw new ValidationException("The staged index is invalid.");
        var included = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "EasyEdgeApps.PackageIndex.dll" };
        foreach (var file in index.Files)
        {
            if (file is null) throw new ValidationException("Invalid package file record.");
            ValidateRelative(file.Path);
            var path = Path.Combine(staged.Directory, file.Path);
            if (!included.Add(file.Path) || !Identity.IsId(file.Sha256) || SafeFiles.Hash(path) != file.Sha256 || new FileInfo(path).Length != file.Size)
                throw new ValidationException("A staged update file changed after verification.");
        }
        var pending = new Stack<string>();
        pending.Push(staged.Directory);
        var inspected = 0;
        while (pending.TryPop(out var directory))
        {
            SafeFiles.CheckPath(directory);
            foreach (var path in System.IO.Directory.EnumerateFileSystemEntries(directory))
            {
                if (++inspected > 8192) throw new ValidationException("The staged directory exceeds its entry bound.");
                SafeFiles.CheckPath(path);
                if (System.IO.Directory.Exists(path)) pending.Push(path);
                else if (!included.Contains(Path.GetRelativePath(staged.Directory, path).Replace('\\', '/')))
                    throw new ValidationException("An unapproved file was added to the staged update.");
            }
        }
    }

    public static byte[] ReadIndex(string assemblyPath)
    {
        using var stream = new MemoryStream(SafeFiles.Read(assemblyPath, 2 * 1024 * 1024), false);
        using var reader = new PEReader(stream);
        if (!reader.HasMetadata || reader.PEHeaders.CorHeader is null) throw new ValidationException("The signed index is not a managed resource container.");
        var metadata = reader.GetMetadataReader();
        var resources = metadata.ManifestResources.Select(metadata.GetManifestResource).Where(resource => metadata.GetString(resource.Name) == "EasyEdgeApps.ReleaseIndex.json" && resource.Implementation.IsNil).ToArray();
        if (resources.Length != 1) throw new ValidationException("The package index resource is missing or ambiguous.");
        var block = reader.GetSectionData(reader.PEHeaders.CorHeader.ResourcesDirectory.RelativeVirtualAddress).GetReader();
        block.Offset = checked((int)resources[0].Offset);
        var count = block.ReadInt32();
        if (count < 2 || count > 2 * 1024 * 1024 || count > block.RemainingBytes) throw new ValidationException("Invalid package resource bounds.");
        return block.ReadBytes(count);
    }

    private static void ValidateRelative(string path)
    {
        if (string.IsNullOrEmpty(path) || path.Length > 1024 || Path.IsPathRooted(path) || path.Contains('\\') || path.Any(char.IsControl) || path.Split('/').Any(segment => segment is "" or "." or ".." || segment.IndexOfAny([':', '"', '<', '>', '|', '?', '*']) >= 0 || segment.EndsWith('.') || segment.EndsWith(' ') || ReservedDevice(segment)))
            throw new ValidationException("Unsafe update package path.");
    }

    private static bool ReservedDevice(string segment)
    {
        var name = segment.Split('.')[0].ToUpperInvariant();
        return name is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$" ||
            name.Length == 4 && (name.StartsWith("COM", StringComparison.Ordinal) || name.StartsWith("LPT", StringComparison.Ordinal)) && (name[3] is >= '1' and <= '9' or '\u00b9' or '\u00b2' or '\u00b3');
    }

    private static async Task Extract(ZipArchiveEntry entry, string path, long maximum, CancellationToken token)
    {
        using var input = entry.Open();
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous);
        var buffer = new byte[65536];
        int count;
        long total = 0;
        while ((count = await input.ReadAsync(buffer, token)) > 0)
        {
            if ((total += count) > maximum) throw new ValidationException("Expanded update file exceeds its bound.");
            await output.WriteAsync(buffer.AsMemory(0, count), token);
        }
        if (total != entry.Length) throw new ValidationException("Incomplete update entry.");
        await output.FlushAsync(token);
        output.Flush(true);
    }
}