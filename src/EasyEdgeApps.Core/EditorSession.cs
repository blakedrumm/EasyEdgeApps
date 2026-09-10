using System.Text.Json;

namespace EasyEdgeApps.Core;

public enum DraftChoice { Save, Discard, Cancel }
public sealed record EditorDraft(AppDefinition Definition, byte[]? IconBytes = null, string IconSource = "", string? RequestedWebsite = null);

public sealed class EditorSession : IDisposable
{
    private EditorDraft baseline;
    private readonly Func<AppDefinition> createNew;
    private long generation;
    private long workGeneration;
    private CancellationTokenSource? workCancellation;
    private Task? pendingWork;
    private bool saving;
    private bool iconFailed;
    public EditorDraft Draft { get; private set; }
    public string? SelectedId { get; private set; }
    public string LastError { get; private set; } = "";
    public bool IsSaving => saving;
    public bool IsIconBlocked => iconFailed;
    public bool IsBusy => saving || pendingWork is { IsCompleted: false };
    public bool IsDirty => pendingWork is { IsCompleted: false } || Fingerprint(Draft) != Fingerprint(baseline);
    public event EventHandler? Changed;

    public EditorSession(AppDefinition? selected = null, Func<AppDefinition>? createNew = null)
    {
        this.createNew = createNew ?? (() => new());
        Draft = baseline = new(selected ?? this.createNew());
        SelectedId = selected?.Id;
    }

    public void Edit(EditorDraft draft)
    {
        if (draft.Definition.Id != Draft.Definition.Id) throw new ValidationException("Editing cannot change permanent identity.");
        if (draft.Definition.Url != Draft.Definition.Url || draft.RequestedWebsite != Draft.RequestedWebsite || draft.IconSource != Draft.IconSource || !draft.IconBytes.AsSpan().SequenceEqual(Draft.IconBytes)) CancelPending();
        generation++;
        Draft = draft with { IconBytes = draft.IconBytes?.ToArray() };
        if (!iconFailed) LastError = "";
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public Task LoadIconAsync(string source, Func<CancellationToken, Task<byte[]>> load, CancellationToken cancellationToken = default)
        => LoadWebsiteIconAsync(source, async token => new("", source, ".ico", await load(token)), cancellationToken);

    public Task LoadWebsiteIconAsync(string source, Func<CancellationToken, Task<DownloadedIcon>> load, CancellationToken cancellationToken = default)
    {
        CancelPending();
        iconFailed = false;
        LastError = "";
        Draft = Draft with { IconSource = source };
        generation++;
        var expected = ++workGeneration;
        workCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = workCancellation.Token;
        pendingWork = CompleteIconAsync(expected, load, token);
        Changed?.Invoke(this, EventArgs.Empty);
        return pendingWork;
    }

    private async Task CompleteIconAsync(long expected, Func<CancellationToken, Task<DownloadedIcon>> load, CancellationToken token)
    {
        try
        {
            var image = await load(token);
            token.ThrowIfCancellationRequested();
            if (expected == workGeneration)
            {
                IconContract.Validate(image.Bytes);
                var website = image.Website.Length == 0 ? Draft.Definition.Url : Identity.Website(image.Website);
                Draft = Draft with
                {
                    Definition = Draft.Definition with { IconKind = "Custom", Url = website }, IconBytes = image.Bytes.ToArray(),
                    RequestedWebsite = image.Website.Length == 0 ? Draft.RequestedWebsite : null, IconSource = image.Source
                };
                LastError = "";
            }
        }
        catch (OperationCanceledException) { if (expected == workGeneration) { iconFailed = true; LastError = "Icon work was cancelled. Choose another icon, Use saved icon, or Automatic before saving."; } }
        catch (Exception failure) when (failure is ValidationException or IOException or HttpRequestException or InvalidOperationException)
        { if (expected == workGeneration) { iconFailed = true; LastError = "The icon could not be prepared. Choose another icon, Use saved icon, or Automatic before saving."; } }
        finally { if (expected == workGeneration) pendingWork = null; Changed?.Invoke(this, EventArgs.Empty); }
    }

    public async Task<bool> SaveAsync(Func<EditorDraft, CancellationToken, Task<AppDefinition>> save, CancellationToken cancellationToken = default)
    {
        if (saving) return false;
        saving = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            if (pendingWork is not null) await pendingWork.WaitAsync(cancellationToken);
            if (iconFailed) return false;
            cancellationToken.ThrowIfCancellationRequested();
            var captured = Draft with { Definition = Draft.Definition.Normalize(), IconBytes = Draft.IconBytes?.ToArray() };
            var expectedGeneration = generation;
            var saved = await save(captured, cancellationToken);
            SelectedId = saved.Id;
            baseline = captured with { Definition = saved, IconBytes = null, IconSource = "", RequestedWebsite = null };
            if (generation == expectedGeneration) Draft = baseline;
            else Draft = Draft with { Definition = Draft.Definition with { Aliases = saved.Aliases.ToArray() } };
            LastError = "";
            return true;
        }
        catch (OperationCanceledException) { LastError = "Save was cancelled. All edits are still here."; return false; }
        catch (ValidationException failure) { LastError = failure.Message; return false; }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or InvalidOperationException)
        { LastError = "Save could not complete. All edits are still here; check ownership, running windows and recovery status."; return false; }
        finally { saving = false; Changed?.Invoke(this, EventArgs.Empty); }
    }

    public async Task<bool> NavigateAsync(AppDefinition? target, DraftChoice choice, Func<EditorDraft, CancellationToken, Task<AppDefinition>> save, CancellationToken cancellationToken = default)
    {
        if (saving) return false;
        if (IsDirty)
        {
            if (choice == DraftChoice.Cancel) return false;
            if (choice == DraftChoice.Save && (!await SaveAsync(save, cancellationToken) || IsDirty)) return false;
        }
        CancelPending();
        Draft = baseline = new(target ?? createNew());
        SelectedId = target?.Id;
        LastError = "";
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    public void CancelPending()
    {
        generation++;
        workGeneration++;
        iconFailed = false;
        workCancellation?.Cancel();
        workCancellation?.Dispose();
        workCancellation = null;
        pendingWork = null;
    }

    private static string Fingerprint(EditorDraft draft) => Identity.Hash(JsonSerializer.SerializeToUtf8Bytes(draft, StrictJson.Options));
    public void Dispose() => CancelPending();
}