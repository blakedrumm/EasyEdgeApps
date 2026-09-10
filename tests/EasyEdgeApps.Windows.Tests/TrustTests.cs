using EasyEdgeApps.Core;
using EasyEdgeApps.Core.Tests;
using EasyEdgeApps.Persistence;
using EasyEdgeApps.Windows;

namespace EasyEdgeApps.Windows.Tests;

public sealed class TrustTests
{
    [Fact]
    public void UnsignedRealArtifactFailsPublisherAndTimestampGate()
    {
        Assert.Throws<ValidationException>(() => PublisherTrust.Verify(typeof(TrustTests).Assembly.Location, new string('a', 40)));
        Assert.Throws<ValidationException>(() => PublisherTrust.Verify(typeof(TrustTests).Assembly.Location, ""));
    }

    [Fact]
    public void SupportReportContainsNoPrivateDefinitionsOrPaths()
    {
        using var fixture = new TestDirectory();
        var store = new CatalogStore(fixture.Layout, new ReportArtifacts());
        store.Save(new() { DisplayName = "PrivateUsername", Url = "https://example.com/?secret=hidden", Notes = "private-note" }, SafeFiles.Missing);
        var report = SupportReport.Create(store, typeof(TrustTests).Assembly.Location);
        foreach (var secret in new[] { "PrivateUsername", "private-note", "example.com", "hidden", fixture.Root, Environment.UserName })
            Assert.DoesNotContain(secret, report, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("AppHealthCounts", report);
    }

    private sealed class ReportArtifacts : IAppArtifacts
    {
        public IDisposable AcquireWriterLease() => new MemoryStream();
        public void ValidateLegacy(LegacyManifest manifest, StoreLayout layout) { }
        public AppArtifacts Build(AppRecord record, StoreLayout layout, byte[]? iconBytes, bool regenerateIcon) => new("synthetic", "test",
            new() { ["Icon"] = [1], ["Launcher"] = [2], ["Configuration"] = [3], ["Desktop"] = [4], ["StartMenu"] = [5] });
    }
}