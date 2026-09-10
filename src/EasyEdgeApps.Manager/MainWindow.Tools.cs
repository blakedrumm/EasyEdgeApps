using System.Text;
using System.Text.Json;
using System.Diagnostics;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;
using EasyEdgeApps.Windows;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using global::Windows.Storage;
using global::Windows.Storage.Pickers;

namespace EasyEdgeApps.Manager;

public sealed partial class MainWindow
{
    private sealed record TextSizeOption(string Label, double Dips);
    private sealed record ProfileOption(string Label, string DirectoryName, bool Available = true);

    private void ApplyTextSize(DependencyObject element, bool includeText = false)
    {
        if (element is IconElement) return;
        if (element is Control control && control.FontSize != preferences.TextSize) control.FontSize = preferences.TextSize;
        if (includeText && element is TextBlock text && text.FontSize != preferences.TextSize &&
            !text.FontFamily.Source.Contains("Icons", StringComparison.OrdinalIgnoreCase) && !text.FontFamily.Source.Contains("Symbol", StringComparison.OrdinalIgnoreCase) && !text.Name.Contains("Glyph", StringComparison.OrdinalIgnoreCase)) text.FontSize = preferences.TextSize;
        for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(element); index++)
            ApplyTextSize(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(element, index), includeText);
    }

    private async Task<ContentDialogResult> ShowSizedDialog(ContentDialog dialog)
    {
        AutomationProperties.SetAutomationId(dialog, "ActiveToolDialog");
        if (dialog.Content is string message) dialog.Content = Message(message);
        dialog.FontSize = preferences.TextSize;
        dialog.RequestedTheme = Shell.RequestedTheme;
        void SizeDialogContent()
        {
            ApplyTextSize(dialog, true);
            if (dialog.Content is DependencyObject content) ApplyTextSize(content, true);
        }
        if (dialog.Content is FrameworkElement contentElement) contentElement.Loaded += (_, _) => SizeDialogContent();
        dialog.Opened += (_, _) => DispatcherQueue.TryEnqueue(SizeDialogContent);
        return await dialog.ShowAsync();
    }

    private async Task<ContentDialogResult> Dialog(string title, UIElement content, string primary = "", string secondary = "", string close = "Cancel")
    {
        var scroll = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = Math.Max(180, Shell.ActualHeight - 220) };
        AutomationProperties.SetAutomationId(scroll, "ToolDialogScroll");
        var dialog = new ContentDialog { XamlRoot = Shell.XamlRoot, FontSize = preferences.TextSize, Title = title, PrimaryButtonText = primary, SecondaryButtonText = secondary,
            CloseButtonText = close, DefaultButton = ContentDialogButton.Close,
            Content = scroll };
        return await ShowSizedDialog(dialog);
    }

    private static TextBlock Message(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, MaxWidth = 640 };

    private async Task<StorageFile?> PickFile(params string[] extensions)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        foreach (var extension in extensions) picker.FileTypeFilter.Add(extension);
        return await picker.PickSingleFileAsync();
    }

    private async Task<bool> SaveFile(string name, string extension, byte[] bytes)
    {
        var picker = new FileSavePicker { SuggestedFileName = name };
        picker.FileTypeChoices.Add("Easy Edge Apps", new List<string> { extension });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSaveFileAsync();
        if (file is null) return false;
        await Task.Run(() => SafeFiles.AtomicWrite(SafeFiles.ExportPath(store.Layout, file.Path), bytes));
        return true;
    }

    private async Task<byte[]?> PasswordOperation(Func<char[], char[], CancellationToken, Task<byte[]>> operation, bool confirm)
    {
        var password = new PasswordBox { Header = "Passphrase", MaxLength = 1024, PasswordRevealMode = PasswordRevealMode.Peek };
        var confirmation = new PasswordBox { Header = "Confirm passphrase", MaxLength = 1024, PasswordRevealMode = PasswordRevealMode.Peek };
        AutomationProperties.SetAutomationId(password, "KitPassword");
        AutomationProperties.SetAutomationId(confirmation, "KitPasswordConfirmation");
        var error = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error };
        AutomationProperties.SetAutomationId(error, "KitPasswordValidation");
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(Message(KitEncryption.Warning)); panel.Children.Add(password);
        if (confirm) panel.Children.Add(confirmation);
        panel.Children.Add(error);
        var scroll = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = Math.Max(180, Shell.ActualHeight - 220) };
        AutomationProperties.SetAutomationId(scroll, "ToolDialogScroll");
        var dialog = new ContentDialog { XamlRoot = Shell.XamlRoot, Title = confirm ? "Encrypt App Kit" : "Unlock App Kit", Content = scroll, PrimaryButtonText = confirm ? "Encrypt" : "Unlock", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        byte[]? result = null;
        var working = false;
        var closeRequested = false;
        dialog.CloseButtonClick += (_, click) =>
        {
            if (!working) return;
            click.Cancel = true;
            closeRequested = true;
            cancellation.Cancel();
        };
        dialog.PrimaryButtonClick += async (_, click) =>
        {
            var deferral = click.GetDeferral();
            working = true;
            dialog.IsPrimaryButtonEnabled = password.IsEnabled = confirmation.IsEnabled = false;
            char[] first = [], second = [];
            try
            {
                first = password.Password.ToCharArray(); second = confirmation.Password.ToCharArray();
                password.Password = confirmation.Password = "";
                result = await operation(first, second, cancellation.Token);
                if (closeRequested) { System.Security.Cryptography.CryptographicOperations.ZeroMemory(result); result = null; click.Cancel = true; }
                error.IsOpen = false;
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { closeRequested = true; click.Cancel = true; }
            catch (Exception failure) { error.Message = SafeMessage(failure); error.IsOpen = true; click.Cancel = true; }
            finally
            {
                Array.Clear(first); Array.Clear(second);
                password.Password = confirmation.Password = "";
                working = false;
                dialog.IsPrimaryButtonEnabled = password.IsEnabled = confirmation.IsEnabled = true;
                deferral.Complete();
                if (closeRequested) dialog.Hide();
            }
        };
        try
        {
            if (await ShowSizedDialog(dialog) == ContentDialogResult.Primary) return result;
            if (result is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(result);
            return null;
        }
        finally { password.Password = confirmation.Password = ""; }
    }

    private async void ImportKitClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft()) return;
        var file = await PickFile(".json");
        if (file is null) return;
        var bytes = SafeFiles.Read(file.Path, 24 * 1024 * 1024);
        using var document = StrictJson.Parse(bytes, 24 * 1024 * 1024);
        if (StrictJson.Text(document.RootElement, "Product") == "EasyEdgeApps.EncryptedKit")
        {
            _ = KitEncryption.ReadEnvelope(bytes);
            var opened = await PasswordOperation((password, _, cancellation) => Task.Run(() => KitCodec.Write(KitEncryption.Unlock(bytes, password, cancellation))), false);
            if (opened is null) return;
            try { await ImportKit(KitCodec.Read(opened)); }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(opened); }
        }
        else await ImportKit(KitCodec.Read(bytes));
    });

    private async Task ImportKit(AppKit kit)
    {
        var selection = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 300 };
        foreach (var app in kit.Apps) selection.Items.Add(app.Name);
        selection.SelectAll();
        AutomationProperties.SetName(selection, "Websites to import");
        if (await Dialog("Select websites", selection, "Preview") != ContentDialogResult.Primary) return;
        var names = selection.SelectedItems.Cast<string>().ToHashSet(StringComparer.Ordinal);
        if (names.Count == 0) return;
        await PreviewKit(kit with { Apps = kit.Apps.Where(app => names.Contains(app.Name)).ToArray() });
    }

    private async Task<bool> PreviewKit(AppKit kit, bool newOnly = false)
    {
        var plan = await Task.Run(() => store.Preview(kit, newOnly));
        var rows = new StackPanel { Spacing = 12 };
        for (var index = 0; index < plan.Rows.Length; index++)
        {
            var row = plan.Rows[index];
            rows.Children.Add(Message(row.Source.Name + "\n" + row.Action + ": " + row.Detail));
            if (row.Effective is null) continue;
            var comparison = Message((row.Current is null ? "Before: Not installed" : "Before:\n" + Describe(row.Current)) + "\n\nAfter:\n" + Describe(row.Effective));
            AutomationProperties.SetAutomationId(comparison, "ImportComparison" + index);
            AutomationProperties.SetName(comparison, comparison.Text);
            rows.Children.Add(comparison);
        }
        var conflict = plan.Rows.Any(row => row.Action == "Conflict");
        if (await Dialog("Import preview", rows, conflict ? "" : "Import", close: "Close") != ContentDialogResult.Primary) return false;
        var result = await Task.Run(() => store.Import(plan));
        Record("Import", result.Completed ? "Success" : "Conflict");
        var selectedDefinition = store.Read().Catalog.Apps.SingleOrDefault(app => !app.Removed && app.Definition.Id == editor.SelectedId)?.Definition;
        await editor.NavigateAsync(selectedDefinition, DraftChoice.Discard, SaveDraft);
        Reload(); LoadDraft();
        var results = new StackPanel { Spacing = 12 };
        foreach (var row in result.Results) results.Children.Add(Message(row.Name + "\n" + row.Status + ": " + row.Detail));
        await Dialog("Import results", results, close: "Close");
        SetStatus(result.Completed ? "Selected websites imported." : "Some websites were not changed. Completed entries were retained.");
        return true;

        static string Describe(AppDefinition definition) => string.Join("\n", new[]
        {
            "Name: " + definition.DisplayName, "Website address: " + definition.Url,
            "Notes: " + (definition.Notes.Length == 0 ? "None" : definition.Notes),
            "Icon: " + definition.IconKind,
            "Desktop: " + (definition.Desktop ? "Yes" : "No"), "Start menu: " + (definition.StartMenu ? "Yes" : "No"),
            "Browsing mode: " + definition.Window.BrowsingMode,
            "Normal Edge profile: " + (definition.EdgeProfile.Length == 0 ? "Automatic" : definition.EdgeProfile),
            "Window mode: " + definition.Window.LaunchMode, "Always on top: " + (definition.Window.AlwaysOnTop ? "Yes" : "No"),
            "Taskbar identity: " + (definition.Window.Taskbar ? "Yes" : "No")
        });
    }

    private async void ExportKitClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft()) return;
        var records = store.Read().Catalog.Apps.Where(app => !app.Removed).ToArray();
        var title = new TextBox { Header = "Kit name", Text = "My websites", MaxLength = 60 };
        var notes = new TextBox { Header = "Kit notes", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxLength = 4000, MinHeight = 100 };
        var encrypted = new CheckBox { Content = "Encrypt App Kit (experimental)" };
        AutomationProperties.SetAutomationId(title, "ExportKitName");
        AutomationProperties.SetAutomationId(notes, "ExportKitNotes");
        AutomationProperties.SetAutomationId(encrypted, "ExportKitEncrypted");
        var selection = new ListView { ItemsSource = records, DisplayMemberPath = "Definition.DisplayName", SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 260 };
        AutomationProperties.SetAutomationId(selection, "ExportWebsiteList");
        selection.SelectAll();
        var error = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error };
        AutomationProperties.SetAutomationId(error, "ExportValidation");
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(title); panel.Children.Add(notes); panel.Children.Add(selection); panel.Children.Add(encrypted); panel.Children.Add(error);
        var scroll = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = Math.Max(180, Shell.ActualHeight - 220) };
        AutomationProperties.SetAutomationId(scroll, "ToolDialogScroll");
        var dialog = new ContentDialog { XamlRoot = Shell.XamlRoot, Title = "Export App Kit", Content = scroll, PrimaryButtonText = "Export", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        AppKit? kit = null;
        byte[] bytes = [];
        dialog.PrimaryButtonClick += async (_, click) =>
        {
            var deferral = click.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                if (string.IsNullOrWhiteSpace(title.Text)) throw new ValidationException("Enter a kit name.");
                var selected = selection.SelectedItems.Cast<AppRecord>().ToArray();
                if (selected.Length == 0) throw new ValidationException("Select at least one website.");
                var kitName = title.Text;
                var kitNotes = notes.Text;
                kit = await Task.Run(() =>
                {
                    var apps = selected.Select(record =>
                    {
                        store.CheckOwned(record);
                        var iconBytes = record.Definition.IconKind == "Custom" ? SafeFiles.Read(store.Layout.Resolve(CatalogStore.Address(record, "Icon")), 1024 * 1024) : null;
                        var icon = iconBytes is null ? new PortableIcon() : new("Embedded", Data: Convert.ToBase64String(iconBytes), Sha256: Identity.Hash(iconBytes));
                        return new KitApp(record.Definition.DisplayName, record.Definition.Url, record.Definition.Desktop, record.Definition.StartMenu, record.Definition.Notes, icon, record.Definition.Window.FreshSession);
                    }).ToArray();
                    return new AppKit(2, kitName, apps, kitNotes);
                });
                bytes = KitCodec.Write(kit);
                error.IsOpen = false;
            }
            catch (Exception failure) { error.Message = SafeMessage(failure); error.IsOpen = true; click.Cancel = true; }
            finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        while (await ShowSizedDialog(dialog) == ContentDialogResult.Primary && kit is not null)
        {
            try
            {
                if (encrypted.IsChecked == true)
                {
                    var protectedBytes = await PasswordOperation((password, confirmation, cancellation) => Task.Run(() => KitEncryption.Protect(kit, password, confirmation, cancellation)), true);
                    System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes);
                    if (protectedBytes is null) continue;
                    bytes = protectedBytes;
                }
                if (await SaveFile("websites.eea-kit", ".json", bytes)) { SetStatus("App Kit exported."); return; }
            }
            catch (Exception failure) { error.Message = SafeMessage(failure); error.IsOpen = true; }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); bytes = []; }
        }
    });

    private async void FavoritesClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft()) return;
        var root = isolated ? store.Layout.Resolve(new(StorageArea.Data, "EdgeProfiles")) : EdgeProfiles.DefaultRoot;
        var profiles = await Task.Run(() => EdgeProfiles.Discover(root).Where(profile => profile.HasBookmarks).ToArray());
        var preferred = Array.FindIndex(profiles, profile => profile.DirectoryName == preferences.DefaultProfile);
        var profileChoice = new ComboBox { Header = "Edge profile", ItemsSource = profiles, DisplayMemberPath = "DisplayName", HorizontalAlignment = HorizontalAlignment.Stretch, SelectedIndex = profiles.Length == 0 ? -1 : Math.Max(0, preferred) };
        var desktop = new CheckBox { Content = "Desktop", IsChecked = true };
        var startMenu = new CheckBox { Content = "Start menu", IsChecked = true };
        var allAvailable = new CheckBox { Content = "All available" };
        var refresh = new Button { Content = new SymbolIcon(Symbol.Refresh), Width = 36, Height = 36, Padding = new Thickness(0) };
        ToolTipService.SetToolTip(refresh, "Refresh Favorites");
        AutomationProperties.SetName(refresh, "Refresh Favorites");
        AutomationProperties.SetAutomationId(profileChoice, "FavoritesProfile");
        AutomationProperties.SetAutomationId(desktop, "FavoritesDesktop");
        AutomationProperties.SetAutomationId(startMenu, "FavoritesStartMenu");
        AutomationProperties.SetAutomationId(allAvailable, "FavoritesAllAvailable");
        AutomationProperties.SetAutomationId(refresh, "RefreshFavorites");
        var selection = new ListView { SelectionMode = ListViewSelectionMode.Multiple, Height = 260, ItemTemplate = (DataTemplate)AppearanceRoot.Resources["FavoriteCandidateTemplate"] };
        AutomationProperties.SetAutomationId(selection, "FavoritesList");
        AutomationProperties.SetName(selection, "Favorites preview and selection");
        selection.ContainerContentChanging += (_, change) =>
        {
            if (change.InRecycleQueue || change.Item is not FavoriteCandidate candidate) return;
            var container = change.ItemContainer;
            container.IsEnabled = candidate.CanImport;
            container.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            AutomationProperties.SetAutomationId(container, "FavoriteCandidate" + change.ItemIndex);
            AutomationProperties.SetName(container, candidate.Name + ", " + candidate.Folder + ", " + candidate.Reason);
            DispatcherQueue.TryEnqueue(() => ApplyTextSize(container, true));
        };
        var source = Message("");
        var error = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error };
        AutomationProperties.SetAutomationId(error, "FavoritesValidation");
        var commands = new FlowPanel { Spacing = 12 };
        commands.Children.Add(refresh); commands.Children.Add(allAvailable); commands.Children.Add(desktop); commands.Children.Add(startMenu);
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(profileChoice); panel.Children.Add(source); panel.Children.Add(commands); panel.Children.Add(selection); panel.Children.Add(error);
        var scroll = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = Math.Max(180, Shell.ActualHeight - 220) };
        AutomationProperties.SetAutomationId(scroll, "ToolDialogScroll");
        var dialog = new ContentDialog { XamlRoot = Shell.XamlRoot, Title = "Favorites bar", Content = scroll, PrimaryButtonText = "Preview", SecondaryButtonText = "Choose file", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        FavoriteCandidate[] candidates = [];
        AppKit? selectedKit = null;
        string? chosenFile = null;
        var selecting = false;
        var reading = false;

        void SelectAvailable(bool include)
        {
            if (selecting) return;
            selecting = true;
            try
            {
                selection.SelectedItems.Clear();
                if (include) foreach (var candidate in candidates.Where(candidate => candidate.CanImport)) selection.SelectedItems.Add(candidate);
                allAvailable.IsChecked = include && candidates.Any(candidate => candidate.CanImport);
            }
            finally { selecting = false; }
        }

        async Task ReadCandidates()
        {
            if (reading) return;
            reading = true;
            dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = refresh.IsEnabled = profileChoice.IsEnabled = false;
            error.IsOpen = false;
            try
            {
                var bookmarks = chosenFile ?? (profileChoice.SelectedIndex >= 0 ? profiles[profileChoice.SelectedIndex].BookmarksPath : null);
                source.Text = chosenFile is null ? "" : Path.GetFileName(chosenFile);
                candidates = bookmarks is null ? [] : await Task.Run(() => store.ReadFavorites(SafeFiles.Read(bookmarks, 16 * 1024 * 1024)));
                selection.ItemsSource = candidates;
                SelectAvailable(true);
                if (candidates.Length == 0) source.Text = "No local Favorites bar entries.";
            }
            catch (Exception failure)
            {
                candidates = [];
                selection.ItemsSource = candidates;
                SelectAvailable(false);
                error.Message = SafeMessage(failure); error.IsOpen = true;
            }
            finally
            {
                reading = false;
                dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = refresh.IsEnabled = true;
                profileChoice.IsEnabled = profiles.Length != 0;
                source.Visibility = source.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            }
        }

        allAvailable.Checked += (_, _) => SelectAvailable(true);
        allAvailable.Unchecked += (_, _) => SelectAvailable(false);
        selection.SelectionChanged += (_, _) =>
        {
            if (selecting) return;
            selecting = true;
            try
            {
                foreach (var unavailable in selection.SelectedItems.Cast<FavoriteCandidate>().Where(candidate => !candidate.CanImport).ToArray()) selection.SelectedItems.Remove(unavailable);
                allAvailable.IsChecked = candidates.Any(candidate => candidate.CanImport) && selection.SelectedItems.Count == candidates.Count(candidate => candidate.CanImport);
            }
            finally { selecting = false; }
        };
        profileChoice.SelectionChanged += async (_, _) => { chosenFile = null; await ReadCandidates(); };
        refresh.Click += async (_, _) => await ReadCandidates();
        dialog.PrimaryButtonClick += (_, click) =>
        {
            try
            {
                if (selection.SelectedItems.Count is < 1 or > 100) throw new ValidationException("Select between 1 and 100 available websites.");
                if (desktop.IsChecked != true && startMenu.IsChecked != true) throw new ValidationException("Select Desktop or Start menu.");
                selectedKit = Favorites.ToKit(selection.SelectedItems.Cast<FavoriteCandidate>(), desktop.IsChecked == true, startMenu.IsChecked == true);
                error.IsOpen = false;
            }
            catch (Exception failure) { error.Message = SafeMessage(failure); error.IsOpen = true; click.Cancel = true; }
        };
        await ReadCandidates();
        while (true)
        {
            var choice = await ShowSizedDialog(dialog);
            if (choice == ContentDialogResult.Secondary)
            {
                var file = await PickFile("*");
                if (file is not null) { chosenFile = file.Path; await ReadCandidates(); }
                continue;
            }
            if (choice != ContentDialogResult.Primary || selectedKit is null) return;
            if (await PreviewKit(selectedKit, true)) return;
        }
    });

    private async void MigrateClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!store.AllowExperimentalMigration) { await Dialog("Migration acceptance required", Message(CatalogStore.MigrationAcceptanceRequired), close: "Close"); return; }
        if (!await GuardDraft()) return;
        var records = await Task.Run(() => store.LegacyApps());
        var selection = new ListView { ItemsSource = records.Where(item => item.Manifest is not null).ToArray(), DisplayMemberPath = "Manifest.App.DisplayName", SelectionMode = ListViewSelectionMode.Single, MaxHeight = 300 };
        if (await Dialog("Legacy websites", selection, "Preview") != ContentDialogResult.Primary || selection.SelectedItem is not LegacyInventory selected) return;
        var plan = await Task.Run(() => store.PreviewMigration(selected.Id));
        var detail = selected.Manifest!.App.DisplayName + "\n\nKeep the permanent ID, browser profile, launcher path and taskbar identity. Archive original owned bytes and transfer management to this catalog. Close older managers and other Windows sessions first.";
        if (await Dialog("Migration preview", Message(detail), "Migrate") != ContentDialogResult.Primary) return;
        var migrated = await Task.Run(() => store.Migrate(plan));
        Record("Migration", "Success");
        await editor.NavigateAsync(migrated.Definition, DraftChoice.Discard, SaveDraft);
        Reload(); LoadDraft(); SetStatus("Website migrated. Original owned files are available for rollback.");
    });

    private async void RollbackClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!store.AllowExperimentalMigration) { await Dialog("Migration acceptance required", Message(CatalogStore.MigrationAcceptanceRequired), close: "Close"); return; }
        if (!await GuardDraft() || editor.SelectedId is null) return;
        if (await Dialog("Restore legacy management?", Message("Restore the archived original owned files. New manager edits to those files will be replaced. Browser data and unrelated files remain unchanged."), "Roll back") != ContentDialogResult.Primary) return;
        await Task.Run(() => store.RollbackMigration(editor.SelectedId, snapshot));
        await editor.NavigateAsync(null, DraftChoice.Discard, SaveDraft);
        Reload(); LoadDraft(); SetStatus("Original owned files restored for the legacy manager.");
    });

    private async void RecoveryClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft()) return;
        var root = store.Layout.Resolve(new(StorageArea.Data, ".transactions"));
        var selection = new ListView { ItemsSource = Directory.Exists(root) ? Directory.EnumerateDirectories(root).Select(Path.GetFileName).ToArray() : [], MaxHeight = 260 };
        if (await Dialog("Transaction recovery", selection, "Verify and recover") != ContentDialogResult.Primary || selection.SelectedItem is not string transaction) return;
        await Task.Run(() => store.Recover(transaction));
        Record("Recovery", "Success");
        Reload(); SetStatus("Recovery completed. Outside changes were not overwritten.");
    });

    private async void SupportClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft()) return;
        var report = await Task.Run(() => SupportReport.Create(store, Environment.ProcessPath!));
        var preview = new TextBox { Text = report, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxWidth = 640 };
        AutomationProperties.SetName(preview, "Support report preview");
        if (await Dialog("Support report preview", preview, "Save report", close: "Close") == ContentDialogResult.Primary)
            await SaveFile("EasyEdgeApps-support", ".json", Encoding.UTF8.GetBytes(report));
    });

    private async void PreferencesClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft()) return;
        var diagnostics = new CheckBox { Content = "Local diagnostic category log", IsChecked = preferences.Diagnostics };
        var updates = new CheckBox { Content = "Check for updates daily", IsChecked = preferences.CheckUpdates };
        var motion = new CheckBox { Content = "Animate the space background", IsChecked = preferences.MotionEnabled };
        AutomationProperties.SetAutomationId(motion, "PreferenceMotion");
        AutomationProperties.SetAutomationId(diagnostics, "PreferenceDiagnostics");
        AutomationProperties.SetAutomationId(updates, "PreferenceUpdates");
        var error = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error };
        AutomationProperties.SetAutomationId(error, "PreferenceError");
        var profiles = new List<ProfileOption> { new("Let Edge choose", "") };
        try
        {
            var root = isolated ? store.Layout.Resolve(new(StorageArea.Data, "EdgeProfiles")) : EdgeProfiles.DefaultRoot;
            profiles.AddRange((await Task.Run(() => EdgeProfiles.Discover(root))).Select(profile => new ProfileOption(profile.DisplayName, profile.DirectoryName)));
        }
        catch (Exception failure) when (failure is ValidationException or IOException or UnauthorizedAccessException)
        { error.Message = "Edge profiles could not be read. Let Edge choose remains available."; error.IsOpen = true; }
        if (profiles.All(profile => profile.DirectoryName != preferences.DefaultProfile)) profiles.Add(new("Unavailable: " + preferences.DefaultProfile, preferences.DefaultProfile, false));
        var profile = new ComboBox { Header = "Default normal Edge profile", ItemsSource = profiles, DisplayMemberPath = nameof(ProfileOption.Label), SelectedItem = profiles.Single(profile => profile.DirectoryName == preferences.DefaultProfile), HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(profile, "PreferenceProfile");
        var tiles = new CheckBox { Content = "Show My Websites as tiles", IsChecked = preferences.Tiles };
        var desktop = new CheckBox { Content = "Desktop shortcut for new websites", IsChecked = preferences.DefaultDesktop };
        var startMenu = new CheckBox { Content = "Start menu entry for new websites", IsChecked = preferences.DefaultStartMenu };
        AutomationProperties.SetAutomationId(tiles, "PreferenceTiles");
        AutomationProperties.SetAutomationId(desktop, "PreferenceDesktop");
        AutomationProperties.SetAutomationId(startMenu, "PreferenceStartMenu");
        var textSizes = new List<TextSizeOption>
        {
            new("12 pt (Default)", 16), new("14 pt", 56.0 / 3.0), new("16 pt", 64.0 / 3.0), new("18 pt", 24)
        };
        if (textSizes.All(option => option.Dips != preferences.TextSize)) textSizes.Insert(0, new((preferences.TextSize * 0.75).ToString("0.#", System.Globalization.CultureInfo.CurrentCulture) + " pt", preferences.TextSize));
        var textSize = new ComboBox { Header = "Text size", ItemsSource = textSizes, DisplayMemberPath = nameof(TextSizeOption.Label), SelectedItem = textSizes.Single(option => option.Dips == preferences.TextSize), HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(textSize, "PreferenceTextSize");
        var panel = new StackPanel { Spacing = 20 };
        var scroll = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = Math.Max(180, Shell.ActualHeight - 220) };
        AutomationProperties.SetAutomationId(scroll, "ToolDialogScroll");
        var dialog = new ContentDialog { XamlRoot = Shell.XamlRoot, Title = "Settings", Content = scroll, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        Func<Task>? requestedAction = null;
        var actionStatus = Message("");
        AutomationProperties.SetAutomationId(actionStatus, "PreferenceActionStatus");
        AutomationProperties.SetLiveSetting(actionStatus, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);

        Button Command(string label, Symbol symbol, string identifier, Func<Task> action)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            content.Children.Add(new SymbolIcon(symbol)); content.Children.Add(Message(label));
            var button = new Button { Content = content };
            AutomationProperties.SetAutomationId(button, identifier); AutomationProperties.SetName(button, label);
            button.Click += (_, _) => { requestedAction = action; dialog.Hide(); };
            return button;
        }

        void Section(string title, Symbol symbol, params UIElement[] controls)
        {
            var section = new StackPanel { Spacing = 10 };
            var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            heading.Children.Add(new SymbolIcon(symbol)); heading.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            section.Children.Add(heading);
            foreach (var control in controls) section.Children.Add(control);
            panel.Children.Add(section);
        }

        var updateCommands = new FlowPanel { Spacing = 8 };
        updateCommands.Children.Add(Command("Check for updates", Symbol.Refresh, "PreferenceCheckUpdates", CheckUpdates));
        updateCommands.Children.Add(Command("Review downloaded update", Symbol.Download, "PreferenceReviewUpdate", ReviewDownloadedUpdate));
        var logCommands = new FlowPanel { Spacing = 8 };
        logCommands.Children.Add(Command("Open log folder", Symbol.OpenFile, "PreferenceOpenLogs", () =>
        {
            var path = store.Layout.Resolve(new(StorageArea.Data, "Logs"));
            if (!Directory.Exists(path)) actionStatus.Text = "No diagnostic logs yet.";
            else
            {
                if (isolated) throw new ValidationException("Opening folders is disabled in isolated test mode.");
                using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            }
            return Task.CompletedTask;
        }));
        logCommands.Children.Add(Command("Clear logs", Symbol.Delete, "PreferenceClearLogs", async () =>
        {
            if (await Dialog("Clear diagnostic logs?", Message("Delete the Easy Edge Apps diagnostic category logs?"), "Clear logs") != ContentDialogResult.Primary) return;
            preferenceStore.ClearLogs(); actionStatus.Text = "Diagnostic logs cleared.";
        }));
        Section("Updates", Symbol.Refresh, Message("Version 2.0.0-preview.1"), updateCommands, updates);
        Section("Websites", Symbol.Link, profile, desktop, startMenu);
        Section("Appearance", Symbol.Pictures, motion, textSize, tiles);
        Section("Diagnostics", Symbol.Help, diagnostics, logCommands);
        panel.Children.Add(actionStatus); panel.Children.Add(error);
        panel.Children.Add(Message("Easy Edge Apps by Blake Drumm\nMIT License. Third-party notices are included with the application."));
        var saved = false;
        dialog.PrimaryButtonClick += async (_, click) =>
        {
            var deferral = click.GetDeferral();
            try
            {
                if (profile.SelectedItem is not ProfileOption { Available: true } selected) throw new ValidationException("Choose an available Edge profile or let Edge choose.");
                var next = preferences with { Theme = ThemeChoice.SelectedIndex switch { 1 => "System", 2 => "Light", 3 => "Dark", _ => "Original" }, Diagnostics = diagnostics.IsChecked == true, CheckUpdates = updates.IsChecked == true, DefaultProfile = selected.DirectoryName, Tiles = tiles.IsChecked == true,
                    DefaultDesktop = desktop.IsChecked == true, DefaultStartMenu = startMenu.IsChecked == true, MotionEnabled = motion.IsChecked == true, TextSize = ((TextSizeOption)textSize.SelectedItem).Dips };
                await Task.Run(() => preferenceStore.Save(next));
                preferences = next;
                AppearanceRoot.FontSize = preferences.TextSize;
                RefreshAppearance(); ApplyTextSize(Shell);
                saved = true;
            }
            catch (Exception failure) { click.Cancel = true; error.Message = SafeMessage(failure); error.IsOpen = true; }
            finally { deferral.Complete(); }
        };
        while (!allowClose && !lifetime.IsCancellationRequested)
        {
            requestedAction = null;
            await ShowSizedDialog(dialog);
            if (saved || requestedAction is null) break;
            error.IsOpen = false;
            try { await requestedAction(); }
            catch (Exception failure) { error.Message = SafeMessage(failure); error.IsOpen = true; }
        }
        if (saved) SetStatus("Preferences saved.");
    });

    private async void WebsitesClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft()) return;
        var records = store.Read().Catalog.Apps.Where(app => !app.Removed).ToArray();
        if (!preferences.Tiles)
        {
            var list = new ListView { ItemsSource = records.Select(record => record.Definition.DisplayName).ToArray(), SelectionMode = ListViewSelectionMode.Single, MaxHeight = 340 };
            if (await Dialog("My Websites", list, "Edit", close: "Close") == ContentDialogResult.Primary && list.SelectedIndex >= 0)
            { await editor.NavigateAsync(records[list.SelectedIndex].Definition, DraftChoice.Discard, SaveDraft); Reload(); LoadDraft(); }
            return;
        }
        var grid = new GridView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 340, IsItemClickEnabled = false };
        foreach (var record in records)
        {
            var tile = new StackPanel { Width = 136, Spacing = 8, Padding = new Thickness(8) };
            var image = new BitmapImage();
            var iconPath = store.Layout.Resolve(CatalogStore.Address(record, "Icon"));
            if (File.Exists(iconPath))
            {
                using var stream = new MemoryStream(IconService.PreviewPng(SafeFiles.Read(iconPath, 1024 * 1024)));
                await image.SetSourceAsync(stream.AsRandomAccessStream());
            }
            tile.Children.Add(new Image { Width = 64, Height = 64, Source = image });
            tile.Children.Add(Message(record.Definition.DisplayName));
            var item = new GridViewItem { Content = tile, Tag = record, MaxWidth = 152 };
            AutomationProperties.SetName(item, record.Definition.DisplayName); grid.Items.Add(item);
        }
        if (await Dialog("My Websites", grid, "Edit", close: "Close") == ContentDialogResult.Primary && grid.SelectedItem is GridViewItem selected && selected.Tag is AppRecord app)
        { await editor.NavigateAsync(app.Definition, DraftChoice.Discard, SaveDraft); Reload(); LoadDraft(); }
    });

    private async void CheckAppsClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft()) return;
        var inspected = store.Read();
        var records = inspected.Catalog.Apps.Where(app => !app.Removed).OrderBy(app => app.Definition.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToArray();
        var inspection = new DesktopInspection(store, Path.Combine(AppContext.BaseDirectory, "WebsiteLauncher", "fresh-session.exe"));
        var checks = await Task.Run(() => inspection.ReadAll(inspected));
        var selection = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 320 };
        AutomationProperties.SetAutomationId(selection, "CheckWebsiteList");
        var canRepair = false;
        foreach (var check in checks)
        {
            var record = records.SingleOrDefault(record => record.Definition.Id == check.Id);
            var detail = check.Status == "Healthy" ? "Owned files, launcher and Edge verified" : check.Status + ": " + string.Join(" ", check.Issues);
            var item = new ListViewItem { Content = Message(check.Name + "\n" + check.BrowsingMode + "\n" + detail), Tag = record, IsEnabled = record is not null && check.CanRepair };
            AutomationProperties.SetAutomationId(item, "CheckWebsite-" + check.Id);
            AutomationProperties.SetName(item, check.Name + ": " + detail);
            AutomationProperties.SetItemStatus(item, check.Status);
            selection.Items.Add(item);
            canRepair |= check.CanRepair;
        }
        if (await Dialog("Check and Repair Apps", selection, canRepair ? "Repair selected" : "", close: "Close") != ContentDialogResult.Primary || selection.SelectedItems.Count == 0) return;
        var results = new StackPanel { Spacing = 12 };
        var expected = inspected.Hash;
        foreach (var selected in selection.SelectedItems.Cast<ListViewItem>().Where(item => item.IsEnabled).Select(item => item.Tag).OfType<AppRecord>())
        {
            try
            {
                await Task.Run(() => store.Repair(selected.Definition.Id, expected));
                expected = store.Read().Hash;
                results.Children.Add(Message(selected.Definition.DisplayName + "\nRepaired. Browser data and window choices retained."));
                Record("Repair", "Success");
            }
            catch (Exception failure)
            { results.Children.Add(Message(selected.Definition.DisplayName + "\nNot repaired: " + SafeMessage(failure))); Record("Repair", "Failed"); }
        }
        Reload();
        await Dialog("Repair results", results, close: "Close");
        SetStatus("Selected checks completed. Review each website's result.");
    });

    private async void UpdatesClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    { if (await GuardDraft()) await CheckUpdates(); });

    private async Task CheckUpdates()
    {
        if (isolated) throw new ValidationException("Network update checks are disabled in isolated test mode.");
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        operationCancellation = cancellation;
        UpdateState();
        try
        {
            SetStatus("Checking the official release endpoint...");
            using var client = new UpdateClient();
            var release = await client.CheckAsync(cancellation.Token);
            preferences = preferences with { LastUpdateCheckUtc = DateTimeOffset.UtcNow.ToString("O") };
            preferenceStore.Save(preferences);
            if (!InstallerUpdate.IsNewerRelease(release.Tag))
            { await Dialog("Updates", Message("No newer compiled release is available."), close: "Close"); SetStatus("Update check completed."); return; }
            var installer = release.Assets.FirstOrDefault(asset => asset.Name.EndsWith("-x64.msi", StringComparison.Ordinal));
            var available = InstallerUpdate.IsConfigured && installer is not null;
            if (await Dialog("Official release", Message(release.Tag + "\n" + release.PageUrl + (available ? "" : "\n\nAutomatic installation is unavailable in this unsigned preview build.")), available ? "Download" : "", close: "Close") != ContentDialogResult.Primary) return;
            var progress = new Progress<long>(bytes => SetStatus("Downloading update: " + (bytes * 100 / installer!.Size) + "%"));
            var approval = await InstallerUpdate.DownloadAsync(client, release, installer!, store.Layout.Resolve(new(StorageArea.Data, "Updates/Downloads")), progress, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            var retained = new PendingUpdateStore(store.Layout);
            await Task.Run(() => retained.Save(new("Updates/Downloads/" + Path.GetFileName(approval.Path), approval.Hash, approval.Version)));
            await ReviewInstaller(approval);
        }
        catch (OperationCanceledException) { SetStatus("Update check or download cancelled."); }
        finally { operationCancellation = null; UpdateState(); }
    }

    private async void ReviewDownloadedUpdateClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (await GuardDraft()) await ReviewDownloadedUpdate();
    });

    private async Task ReviewDownloadedUpdate()
    {
        var retained = new PendingUpdateStore(store.Layout);
        var pending = await Task.Run(retained.Read);
        if (pending is null)
        {
            await Dialog("Downloaded update", Message("No downloaded installer is retained."), close: "Close");
            return;
        }
        await ReviewInstaller(new(retained.Resolve(pending), pending.Sha256, pending.Version));
    }

    private async Task ReviewInstaller(InstallerApproval approval)
    {
        SetStatus("Verifying the retained installer...");
        await Task.Run(() => InstallerUpdate.ValidateApproval(approval));
        if (await Dialog("Install verified update?", Message("The expected publisher and timestamp were verified. Windows Installer will manage installation and failure rollback. Website profiles and per-site launchers remain unchanged."), "Install", close: "Later") != ContentDialogResult.Primary)
        { SetStatus("Verified installer retained for later review."); return; }
        if (isolated) throw new ValidationException("Installer launches are disabled in isolated test mode.");
        var start = InstallerUpdate.CreateStartInfo(approval);
        if (Process.Start(start) is not { } process) throw new ValidationException("Windows Installer did not start.");
        process.Dispose();
        Record("Update", "Success");
        allowClose = true;
        Close();
    }

    private async void TaskbarClicked(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await GuardDraft() || editor.SelectedId is null) return;
        var record = store.Read().Catalog.Apps.Single(app => app.Definition.Id == editor.SelectedId);
        store.CheckOwned(record);
        var ready = record.Definition.Window.Taskbar && record.Definition.Window.DedicatedProfile && record.Definition.StartMenu;
        if (await Dialog("Taskbar pinning", Message(ready
            ? "This website has a stable taskbar identity. Pin its owned Start menu shortcut through Windows. Existing pins are not replaced or removed automatically."
            : "Enable Taskbar identity, Separate profile, and Start menu for this website before requesting a dedicated pin."), ready ? "Request Windows pin" : "", close: "Close") != ContentDialogResult.Primary) return;
        SetStatus(await RequestTaskbarPin(record, lifetime.Token));
    });

    private async Task<string> RequestTaskbarPin(AppRecord record, CancellationToken token)
    {
        if (isolated) return "Pin requests are disabled in isolated test mode.";
        if (!taskbarSupported) return "Windows taskbar pin requests are unavailable. Use the owned Start menu shortcut.";
        token.ThrowIfCancellationRequested();
        SetStatus("Waiting for Windows taskbar approval...");
        return await TaskbarAssistance.RequestAsync(store, record, token);
    }
}