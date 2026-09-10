using System.Text.Json;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Core.Tests;

public sealed class TestDirectory : IDisposable
{
    public string Root { get; }
    public StoreLayout Layout { get; }
    public TestDirectory()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "EasyEdgeApps.ps1"))) directory = directory.Parent;
        if (directory is null) throw new InvalidOperationException("Tests must run from the authorized repository.");
        Root = Path.Combine(directory.FullName, "artifacts", "dotnet-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Root);
        Layout = new(Path.Combine(Root, "Data"), Path.Combine(Root, "Desktop"), Path.Combine(Root, "Programs"), Path.Combine(Root, "Legacy"));
    }
    public void Dispose() { if (Directory.Exists(Root)) Directory.Delete(Root, true); }
}

public sealed class TransactionTests
{
    [Fact]
    public void OversizedJournalIsRejectedBeforeCreatingRecoveryState()
    {
        using var fixture = new TestDirectory();
        var changes = Enumerable.Range(0, 1025).Select(index => new FileChange(new(StorageArea.Data, "unchanged-" + index), SafeFiles.Missing, null)).ToArray();
        var transaction = new FileTransaction(fixture.Layout);

        Assert.Throws<ValidationException>(() => transaction.Execute(changes, archiveUnchanged: true));

        Assert.False(Directory.Exists(Path.Combine(fixture.Layout.DataRoot, ".transactions")));
        transaction.RequireRecovered();
    }

    [Fact]
    public async Task RecoveryRechecksOwnershipBeforeEachRestore()
    {
        using var fixture = new TestDirectory();
        var first = new FileAddress(StorageArea.Data, "first.bin");
        var second = new FileAddress(StorageArea.Data, "second.bin");
        var firstPath = fixture.Layout.Resolve(first);
        var secondPath = fixture.Layout.Resolve(second);
        SafeFiles.AtomicWrite(firstPath, "after"u8.ToArray());
        SafeFiles.AtomicWrite(secondPath, "after"u8.ToArray());
        var transactionId = Guid.NewGuid().ToString("N");
        var root = Path.Combine(fixture.Layout.DataRoot, ".transactions", transactionId);
        var entries = new[] { first, second }.Select((address, index) => new JournalEntry(address, Identity.Hash("before"u8), Identity.Hash("after"u8), index)).ToArray();
        foreach (var entry in entries) SafeFiles.AtomicWrite(Path.Combine(root, entry.Index + ".before"), "before"u8.ToArray());
        SafeFiles.AtomicWrite(Path.Combine(root, "journal.json"), JsonSerializer.SerializeToUtf8Bytes(new FileJournal(1, "Applying", entries), StrictJson.Options));
        var staged = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var watcher = new FileSystemWatcher(fixture.Layout.DataRoot, "second.bin.*.tmp");
        watcher.Created += (_, _) => staged.TrySetResult();
        watcher.EnableRaisingEvents = true;
        using var blocker = new FileStream(secondPath, FileMode.Open, FileAccess.Read, FileShare.Read);
        var transaction = new FileTransaction(fixture.Layout);
        var recovery = Task.Run(() => transaction.Recover(transactionId));
        try
        {
            await staged.Task.WaitAsync(TimeSpan.FromSeconds(5));
            File.WriteAllText(firstPath, "external change after recovery preflight");
            blocker.Dispose();

            await Assert.ThrowsAsync<ValidationException>(async () => await recovery.WaitAsync(TimeSpan.FromSeconds(5)));

            Assert.Equal("external change after recovery preflight", File.ReadAllText(firstPath));
            Assert.Equal("before", File.ReadAllText(secondPath));
            Assert.Throws<ValidationException>(() => transaction.RequireRecovered());
        }
        finally
        {
            blocker.Dispose();
            await Record.ExceptionAsync(async () => await recovery.WaitAsync(TimeSpan.FromSeconds(5)));
        }
    }

    [Fact]
    public void StreamedStageIsVerifiedBeforeReplacingAnExistingDestination()
    {
        using var fixture = new TestDirectory();
        var source = fixture.Layout.Resolve(new(StorageArea.Data, "source.stage"));
        var destination = fixture.Layout.Resolve(new(StorageArea.Data, "destination.bin"));
        SafeFiles.AtomicWrite(source, "staged replacement"u8.ToArray());
        SafeFiles.AtomicWrite(destination, "original"u8.ToArray());
        Assert.Throws<ValidationException>(() => SafeFiles.AtomicCopy(source, destination, Identity.Hash("not these bytes"u8)));
        Assert.Equal("original", File.ReadAllText(destination));
        Assert.Empty(Directory.EnumerateFiles(fixture.Layout.DataRoot, "*.tmp"));
        SafeFiles.AtomicCopy(source, destination, Identity.Hash("staged replacement"u8));
        Assert.Equal("staged replacement", File.ReadAllText(destination));
        Assert.Equal("staged replacement", File.ReadAllText(source));
        Assert.Empty(Directory.EnumerateFiles(fixture.Layout.DataRoot, "*.tmp"));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public void FailedTransactionRestoresPreviousBytesAndUnrelatedData(int failAt)
    {
        using var fixture = new TestDirectory();
        var first = new FileAddress(StorageArea.Data, "first.json");
        var second = new FileAddress(StorageArea.Desktop, "second.lnk");
        SafeFiles.AtomicWrite(fixture.Layout.Resolve(first), "before"u8.ToArray());
        var sentinel = Path.Combine(fixture.Root, "unrelated");
        File.WriteAllText(sentinel, "never change");
        var changes = new FileChange[] { new(first, Identity.Hash("before"u8), "after"u8.ToArray()), new(second, SafeFiles.Missing, "new"u8.ToArray()) };
        var transaction = new FileTransaction(fixture.Layout, index => { if (index == failAt) throw new IOException("Synthetic failure."); });
        Assert.Throws<IOException>(() => transaction.Execute(changes));
        Assert.Equal("before", File.ReadAllText(fixture.Layout.Resolve(first)));
        Assert.False(File.Exists(fixture.Layout.Resolve(second)));
        Assert.Equal("never change", File.ReadAllText(sentinel));
        transaction.RequireRecovered();
    }

    [Fact]
    public void StaleApprovalAndLockedFileFailWithoutChangingData()
    {
        using var fixture = new TestDirectory();
        var address = new FileAddress(StorageArea.Data, "app.json");
        var path = fixture.Layout.Resolve(address);
        SafeFiles.AtomicWrite(path, "before"u8.ToArray());
        var transaction = new FileTransaction(fixture.Layout);
        Assert.Throws<ValidationException>(() => transaction.Execute([new(address, SafeFiles.Missing, "after"u8.ToArray())]));
        using (var lease = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.Throws<IOException>(() => transaction.Execute([new(address, Identity.Hash("before"u8), "after"u8.ToArray())]));
        Assert.Equal("before", File.ReadAllText(path));
    }

    [Fact]
    public async Task BriefReaderContentionDoesNotLoseAnAtomicWrite()
    {
        using var fixture = new TestDirectory();
        var path = fixture.Layout.Resolve(new(StorageArea.Data, "contention.json"));
        SafeFiles.AtomicWrite(path, "before"u8.ToArray());
        var staged = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var watcher = new FileSystemWatcher(fixture.Layout.DataRoot, "contention.json.*.tmp");
        watcher.Created += (_, _) => staged.TrySetResult();
        watcher.EnableRaisingEvents = true;
        using var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var write = Task.Run(() => SafeFiles.AtomicWrite(path, "after"u8.ToArray()));
        try
        {
            await staged.Task.WaitAsync(TimeSpan.FromSeconds(15));
            Assert.False(write.IsCompleted);
            Assert.Equal("before", File.ReadAllText(path));
            reader.Dispose();
            await write.WaitAsync(TimeSpan.FromSeconds(15));
        }
        finally
        {
            reader.Dispose();
            await write;
        }
        Assert.Equal("after", File.ReadAllText(path));
        Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(path)!, "*.tmp"));
    }

    [Fact]
    public void PersistentReaderContentionFailsWithoutDeletingTheOriginal()
    {
        using var fixture = new TestDirectory();
        var path = fixture.Layout.Resolve(new(StorageArea.Data, "contention.json"));
        SafeFiles.AtomicWrite(path, "before"u8.ToArray());
        using var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Assert.Throws<IOException>(() => SafeFiles.AtomicWrite(path, "after"u8.ToArray()));
        Assert.Equal("before", File.ReadAllText(path));
        Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(path)!, "*.tmp"));
    }

    [Fact]
    public void UnrelatedChangesDuringRollbackArePreservedForExplicitRecovery()
    {
        using var fixture = new TestDirectory();
        var address = new FileAddress(StorageArea.Data, "app.json");
        var path = fixture.Layout.Resolve(address);
        SafeFiles.AtomicWrite(path, "before"u8.ToArray());
        var transaction = new FileTransaction(fixture.Layout, _ => { File.WriteAllText(path, "external"); throw new IOException("Fault"); });
        Assert.Throws<IOException>(() => transaction.Execute([new(address, Identity.Hash("before"u8), "after"u8.ToArray())]));
        Assert.Equal("external", File.ReadAllText(path));
        Assert.Throws<ValidationException>(() => transaction.RequireRecovered());
    }

    [Fact]
    public void InterruptedPreparationCanBeRetiredWithoutCompleteBackupsOrDestinationWrites()
    {
        using var fixture = new TestDirectory();
        var address = new FileAddress(StorageArea.Data, "app.json");
        var path = fixture.Layout.Resolve(address);
        SafeFiles.AtomicWrite(path, "before"u8.ToArray());
        var transactionId = Guid.NewGuid().ToString("N");
        var journalPath = Path.Combine(fixture.Layout.DataRoot, ".transactions", transactionId, "journal.json");
        var journal = new FileJournal(1, "Preparing", [new(address, Identity.Hash("before"u8), Identity.Hash("after"u8), 0)]);
        SafeFiles.AtomicWrite(journalPath, JsonSerializer.SerializeToUtf8Bytes(journal, StrictJson.Options));
        var transaction = new FileTransaction(fixture.Layout);
        Assert.Throws<ValidationException>(() => transaction.RequireRecovered());
        transaction.Recover(transactionId);
        Assert.Equal("before", File.ReadAllText(path));
        transaction.RequireRecovered();
        using var document = JsonDocument.Parse(File.ReadAllBytes(journalPath));
        Assert.Equal("RolledBack", document.RootElement.GetProperty("State").GetString());
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[null]")]
    [InlineData("[{\"Address\":null,\"BeforeHash\":\"Missing\",\"AfterHash\":\"Missing\",\"Index\":0}]")]
    [InlineData("[{\"Address\":{\"Area\":\"Data\",\"RelativePath\":null},\"BeforeHash\":\"Missing\",\"AfterHash\":\"Missing\",\"Index\":0}]")]
    [InlineData("[{\"Address\":{\"RelativePath\":\"app.json\"},\"BeforeHash\":\"Missing\",\"AfterHash\":\"Missing\",\"Index\":0}]")]
    [InlineData("[{\"Address\":{\"Area\":\"Data\",\"RelativePath\":\"app.json\"},\"BeforeHash\":\"Missing\",\"AfterHash\":\"Missing\"}]")]
    public void InvalidRecoveryRecordsAreRejectedAsValidationBeforeAnyWrite(string entries)
    {
        using var fixture = new TestDirectory();
        var transactionId = Guid.NewGuid().ToString("N");
        var journalPath = Path.Combine(fixture.Layout.DataRoot, ".transactions", transactionId, "journal.json");
        var bytes = System.Text.Encoding.UTF8.GetBytes("{\"SchemaVersion\":1,\"State\":\"Applying\",\"Entries\":" + entries + "}");
        SafeFiles.AtomicWrite(journalPath, bytes);
        Assert.Throws<ValidationException>(() => new FileTransaction(fixture.Layout).Recover(transactionId));
        Assert.Equal(bytes, File.ReadAllBytes(journalPath));
    }

    [Fact]
    public void DuplicateAndInvalidBackupIndexesAreRejectedBeforeRollback()
    {
        using var fixture = new TestDirectory();
        var address = new FileAddress(StorageArea.Data, "app.json");
        var path = fixture.Layout.Resolve(address);
        SafeFiles.AtomicWrite(path, "after"u8.ToArray());
        var transactionId = Guid.NewGuid().ToString("N");
        var root = Path.Combine(fixture.Layout.DataRoot, ".transactions", transactionId);
        var entry = new JournalEntry(address, Identity.Hash("before"u8), Identity.Hash("after"u8), 0);
        SafeFiles.AtomicWrite(Path.Combine(root, "0.before"), "before"u8.ToArray());
        foreach (var entries in new[] { new[] { entry, entry }, new[] { entry with { Index = -1 } } })
        {
            SafeFiles.AtomicWrite(Path.Combine(root, "journal.json"), JsonSerializer.SerializeToUtf8Bytes(new FileJournal(1, "Applying", entries), StrictJson.Options));
            Assert.Throws<ValidationException>(() => new FileTransaction(fixture.Layout).Recover(transactionId));
            Assert.Equal("after", File.ReadAllText(path));
        }
    }

    [Theory]
    [InlineData("../outside")]
    [InlineData("app.json:stream")]
    [InlineData("C:\\outside")]
    public void StorageAddressCannotEscape(string relative)
    {
        using var fixture = new TestDirectory();
        Assert.Throws<ValidationException>(() => fixture.Layout.Resolve(new(StorageArea.Data, relative)));
    }
}