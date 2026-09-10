using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Windows;

public static class TaskbarAssistance
{
    public static ProcessStartInfo CreateRequest(CatalogStore store, AppRecord record)
    {
        record.Definition.Normalize();
        if (!record.Definition.Window.Taskbar || !record.Definition.Window.DedicatedProfile || !record.Definition.StartMenu)
            throw new ValidationException("Taskbar pinning requires Taskbar identity, Separate profile and Start menu.");
        store.CheckOwned(record);
        var start = new ProcessStartInfo(store.Layout.Resolve(CatalogStore.Address(record, "Launcher"))) { UseShellExecute = false };
        start.ArgumentList.Add("--pin");
        return start;
    }

    public static async Task<string> RequestAsync(CatalogStore store, AppRecord record, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        using var process = Process.Start(CreateRequest(store, record)) ?? throw new ValidationException("The owned pin helper did not start.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(140));
        try { await process.WaitForExitAsync(deadline.Token); }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(true);
            await process.WaitForExitAsync(CancellationToken.None);
            throw;
        }
        return process.ExitCode switch { 0 => "Windows confirmed the website pin.", 3 => "The website was not pinned.", _ => "Windows could not confirm a pin. Use the owned Start menu shortcut." };
    }
}