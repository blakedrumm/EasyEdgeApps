#requires -Version 5.1
[CmdletBinding()]
param([string]$ManagerPath, [string]$ScreenshotDirectory, [switch]$Worker, [string]$FixtureRoot, [ValidateSet(14, 16, 18, 24)][int]$TextSize = 16, [ValidateSet('Original', 'System', 'Light', 'Dark')][string]$Theme = 'Original', [switch]$AppearanceOnly, [switch]$SettingsOnly, [switch]$WindowChoicesOnly, [switch]$FavoritesOnly, [switch]$KitFiles, [switch]$KitFilesOnly, [switch]$SafetyOnly, [ValidateSet(0, 12, 14, 16, 18)][int]$LegacySettingsPoints = 0)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (@(@($AppearanceOnly, $SettingsOnly, $WindowChoicesOnly, $FavoritesOnly, $KitFilesOnly, $SafetyOnly) | Where-Object { $_ }).Count -gt 1) { throw 'Choose one focused GUI workflow at a time.' }
if ($KitFiles -and @(@($AppearanceOnly, $SettingsOnly, $WindowChoicesOnly, $FavoritesOnly, $KitFilesOnly, $SafetyOnly) | Where-Object { $_ }).Count -ne 0) { throw 'KitFiles extends the complete GUI workflow, not a focused workflow.' }
if ($LegacySettingsPoints -and -not $SettingsOnly) { throw 'Legacy preference fixtures require SettingsOnly.' }
$repository = Split-Path $PSScriptRoot -Parent
if (-not $ManagerPath) { $ManagerPath = Join-Path $repository 'src\EasyEdgeApps.Manager\bin\Release\net10.0-windows10.0.26100.0\win-x64\EasyEdgeApps.Manager.exe' }
if (-not $ScreenshotDirectory) { $ScreenshotDirectory = Join-Path $repository 'artifacts\compiled-ui' }
$ManagerPath = [IO.Path]::GetFullPath($ManagerPath)
$ScreenshotDirectory = [IO.Path]::GetFullPath($ScreenshotDirectory)
if (-not $ManagerPath.StartsWith($repository + '\', [StringComparison]::OrdinalIgnoreCase) -or -not $ScreenshotDirectory.StartsWith((Join-Path $repository 'artifacts\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep manager tests and screenshots inside the authorized repository.' }
if (-not [IO.File]::Exists($ManagerPath)) { throw 'Build the compiled manager before running its UI tests.' }
if (-not $Worker) {
    $ownedRoot = Join-Path $repository ('artifacts\winui-test-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($ownedRoot)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $start.Arguments = '-NoLogo -NoProfile -MTA -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Worker -FixtureRoot "' + $ownedRoot + '" -ManagerPath "' + $ManagerPath + '" -ScreenshotDirectory "' + $ScreenshotDirectory + '" -TextSize ' + $TextSize + ' -Theme ' + $Theme
    if ($AppearanceOnly) { $start.Arguments += ' -AppearanceOnly' }
    if ($SettingsOnly) { $start.Arguments += ' -SettingsOnly' }
    if ($WindowChoicesOnly) { $start.Arguments += ' -WindowChoicesOnly' }
    if ($FavoritesOnly) { $start.Arguments += ' -FavoritesOnly' }
    if ($KitFiles) { $start.Arguments += ' -KitFiles' }
    if ($KitFilesOnly) { $start.Arguments += ' -KitFilesOnly' }
    if ($SafetyOnly) { $start.Arguments += ' -SafetyOnly' }
    if ($LegacySettingsPoints) { $start.Arguments += ' -LegacySettingsPoints ' + $LegacySettingsPoints }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['PSModulePath'] = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\Modules'
    $workerProcess = [Diagnostics.Process]::Start($start)
    $output = $workerProcess.StandardOutput.ReadToEndAsync()
    $errors = $workerProcess.StandardError.ReadToEndAsync()
    try {
        if (-not $workerProcess.WaitForExit(120000)) {
            $idPath = Join-Path $ownedRoot 'manager.pid'
            if ([IO.File]::Exists($idPath)) {
                $ownedProcess = Get-Process -Id ([int][IO.File]::ReadAllText($idPath)) -ErrorAction SilentlyContinue
                if ($null -ne $ownedProcess -and $ownedProcess.Path -eq $ManagerPath) { $ownedProcess.Kill() }
            }
            $workerProcess.Kill()
            [void]$workerProcess.WaitForExit(10000)
            Write-Host $output.GetAwaiter().GetResult()
            Write-Host $errors.GetAwaiter().GetResult()
            throw 'The isolated UI Automation worker exceeded its overall deadline.'
        }
        Write-Host $output.GetAwaiter().GetResult()
        Write-Host $errors.GetAwaiter().GetResult()
        if ($workerProcess.ExitCode -ne 0) { throw 'The isolated WinUI worker failed.' }
    }
    finally {
        $workerProcess.Dispose()
        if ([IO.Directory]::Exists($ownedRoot)) { [IO.Directory]::Delete($ownedRoot, $true) }
    }
    return
}
if (-not $FixtureRoot -or -not [IO.Path]::GetFullPath($FixtureRoot).StartsWith((Join-Path $repository 'artifacts\winui-test-'), [StringComparison]::OrdinalIgnoreCase)) { throw 'The UI worker needs an owned synthetic root.' }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class CompiledUiNative {
    [StructLayout(LayoutKind.Sequential)] public struct Rectangle { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr window, int left, int top, int width, int height, bool repaint);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rectangle rectangle);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr context, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr dialog, int identifier);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();
    private delegate bool WindowCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int maximum);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessage(IntPtr window, uint message, IntPtr first, IntPtr second);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW", SetLastError = true)] private static extern IntPtr SendTextTimeout(IntPtr window, uint message, IntPtr first, string text, uint flags, uint milliseconds, out IntPtr result);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW", SetLastError = true)] private static extern IntPtr ReadTextTimeout(IntPtr window, uint message, IntPtr capacity, StringBuilder text, uint flags, uint milliseconds, out IntPtr result);
    public static bool SetPickerFilename(IntPtr dialog, IntPtr field, string value, out string failure) {
        failure = "The native filename control could not be resolved.";
        StringBuilder name = new StringBuilder(64);
        GetClassName(field, name, name.Capacity);
        if (field == IntPtr.Zero || GetAncestor(field, 2) != dialog || (name.ToString() != "Edit" && name.ToString() != "ComboBox" && name.ToString() != "ComboBoxEx32")) {
            IntPtr filename = IntPtr.Zero;
            int count = 0;
            EnumChildWindows(dialog, delegate(IntPtr candidate, IntPtr parameter) {
                int identifier = GetDlgCtrlID(candidate);
                bool filenameControl = identifier == 1148 && GetDlgCtrlID(GetParent(candidate)) != 1148;
                if (identifier == 1001) {
                    StringBuilder candidateClass = new StringBuilder(64);
                    StringBuilder parentClass = new StringBuilder(64);
                    StringBuilder containerClass = new StringBuilder(64);
                    IntPtr parent = GetParent(candidate);
                    GetClassName(candidate, candidateClass, candidateClass.Capacity);
                    GetClassName(parent, parentClass, parentClass.Capacity);
                    GetClassName(GetParent(parent), containerClass, containerClass.Capacity);
                    filenameControl = candidateClass.ToString() == "Edit" && parentClass.ToString() == "ComboBox" && containerClass.ToString() == "FloatNotifySink";
                }
                if (filenameControl && IsWindowVisible(candidate) && IsWindowEnabled(candidate) && GetAncestor(candidate, 2) == dialog) { filename = candidate; count++; }
                return true;
            }, IntPtr.Zero);
            if (count != 1) { failure = "Expected one native filename control; found " + count + "."; return false; }
            field = filename;
            name.Clear();
            GetClassName(field, name, name.Capacity);
        }
        if (name.ToString() == "ComboBoxEx32") field = FindWindowEx(field, IntPtr.Zero, "ComboBox", null);
        name.Clear();
        GetClassName(field, name, name.Capacity);
        if (name.ToString() == "ComboBox") field = FindWindowEx(field, IntPtr.Zero, "Edit", null);
        name.Clear();
        GetClassName(field, name, name.Capacity);
        bool owned = field != IntPtr.Zero && GetAncestor(field, 2) == dialog;
        bool visible = IsWindowVisible(field);
        bool enabled = IsWindowEnabled(field);
        bool readOnly = (GetWindowLong(field, -16) & 0x0800) != 0;
        if (name.ToString() != "Edit" || !owned || !visible || !enabled || readOnly) {
            failure = "Filename guard: class=" + name + "; owned=" + owned + "; visible=" + visible + "; enabled=" + enabled + "; readOnly=" + readOnly + ".";
            return false;
        }
        IntPtr result;
        if (SendTextTimeout(field, 0x000c, IntPtr.Zero, value, 3, 5000, out result) == IntPtr.Zero || result == IntPtr.Zero) {
            failure = "The native filename WM_SETTEXT did not succeed.";
            return false;
        }
        StringBuilder actual = new StringBuilder(32768);
        if (ReadTextTimeout(field, 0x000d, new IntPtr(actual.Capacity), actual, 3, 5000, out result) == IntPtr.Zero) {
            failure = "The native filename WM_GETTEXT did not complete.";
            return false;
        }
        if (actual.ToString() != value) { failure = "The native filename read-back did not match the synthetic path."; return false; }
        failure = String.Empty;
        return true;
    }
    public static bool ClickPickerCommand(IntPtr dialog, int identifier, out string failure) {
        failure = "The picker command identifier is not allowed.";
        if (identifier != 1 && identifier != 2) return false;
        IntPtr command = GetDlgItem(dialog, identifier);
        failure = "The picker command is not a visible, enabled direct child.";
        if (command == IntPtr.Zero || GetParent(command) != dialog || !IsWindowVisible(command) || !IsWindowEnabled(command)) return false;
        StringBuilder name = new StringBuilder(64);
        StringBuilder text = new StringBuilder(64);
        GetClassName(command, name, name.Capacity);
        GetWindowText(command, text, text.Capacity);
        string label = text.ToString().Replace("&", "");
        failure = "The native command class or expected label did not match; class=" + name + ".";
        if (name.ToString() != "Button" || (identifier == 2 ? label != "Cancel" : label != "Save" && label != "Open")) return false;
        if (!PostMessage(command, 0x00f5, IntPtr.Zero, IntPtr.Zero)) {
            failure = "The native click could not be queued; Win32Error=" + Marshal.GetLastWin32Error() + ".";
            return false;
        }
        failure = String.Empty;
        return true;
    }
    public static IntPtr OwnedFileDialog(IntPtr owner) {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr candidate, IntPtr parameter) {
            if (!IsWindowVisible(candidate)) return true;
            StringBuilder name = new StringBuilder(256);
            GetClassName(candidate, name, name.Capacity);
            if (name.ToString() != "#32770") return true;
            IntPtr ancestor = GetWindow(candidate, 4);
            for (int depth = 0; ancestor != IntPtr.Zero && depth < 8; depth++) {
                if (ancestor == owner) { result = candidate; return false; }
                ancestor = GetWindow(ancestor, 4);
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@

function Assert-CompiledUi {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Wait-CompiledUi {
    param([scriptblock]$Condition, [string]$Failure, [int]$Milliseconds = 15000)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $Milliseconds) {
        try { if (& $Condition) { return } }
        catch {
            if ($_.Exception -isnot [IO.IOException] -and $_.Exception.InnerException -isnot [IO.IOException]) { throw }
        }
        [Windows.Forms.Application]::DoEvents()
        [void][Threading.Thread]::Yield()
    }
    throw $Failure
}

function Find-CompiledUi {
    param([string]$Value, [switch]$Name)
    $property = if ($Name) { [Windows.Automation.AutomationElement]::NameProperty } else { [Windows.Automation.AutomationElement]::AutomationIdProperty }
    $element = $script:uiRoot.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($property, $Value)))
    if ($null -eq $element -and -not $Name -and $Value -eq 'MoreButton') {
        $element = $script:uiRoot.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($property, 'MainCommandsMoreButton')))
    }
    return $element
}

function Set-CompiledText {
    param([string]$Id, [string]$Text)
    $element = Find-CompiledUi $Id
    Assert-CompiledUi ($null -ne $element) ('Missing input: ' + $Id)
    ([Windows.Automation.ValuePattern]$element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)).SetValue($Text)
}

function Get-CompiledText {
    param([string]$Id)
    $element = Find-CompiledUi $Id
    if ($null -eq $element) { return $null }
    return ([Windows.Automation.ValuePattern]$element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)).Current.Value
}

function Invoke-CompiledButton {
    param([string]$Value, [switch]$Name)
    if ($Name) {
        $commandRoot = Find-CompiledUi 'ActiveToolDialog'
        if ($null -eq $commandRoot) { $commandRoot = $script:uiRoot }
        $buttonCondition = New-Object Windows.Automation.AndCondition(
            (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, $Value)),
            (New-Object Windows.Automation.AndCondition(
                (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::IsEnabledProperty, $true)),
                (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::IsInvokePatternAvailableProperty, $true)))))
        Wait-CompiledUi { $null -ne $commandRoot.FindFirst([Windows.Automation.TreeScope]::Descendants, $buttonCondition) } ('No enabled command: ' + $Value)
        $element = $commandRoot.FindFirst([Windows.Automation.TreeScope]::Descendants, $buttonCondition)
    }
    else { $element = Find-CompiledUi $Value }
    Assert-CompiledUi ($null -ne $element) ('Missing command: ' + $Value)
    ([Windows.Automation.InvokePattern]$element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()
}

function Test-CompiledSaveComplete {
    $statusElement = Find-CompiledUi 'Status'
    $saveElement = Find-CompiledUi 'SaveWebsite'
    return $null -ne $statusElement -and $null -ne $saveElement -and $statusElement.Current.Name -eq 'Website saved.' -and $saveElement.Current.IsEnabled
}

function Complete-CompiledFilePicker {
    param([string]$Path, [switch]$Cancel)
    $pickerState = @{ Handle = [IntPtr]::Zero }
    Wait-CompiledUi {
        $pickerState.Handle = [CompiledUiNative]::OwnedFileDialog($script:windowHandle)
        return $pickerState.Handle -ne [IntPtr]::Zero
    } 'The system picker did not expose a visible dialog owned by the exact test window.'
    $picker = [Windows.Automation.AutomationElement]::FromHandle($pickerState.Handle)
    if (-not $Cancel) {
        $resolved = [IO.Path]::GetFullPath($Path)
        Assert-CompiledUi ($resolved.StartsWith($fixture + '\', [StringComparison]::OrdinalIgnoreCase)) 'Picker test paths must remain within the synthetic fixture.'
        $filenameLabels = New-Object Windows.Automation.OrCondition(
            (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'File name:')),
            (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'File name')))
        $filenameCondition = New-Object Windows.Automation.AndCondition($filenameLabels,
            (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::IsValuePatternAvailableProperty, $true)))
        $pickerState.Filename = $picker.FindFirst([Windows.Automation.TreeScope]::Descendants, $filenameCondition)
        $filenameValue = $null
        $filenameHandle = [IntPtr]::Zero
        if ($null -ne $pickerState.Filename -and $pickerState.Filename.Current.IsEnabled -and -not $pickerState.Filename.Current.IsOffscreen) {
            $filenameValue = [Windows.Automation.ValuePattern]$pickerState.Filename.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
            $filenameHandle = [IntPtr]$pickerState.Filename.Current.NativeWindowHandle
        }
        if ($null -ne $filenameValue -and $filenameValue.Current.IsReadOnly) {
            $valueCondition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::IsValuePatternAvailableProperty, $true)
            foreach ($candidate in $pickerState.Filename.FindAll([Windows.Automation.TreeScope]::Descendants, $valueCondition)) {
                $candidateValue = [Windows.Automation.ValuePattern]$candidate.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
                if (-not $candidateValue.Current.IsReadOnly) { $filenameValue = $candidateValue; break }
            }
        }
        if ($null -ne $filenameValue -and -not $filenameValue.Current.IsReadOnly) { $filenameValue.SetValue($resolved) }
        else {
            $filenameFailure = ''
            $filenameSet = [CompiledUiNative]::SetPickerFilename($pickerState.Handle, $filenameHandle, $resolved, [ref]$filenameFailure)
            Assert-CompiledUi $filenameSet ('The exact owned native filename Edit could not be set safely. ' + $filenameFailure)
        }
    }
    $commandIdentifier = if ($Cancel) { 2 } else { 1 }
    Wait-CompiledUi {
        $commandHandle = [CompiledUiNative]::GetDlgItem($pickerState.Handle, $commandIdentifier)
        if ($commandHandle -eq [IntPtr]::Zero) { return $false }
        $pickerState.Button = [Windows.Automation.AutomationElement]::FromHandle($commandHandle)
        $label = $pickerState.Button.Current.Name.Replace('&', '')
        $expectedLabel = if ($Cancel) { $label -ceq 'Cancel' } else { $label -ceq 'Save' -or $label -ceq 'Open' }
        return $expectedLabel -and $pickerState.Button.Current.IsEnabled -and -not $pickerState.Button.Current.IsOffscreen
    } 'The direct owned picker command did not become ready.'
    $button = $pickerState.Button
    Write-Host ('CHECK: Owned picker action {0}; native button {1}.' -f $(if ($Cancel) { 'Cancel' } else { 'Select synthetic file' }), $button.Current.Name)
    $invoke = $null
    if ($button.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) { ([Windows.Automation.InvokePattern]$invoke).Invoke() }
    else {
        $commandFailure = ''
        $commandInvoked = [CompiledUiNative]::ClickPickerCommand($pickerState.Handle, $commandIdentifier, [ref]$commandFailure)
        if (-not $commandInvoked) {
            $dialogRemains = [CompiledUiNative]::OwnedFileDialog($script:windowHandle) -ne [IntPtr]::Zero
            $syntheticFileExists = -not $Cancel -and [IO.File]::Exists($resolved)
            throw ('The exact owned native Button command could not be invoked safely. ' + $commandFailure + ' Dialog remains=' + $dialogRemains + '; synthetic file exists=' + $syntheticFileExists + '.')
        }
    }
    Wait-CompiledUi { [CompiledUiNative]::OwnedFileDialog($script:windowHandle) -eq [IntPtr]::Zero } 'The owned file picker did not close after its direct command.'
}

function Test-CompiledProtectedKitFiles {
    param([string]$CatalogPath)
    $encryptedPath = Join-Path $fixture 'synthetic.encrypted-kit.json'
    $beforePickerImport = [Convert]::ToBase64String([IO.File]::ReadAllBytes($CatalogPath))
    foreach ($cancelPicker in @($true, $false)) {
        Invoke-CompiledButton 'Export' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'KitPassword') } 'Protected export did not reopen its password dialog.'
        Set-CompiledText 'KitPassword' 'Synthetic passphrase for this fixture'
        Set-CompiledText 'KitPasswordConfirmation' 'Synthetic passphrase for this fixture'
        Invoke-CompiledButton 'Encrypt' -Name
        Complete-CompiledFilePicker -Path $encryptedPath -Cancel:$cancelPicker
        if ($cancelPicker) {
            Wait-CompiledUi { $null -ne (Find-CompiledUi 'ExportKitNotes') } 'Cancelling the actual save picker lost the export draft.'
            Assert-CompiledUi ((Get-CompiledText 'ExportKitName') -ceq 'Synthetic export' -and (Get-CompiledText 'ExportKitNotes') -ceq 'Synthetic kit-level notes retained after invalid export.') 'Picker cancellation changed the export draft.'
            Assert-CompiledUi (-not [IO.File]::Exists($encryptedPath)) 'Cancelling the save picker wrote an export.'
        }
    }
    Wait-CompiledUi { $status = Find-CompiledUi 'Status'; $null -ne $status -and $status.Current.Name -eq 'App Kit exported.' } 'The actual encrypted file export did not complete.'
    $encryptedJson = [IO.File]::ReadAllText($encryptedPath)
    $envelope = $encryptedJson | ConvertFrom-Json
    Assert-CompiledUi ($envelope.Product -ceq 'EasyEdgeApps.EncryptedKit' -and $envelope.Iterations -eq 600000) 'The exported file is not a protected App Kit.'
    Assert-CompiledUi (-not $encryptedJson.Contains('Synthetic kit-level notes') -and -not $encryptedJson.Contains('Renamed WinUI')) 'Protected export leaked plaintext kit fields.'
    $encryptedBeforeImport = [Convert]::ToBase64String([IO.File]::ReadAllBytes($encryptedPath))
    Invoke-CompiledButton 'ImportKit'
    Complete-CompiledFilePicker -Path $encryptedPath
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'KitPassword') } 'The actual protected import did not ask for its passphrase.'
    Set-CompiledText 'KitPassword' 'Incorrect synthetic fixture password'
    Invoke-CompiledButton 'Unlock' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Incorrect password or damaged kit.' -Name) } 'Wrong-password input did not retain the unlock dialog.'
    Set-CompiledText 'KitPassword' 'Synthetic passphrase for this fixture'
    Invoke-CompiledButton 'Unlock' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Websites to import' -Name) } 'A correct passphrase did not expose the imported website selection.'
    Invoke-CompiledButton 'Preview' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'ImportComparison0') } 'Protected import omitted the current/effective comparison.'
    Save-CompiledCapture 'protected-import-preview'
    Invoke-CompiledButton 'Import' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Import results' -Name) } 'The protected import did not complete.'
    Invoke-CompiledButton 'Close' -Name
    Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($CatalogPath)) -ceq $beforePickerImport) 'Round-trip import changed an otherwise identical saved definition.'
    Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($encryptedPath)) -ceq $encryptedBeforeImport) 'Import changed the encrypted source file.'
    $measurements.ProtectedKitPickerRoundTripVerified = $true
    $measurements.SavePickerCancellationKeepsDraft = $true
    Write-Host 'CHECK: Protected export, save-picker cancellation, wrong-password retry and unchanged-data import verified.'
}

function Show-CompiledEditorControl {
    param([string]$Id, [string]$ViewportId = 'EditorScroll')
    Wait-CompiledUi { $null -ne (Find-CompiledUi $ViewportId) } ('The scroll viewport was not exposed: ' + $ViewportId)
    $viewport = Find-CompiledUi $ViewportId
    $scrollPattern = [Windows.Automation.ScrollPattern]$viewport.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern)
    if ($scrollPattern.Current.VerticallyScrollable) { $scrollPattern.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, 0) }
    Wait-CompiledUi {
        $element = Find-CompiledUi $Id
        if ($null -ne $element -and -not $element.Current.IsOffscreen) {
            $bounds = $element.Current.BoundingRectangle
            $visible = $viewport.Current.BoundingRectangle
            if ($bounds.Top -ge $visible.Top - 2 -and $bounds.Bottom -le $visible.Bottom + 2) { return $true }
        }
        if ($scrollPattern.Current.VerticallyScrollable -and $scrollPattern.Current.VerticalScrollPercent -lt 100) {
            $scrollPattern.Scroll([Windows.Automation.ScrollAmount]::NoAmount, [Windows.Automation.ScrollAmount]::SmallIncrement)
        }
        return $false
    } ('The editor control is not fully reachable: ' + $Id)
}

function Set-CompiledToggle {
    param([string]$Id, [bool]$Enabled, [string]$ViewportId = 'ToolDialogScroll')
    Show-CompiledEditorControl $Id -ViewportId $ViewportId
    $pattern = [Windows.Automation.TogglePattern](Find-CompiledUi $Id).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    $state = if ($Enabled) { [Windows.Automation.ToggleState]::On } else { [Windows.Automation.ToggleState]::Off }
    if ($pattern.Current.ToggleState -ne $state) { $pattern.Toggle() }
    Wait-CompiledUi { $pattern.Current.ToggleState -eq $state } ('The setting did not change: ' + $Id)
}

function Select-CompiledOption {
    param([string]$Id, [string]$Label, [string]$ViewportId = 'ToolDialogScroll')
    Show-CompiledEditorControl $Id -ViewportId $ViewportId
    $expand = [Windows.Automation.ExpandCollapsePattern](Find-CompiledUi $Id).GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    $selected = @{ Pattern = $null }
    $optionCondition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, $Label)
    Wait-CompiledUi {
        foreach ($candidate in $script:uiRoot.FindAll([Windows.Automation.TreeScope]::Descendants, $optionCondition)) {
            $optionPattern = $null
            if (-not $candidate.Current.IsOffscreen -and $candidate.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$optionPattern)) {
                $selected.Pattern = $optionPattern
                return $true
            }
        }
        return $false
    } ('The selectable setting was not exposed: ' + $Label)
    ([Windows.Automation.SelectionItemPattern]$selected.Pattern).Select()
    if ($expand.Current.ExpandCollapseState -eq [Windows.Automation.ExpandCollapseState]::Expanded) { $expand.Collapse() }
}

function Save-CompiledCapture {
    param([string]$Name, [switch]$SceneSample)
    $rectangle = New-Object CompiledUiNative+Rectangle
    [void][CompiledUiNative]::GetWindowRect($script:windowHandle, [ref]$rectangle)
    $bitmap = New-Object Drawing.Bitmap(($rectangle.Right - $rectangle.Left), ($rectangle.Bottom - $rectangle.Top))
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        [void][CompiledUiNative]::DwmFlush()
        $context = $graphics.GetHdc()
        try { [void][CompiledUiNative]::PrintWindow($script:windowHandle, $context, 2) }
        finally { $graphics.ReleaseHdc($context) }
        $colors = New-Object 'System.Collections.Generic.HashSet[int]'
        for ($row = 40; $row -lt $bitmap.Height - 20; $row += 12) {
            for ($column = 20; $column -lt $bitmap.Width - 20; $column += 12) { [void]$colors.Add($bitmap.GetPixel($column, $row).ToArgb()) }
        }
        if ($colors.Count -lt 8) {
            [void][CompiledUiNative]::SetForegroundWindow($script:windowHandle)
            Assert-CompiledUi ([CompiledUiNative]::GetForegroundWindow() -eq $script:windowHandle) 'The exact owned test window must be foreground before screen capture.'
            $graphics.CopyFromScreen($rectangle.Left, $rectangle.Top, 0, 0, $bitmap.Size)
        }
        if ($SceneSample) {
            $nameBounds = (Find-CompiledUi 'WebsiteName').Current.BoundingRectangle
            $sampleLeft = [int]($nameBounds.Left - $rectangle.Left - 18)
            $sampleTop = [int]($nameBounds.Top - $rectangle.Top)
            $sampleHeight = [Math]::Min(320, $bitmap.Height - $sampleTop - 160)
            Assert-CompiledUi ($sampleLeft -ge 0 -and $sampleHeight -gt 32) 'The background sample is outside the editor-column gap.'
            $pixels = New-Object 'int[]' (12 * $sampleHeight)
            $sampleColors = New-Object 'System.Collections.Generic.HashSet[int]'
            for ($row = 0; $row -lt $sampleHeight; $row++) {
                for ($column = 0; $column -lt 12; $column++) {
                    $color = $bitmap.GetPixel($sampleLeft + $column, $sampleTop + $row).ToArgb()
                    $pixels[$row * 12 + $column] = $color
                    [void]$sampleColors.Add($color)
                }
            }
            $bytes = New-Object 'byte[]' ($pixels.Length * 4)
            [Buffer]::BlockCopy($pixels, 0, $bytes, 0, $bytes.Length)
            $hash = [Security.Cryptography.SHA256]::Create()
            try { return [pscustomobject]@{ Hash = [Convert]::ToBase64String($hash.ComputeHash($bytes)); Colors = $sampleColors.Count } }
            finally { $hash.Dispose() }
        }
        $bitmap.Save((Join-Path $ScreenshotDirectory ($Name + '.png')), [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
}

$fixture = $FixtureRoot
[void][IO.Directory]::CreateDirectory($fixture)
[void][IO.Directory]::CreateDirectory($ScreenshotDirectory)
$process = $null
$script:uiRoot = $null
$measurements = [ordered]@{ Evidence = 'Observed native isolated WinUI run; not a benchmark or clean-machine acceptance'; TextSize = $TextSize; Theme = $Theme; StartupMilliseconds = 0; SaveMilliseconds = 0; RenameMilliseconds = 0; WorkingSetBytes = 0; PeakWorkingSetBytes = 0 }
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'Data'))
    $preferencePath = Join-Path $fixture 'Data\preferences.json'
    $legacyPreferencePath = Join-Path $fixture 'Legacy\settings.json'
    $effectiveTextSize = [double]$TextSize
    if ($LegacySettingsPoints) {
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'Legacy'))
        $legacyPreferenceBytes = [Text.Encoding]::UTF8.GetBytes((@{ Product = 'EasyEdgeApps.Settings'; SchemaVersion = 1; AutomaticUpdateChecks = $true; DebugLogging = $true; DefaultEdgeProfile = 'Profile 3'; DefaultDesktop = $false; DefaultStartMenu = $true; MotionEnabled = $false; TextSize = $LegacySettingsPoints } | ConvertTo-Json -Compress))
        [IO.File]::WriteAllBytes($legacyPreferencePath, $legacyPreferenceBytes)
        $effectiveTextSize = $LegacySettingsPoints * 4.0 / 3.0
    }
    else { [IO.File]::WriteAllText($preferencePath, (@{ TextSize = $TextSize; Theme = $Theme } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false))) }
    if ($SettingsOnly -or $FavoritesOnly) {
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'Data\EdgeProfiles\Default'))
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'Data\EdgeProfiles\Profile 3'))
        [IO.File]::WriteAllText((Join-Path $fixture 'Data\EdgeProfiles\Local State'), '{"profile":{"info_cache":{"Profile 3":{"name":"Synthetic work"}}}}', (New-Object Text.UTF8Encoding($false)))
    }
    if ($FavoritesOnly) {
        [IO.File]::WriteAllText($preferencePath, (@{ TextSize = $TextSize; Theme = $Theme; DefaultProfile = 'Profile 3'; DefaultDesktop = $false; DefaultStartMenu = $true } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        $favoritesBookmarks = Join-Path $fixture 'Data\EdgeProfiles\Profile 3\Bookmarks'
        $favoritesBytes = [Text.Encoding]::UTF8.GetBytes('{"roots":{"bookmark_bar":{"type":"folder","name":"Favorites bar","children":[{"type":"folder","name":"Projects","children":[{"type":"url","name":"Work","url":"https://work.example.com/"},{"type":"url","name":"Mail","url":"https://mail.example.com/"},{"type":"url","name":"Work duplicate","url":"https://work.example.com/"},{"type":"url","name":"HTTP only","url":"http://example.com/"}]}]}}}')
        [IO.File]::WriteAllBytes($favoritesBookmarks, $favoritesBytes)
        [IO.File]::WriteAllText((Join-Path $fixture 'Data\EdgeProfiles\Default\Bookmarks'), '{"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"url","name":"Personal","url":"https://personal.example.com/"}]}}}')
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'Desktop'))
        $foreignShortcut = Join-Path $fixture 'Desktop\Work.lnk'
        [IO.File]::WriteAllText($foreignShortcut, 'Synthetic unrelated shortcut')
    }
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $ManagerPath -ArgumentList ('--isolated-root "' + $fixture + '"') -PassThru
    [IO.File]::WriteAllText((Join-Path $fixture 'manager.pid'), [string]$process.Id)
    [void]$process.WaitForInputIdle(15000)
    Wait-CompiledUi {
        $process.Refresh()
        if ($process.HasExited) { throw ('The compiled manager exited at startup with code ' + $process.ExitCode) }
        $process.MainWindowHandle -ne [IntPtr]::Zero
    } 'The compiled manager did not create a native window.'
    $script:windowHandle = $process.MainWindowHandle
    Write-Host 'CHECK: Native manager window created.'
    $script:uiRoot = [Windows.Automation.AutomationElement]::FromHandle($script:windowHandle)
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'WebsiteName') } 'The compiled editor was not exposed to UI Automation.'
    $measurements.StartupMilliseconds = $elapsed.ElapsedMilliseconds
    Write-Host 'CHECK: UI Automation editor located.'
    $startupArea = [Windows.Forms.Screen]::FromHandle($script:windowHandle).WorkingArea
    $startupBounds = $script:uiRoot.Current.BoundingRectangle
    Assert-CompiledUi ($startupBounds.Left -ge $startupArea.Left - 8 -and $startupBounds.Top -ge $startupArea.Top - 8 -and $startupBounds.Right -le $startupArea.Right + 8 -and $startupBounds.Bottom -le $startupArea.Bottom + 8) 'The initial manager window does not fit the monitor working area.'
    Assert-CompiledUi ([Math]::Abs(($startupBounds.Left + $startupBounds.Width / 2) - ($startupArea.Left + $startupArea.Width / 2)) -le 16 -and [Math]::Abs(($startupBounds.Top + $startupBounds.Height / 2) - ($startupArea.Top + $startupArea.Height / 2)) -le 16) 'The initial manager window is not centered in the working area.'
    $measurements.InitialWorkingAreaFitVerified = $true
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    [void][CompiledUiNative]::MoveWindow($script:windowHandle, $area.Left + 10, $area.Top + 10, [Math]::Min(1024, $area.Width - 20), [Math]::Min(740, $area.Height - 20), $true)
    if ($SafetyOnly) {
        foreach ($siteName in @('Safety Alpha', 'Safety Bravo')) {
            if ($siteName -eq 'Safety Bravo') {
                Invoke-CompiledButton 'NewWebsite'
                Wait-CompiledUi { (Get-CompiledText 'WebsiteName') -eq '' } 'The second synthetic draft did not open.'
            }
            Set-CompiledText 'WebsiteName' $siteName
            Set-CompiledText 'WebsiteAddress' 'https://example.com/'
            Wait-CompiledUi { $save = Find-CompiledUi 'SaveWebsite'; $null -ne $save -and $save.Current.IsEnabled -and $save.Current.ItemStatus -eq 'Unsaved changes' } 'The safety fixture did not become ready to save.'
            Invoke-CompiledButton 'SaveWebsite'
            Wait-CompiledUi { Test-CompiledSaveComplete } 'The synthetic safety website did not save.'
        }
        $catalogPath = Join-Path $fixture 'Data\catalog.json'
        $savedCatalog = [Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath))
        $websiteList = Find-CompiledUi 'WebsiteList'
        Invoke-CompiledButton 'ExportKit'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'ExportKitNotes') } 'The safety export dialog did not open.'
        $measurements.BusySelectionLocked = -not $websiteList.Current.IsEnabled
        Invoke-CompiledButton 'Cancel' -Name
        Wait-CompiledUi { $null -eq (Find-CompiledUi 'ActiveToolDialog') -and (Find-CompiledUi 'NewWebsite').Current.IsEnabled } 'Export cancellation did not return to the editor.'
        Assert-CompiledUi ((Get-CompiledText 'WebsiteName') -ceq 'Safety Bravo') 'The editor changed selection during export cancellation.'
        Invoke-CompiledButton 'RemoveWebsite'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Remove website shortcuts?' -Name) } 'The Remove confirmation did not open.'
        $dialog = Find-CompiledUi 'ActiveToolDialog'
        $dialogNames = @($dialog.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name }) -join "`n"
        $measurements.RemoveNamesExactWebsite = $dialogNames.Contains('Safety Bravo') -and -not $dialogNames.Contains('Safety Alpha')
        Save-CompiledCapture 'remove-confirmation'
        Invoke-CompiledButton 'Cancel' -Name
        Wait-CompiledUi { $null -eq (Find-CompiledUi 'ActiveToolDialog') -and (Find-CompiledUi 'NewWebsite').Current.IsEnabled } 'Remove cancellation did not return to the editor.'
        Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath)) -ceq $savedCatalog) 'Cancelling Remove changed the saved catalog.'
        Set-CompiledText 'WebsiteNotes' 'Retain this draft after an invalid icon.'
        $invalidIcon = Join-Path $fixture 'invalid.png'
        [IO.File]::WriteAllBytes($invalidIcon, [Text.Encoding]::UTF8.GetBytes('Synthetic invalid image'))
        Show-CompiledEditorControl 'UseSavedIcon'
        Invoke-CompiledButton 'Choose icon' -Name
        Complete-CompiledFilePicker -Path $invalidIcon
        Wait-CompiledUi { $status = Find-CompiledUi 'Status'; $null -ne $status -and $status.Current.Name -match 'icon.*(could not|unavailable)' -and (Find-CompiledUi 'NewWebsite').Current.IsEnabled } 'The invalid icon did not produce a completed recoverable error.'
        $measurements.FailedIconBlocksSave = -not (Find-CompiledUi 'SaveWebsite').Current.IsEnabled
        $measurements.FailedIconExplainsRecovery = (Find-CompiledUi 'Status').Current.Name.Contains('Use saved icon')
        Save-CompiledCapture 'icon-recovery'
        Invoke-CompiledButton 'NewWebsite'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Unsaved changes' -Name) } 'The icon-failure draft guard did not open.'
        $measurements.FailedIconBlocksDraftSave = -not (Find-CompiledUi 'Save' -Name).Current.IsEnabled
        Invoke-CompiledButton 'Cancel' -Name
        Wait-CompiledUi { $null -eq (Find-CompiledUi 'ActiveToolDialog') -and (Find-CompiledUi 'NewWebsite').Current.IsEnabled } 'Draft cancellation did not return to the editor.'
        Show-CompiledEditorControl 'UseSavedIcon'
        Invoke-CompiledButton 'UseSavedIcon'
        Wait-CompiledUi { (Find-CompiledUi 'SaveWebsite').Current.IsEnabled } 'Restoring the saved icon did not unblock Save.'
        Assert-CompiledUi ((Get-CompiledText 'WebsiteNotes') -ceq 'Retain this draft after an invalid icon.') 'Icon recovery lost unrelated notes.'
        Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath)) -ceq $savedCatalog) 'Failed icon preparation or recovery changed the saved catalog.'
        Invoke-CompiledButton 'SaveWebsite'
        Wait-CompiledUi { Test-CompiledSaveComplete } 'The recovered icon draft did not save.'
        $measurements.SavedIconRecoveryPreservesDraft = $true
        $measurements.WorkingSetBytes = $process.WorkingSet64
        $measurements.PeakWorkingSetBytes = $process.PeakWorkingSet64
        [IO.File]::WriteAllText((Join-Path $ScreenshotDirectory 'observations.json'), ($measurements | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        $safetyFailures = @(@('BusySelectionLocked', 'RemoveNamesExactWebsite', 'FailedIconBlocksSave', 'FailedIconExplainsRecovery', 'FailedIconBlocksDraftSave') | Where-Object { -not $measurements[$_] })
        Assert-CompiledUi ($safetyFailures.Count -eq 0) ('Safety controls failed: ' + ($safetyFailures -join ', '))
        [void]$process.CloseMainWindow()
        Assert-CompiledUi ($process.WaitForExit(15000)) 'The clean safety fixture did not close.'
        Assert-CompiledUi ($process.ExitCode -eq 0) 'The safety fixture closed with an error exit code.'
        Write-Host 'PASS: Command selection locking, exact Remove target, cancelled-operation preservation and failed-icon draft recovery. No browser or pin was requested.'
        return
    }
    if ($KitFilesOnly) {
        Set-CompiledText 'WebsiteName' 'Renamed WinUI'
        Set-CompiledText 'WebsiteAddress' 'https://example.com/'
        Wait-CompiledUi {
            $save = Find-CompiledUi 'SaveWebsite'
            $null -ne $save -and $save.Current.IsEnabled -and $save.Current.ItemStatus -eq 'Unsaved changes'
        } 'The protected-kit fixture draft did not become ready to save.'
        $saveClock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-CompiledButton 'SaveWebsite'
        Wait-CompiledUi { Test-CompiledSaveComplete } 'The protected-kit fixture website did not save.'
        $measurements.SaveMilliseconds = $saveClock.ElapsedMilliseconds
        Invoke-CompiledButton 'ExportKit'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'ExportKitNotes') } 'The protected-kit export draft did not open.'
        Set-CompiledText 'ExportKitName' 'Synthetic export'
        Set-CompiledText 'ExportKitNotes' 'Synthetic kit-level notes retained after invalid export.'
        Set-CompiledToggle 'ExportKitEncrypted' $true
        Test-CompiledProtectedKitFiles -CatalogPath (Join-Path $fixture 'Data\catalog.json')
        Wait-CompiledUi {
            $save = Find-CompiledUi 'SaveWebsite'
            $null -eq (Find-CompiledUi 'ActiveToolDialog') -and $null -ne $save -and $save.Current.IsEnabled
        } 'The protected-kit workflow did not return to the ready editor.'
        $process.Refresh()
        $measurements.WorkingSetBytes = $process.WorkingSet64
        $measurements.PeakWorkingSetBytes = $process.PeakWorkingSet64
        [IO.File]::WriteAllText((Join-Path $ScreenshotDirectory 'observations.json'), ($measurements | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        [void]$process.CloseMainWindow()
        Assert-CompiledUi ($process.WaitForExit(15000)) 'The clean protected-kit fixture did not close.'
        Write-Host 'PASS: Actual protected-kit pickers, cancellation retention, password retry and round-trip source/catalog preservation. No browser or pin was requested.'
        return
    }
    if ($FavoritesOnly) {
        Invoke-CompiledButton 'ImportFavorites'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'FavoritesProfile') } 'Favorites did not expose its local profile selector.'
        $favoriteProfile = [Windows.Automation.SelectionPattern](Find-CompiledUi 'FavoritesProfile').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)
        Assert-CompiledUi ($favoriteProfile.Current.GetSelection()[0].Current.Name -ceq 'Synthetic work (Profile 3)') 'Favorites ignored the saved Edge profile default.'
        Wait-CompiledUi { $list = Find-CompiledUi 'FavoritesList'; $null -ne $list -and ([Windows.Automation.SelectionPattern]$list.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)).Current.GetSelection().Count -eq 2 } 'Favorites did not select only the available HTTPS entries.'
        foreach ($placement in @('FavoritesDesktop', 'FavoritesStartMenu')) {
            Show-CompiledEditorControl $placement -ViewportId 'ToolDialogScroll'
            Assert-CompiledUi (([Windows.Automation.TogglePattern](Find-CompiledUi $placement).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)).Current.ToggleState -eq [Windows.Automation.ToggleState]::On) 'Favorites must retain its original Desktop and Start defaults independently of editor defaults.'
        }
        Show-CompiledEditorControl 'FavoritesList' -ViewportId 'ToolDialogScroll'
        foreach ($excludedId in @('FavoriteCandidate2', 'FavoriteCandidate3')) {
            Show-CompiledEditorControl $excludedId -ViewportId 'FavoritesList'
            Assert-CompiledUi (-not (Find-CompiledUi $excludedId).Current.IsEnabled) ('An excluded Favorite was hidden or selectable: ' + $excludedId)
        }
        Assert-CompiledUi ($null -ne (Find-CompiledUi 'Projects' -Name)) 'Favorites lost its nested folder context.'
        Save-CompiledCapture 'favorites-candidates'
        Set-CompiledToggle 'FavoritesAllAvailable' $false
        Invoke-CompiledButton 'Preview' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Select between 1 and 100 available websites.' -Name) } 'An empty Favorites selection did not retain the dialog with an error.'
        Set-CompiledToggle 'FavoritesAllAvailable' $true
        Set-CompiledToggle 'FavoritesDesktop' $false
        Set-CompiledToggle 'FavoritesStartMenu' $false
        Invoke-CompiledButton 'Preview' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Select Desktop or Start menu.' -Name) } 'Invalid Favorites placement dismissed its draft.'
        Set-CompiledToggle 'FavoritesStartMenu' $true
        Invoke-CompiledButton 'Preview' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Import preview' -Name) } 'Favorites did not proceed directly to the selected import preview.'
        $comparison = Find-CompiledUi 'ImportComparison0'
        Assert-CompiledUi ($null -ne $comparison) 'The import preview omitted its actual before-and-after settings.'
        Assert-CompiledUi ($comparison.Current.Name.Contains('Before: Not installed') -and $comparison.Current.Name.Contains('After:') -and $comparison.Current.Name.Contains('Desktop: No') -and $comparison.Current.Name.Contains('Start menu: Yes') -and $comparison.Current.Name.Contains('Normal Edge profile: Profile 3')) 'The import comparison did not expose reviewed placement and effective local profile settings.'
        Save-CompiledCapture 'favorites-preview'
        $measurements.ImportBeforeAfterSettingsVerified = $true
        Assert-CompiledUi (-not [IO.File]::Exists((Join-Path $fixture 'Data\catalog.json'))) 'Favorites preview wrote website data.'
        Invoke-CompiledButton 'Close' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'FavoritesProfile') } 'Cancelling the preview lost the Favorites selection dialog.'
        $favoriteSelection = [Windows.Automation.SelectionPattern](Find-CompiledUi 'FavoritesList').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)
        Assert-CompiledUi ($favoriteSelection.Current.GetSelection().Count -eq 2) 'Cancelling the preview lost selected Favorites.'
        Show-CompiledEditorControl 'FavoritesDesktop' -ViewportId 'ToolDialogScroll'
        Assert-CompiledUi (([Windows.Automation.TogglePattern](Find-CompiledUi 'FavoritesDesktop').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)).Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) 'Cancelling the preview lost Favorites placement choices.'
        Invoke-CompiledButton 'Preview' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Import preview' -Name) } 'The retained Favorites selection could not be previewed again.'
        Invoke-CompiledButton 'Import' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Import results' -Name) } 'Approved Favorites did not return per-app results.'
        Invoke-CompiledButton 'Close' -Name
        Wait-CompiledUi { $null -eq (Find-CompiledUi 'ActiveToolDialog') -and (Find-CompiledUi 'ImportFavorites').Current.IsEnabled } 'Favorites import did not return to the editor.'
        $importedCatalog = [IO.File]::ReadAllText((Join-Path $fixture 'Data\catalog.json')) | ConvertFrom-Json
        $importedApps = @($importedCatalog.Apps | Where-Object { -not $_.Removed })
        Assert-CompiledUi ($importedApps.Count -eq 2) 'Favorites imported an excluded entry or the wrong profile.'
        Assert-CompiledUi (@($importedApps | Where-Object { $_.Definition.DisplayName -ceq 'Work (2)' }).Count -eq 1) 'Favorites did not choose a name that avoids the occupied shortcut.'
        Assert-CompiledUi ([IO.File]::ReadAllText($foreignShortcut) -ceq 'Synthetic unrelated shortcut') 'Favorites changed an unowned shortcut.'
        foreach ($importedApp in $importedApps) {
            Assert-CompiledUi (-not $importedApp.Definition.Desktop -and $importedApp.Definition.StartMenu -and $importedApp.Definition.EdgeProfile -ceq 'Profile 3') 'Favorites import did not preserve its reviewed placement and destination profile default.'
        }
        Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($favoritesBookmarks)) -ceq [Convert]::ToBase64String($favoritesBytes)) 'Favorites import changed its source Bookmarks.'
        $measurements.FavoritesProfileSelectionAndExclusionsVerified = $true
        $measurements.FavoritesPlacementAndCancelledPreviewRetentionVerified = $true
        $measurements.FavoritesApprovedImportAndSourcePreservationVerified = $true
        Save-CompiledCapture 'favorites-imported'
        [IO.File]::WriteAllText((Join-Path $ScreenshotDirectory 'observations.json'), ($measurements | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        [void]$process.CloseMainWindow()
        Assert-CompiledUi ($process.WaitForExit(15000)) 'The clean Favorites fixture did not close.'
        Write-Host 'PASS: Actual Favorites profile default, visible exclusions, folder context, placement validation, cancelled-preview retention and approved import. Source Bookmarks unchanged; no browser or pin was requested.'
        return
    }
    if ($SettingsOnly) {
        $editorText = [Windows.Automation.TextPattern](Find-CompiledUi 'WebsiteName').GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
        $measurements.ObservedEditorFontSize = $editorText.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::FontSizeAttribute)
        Assert-CompiledUi ([Math]::Abs($measurements.ObservedEditorFontSize - $effectiveTextSize * 0.75) -lt 0.05) 'The editor did not preserve the exact legacy point-to-DIP text size.'
        $initialSettings = if ([IO.File]::Exists($preferencePath)) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencePath)) } else { '' }
        Invoke-CompiledButton 'OpenPreferences'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'PreferenceProfile') } 'Settings did not open.'
        foreach ($section in @('Updates', 'Websites', 'Appearance', 'Diagnostics')) { Assert-CompiledUi ($null -ne (Find-CompiledUi $section -Name)) ('Missing Settings group: ' + $section) }
        Save-CompiledCapture 'settings-initial'
        foreach ($setting in @('PreferenceProfile', 'PreferenceDesktop', 'PreferenceStartMenu', 'PreferenceMotion', 'PreferenceTextSize', 'PreferenceTiles', 'PreferenceDiagnostics', 'PreferenceOpenLogs', 'PreferenceClearLogs')) { Show-CompiledEditorControl $setting -ViewportId 'ToolDialogScroll' }
        Set-CompiledToggle 'PreferenceDesktop' $false
        Set-CompiledToggle 'PreferenceStartMenu' $false
        Invoke-CompiledButton 'Save' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Invalid or unsupported preferences.' -Name) } 'Invalid settings did not remain open with a validation error.'
        Assert-CompiledUi ($null -ne (Find-CompiledUi 'PreferenceTextSize')) 'A failed settings save closed and lost the settings draft.'
        $afterInvalid = if ([IO.File]::Exists($preferencePath)) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencePath)) } else { '' }
        Assert-CompiledUi ($afterInvalid -ceq $initialSettings) 'Invalid settings changed stored preferences.'
        Set-CompiledToggle 'PreferenceStartMenu' $true
        Set-CompiledToggle 'PreferenceUpdates' $true
        Set-CompiledToggle 'PreferenceDiagnostics' $true
        Set-CompiledToggle 'PreferenceMotion' $false
        Set-CompiledToggle 'PreferenceTiles' $true
        Select-CompiledOption 'PreferenceProfile' 'Synthetic work (Profile 3)'
        Select-CompiledOption 'PreferenceTextSize' '14 pt'
        Show-CompiledEditorControl 'PreferenceReviewUpdate' -ViewportId 'ToolDialogScroll'
        Invoke-CompiledButton 'PreferenceReviewUpdate'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'No downloaded installer is retained.' -Name) } 'Review downloaded update did not handle the empty retained state.'
        Invoke-CompiledButton 'Close' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'PreferenceProfile') } 'Returning from update review lost the Settings draft.'
        Show-CompiledEditorControl 'PreferenceCheckUpdates' -ViewportId 'ToolDialogScroll'
        Invoke-CompiledButton 'PreferenceCheckUpdates'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Network update checks are disabled in isolated test mode.' -Name) } 'The settings update action did not fail closed in isolated mode.'
        Show-CompiledEditorControl 'PreferenceOpenLogs' -ViewportId 'ToolDialogScroll'
        Invoke-CompiledButton 'PreferenceOpenLogs'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'No diagnostic logs yet.' -Name) } 'The log-folder action did not report the absent owned logs.'
        $logs = Join-Path $fixture 'Data\Logs'
        [void][IO.Directory]::CreateDirectory($logs)
        [IO.File]::WriteAllText((Join-Path $logs 'events.jsonl'), '{"Operation":"Save","Outcome":"Success"}')
        [IO.File]::WriteAllText((Join-Path $logs 'keep.txt'), 'Synthetic unrelated file')
        Show-CompiledEditorControl 'PreferenceClearLogs' -ViewportId 'ToolDialogScroll'
        Invoke-CompiledButton 'PreferenceClearLogs'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Clear diagnostic logs?' -Name) } 'Clearing logs omitted confirmation.'
        Invoke-CompiledButton 'Cancel' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'PreferenceProfile') } 'Cancelling log deletion did not restore Settings.'
        Assert-CompiledUi ([IO.File]::Exists((Join-Path $logs 'events.jsonl'))) 'Cancelling log deletion removed the log.'
        Show-CompiledEditorControl 'PreferenceClearLogs' -ViewportId 'ToolDialogScroll'
        Invoke-CompiledButton 'PreferenceClearLogs'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Clear diagnostic logs?' -Name) } 'The second log-clear confirmation was not shown.'
        Invoke-CompiledButton 'Clear logs' -Name
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Diagnostic logs cleared.' -Name) } 'Confirmed log deletion did not return its result to Settings.'
        Assert-CompiledUi (-not [IO.File]::Exists((Join-Path $logs 'events.jsonl')) -and [IO.File]::Exists((Join-Path $logs 'keep.txt'))) 'Log deletion removed an unrelated file or retained the selected category log.'
        Show-CompiledEditorControl 'PreferenceTextSize' -ViewportId 'ToolDialogScroll'
        Save-CompiledCapture 'settings-actions-retained'
        Invoke-CompiledButton 'Save' -Name
        Wait-CompiledUi { $null -eq (Find-CompiledUi 'PreferenceProfile') -and (Find-CompiledUi 'OpenPreferences').Current.IsEnabled } 'Valid settings did not save and close.'
        $savedPreferences = [IO.File]::ReadAllText($preferencePath) | ConvertFrom-Json
        Assert-CompiledUi ($savedPreferences.DefaultProfile -ceq 'Profile 3' -and -not $savedPreferences.DefaultDesktop -and $savedPreferences.DefaultStartMenu -and $savedPreferences.CheckUpdates -and $savedPreferences.Diagnostics -and -not $savedPreferences.MotionEnabled -and $savedPreferences.Tiles -and [Math]::Abs($savedPreferences.TextSize - 56.0 / 3.0) -lt 0.000001) 'Saving after tool actions lost one or more pending preference edits.'
        $savedBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencePath))
        Invoke-CompiledButton 'OpenPreferences'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'PreferenceProfile') } 'Saved settings could not be reopened.'
        $profileSelection = [Windows.Automation.SelectionPattern](Find-CompiledUi 'PreferenceProfile').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)
        Assert-CompiledUi ($profileSelection.Current.GetSelection()[0].Current.Name -ceq 'Synthetic work (Profile 3)') 'The saved profile was not restored on reopening Settings.'
        $textSelection = [Windows.Automation.SelectionPattern](Find-CompiledUi 'PreferenceTextSize').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)
        Assert-CompiledUi ($textSelection.Current.GetSelection()[0].Current.Name -ceq '14 pt') 'The saved fractional text size was not restored on reopening Settings.'
        Set-CompiledToggle 'PreferenceDesktop' $true
        Invoke-CompiledButton 'Cancel' -Name
        Wait-CompiledUi { $null -eq (Find-CompiledUi 'PreferenceProfile') -and (Find-CompiledUi 'OpenPreferences').Current.IsEnabled } 'Settings cancellation did not return to the editor.'
        Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencePath)) -ceq $savedBytes) 'Cancelling Settings wrote pending changes.'
        Invoke-CompiledButton 'NewWebsite'
        $profileDetails = [Windows.Automation.ExpandCollapsePattern](Find-CompiledUi 'AdvancedSettings').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
        $profileDetails.Expand()
        Show-CompiledEditorControl 'NormalEdgeProfile'
        Wait-CompiledUi { (Get-CompiledText 'NormalEdgeProfile') -ceq 'Profile 3' } 'A new website did not inherit the saved profile default.'
        $desktop = [Windows.Automation.TogglePattern](Find-CompiledUi 'DesktopPlacement').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
        $startMenu = [Windows.Automation.TogglePattern](Find-CompiledUi 'StartMenuPlacement').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
        Assert-CompiledUi ($desktop.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off -and $startMenu.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) 'A new website did not inherit saved shortcut defaults.'
        if ($LegacySettingsPoints) { Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($legacyPreferencePath)) -ceq [Convert]::ToBase64String($legacyPreferenceBytes)) 'Settings migration modified the legacy preference file.' }
        Assert-CompiledUi (-not [IO.File]::Exists((Join-Path $fixture 'Data\catalog.json'))) 'Settings actions created website data.'
        $measurements.SettingsSaveReopenCancelVerified = $true
        $measurements.SettingsValidationAndToolDraftRetentionVerified = $true
        $measurements.SettingsLogActionsAndUpdateIsolationVerified = $true
        $measurements.LegacySettingsPoints = $LegacySettingsPoints
        Save-CompiledCapture 'settings-new-defaults'
        [IO.File]::WriteAllText((Join-Path $ScreenshotDirectory 'observations.json'), ($measurements | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        [void]$process.CloseMainWindow()
        Assert-CompiledUi ($process.WaitForExit(15000)) 'The clean Settings fixture did not close.'
        Write-Host 'PASS: Actual Settings grouping, profile picker, exact font mapping, failed-save retention, update isolation, log confirmation, save/reopen/cancel and new website defaults. No website, browser or installer was started.'
        return
    }
    Set-CompiledText 'WebsiteName' 'Synthetic WinUI'
    Set-CompiledText 'WebsiteAddress' 'https://example.com/'
    $nameTextPattern = [Windows.Automation.TextPattern](Find-CompiledUi 'WebsiteName').GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
    $observedFontSize = $nameTextPattern.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::FontSizeAttribute)
    Assert-CompiledUi ($observedFontSize -is [double] -and $observedFontSize -ge $TextSize * 0.74) 'The website editor did not apply the chosen text size.'
    $measurements.ObservedEditorFontSize = $observedFontSize
    Wait-CompiledUi { $save = Find-CompiledUi 'SaveWebsite'; $null -ne $save -and $save.Current.IsEnabled } 'A valid website never enabled Save.'
    Wait-CompiledUi {
        $save = Find-CompiledUi 'SaveWebsite'; $name = Find-CompiledUi 'WebsiteName'
        $null -ne $save -and $null -ne $name -and -not $save.Current.IsOffscreen -and -not $name.Current.IsOffscreen
    } 'Primary editing commands are not initially visible at this text size.'
    if ($WindowChoicesOnly) {
        Write-Host 'CHECK: Window-choice transitions started.'
        Set-CompiledToggle 'DedicatedProfile' $false -ViewportId 'EditorScroll'
        Set-CompiledToggle 'StartMenuPlacement' $false -ViewportId 'EditorScroll'
        Assert-CompiledUi ((Find-CompiledUi 'TaskbarIdentity').Current.IsEnabled) 'Taskbar cannot be selected to establish its required profile and Start entry.'
        Set-CompiledToggle 'TaskbarIdentity' $true -ViewportId 'EditorScroll'
        foreach ($requiredChoice in @('DedicatedProfile', 'StartMenuPlacement')) {
            $element = Find-CompiledUi $requiredChoice
            $toggle = [Windows.Automation.TogglePattern]$element.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
            Assert-CompiledUi ($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::On -and -not $element.Current.IsEnabled) ('Taskbar did not select and lock its required choice: ' + $requiredChoice)
        }
        Set-CompiledToggle 'TaskbarIdentity' $false -ViewportId 'EditorScroll'
        Assert-CompiledUi ((Find-CompiledUi 'DedicatedProfile').Current.IsEnabled -and (Find-CompiledUi 'StartMenuPlacement').Current.IsEnabled) 'Clearing Taskbar did not unlock its retained profile and Start choices.'
        Write-Host 'CHECK: Taskbar dependencies and unlock verified.'
        Set-CompiledToggle 'AlwaysOnTop' $true -ViewportId 'EditorScroll'
        Select-CompiledOption 'WindowLaunchMode' 'Full screen' -ViewportId 'EditorScroll'
        Show-CompiledEditorControl 'AlwaysOnTop'
        $topmost = [Windows.Automation.TogglePattern](Find-CompiledUi 'AlwaysOnTop').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
        Assert-CompiledUi ($topmost.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off -and -not (Find-CompiledUi 'AlwaysOnTop').Current.IsEnabled) 'Full screen did not clear and disable Always on top.'
        Select-CompiledOption 'WindowLaunchMode' 'Remember last size' -ViewportId 'EditorScroll'
        Set-CompiledToggle 'AlwaysOnTop' $true -ViewportId 'EditorScroll'
        Set-CompiledToggle 'DedicatedProfile' $false -ViewportId 'EditorScroll'
        Assert-CompiledUi ($topmost.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off -and -not (Find-CompiledUi 'AlwaysOnTop').Current.IsEnabled) 'Removing owned-profile support did not clear Always on top.'
        Set-CompiledToggle 'FreshSession' $true -ViewportId 'EditorScroll'
        Assert-CompiledUi ((Find-CompiledUi 'AlwaysOnTop').Current.IsEnabled) 'Fresh session did not enable owned-window choices.'
        Set-CompiledToggle 'AlwaysOnTop' $true -ViewportId 'EditorScroll'
        Set-CompiledToggle 'FreshSession' $false -ViewportId 'EditorScroll'
        Assert-CompiledUi ($topmost.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) 'Clearing the last owned-profile choice retained Always on top.'
        Select-CompiledOption 'WindowLaunchMode' 'Full screen' -ViewportId 'EditorScroll'
        Wait-CompiledUi { $save = Find-CompiledUi 'SaveWebsite'; $null -ne $save -and -not $save.Current.IsEnabled } 'A shared-profile full-screen draft was allowed to save.'
        Select-CompiledOption 'WindowLaunchMode' 'Remember last size' -ViewportId 'EditorScroll'
        Wait-CompiledUi { $save = Find-CompiledUi 'SaveWebsite'; $null -ne $save -and $save.Current.IsEnabled } 'Returning to a valid shared-profile window did not restore Save.'
        Write-Host 'CHECK: Owned-window and full-screen transitions verified.'
        [void][CompiledUiNative]::MoveWindow($script:windowHandle, $area.Left + 10, $area.Top + 10, [Math]::Min(700, $area.Width - 20), [Math]::Min(650, $area.Height - 20), $true)
        foreach ($controlId in @('WebsiteName', 'WebsiteAddress', 'WebsiteNotes', 'DesktopPlacement', 'StartMenuPlacement', 'TaskbarIdentity', 'DedicatedProfile', 'FreshSession', 'WindowLaunchMode', 'AlwaysOnTop', 'UseSavedIcon')) {
            Show-CompiledEditorControl $controlId
            Write-Host ('CHECK: Compact control reachable: ' + $controlId)
        }
        foreach ($commandId in @('SaveWebsite', 'NewWebsite', 'ExportKit', 'ImportKit', 'ImportFavorites', 'CheckApps', 'OpenPreferences')) { Assert-CompiledUi (-not (Find-CompiledUi $commandId).Current.IsOffscreen) ('A compact primary command is offscreen: ' + $commandId) }
        Save-CompiledCapture 'window-choices-compact'
        Assert-CompiledUi (-not [IO.File]::Exists((Join-Path $fixture 'Data\catalog.json'))) 'Changing draft window choices created website data.'
        $measurements.WindowChoiceParityVerified = $true
        $measurements.CompactAllPrimaryControlsReachable = $true
        [IO.File]::WriteAllText((Join-Path $ScreenshotDirectory 'observations.json'), ($measurements | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        [void]$process.CloseMainWindow()
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Discard' -Name) } 'The window-choice fixture lost its dirty-draft close guard.'
        Invoke-CompiledButton 'Discard' -Name
        Assert-CompiledUi ($process.WaitForExit(15000)) 'The window-choice fixture did not close.'
        Write-Host 'PASS: Actual Taskbar dependencies, owned-window transitions and complete compact editor reachability. No website, browser or pin request was created.'
        return
    }
    if ($AppearanceOnly) {
        $motionElement = Find-CompiledUi 'BackgroundMotion'
        Assert-CompiledUi ($null -ne $motionElement) 'The original motion control is missing.'
        $motion = [Windows.Automation.TogglePattern]$motionElement.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
        $sample = Save-CompiledCapture -SceneSample
        $systemLight = $false
        if ($Theme -eq 'System') {
            $systemLight = [int][Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'AppsUseLightTheme', 1) -ne 0
        }
        if ($Theme -eq 'Light' -or $systemLight -or [Windows.Forms.SystemInformation]::HighContrast) {
            Assert-CompiledUi (-not $motionElement.Current.IsEnabled) 'Motion must be disabled when the starfield is hidden.'
            $measurements.MotionAcceptance = 'Hidden by theme or high contrast; animation not requested.'
        }
        elseif (-not $motionElement.Current.IsEnabled) {
            Assert-CompiledUi ($sample.Colors -gt 32) 'The reduced-motion scene is blank.'
            $measurements.MotionAcceptance = 'Static scene verified; Windows motion or remote-session policy disables animation.'
        }
        else {
            Assert-CompiledUi ($sample.Colors -gt 32) 'The original starfield is not visible in the editor-column gap.'
            Assert-CompiledUi ($motion.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) 'Default motion preference was not preserved.'
            Wait-CompiledUi { (Save-CompiledCapture -SceneSample).Hash -ne $sample.Hash } 'The running starfield did not advance.' -Milliseconds 5000
            $motion.Toggle()
            Wait-CompiledUi {
                $settings = [IO.File]::ReadAllText((Join-Path $fixture 'Data\preferences.json')) | ConvertFrom-Json
                $motion.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off -and -not $settings.MotionEnabled
            } 'Pausing the background did not persist the preference.'
            $stable = Save-CompiledCapture -SceneSample
            Wait-CompiledUi { (Save-CompiledCapture -SceneSample).Hash -eq $stable.Hash } 'The paused frame did not settle.' -Milliseconds 2000
            $pausedClock = [Diagnostics.Stopwatch]::StartNew()
            while ($pausedClock.ElapsedMilliseconds -lt 600) {
                Assert-CompiledUi ((Save-CompiledCapture -SceneSample).Hash -eq $stable.Hash) 'The starfield continued moving while paused.'
            }
            Save-CompiledCapture 'paused'
            $motion.Toggle()
            Wait-CompiledUi {
                $settings = [IO.File]::ReadAllText((Join-Path $fixture 'Data\preferences.json')) | ConvertFrom-Json
                $motion.Current.ToggleState -eq [Windows.Automation.ToggleState]::On -and $settings.MotionEnabled
            } 'Resuming the background did not persist the preference.'
            Wait-CompiledUi { (Save-CompiledCapture -SceneSample).Hash -ne $stable.Hash } 'The starfield did not resume after being paused.' -Milliseconds 5000
            $measurements.MotionAcceptance = 'Actual animated pixels, pause stability, resume and persistence verified.'
        }
        Save-CompiledCapture 'appearance'
        Assert-CompiledUi (-not [IO.File]::Exists((Join-Path $fixture 'Data\catalog.json'))) 'Appearance changes created website data.'
        [IO.File]::WriteAllText((Join-Path $ScreenshotDirectory 'observations.json'), ($measurements | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        [void]$process.CloseMainWindow()
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Discard' -Name) } 'Closing the appearance fixture did not preserve the dirty draft guard.'
        Invoke-CompiledButton 'Discard' -Name
        Assert-CompiledUi ($process.WaitForExit(15000)) 'The appearance fixture did not close and dispose the background.'
        Write-Host ('PASS: ' + $measurements.MotionAcceptance)
        return
    }
    $elapsed.Restart()
    Invoke-CompiledButton 'SaveWebsite'
    Write-Host 'CHECK: Save invoked.'
    $catalogPath = Join-Path $fixture 'Data\catalog.json'
    Wait-CompiledUi { [IO.File]::Exists($catalogPath) -and (Test-CompiledSaveComplete) } 'The WinUI save did not complete.'
    $measurements.SaveMilliseconds = $elapsed.ElapsedMilliseconds
    $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
    $permanentId = $catalog.Apps[0].Definition.Id
    Assert-CompiledUi ($catalog.Apps[0].Definition.Window.DedicatedProfile -and $catalog.Apps[0].Definition.Window.LaunchMode -eq 'RememberLast') 'The compiled editor changed new-app defaults.'
    Set-CompiledText 'WebsiteName' 'Renamed WinUI'
    $elapsed.Restart()
    Invoke-CompiledButton 'SaveWebsite'
    Wait-CompiledUi { Test-CompiledSaveComplete } 'The compiled rename did not complete.'
    Wait-CompiledUi {
        $list = Find-CompiledUi 'WebsiteList'
        $null -ne $list -and $null -ne $list.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'Renamed WinUI')))
    } 'The saved website label is missing after rename.'
    $measurements.RenameMilliseconds = $elapsed.ElapsedMilliseconds
    $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
    Assert-CompiledUi ($catalog.Apps[0].Definition.DisplayName -ceq 'Renamed WinUI') 'The compiled rename did not persist.'
    Assert-CompiledUi ($catalog.Apps[0].Definition.Id -ceq $permanentId) 'Rename changed the permanent website ID.'
    Assert-CompiledUi ([IO.File]::Exists((Join-Path $fixture 'Desktop\Synthetic WinUI.lnk'))) 'Rename changed the owned shortcut path.'
    Save-CompiledCapture 'desktop'
    Write-Host 'CHECK: Rename and desktop capture completed.'
    foreach ($directCommand in @('ExportKit', 'ImportKit', 'ImportFavorites', 'CheckApps', 'OpenPreferences', 'NewWebsite', 'SaveWebsite')) {
        Wait-CompiledUi {
            $command = Find-CompiledUi $directCommand
            $null -ne $command -and -not $command.Current.IsOffscreen -and $command.Current.IsEnabled
        } ('The original workflow command is not directly available: ' + $directCommand)
    }
    foreach ($primaryChoice in @('WebsiteNotes', 'DedicatedProfile', 'FreshSession', 'TaskbarIdentity', 'WindowLaunchMode', 'AlwaysOnTop', 'UseSavedIcon')) {
        Show-CompiledEditorControl $primaryChoice
    }
    $measurements.DirectWorkflowControlsVerified = $true
    Set-CompiledToggle 'TaskbarIdentity' $true -ViewportId 'EditorScroll'
    Invoke-CompiledButton 'SaveWebsite'
    Wait-CompiledUi {
        $save = Find-CompiledUi 'SaveWebsite'; $status = Find-CompiledUi 'Status'
        $null -ne $save -and $save.Current.IsEnabled -and $save.Current.ItemStatus -eq 'Saved' -and $null -ne $status -and $status.Current.Name -eq 'Website saved. Pin requests are disabled in isolated test mode.'
    } 'Saving Taskbar did not report the isolated pin handoff without losing the successful save.'
    $taskbarCatalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
    Assert-CompiledUi ($taskbarCatalog.Apps[0].Definition.Window.Taskbar -and $taskbarCatalog.Apps[0].Definition.Id -ceq $permanentId) 'Taskbar save did not retain permanent identity and the selected mode.'
    Assert-CompiledUi (@(Get-Process -Name fresh-session -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($fixture + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) 'The isolated Taskbar save launched a real helper.'
    Set-CompiledToggle 'TaskbarIdentity' $false -ViewportId 'EditorScroll'
    Invoke-CompiledButton 'SaveWebsite'
    Wait-CompiledUi { Test-CompiledSaveComplete } 'Clearing Taskbar did not return a normal successful save.'
    $measurements.TaskbarSaveIsolationAndOutcomeVerified = $true
    $beforeIconChoice = [Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath))
    Invoke-CompiledButton 'Automatic icon' -Name
    Wait-CompiledUi {
        $save = Find-CompiledUi 'SaveWebsite'; $status = Find-CompiledUi 'Status'
        $null -ne $save -and $save.Current.ItemStatus -eq 'Unsaved changes' -and $null -ne $status -and $status.Current.Name -eq 'Automatic icon selected.'
    } 'Choosing an automatic replacement did not update the draft.'
    Show-CompiledEditorControl 'UseSavedIcon'
    Invoke-CompiledButton 'UseSavedIcon'
    Wait-CompiledUi {
        $save = Find-CompiledUi 'SaveWebsite'; $status = Find-CompiledUi 'Status'
        $null -ne $save -and $save.Current.IsEnabled -and $save.Current.ItemStatus -eq 'Saved' -and $null -ne $status -and $status.Current.Name -like 'Saved icon restored*'
    } 'Restoring the saved icon left a false unsaved-change state.'
    Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath)) -ceq $beforeIconChoice) 'Restoring the saved icon wrote the catalog.'
    Assert-CompiledUi ((Get-CompiledText 'WebsiteName') -ceq 'Renamed WinUI') 'Restoring the saved icon changed the website name.'
    $measurements.SavedIconRestorationVerified = $true
    $unownedId = 'b' * 64
    $retainedData = Join-Path $fixture ('Data\Apps\' + $unownedId + '\AppProfile\Cookies')
    [void][IO.Directory]::CreateDirectory((Split-Path $retainedData -Parent))
    [IO.File]::WriteAllText($retainedData, 'Synthetic unowned browser data')
    Invoke-CompiledButton 'CheckApps'
    Wait-CompiledUi { $item = Find-CompiledUi ('CheckWebsite-' + $permanentId); $null -ne $item -and $item.Current.ItemStatus -eq 'Healthy' } 'Check apps did not report a verified healthy native website.'
    Assert-CompiledUi (-not (Find-CompiledUi ('CheckWebsite-' + $permanentId)).Current.IsEnabled) 'A healthy website was selected for unnecessary repair.'
    Wait-CompiledUi { $item = Find-CompiledUi ('CheckWebsite-' + $unownedId); $null -ne $item -and $item.Current.ItemStatus -eq 'Conflict' } 'Check apps silently omitted unowned retained data.'
    Assert-CompiledUi (-not (Find-CompiledUi ('CheckWebsite-' + $unownedId)).Current.IsEnabled) 'Check apps offered to repair or adopt unowned data.'
    Invoke-CompiledButton 'Close' -Name
    Wait-CompiledUi { $null -eq (Find-CompiledUi 'ActiveToolDialog') -and (Find-CompiledUi 'CheckApps').Current.IsEnabled } 'Closing healthy inspection did not restore the editor.'
    $repairCatalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
    $missingShortcut = Join-Path $fixture ('Desktop\' + $repairCatalog.Apps[0].ShortcutName + '.lnk')
    Assert-CompiledUi ([IO.File]::Exists($missingShortcut)) 'The repair fixture needs an owned Desktop shortcut.'
    [IO.File]::Delete($missingShortcut)
    foreach ($staleInspection in @($true, $false)) {
        Invoke-CompiledButton 'CheckApps'
        $checkedWebsite = @{ Item = $null }
        Wait-CompiledUi {
            $checkList = Find-CompiledUi 'CheckWebsiteList'
            if ($null -eq $checkList) { return $false }
            $checkedWebsite.Item = Find-CompiledUi ('CheckWebsite-' + $permanentId)
            return $null -ne $checkedWebsite.Item -and $checkedWebsite.Item.Current.ItemStatus -eq 'Repairable' -and $checkedWebsite.Item.Current.IsEnabled
        } 'Check apps did not report the synthetic website ownership state.'
        ([Windows.Automation.SelectionItemPattern]$checkedWebsite.Item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        if ($staleInspection) { [IO.File]::AppendAllText($catalogPath, "`n") }
        $beforeRepair = [Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath))
        Invoke-CompiledButton 'Repair selected' -Name
        $repairMessage = if ($staleInspection) { "Renamed WinUI`nNot repaired: The catalog changed after preview. Refresh before applying." } else { "Renamed WinUI`nRepaired. Browser data and window choices retained." }
        Wait-CompiledUi { $null -ne (Find-CompiledUi $repairMessage -Name) } 'Check apps did not enforce its inspected snapshot or return the selected repair result.'
        if ($staleInspection) { Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath)) -ceq $beforeRepair) 'Stale inspection repair changed catalog bytes.' }
        Save-CompiledCapture $(if ($staleInspection) { 'check-apps-stale' } else { 'check-apps' })
        Invoke-CompiledButton 'Close' -Name
        Wait-CompiledUi {
            $save = Find-CompiledUi 'SaveWebsite'; $status = Find-CompiledUi 'Status'
            $null -ne $save -and $save.Current.IsEnabled -and $null -ne $status -and $status.Current.Name -like 'Selected checks completed*'
        } 'Check apps did not return to the ready editor.'
    }
    $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
    Assert-CompiledUi ([IO.File]::Exists($missingShortcut)) 'Repair did not recreate the missing owned shortcut.'
    Assert-CompiledUi ([IO.File]::ReadAllText($retainedData) -ceq 'Synthetic unowned browser data') 'Repair changed retained data without ownership.'
    Assert-CompiledUi ($catalog.Apps[0].Definition.Id -ceq $permanentId -and $catalog.Apps[0].Definition.Window.DedicatedProfile -and $catalog.Apps[0].Definition.Window.LaunchMode -eq 'RememberLast') 'Repair changed identity or window settings.'
    $measurements.CheckAndRepairVerified = $true
    $measurements.StaleInspectionRepairRejected = $true
    $advanced = Find-CompiledUi 'AdvancedSettings'
    Assert-CompiledUi ($null -ne $advanced) 'Profile details are missing from UI Automation.'
    $expand = [Windows.Automation.ExpandCollapsePattern]$advanced.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
    Assert-CompiledUi ($expand.Current.ExpandCollapseState -eq [Windows.Automation.ExpandCollapseState]::Collapsed) 'Primary choices required opening the profile-details expander.'
    $beforeProfileChoice = [Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath))
    Show-CompiledEditorControl 'DedicatedProfile'
    $dedicated = [Windows.Automation.TogglePattern](Find-CompiledUi 'DedicatedProfile').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    $dedicated.Toggle()
    Invoke-CompiledButton 'SaveWebsite'
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Change browsing mode?' -Name) } 'Changing a saved browsing mode did not require confirmation.'
    Invoke-CompiledButton 'Cancel' -Name
    Wait-CompiledUi { $save = Find-CompiledUi 'SaveWebsite'; $null -ne $save -and $save.Current.IsEnabled } 'Cancelling browsing-mode confirmation left the draft unavailable.'
    Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath)) -ceq $beforeProfileChoice) 'Cancelling browsing-mode confirmation changed stored bytes.'
    Assert-CompiledUi ($dedicated.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) 'Cancelling browsing-mode confirmation discarded the chosen draft mode.'
    $dedicated.Toggle()
    $measurements.BrowsingModeConfirmationVerified = $true
    $scrollElement = Find-CompiledUi 'EditorScroll'
    $scroll = [Windows.Automation.ScrollPattern]$scrollElement.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern)
    Show-CompiledEditorControl 'WebsiteNotes'
    Set-CompiledText 'WebsiteNotes' 'Synthetic draft notes retained through a failed save.'
    $beforeFailure = [Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath))
    $writerLock = [IO.File]::Open((Join-Path $fixture 'Data\.writer.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Invoke-CompiledButton 'SaveWebsite'
        Wait-CompiledUi {
            $status = Find-CompiledUi 'Status'; $save = Find-CompiledUi 'SaveWebsite'
            $null -ne $status -and $null -ne $save -and $status.Current.Name -like '*All edits are still here*' -and $save.Current.IsEnabled
        } 'The failed save did not return a retryable draft.'
        Assert-CompiledUi ((Get-CompiledText 'WebsiteNotes') -ceq 'Synthetic draft notes retained through a failed save.') 'The failed save lost Notes.'
        Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath)) -ceq $beforeFailure) 'The failed save changed catalog bytes.'
        Invoke-CompiledButton 'NewWebsite'
        Wait-CompiledUi { $null -ne (Find-CompiledUi 'Cancel' -Name) } 'Failed draft navigation omitted Save/Discard/Cancel.'
        Invoke-CompiledButton 'Cancel' -Name
        Wait-CompiledUi {
            $save = Find-CompiledUi 'SaveWebsite'
            $null -ne $save -and $save.Current.IsEnabled -and (Get-CompiledText 'WebsiteName') -ceq 'Renamed WinUI'
        } 'Cancelling navigation did not return the failed draft for retry.'
    }
    finally { $writerLock.Dispose() }
    Invoke-CompiledButton 'SaveWebsite'
    Wait-CompiledUi { Test-CompiledSaveComplete } 'Retry did not save the preserved draft.'
    $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
    Assert-CompiledUi ($catalog.Apps[0].Definition.Notes -ceq 'Synthetic draft notes retained through a failed save.' -and $catalog.Apps[0].Definition.Id -ceq $permanentId) 'Retry lost notes or permanent identity.'
    Show-CompiledEditorControl 'WebsiteNotes'
    Save-CompiledCapture 'advanced'
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, 0) }
    $measurements.AdvancedNotesReachable = $true
    $measurements.FailedSaveRetryVerified = $true
    Write-Host 'CHECK: Direct workflow controls, notes reachability, failed-save retention and retry completed.'
    Invoke-CompiledButton 'ExportKit'
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'ExportWebsiteList') } 'The export dialog did not open.'
    $exportList = Find-CompiledUi 'ExportWebsiteList'
    Wait-CompiledUi {
        $null -ne $exportList.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'Renamed WinUI')))
    } 'The export dialog does not show the saved website name.'
    Assert-CompiledUi ($null -ne (Find-CompiledUi 'ExportKitNotes')) 'The export dialog is missing kit-level notes.'
    Show-CompiledEditorControl 'ExportKitNotes' -ViewportId 'ToolDialogScroll'
    Set-CompiledText 'ExportKitNotes' 'Synthetic kit-level notes retained after invalid export.'
    Set-CompiledText 'ExportKitName' ''
    Invoke-CompiledButton 'Export' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Enter a kit name.' -Name) } 'An invalid export name did not retain the dialog with a validation error.'
    Assert-CompiledUi ((Get-CompiledText 'ExportKitNotes') -ceq 'Synthetic kit-level notes retained after invalid export.') 'Validation lost the kit notes.'
    Set-CompiledText 'ExportKitName' 'Synthetic export'
    $exportItem = $exportList.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'Renamed WinUI')))
    $exportSelection = [Windows.Automation.SelectionItemPattern]$exportItem.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
    $exportSelection.RemoveFromSelection()
    Invoke-CompiledButton 'Export' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Select at least one website.' -Name) } 'An empty export selection did not keep the draft open.'
    Assert-CompiledUi ((Get-CompiledText 'ExportKitName') -ceq 'Synthetic export' -and (Get-CompiledText 'ExportKitNotes') -ceq 'Synthetic kit-level notes retained after invalid export.') 'Empty-selection validation lost the export draft.'
    $exportSelection.AddToSelection()
    Show-CompiledEditorControl 'ExportKitNotes' -ViewportId 'ToolDialogScroll'
    $measurements.ExportValidationKeepsDraft = $true
    Save-CompiledCapture 'export'
    Set-CompiledToggle 'ExportKitEncrypted' $true
    Invoke-CompiledButton 'Export' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'KitPassword') } 'Encrypted export did not ask for a passphrase.'
    Assert-CompiledUi ((Find-CompiledUi 'KitPassword').Current.IsPassword) 'The kit passphrase field is not a protected password control.'
    Invoke-CompiledButton 'Encrypt' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Choose a passphrase of 12 to 1024 characters and confirm it.' -Name) } 'Empty encryption input did not show its validation error.'
    Assert-CompiledUi ($null -ne (Find-CompiledUi 'KitPassword')) 'Passphrase validation dismissed the password dialog instead of allowing retry.'
    Set-CompiledText 'KitPassword' 'Synthetic passphrase for this fixture'
    Set-CompiledText 'KitPasswordConfirmation' 'Different synthetic fixture passphrase'
    Invoke-CompiledButton 'Encrypt' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'The passphrases do not match.' -Name) } 'Passphrase confirmation mismatch did not allow retry.'
    Assert-CompiledUi ($null -ne (Find-CompiledUi 'KitPassword')) 'A mismatched confirmation dismissed the password dialog.'
    Save-CompiledCapture 'encrypted-validation'
    Invoke-CompiledButton 'Cancel' -Name
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'ExportKitNotes') } 'Cancelling encryption lost the export draft.'
    Assert-CompiledUi ((Get-CompiledText 'ExportKitName') -ceq 'Synthetic export' -and (Get-CompiledText 'ExportKitNotes') -ceq 'Synthetic kit-level notes retained after invalid export.') 'Cancelling encryption lost the kit name or notes.'
    $retainedExportSelection = [Windows.Automation.SelectionPattern](Find-CompiledUi 'ExportWebsiteList').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)
    Assert-CompiledUi ($retainedExportSelection.Current.GetSelection().Count -eq 1) 'Cancelling encryption lost the export website selection.'
    $measurements.EncryptedDialogValidationAndDraftRetentionVerified = $true
    if ($KitFiles) { Test-CompiledProtectedKitFiles -CatalogPath $catalogPath }
    else { Invoke-CompiledButton 'Cancel' -Name }
    Wait-CompiledUi {
        $save = Find-CompiledUi 'SaveWebsite'
        $null -eq (Find-CompiledUi 'ExportWebsiteList') -and $null -ne $save -and $save.Current.IsEnabled
    } 'Export cancellation did not return to the ready editor.'
    $measurements.ExportSelectionVisible = $true
    Invoke-CompiledButton 'OpenPreferences'
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'PreferenceTextSize') } 'Preferences did not expose its text-size choice.'
    $preferenceProfile = Find-CompiledUi 'PreferenceProfile'
    Assert-CompiledUi ($null -ne $preferenceProfile) 'The Preferences profile editor was not exposed.'
    $profileLabel = Find-CompiledUi 'Version 2.0.0-preview.1' -Name
    Assert-CompiledUi ($null -ne $profileLabel) 'The Settings version text was not exposed.'
    $preferenceText = [Windows.Automation.TextPattern]$profileLabel.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
    Wait-CompiledUi {
        $fontSize = $preferenceText.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::FontSizeAttribute)
        $fontSize -is [double] -and $fontSize -ge $TextSize * 0.74
    } 'Preferences did not apply the chosen text size after layout.'
    $preferenceFontSize = $preferenceText.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::FontSizeAttribute)
    Assert-CompiledUi ($preferenceFontSize -is [double] -and $preferenceFontSize -ge $TextSize * 0.74) ('Preferences did not apply the chosen text size. Observed points: ' + $preferenceFontSize)
    $measurements.ObservedPreferencesFontSize = $preferenceFontSize
    Show-CompiledEditorControl 'PreferenceTextSize' -ViewportId 'ToolDialogScroll'
    Save-CompiledCapture 'preferences'
    Invoke-CompiledButton 'Cancel' -Name
    Wait-CompiledUi {
        $save = Find-CompiledUi 'SaveWebsite'
        $null -eq (Find-CompiledUi 'PreferenceTextSize') -and $null -ne $save -and $save.Current.IsEnabled
    } 'Preferences cancellation did not return to the ready editor.'
    $measurements.PreferencesReachable = $true
    $beforeAddressChoice = [Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath))
    Set-CompiledText 'WebsiteAddress' 'http://example.com/'
    Wait-CompiledUi {
        $save = Find-CompiledUi 'SaveWebsite'
        $null -ne $save -and $save.Current.IsEnabled -and $save.Current.ItemStatus -eq 'Unsaved changes'
    } 'The HTTP address edit did not reach the draft.'
    Invoke-CompiledButton 'SaveWebsite'
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Save HTTP website?' -Name) } 'Saving HTTP did not require explicit confirmation.'
    $httpMessage = Find-CompiledUi ("HTTP is unencrypted. Do not use it for passwords or sensitive information.`n`nhttp://example.com/") -Name
    Assert-CompiledUi ($null -ne $httpMessage) 'The HTTP confirmation text was not exposed.'
    $httpText = [Windows.Automation.TextPattern]$httpMessage.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
    Wait-CompiledUi {
        $fontSize = $httpText.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::FontSizeAttribute)
        $fontSize -is [double] -and $fontSize -ge $TextSize * 0.74
    } 'The HTTP confirmation did not apply the chosen text size after layout.'
    $httpFontSize = $httpText.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::FontSizeAttribute)
    Assert-CompiledUi ($httpFontSize -is [double] -and $httpFontSize -ge $TextSize * 0.74) ('The HTTP confirmation did not apply the chosen text size. Observed points: ' + $httpFontSize)
    $measurements.ObservedConfirmationFontSize = $httpFontSize
    Save-CompiledCapture 'http-confirmation'
    Invoke-CompiledButton 'Cancel' -Name
    Wait-CompiledUi { $save = Find-CompiledUi 'SaveWebsite'; $null -ne $save -and $save.Current.IsEnabled } 'Cancelling HTTP confirmation left Save disabled.'
    Assert-CompiledUi ((Get-CompiledText 'WebsiteAddress') -ceq 'http://example.com/') 'Cancelling HTTP confirmation changed the draft address.'
    Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath)) -ceq $beforeAddressChoice) 'Cancelling HTTP confirmation changed stored bytes.'
    Set-CompiledText 'WebsiteAddress' 'example.com/synthetic-probe'
    Invoke-CompiledButton 'SaveWebsite'
    Wait-CompiledUi {
        $status = Find-CompiledUi 'Status'; $save = Find-CompiledUi 'SaveWebsite'
        $null -ne $status -and $null -ne $save -and $status.Current.Name -like '*resolution is disabled in isolated test mode*' -and $save.Current.IsEnabled
    } 'An isolated scheme-less save did not fail closed before network access.'
    Assert-CompiledUi ((Get-CompiledText 'WebsiteAddress') -ceq 'example.com/synthetic-probe') 'The failed address probe lost the raw draft.'
    Assert-CompiledUi ([Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath)) -ceq $beforeAddressChoice) 'A blocked isolated address probe changed stored bytes.'
    Set-CompiledText 'WebsiteAddress' 'https://example.com/'
    $measurements.AddressConfirmationAndIsolationVerified = $true
    Set-CompiledText 'WebsiteName' 'Unsaved name'
    Invoke-CompiledButton 'NewWebsite'
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Cancel' -Name) } 'The unsaved-edit dialog was not shown.'
    Invoke-CompiledButton 'Cancel' -Name
    Wait-CompiledUi {
        $save = Find-CompiledUi 'SaveWebsite'
        $null -ne $save -and $save.Current.IsEnabled -and (Get-CompiledText 'WebsiteName') -eq 'Unsaved name'
    } 'Cancel did not return the retained draft to the editor.'
    Invoke-CompiledButton 'NewWebsite'
    Wait-CompiledUi { $null -ne (Find-CompiledUi 'Discard' -Name) } 'The discard option was not shown.'
    Invoke-CompiledButton 'Discard' -Name
    Wait-CompiledUi { (Get-CompiledText 'WebsiteName') -eq '' } 'Discard did not enter a new draft.'
    Wait-CompiledUi { $status = Find-CompiledUi 'Status'; $null -ne $status -and $status.Current.Name -eq 'New website.' } 'Successful navigation left an obsolete error in the status region.'
    [void][CompiledUiNative]::MoveWindow($script:windowHandle, $area.Left + 10, $area.Top + 10, [Math]::Min(700, $area.Width - 20), [Math]::Min(650, $area.Height - 20), $true)
    Wait-CompiledUi { $name = Find-CompiledUi 'WebsiteName'; $null -ne $name -and -not $name.Current.IsOffscreen } 'The compact editor is not reachable.'
    Save-CompiledCapture 'compact'
    $process.Refresh()
    $measurements.WorkingSetBytes = $process.WorkingSet64
    $measurements.PeakWorkingSetBytes = $process.PeakWorkingSet64
    [IO.File]::WriteAllText((Join-Path $ScreenshotDirectory 'observations.json'), ($measurements | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Write-Host 'PASS: Actual WinUI startup, text size, defaults, save, stable rename, browsing/HTTP approval, advanced scrolling, failed-save retry, export/preferences, Cancel/Discard and compact layout. No browser was launched.'
    [void]$process.CloseMainWindow()
    Assert-CompiledUi ($process.WaitForExit(15000)) 'The clean compiled manager did not close.'
}
catch {
    if ($null -ne $script:uiRoot) {
        try {
            Write-Host ('STATE: name=' + (Get-CompiledText 'WebsiteName') + '; address=' + (Get-CompiledText 'WebsiteAddress') + '; status=' + (Find-CompiledUi 'Status').Current.Name + '; saveEnabled=' + (Find-CompiledUi 'SaveWebsite').Current.IsEnabled)
            Save-CompiledCapture 'failure'
        }
        catch { Write-Host 'The native provider could not return failure-state diagnostics.' }
    }
    throw
}
finally {
    $script:uiRoot = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(15000) }
        $process.Dispose()
    }
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}