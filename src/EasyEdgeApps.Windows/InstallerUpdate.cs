using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Windows;

public sealed record InstallerApproval(string Path, string Hash, string Version);

public static class InstallerUpdate
{
    public static string ExpectedPublisher => typeof(InstallerUpdate).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().SingleOrDefault(attribute => attribute.Key == "ExpectedPublisherThumbprint")?.Value ?? "";
    public static bool IsConfigured => Regex.IsMatch(ExpectedPublisher, "\\A[A-Fa-f0-9]{40}\\z");

    public static bool IsNewerRelease(string tag)
    {
        if (!Regex.IsMatch(tag ?? "", "\\Av[0-9]+\\.[0-9]+\\.[0-9]+\\z") || !Version.TryParse(tag.Substring(1), out var release)) return false;
        var assembly = typeof(InstallerUpdate).Assembly;
        var version = assembly.GetName().Version;
        var current = new Version(version.Major, version.Minor, version.Build);
        var prerelease = (assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "").Split('+')[0].Contains('-');
        return release > current || prerelease && release == current;
    }

    public static async Task<InstallerApproval> DownloadAsync(UpdateClient client, ReleaseInfo release, ReleaseAsset asset, string root, IProgress<long> progress, CancellationToken token)
    {
        if (!IsConfigured) throw new ValidationException("This build has no production publisher pin. Automatic installation is unavailable.");
        if (!asset.Name.EndsWith("-x64.msi", StringComparison.Ordinal) || asset.Size > 512L * 1024 * 1024 || !IsNewerRelease(release.Tag) || !Version.TryParse(release.Tag.TrimStart('v'), out var version))
            throw new ValidationException("Select a compatible compiled x64 installer.");
        root = System.IO.Path.GetFullPath(root); SafeFiles.CheckPath(root);
        Directory.CreateDirectory(root);
        var path = System.IO.Path.Combine(root, Guid.NewGuid().ToString("N") + ".msi");
        var retained = false;
        try
        {
            using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous))
            {
                await client.DownloadAsync(release, asset, file, progress, token);
                await file.FlushAsync(token); file.Flush(true);
            }
            PublisherTrust.Verify(path, ExpectedPublisher);
            ValidateProduct(path, version.ToString());
            token.ThrowIfCancellationRequested();
            var approval = new InstallerApproval(path, SafeFiles.Hash(path), version.ToString());
            retained = true;
            return approval;
        }
        finally { if (!retained && File.Exists(path)) File.Delete(path); }
    }

    public static ProcessStartInfo CreateStartInfo(InstallerApproval approval)
    {
        ValidateApproval(approval);
        var start = new ProcessStartInfo(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "msiexec.exe")) { UseShellExecute = false };
        start.ArgumentList.Add("/i"); start.ArgumentList.Add(approval.Path); start.ArgumentList.Add("/norestart");
        return start;
    }

    public static void ValidateApproval(InstallerApproval approval)
    {
        if (!IsConfigured) throw new ValidationException("This build has no production publisher pin. Automatic installation is unavailable.");
        if (!IsNewerRelease("v" + approval.Version)) throw new ValidationException("The approved release is no longer newer than this build.");
        if (SafeFiles.Hash(approval.Path) != approval.Hash) throw new ValidationException("The approved installer changed. Download and verify it again.");
        PublisherTrust.Verify(approval.Path, ExpectedPublisher);
        ValidateProduct(approval.Path, approval.Version);
    }

    public static void ValidateProduct(string path, string expectedVersion)
    {
        SafeFiles.CheckPath(System.IO.Path.GetFullPath(path));
        dynamic installer = Activator.CreateInstance(Type.GetTypeFromProgID("WindowsInstaller.Installer", true));
        object databaseObject = null;
        try
        {
            dynamic database = installer.OpenDatabase(path, 0);
            databaseObject = database;
            string Property(string name)
            {
                dynamic view = database.OpenView("SELECT `Value` FROM `Property` WHERE `Property` = '" + name + "'");
                object recordObject = null;
                try
                {
                    view.Execute(); dynamic record = view.Fetch(); recordObject = record;
                    return record is null ? "" : (string)record.StringData(1);
                }
                finally { if (recordObject is not null) Marshal.FinalReleaseComObject(recordObject); view.Close(); Marshal.FinalReleaseComObject(view); }
            }
            if (Property("UpgradeCode") != "{9D0AF71A-353C-4A88-A171-16249356093F}" || Property("ProductName") != "Easy Edge Apps" || Property("ProductVersion") != expectedVersion || Property("ALLUSERS").Length != 0)
                throw new ValidationException("The signed installer has unexpected product, version or per-user identity.");
        }
        finally { if (databaseObject is not null) Marshal.FinalReleaseComObject(databaseObject); Marshal.FinalReleaseComObject(installer); }
    }
}