using System.Diagnostics;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;
using EasyEdgeApps.Windows;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using global::Windows.Storage.Pickers;

namespace EasyEdgeApps.Manager;

public sealed partial class MainWindow : Window
{
    private readonly CatalogStore store;
    private readonly EditorSession editor;
    private readonly IconWorkerClient iconWorker = new(Path.Combine(AppContext.BaseDirectory, "EasyEdgeApps.ImageWorker.exe"));
    private readonly PreferenceStore preferenceStore;
    private UserPreferences preferences = new();
    private readonly bool isolated;
    private readonly bool taskbarSupported;
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? operationCancellation;
    private string snapshot = SafeFiles.Missing;
    private bool loading = true;
    private bool navigating;
    private bool allowClose;
    private bool closingPrompt;
    private bool commandRunning;
    private long previewGeneration;
    private string lastSaveStatus = "Website saved.";

    public MainWindow(string[] arguments)
    {
        InitializeComponent();
        var isolatedIndex = Array.IndexOf(arguments, "--isolated-root");
        if (isolatedIndex >= 0 && isolatedIndex + 1 >= arguments.Length) throw new ValidationException("The isolated root needs a directory.");
        isolated = isolatedIndex >= 0;
        try { taskbarSupported = isolated || EasyEdgeApps.Taskbar.Native.SupportsPinRequests(); }
        catch { taskbarSupported = false; }
        StoreLayout layout;
        if (isolatedIndex >= 0 && isolatedIndex + 1 < arguments.Length)
        {
            var root = Path.GetFullPath(arguments[isolatedIndex + 1]);
            layout = new(Path.Combine(root, "Data"), Path.Combine(root, "Desktop"), Path.Combine(root, "Programs"), Path.Combine(root, "Legacy"));
        }
        else
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            layout = new(Path.Combine(local, "EasyEdgeApps.Next"), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Easy Edge Apps"), Path.Combine(local, "EasyEdgeApps"));
        }
        store = new(layout, new DesktopArtifacts(Path.Combine(AppContext.BaseDirectory, "WebsiteLauncher", "fresh-session.exe"))) { AllowExperimentalMigration = isolated };
        preferenceStore = new(layout);
        BrandImage.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Brand.png")));
        try { preferences = preferenceStore.Read(); } catch (Exception failure) { SetStatus(SafeMessage(failure)); }
        editor = new(createNew: () => new AppDefinition { EdgeProfile = preferences.DefaultProfile, Desktop = preferences.DefaultDesktop, StartMenu = preferences.DefaultStartMenu });
        AppearanceRoot.FontSize = preferences.TextSize;
        ThemeChoice.SelectedIndex = preferences.Theme switch { "System" => 1, "Light" => 2, "Dark" => 3, _ => 0 };
        SystemBackdrop = new MicaBackdrop();
        var workingArea = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        var initialWidth = Math.Min(1040, workingArea.Width);
        var initialHeight = Math.Min(780, workingArea.Height);
        AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(workingArea.X + (workingArea.Width - initialWidth) / 2, workingArea.Y + (workingArea.Height - initialHeight) / 2, initialWidth, initialHeight));
        AppWindow.Closing += Closing;
        WebsiteList.ContainerContentChanging += (_, change) => ApplyTextSize(change.ItemContainer);
        AdvancedPanel.RegisterPropertyChangedCallback(Expander.IsExpandedProperty, (_, _) => DispatcherQueue.TryEnqueue(() => ApplyTextSize(AdvancedPanel)));
        editor.Changed += (_, _) => DispatcherQueue.TryEnqueue(UpdateState);
        Reload();
        LoadDraft();
        loading = false;
        UpdateState();
        Shell.Loaded += async (_, _) =>
        {
            InitializeAppearance();
            ApplyTextSize(Shell);
            if (!isolated && preferences.CheckUpdates && (!DateTimeOffset.TryParse(preferences.LastUpdateCheckUtc, out var checkedAt) || checkedAt < DateTimeOffset.UtcNow.AddDays(-1)))
                await Run(CheckUpdates);
        };
    }

    private void Reload()
    {
        var priorLoading = loading;
        loading = true;
        try
        {
            var current = store.Read();
            snapshot = current.Hash;
            WebsiteList.ItemsSource = current.Catalog.Apps.Where(app => !app.Removed).OrderBy(app => app.Definition.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToArray();
            WebsiteList.SelectedItem = ((IEnumerable<AppRecord>)WebsiteList.ItemsSource).SingleOrDefault(app => app.Definition.Id == editor.SelectedId);
        }
        catch (Exception failure) { SetStatus(SafeMessage(failure)); }
        finally { loading = priorLoading; }
    }

    private void LoadDraft()
    {
        var priorLoading = loading;
        loading = true;
        var draft = editor.Draft.Definition;
        NameInput.Text = draft.DisplayName; AddressInput.Text = editor.Draft.RequestedWebsite ?? draft.Url; NotesInput.Text = draft.Notes; ProfileInput.Text = draft.EdgeProfile;
        DesktopChoice.IsChecked = draft.Desktop; StartChoice.IsChecked = draft.StartMenu;
        DedicatedChoice.IsChecked = draft.Window.DedicatedProfile; FreshChoice.IsChecked = draft.Window.FreshSession;
        WindowChoice.SelectedIndex = (int)draft.Window.LaunchMode; TopmostChoice.IsChecked = draft.Window.AlwaysOnTop; TaskbarChoice.IsChecked = draft.Window.Taskbar;
        loading = priorLoading;
        previewGeneration++;
        IconPreview.Source = null;
        if (editor.SelectedId is not null)
        {
            var record = store.Read().Catalog.Apps.Single(app => app.Definition.Id == editor.SelectedId);
            var iconPath = store.Layout.Resolve(CatalogStore.Address(record, "Icon"));
            if (File.Exists(iconPath)) _ = ShowIcon(SafeFiles.Read(iconPath, 1024 * 1024));
        }
        UpdateState();
    }

    private async Task ShowIcon(byte[] bytes)
    {
        var expected = ++previewGeneration;
        try
        {
            using var stream = new MemoryStream(IconService.PreviewPng(bytes));
            var image = new BitmapImage();
            await image.SetSourceAsync(stream.AsRandomAccessStream());
            if (expected == previewGeneration) IconPreview.Source = image;
        }
        catch (Exception failure) { if (expected == previewGeneration) SetStatus(SafeMessage(failure)); }
    }

    private void CaptureDraft()
    {
        if (loading || store is null) return;
        var address = AddressInput.Text;
        string? requestedWebsite = null;
        try
        {
            address = Identity.Website(address, true);
            var supplied = AddressInput.Text.Trim();
            if (!supplied.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !supplied.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) requestedWebsite = AddressInput.Text;
        }
        catch (ValidationException) { }
        editor.Edit(editor.Draft with
        {
            RequestedWebsite = requestedWebsite,
            Definition = editor.Draft.Definition with
            {
                DisplayName = NameInput.Text, Url = address, Notes = NotesInput.Text, EdgeProfile = ProfileInput.Text,
                Desktop = DesktopChoice.IsChecked == true, StartMenu = StartChoice.IsChecked == true,
                Window = new() { DedicatedProfile = DedicatedChoice.IsChecked == true, FreshSession = FreshChoice.IsChecked == true, LaunchMode = (LaunchMode)Math.Max(0, WindowChoice.SelectedIndex), AlwaysOnTop = TopmostChoice.IsChecked == true, Taskbar = TaskbarChoice.IsChecked == true }
            }
        });
        UpdateState();
    }

    private void InputChanged(object sender, TextChangedEventArgs args) => CaptureDraft();
    private void ChoiceChanged(object sender, RoutedEventArgs args) => SynchronizeWindowChoices();
    private void WindowChanged(object sender, SelectionChangedEventArgs args) => SynchronizeWindowChoices();

    private void SynchronizeWindowChoices()
    {
        if (loading) return;
        loading = true;
        try
        {
            if (TaskbarChoice.IsChecked == true)
            {
                StartChoice.IsChecked = true;
                DedicatedChoice.IsChecked = true;
            }
            var owned = DedicatedChoice.IsChecked == true || FreshChoice.IsChecked == true;
            if (!owned || WindowChoice.SelectedIndex == (int)LaunchMode.FullScreen) TopmostChoice.IsChecked = false;
        }
        finally { loading = false; }
        CaptureDraft();
    }

    private void UpdateState()
    {
        if (NameInput is null) return;
        ApplyTextSize(Shell);
        Activity.IsActive = editor.IsBusy || operationCancellation is not null;
        CancelOperationButton.Visibility = operationCancellation is not null ? Visibility.Visible : Visibility.Collapsed;
        CancelOperationButton.IsEnabled = operationCancellation is { IsCancellationRequested: false };
        MainCommands.IsEnabled = !commandRunning;
        PreferencesButton.IsEnabled = !commandRunning;
        foreach (var action in FooterActions.Children.OfType<Control>()) action.IsEnabled = !commandRunning;
        NewButton.IsEnabled = !commandRunning && !editor.IsSaving;
        WebsiteList.IsEnabled = !commandRunning && !editor.IsSaving;
        LaunchButton.IsEnabled = RemoveButton.IsEnabled = editor.SelectedId is not null && !editor.IsBusy && !commandRunning;
        SaveLabel.Text = editor.SelectedId is null ? "Add website" : "Save changes";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(SaveButton, editor.IsDirty ? "Unsaved changes" : "Saved");
        IconStatus.Text = editor.IsBusy ? "Preparing icon..." : editor.Draft.IconBytes is not null ? editor.Draft.IconSource : editor.SelectedId is not null ? "Saved icon" : "Automatic";
        var window = editor.Draft.Definition.Window;
        ProfileSummary.Text = window.FreshSession ? "You will sign in again each time. Temporary website data is removed after its owned windows close." : window.DedicatedProfile ? "Sign-in stays with this website. Your normal Edge data is not copied." : "This website uses your normal Edge profile. Its windows are not managed by Easy Edge Apps.";
        TopmostChoice.IsEnabled = window.LaunchMode != LaunchMode.FullScreen && window.Owned;
        TaskbarChoice.IsEnabled = taskbarSupported || window.Taskbar;
        StartChoice.IsEnabled = DedicatedChoice.IsEnabled = !window.Taskbar;
        ProfileInput.IsEnabled = !window.Owned;
        try
        {
            editor.Draft.Definition.Normalize();
            ValidationBar.IsOpen = editor.IsIconBlocked;
            ValidationBar.Message = editor.IsIconBlocked ? editor.LastError : "";
            SaveButton.IsEnabled = !editor.IsIconBlocked && !editor.IsSaving && !commandRunning;
        }
        catch (ValidationException failure) { ValidationBar.Message = failure.Message; ValidationBar.IsOpen = editor.IsDirty; SaveButton.IsEnabled = false; }
        if (editor.LastError.Length != 0) SetStatus(editor.LastError);
    }

    private async Task<AppDefinition> SaveDraft(EditorDraft draft, CancellationToken token)
    {
        var expected = snapshot;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(token, lifetime.Token);
        operationCancellation = cancellation;
        try
        {
            var definition = draft.Definition;
            var previous = store.Read().Catalog.Apps.SingleOrDefault(app => !app.Removed && app.Definition.Id == definition.Id)?.Definition;
            var changedMode = previous is not null && (previous.Window.FreshSession != definition.Window.FreshSession || previous.Window.DedicatedProfile != definition.Window.DedicatedProfile ||
                (!definition.Window.Owned && previous.EdgeProfile != definition.EdgeProfile));
            if (changedMode || (previous is null && definition.Window.FreshSession))
            {
                var detail = (previous is null ? "New website" : previous.Window.BrowsingMode) + "\nTo: " + definition.Window.BrowsingMode + "\n\nNormal Edge data is not copied or cleared. Existing dedicated data is retained. Fresh sessions start with empty website data and remove only their owned temporary profile after exit.";
                if (await Dialog("Change browsing mode?", Message(detail), "Save mode") != ContentDialogResult.Primary) throw new OperationCanceledException(cancellation.Token);
            }
            if (draft.RequestedWebsite is not null)
            {
                if (isolated) throw new ValidationException("Network address resolution is disabled in isolated test mode. Use a complete HTTP/HTTPS address for synthetic fixtures.");
                SetStatus("Resolving website address...");
                using var client = new WebsiteIconClient();
                var resolved = await client.ResolveAsync(draft.RequestedWebsite, cancellation.Token);
                definition = definition with { Url = resolved.Website };
            }
            if (new Uri(definition.Url).Scheme == "http")
            {
                var dialog = new ContentDialog { XamlRoot = Shell.XamlRoot, FontSize = preferences.TextSize, Title = "Save HTTP website?", Content = "HTTP is unencrypted. Do not use it for passwords or sensitive information.\n\n" + definition.Url,
                    PrimaryButtonText = "Save HTTP", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
                if (await ShowSizedDialog(dialog) != ContentDialogResult.Primary) throw new OperationCanceledException(cancellation.Token);
            }
            var result = await Task.Run(() => { cancellation.Token.ThrowIfCancellationRequested(); return store.Save(definition, expected, draft.IconBytes); }, cancellation.Token);
            snapshot = store.Read().Hash;
            Record("Save", "Success");
            lastSaveStatus = "Website saved.";
            if (result.Definition.Window.Taskbar)
            {
                try { lastSaveStatus += " " + await RequestTaskbarPin(result, cancellation.Token); }
                catch (OperationCanceledException) { lastSaveStatus += " Pin request cancelled."; }
                catch { lastSaveStatus += " Windows could not offer a pin. Use the owned Start menu shortcut."; }
            }
            SetStatus(lastSaveStatus);
            return result.Definition;
        }
        catch (OperationCanceledException) { Record("Save", "Cancelled"); throw; }
        catch (HttpRequestException) { Record("Save", "Failed"); throw new ValidationException("The website address could not be resolved. Your draft is unchanged. Check the connection or enter a complete address."); }
        catch (ValidationException) { Record("Save", "Conflict"); throw; }
        catch { Record("Save", "Failed"); throw; }
        finally { operationCancellation = null; }
    }

    private async Task<DraftChoice> AskDraft()
    {
        CaptureDraft();
        if (!editor.IsDirty) return DraftChoice.Discard;
        var dialog = new ContentDialog { XamlRoot = Shell.XamlRoot, FontSize = preferences.TextSize, Title = "Unsaved changes", Content = editor.IsIconBlocked ? editor.LastError : "Save changes to this website?", PrimaryButtonText = "Save", IsPrimaryButtonEnabled = !editor.IsIconBlocked, SecondaryButtonText = "Discard", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        return await ShowSizedDialog(dialog) switch { ContentDialogResult.Primary => DraftChoice.Save, ContentDialogResult.Secondary => DraftChoice.Discard, _ => DraftChoice.Cancel };
    }

    private async Task<bool> GuardDraft()
    {
        if (editor.IsSaving) return false;
        var choice = await AskDraft();
        if (choice == DraftChoice.Cancel) return false;
        if (choice == DraftChoice.Save) { if (!await editor.SaveAsync(SaveDraft) || editor.IsDirty) return false; Reload(); LoadDraft(); }
        else if (editor.IsDirty)
        {
            var saved = store.Read().Catalog.Apps.SingleOrDefault(app => app.Definition.Id == editor.SelectedId)?.Definition;
            if (!await editor.NavigateAsync(saved, DraftChoice.Discard, SaveDraft)) return false;
            LoadDraft();
        }
        return true;
    }

    private async Task Navigate(AppDefinition? target)
    {
        if (navigating) return;
        navigating = true;
        try { if (await editor.NavigateAsync(target, await AskDraft(), SaveDraft)) { LoadDraft(); SetStatus(target is null ? "New website." : "Website selected."); } Reload(); }
        finally { navigating = false; }
    }

    private async void SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (loading || navigating) return;
        if (commandRunning || editor.IsSaving)
        {
            loading = true;
            try { WebsiteList.SelectedItem = ((IEnumerable<AppRecord>)WebsiteList.ItemsSource).SingleOrDefault(app => app.Definition.Id == editor.SelectedId); }
            finally { loading = false; }
            return;
        }
        if (WebsiteList.SelectedItem is AppRecord selected) await Run(() => Navigate(selected.Definition));
    }
    private async void NewClicked(object sender, RoutedEventArgs args) => await Run(() => Navigate(null));
    private async void SaveClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        CaptureDraft();
        SetStatus("Saving website...");
        if (await editor.SaveAsync(SaveDraft)) { Reload(); LoadDraft(); SetStatus(lastSaveStatus); }
        else SetStatus(editor.LastError);
    });

    private async void LaunchClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft() || editor.SelectedId is null) return;
        if (isolated) throw new ValidationException("Browser launch is disabled in isolated test mode.");
        var record = store.Read().Catalog.Apps.Single(app => app.Definition.Id == editor.SelectedId);
        store.CheckOwned(record);
        Process.Start(new ProcessStartInfo(store.Layout.Resolve(CatalogStore.Address(record, "Launcher"))) { UseShellExecute = false });
        SetStatus("Website opened.");
    });

    private async void RemoveClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft() || editor.SelectedId is null) return;
        var target = store.Read().Catalog.Apps.Single(app => !app.Removed && app.Definition.Id == editor.SelectedId);
        var dialog = new ContentDialog { XamlRoot = Shell.XamlRoot, FontSize = preferences.TextSize, Title = "Remove website shortcuts?", Content = "Website: " + target.Definition.DisplayName + "\n\nBrowser data and unrelated files will remain. Windows pins are not removed automatically.", PrimaryButtonText = "Remove", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        if (await ShowSizedDialog(dialog) != ContentDialogResult.Primary) return;
        store.Remove(target.Definition.Id, snapshot);
        Record("Remove", "Success");
        await editor.NavigateAsync(null, DraftChoice.Discard, SaveDraft);
        Reload(); LoadDraft(); SetStatus("Owned website files removed. Browser data was retained.");
    });

    private async void RepairClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft() || editor.SelectedId is null) return;
        var result = await Task.Run(() => store.Repair(editor.SelectedId, snapshot));
        Record("Repair", "Success");
        await editor.NavigateAsync(result.Definition, DraftChoice.Discard, SaveDraft);
        Reload(); LoadDraft(); SetStatus("Website files verified and repaired. Profile and window choices were retained.");
    });

    private async void ChooseIconClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        foreach (var extension in new[] { ".ico", ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".svg" }) picker.FileTypeFilter.Add(extension);
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        await LoadIconFile(file.Path);
    });

    private async Task LoadIconFile(string path)
    {
        await editor.LoadIconAsync(path, token => iconWorker.FromFileAsync(path, token), lifetime.Token);
        if (editor.Draft.IconBytes is not null) await ShowIcon(editor.Draft.IconBytes);
        UpdateState();
    }

    private async void FetchIconClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (isolated) throw new ValidationException("Network icon requests are disabled in isolated test mode.");
        var website = AddressInput.Text;
        _ = Identity.Website(website, true);
        SetStatus("Fetching website icon...");
        await editor.LoadWebsiteIconAsync("Website:" + website, async token =>
        {
            using var client = new WebsiteIconClient();
            return await client.FetchAsync(website, (image, conversionToken) => iconWorker.ConvertAsync(image.Bytes, image.Format, conversionToken), token);
        }, lifetime.Token);
        if (editor.Draft.RequestedWebsite is null && editor.LastError.Length == 0)
        {
            var wasLoading = loading;
            loading = true;
            AddressInput.Text = editor.Draft.Definition.Url;
            loading = wasLoading;
        }
        if (editor.Draft.IconBytes is not null) await ShowIcon(editor.Draft.IconBytes);
        SetStatus(editor.LastError.Length == 0 ? "Website icon prepared." : editor.LastError);
    });

    private async void ResetIconClicked(object sender, RoutedEventArgs args) => await Run(ResetIcon);

    private async Task ResetIcon()
    {
        var bytes = IconService.Generate(NameInput.Text);
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { IconKind = "Generated" }, IconBytes = bytes, IconSource = "Automatic" });
        await ShowIcon(bytes);
        SetStatus("Automatic icon selected.");
    }

    private async void SavedIconClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        editor.CancelPending();
        if (editor.SelectedId is null)
        { await ResetIcon(); return; }
        var record = store.Read().Catalog.Apps.Single(app => !app.Removed && app.Definition.Id == editor.SelectedId);
        store.CheckOwned(record);
        var bytes = SafeFiles.Read(store.Layout.Resolve(CatalogStore.Address(record, "Icon")), 1024 * 1024);
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { IconKind = record.Definition.IconKind }, IconBytes = null, IconSource = "" });
        await ShowIcon(bytes);
        SetStatus("Saved icon restored. Other draft edits remain.");
    });

    private void CloseClicked(object sender, RoutedEventArgs args) => Close();
    private void CancelWorkClicked(object sender, RoutedEventArgs args) { operationCancellation?.Cancel(); editor.CancelPending(); UpdateState(); SetStatus("Pending work cancelled. Existing edits remain."); }
    private void ThemeChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!loading)
        {
            var next = preferences with { Theme = ThemeChoice.SelectedIndex switch { 1 => "System", 2 => "Light", 3 => "Dark", _ => "Original" } };
            try { preferenceStore.Save(next); preferences = next; }
            catch (Exception failure) { SetStatus(SafeMessage(failure)); }
        }
        RefreshAppearance();
    }

    private async void Closing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (allowClose) { lifetime.Cancel(); editor.Dispose(); return; }
        if (!editor.IsSaving) CaptureDraft();
        if (!editor.IsDirty && !editor.IsBusy && !commandRunning) { lifetime.Cancel(); editor.Dispose(); return; }
        args.Cancel = true;
        if (closingPrompt || editor.IsSaving || commandRunning) return;
        closingPrompt = true;
        try { await Run(async () => { if (await GuardDraft()) { allowClose = true; Close(); } }); }
        finally { closingPrompt = false; }
    }

    private void SetStatus(string message)
    {
        if (Status.Text == message) return;
        Status.Text = message;
        var peer = FrameworkElementAutomationPeer.FromElement(Status) ?? FrameworkElementAutomationPeer.CreatePeerForElement(Status);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void Record(string operation, string outcome)
    {
        try { preferenceStore.Record(operation, outcome); }
        catch { }
    }

    private async Task Run(Func<Task> operation)
    {
        if (commandRunning) return;
        commandRunning = true;
        try { UpdateState(); await operation(); }
        catch (Exception failure) { SetStatus(SafeMessage(failure)); }
        finally { commandRunning = false; UpdateState(); }
    }

    private void ShellSizeChanged(object sender, SizeChangedEventArgs args)
    {
        if (Body is null || WebsitePanel is null || EditorColumn is null) return;
        var compact = args.NewSize.Width < 820;
        Body.ColumnDefinitions[0].Width = new GridLength(compact ? 1 : 0.34, GridUnitType.Star);
        Body.ColumnDefinitions[1].Width = compact ? new GridLength(0) : new GridLength(0.66, GridUnitType.Star);
        Grid.SetRowSpan(WebsitePanel, compact ? 1 : 2);
        Grid.SetRowSpan(EditorColumn, compact ? 1 : 2);
        Grid.SetRow(EditorColumn, compact ? 1 : 0);
        Grid.SetColumn(EditorColumn, compact ? 0 : 1);
        WebsiteList.MaxHeight = compact ? 100 : double.PositiveInfinity;
        RenderScene();
    }

    private void SaveAccelerator(Microsoft.UI.Xaml.Input.KeyboardAccelerator sender, Microsoft.UI.Xaml.Input.KeyboardAcceleratorInvokedEventArgs args)
    { args.Handled = true; if (SaveButton.IsEnabled) SaveClicked(SaveButton, new()); }
    private void NewAccelerator(Microsoft.UI.Xaml.Input.KeyboardAccelerator sender, Microsoft.UI.Xaml.Input.KeyboardAcceleratorInvokedEventArgs args)
    { args.Handled = true; NewClicked(NewButton, new()); }

    private void IconDragOver(object sender, DragEventArgs args)
    {
        if (args.DataView.Contains(global::Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems))
            args.AcceptedOperation = global::Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
    }

    private async void IconDropped(object sender, DragEventArgs args) => await Run(async () =>
    {
        var items = await args.DataView.GetStorageItemsAsync();
        if (items.Count != 1 || items[0] is not global::Windows.Storage.StorageFile file) throw new ValidationException("Drop one ICO, PNG, JPEG, GIF, BMP or static SVG image.");
        await LoadIconFile(file.Path);
    });

    private static string SafeMessage(Exception failure) => failure is ValidationException validation ? validation.Message : "The operation could not finish safely. Existing data and edits were retained; check running windows and recovery status.";
}