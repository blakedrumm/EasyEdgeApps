using EasyEdgeApps.Core;

namespace EasyEdgeApps.Core.Tests;

public sealed class EditorTests
{
    private static AppDefinition App(string name) => new() { DisplayName = name, Url = "https://example.com/" };

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RenameCompletionRefreshesOwnedMetadataWithoutDiscardingConcurrentNotes(bool changeNotes)
    {
        using var editor = new EditorSession(App("First"));
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { DisplayName = "Second" } });
        var completion = new TaskCompletionSource<AppDefinition>(TaskCreationOptions.RunContinuationsAsynchronously);
        var save = editor.SaveAsync((_, _) => completion.Task);
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { Notes = changeNotes ? "Typed while saving" : "" } });
        completion.SetResult(editor.Draft.Definition with { Aliases = ["First"], Notes = "" });
        Assert.True(await save);
        Assert.Equal(new[] { "First" }, editor.Draft.Definition.Aliases);
        Assert.Equal(changeNotes ? "Typed while saving" : "", editor.Draft.Definition.Notes);
        Assert.Equal(changeNotes, editor.IsDirty);
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { Notes = "" } });
        Assert.False(editor.IsDirty);
    }

    [Fact]
    public async Task WebsiteLookupCommitsResolvedAddressAndIconTogetherWhilePreservingNotes()
    {
        using var editor = new EditorSession(App("First"));
        editor.Edit(editor.Draft with { RequestedWebsite = "example.com" });
        var completion = new TaskCompletionSource<DownloadedIcon>(TaskCreationOptions.RunContinuationsAsynchronously);
        var lookup = editor.LoadWebsiteIconAsync("example.com", _ => completion.Task);
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { Notes = "Typed during lookup" } });
        completion.SetResult(new("http://example.com/app/", "http://example.com/favicon.ico", ".ico", WebsiteIconTests.ValidIcon()));
        await lookup;
        Assert.Equal("http://example.com/app/", editor.Draft.Definition.Url);
        Assert.Null(editor.Draft.RequestedWebsite);
        Assert.Equal("Typed during lookup", editor.Draft.Definition.Notes);
        Assert.Equal(WebsiteIconTests.ValidIcon(), editor.Draft.IconBytes);
        Assert.True(editor.IsDirty);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ChangedAddressOrInvalidImageCannotApplyAStaleResolvedWebsite(bool invalidImage)
    {
        using var editor = new EditorSession(App("First"));
        editor.Edit(editor.Draft with { RequestedWebsite = "example.com" });
        var completion = new TaskCompletionSource<DownloadedIcon>(TaskCreationOptions.RunContinuationsAsynchronously);
        var lookup = editor.LoadWebsiteIconAsync("example.com", _ => completion.Task);
        if (!invalidImage) editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { Url = "https://example.org/" }, RequestedWebsite = "example.org" });
        var expected = editor.Draft;
        completion.SetResult(new("http://example.com/", "http://example.com/favicon.ico", ".ico", invalidImage ? [1, 2] : WebsiteIconTests.ValidIcon()));
        await lookup;
        Assert.Equal(expected, editor.Draft);
        Assert.Null(editor.Draft.IconBytes);
        Assert.False(editor.IsBusy);
    }

    [Theory]
    [InlineData(DraftChoice.Cancel)]
    [InlineData(DraftChoice.Save)]
    public async Task CancelAndFailedSaveKeepSelectionAndEveryEdit(DraftChoice choice)
    {
        var original = App("First");
        using var editor = new EditorSession(original);
        var changed = editor.Draft with { Definition = original with { Url = "https://example.org/", Notes = "Draft", Window = original.Window with { AlwaysOnTop = true } }, IconBytes = [1, 2, 3], IconSource = "pending-image.png" };
        editor.Edit(changed);
        var before = editor.Draft;
        Assert.False(await editor.NavigateAsync(App("Second"), choice, (_, _) => throw new IOException("Synthetic failure")));
        Assert.Equal(original.Id, editor.SelectedId);
        Assert.Equal(before, editor.Draft);
        Assert.True(editor.IsDirty);
    }

    [Fact]
    public async Task SaveAndDiscardAdvanceOnlyAfterTheirChosenOutcome()
    {
        using var editor = new EditorSession(App("First"));
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { Notes = "save me" } });
        var saves = 0;
        Task<AppDefinition> Save(EditorDraft draft, CancellationToken token) { saves++; return Task.FromResult(draft.Definition); }
        var second = App("Second");
        Assert.True(await editor.NavigateAsync(second, DraftChoice.Save, Save));
        Assert.Equal(1, saves);
        Assert.Equal(second.Id, editor.SelectedId);
        editor.Edit(editor.Draft with { Definition = second with { Notes = "discard me" } });
        Assert.True(await editor.NavigateAsync(null, DraftChoice.Discard, Save));
        Assert.Equal(1, saves);
        Assert.Null(editor.SelectedId);
        Assert.False(editor.IsDirty);
    }

    [Fact]
    public async Task LateIconCompletionCannotModifyTheNewSelection()
    {
        using var editor = new EditorSession(App("First"));
        var completion = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = editor.LoadIconAsync("https://example.com/favicon.ico", _ => completion.Task);
        Assert.True(editor.IsDirty);
        var next = App("Second");
        Assert.True(await editor.NavigateAsync(next, DraftChoice.Discard, (draft, _) => Task.FromResult(draft.Definition)));
        completion.SetResult([1, 2, 3]);
        await pending;
        Assert.Equal(next.Id, editor.SelectedId);
        Assert.Null(editor.Draft.IconBytes);
        Assert.False(editor.IsDirty);
    }

    [Fact]
    public async Task SaveCancellationAndConcurrentEditsRemainRecoverable()
    {
        using var editor = new EditorSession(App("First"));
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { Notes = "before save" } });
        Assert.False(await editor.SaveAsync((draft, _) => Task.FromResult(draft.Definition), new CancellationToken(true)));
        Assert.Equal("before save", editor.Draft.Definition.Notes);
        editor.Edit(editor.Draft);
        var completion = new TaskCompletionSource<AppDefinition>(TaskCreationOptions.RunContinuationsAsynchronously);
        var captured = editor.Draft.Definition;
        var save = editor.SaveAsync((_, _) => completion.Task);
        editor.Edit(editor.Draft with { Definition = captured with { Notes = "edited while saving" } });
        completion.SetResult(captured);
        Assert.True(await save);
        Assert.Equal("edited while saving", editor.Draft.Definition.Notes);
        Assert.True(editor.IsDirty);
    }

    [Fact]
    public async Task NotesEditedDuringIconWorkDoNotDiscardTheChosenIcon()
    {
        using var editor = new EditorSession(App("First"));
        var completion = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = editor.LoadIconAsync("chosen.png", _ => completion.Task);
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { Notes = "Keep this note" } });
        var icon = new byte[70];
        icon[2] = icon[4] = icon[6] = icon[7] = icon[10] = icon[26] = icon[34] = 1;
        icon[12] = icon[36] = 32; icon[14] = 48; icon[18] = 22; icon[22] = 40; icon[30] = 2; icon[42] = 4; icon[65] = 255;
        completion.SetResult(icon);
        await pending;
        Assert.Equal(icon, editor.Draft.IconBytes);
        Assert.Equal("Keep this note", editor.Draft.Definition.Notes);
        Assert.False(editor.IsBusy);
    }

    [Fact]
    public async Task DiscardingAFailedIconDoesNotPoisonTheNextDraft()
    {
        using var editor = new EditorSession(App("First"));
        await editor.LoadIconAsync("invalid.png", _ => throw new ValidationException("Synthetic bad image"));
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { Notes = "An unrelated edit" } });
        Assert.False(await editor.SaveAsync((draft, _) => Task.FromResult(draft.Definition)));
        Assert.True(await editor.NavigateAsync(App("Second"), DraftChoice.Discard, (draft, _) => Task.FromResult(draft.Definition)));
        Assert.True(await editor.SaveAsync((draft, _) => Task.FromResult(draft.Definition)));
        Assert.False(editor.IsDirty);
    }
}