#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.EditorTests.' + [Guid]::NewGuid().ToString('N'))
$context = [pscustomobject]@{ Root = (Join-Path $testRoot 'Data'); Desktop = (Join-Path $testRoot 'Desktop'); Programs = (Join-Path $testRoot 'Programs') }
$script:DiscardApproved = $false
$script:DiscardRequests = 0
$form = $null

function Assert-Editor {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-EditorMnemonics {
    param($Control)
    if ($Control.Visible -and $Control.Enabled -and
        ($Control -is [Windows.Forms.ButtonBase] -or $Control -is [Windows.Forms.Label]) -and
        $Control.UseMnemonic -and $Control.Text -match '(?<!&)&([^&])') {
        [pscustomobject]@{ Key = $Matches[1].ToUpperInvariant(); Text = $Control.Text }
    }
    foreach ($child in $Control.Controls) { Get-EditorMnemonics $child }
}

function Assert-EditorMnemonics {
    param($Form)
    $duplicates = @(Get-EditorMnemonics $Form | Group-Object Key | Where-Object { $_.Count -gt 1 })
    Assert-Editor ($duplicates.Count -eq 0) ('Visible editor mnemonics must be unique: ' + (($duplicates | ForEach-Object { $_.Group.Text -join ', ' }) -join '; '))
}

function Confirm-EeaChange {
    param($Form, [string]$Message, [string]$Title)
    if ($Title -ceq 'Discard unsaved changes?') { $script:DiscardRequests++ }
    return $script:DiscardApproved
}

function Show-EeaFormError {
    param($Form, $Failure)
    throw $Failure
}

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public sealed class EeaAccessibilityProbe : IDisposable
{
    private delegate void Callback(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time);
    private readonly Callback callback;
    private readonly IntPtr hook, status, spinner;
    public int StatusEvents, StatusValueEvents, BusyEvents, DescriptionEvents;
    public EeaAccessibilityProbe(IntPtr status, IntPtr spinner)
    {
        this.status = status; this.spinner = spinner;
        callback = Changed;
        hook = SetWinEventHook(0x800a, 0x800e, IntPtr.Zero, callback, (uint)Process.GetCurrentProcess().Id, 0, 0);
        if (hook == IntPtr.Zero) throw new InvalidOperationException("Accessibility observation could not start.");
    }
    private void Changed(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time)
    {
        if (objectId != -4 || childId != 0) return;
        if (window == status && eventType == 0x800c) StatusEvents++;
        if (window == status && eventType == 0x800e) StatusValueEvents++;
        if (window == spinner && eventType == 0x800a) BusyEvents++;
        if (window == spinner && eventType == 0x800d) DescriptionEvents++;
    }
    public void Dispose() { UnhookWinEvent(hook); }
    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint minimum, uint maximum, IntPtr module, Callback callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
}
'@

try {
    $null = Install-EeaApp -AppName 'First app' -Website 'https://example.com/' -Context $context -Confirm:$false
    $null = Install-EeaApp -AppName 'Shared app' -Website 'https://example.org/' -DedicatedProfile $false -LaunchMode Maximized -Context $context -Confirm:$false
    $form = New-EeaSetupForm -Context $context
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object Drawing.Point(-10000, -10000)
    $form.ShowInTaskbar = $false
    $form.Show()
    $ui = $form.Tag
    Assert-EditorMnemonics $form
    Assert-Editor ($ui.StatusLabel.AccessibilityObject.Role -eq [Windows.Forms.AccessibleRole]::StatusBar) 'Status feedback must expose a native status role.'
    Assert-Editor ($ui.ActivitySpinner.AccessibilityObject.Role -eq [Windows.Forms.AccessibleRole]::ProgressBar) 'Activity must expose its native accessibility object before observing changes.'
    $probe = New-Object EeaAccessibilityProbe($ui.StatusLabel.Handle, $ui.ActivitySpinner.Handle)
    try {
        $ui.StatusLabel.Text = 'Synthetic status notification'
        $ui.ActivitySpinner.IsBusy = $true
        Assert-Editor (($ui.ActivitySpinner.AccessibilityObject.State -band [Windows.Forms.AccessibleStates]::Busy) -ne 0) 'Website activity must expose its actual busy state.'
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        while (($probe.StatusEvents -eq 0 -or $probe.StatusValueEvents -eq 0 -or $probe.BusyEvents -eq 0 -or $probe.DescriptionEvents -eq 0) -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents() }
        Assert-Editor ($probe.StatusEvents -gt 0 -and $probe.StatusValueEvents -gt 0 -and $probe.BusyEvents -gt 0 -and $probe.DescriptionEvents -gt 0) ('Status text and activity changes must emit native client accessibility events. Name: {0}; Value: {1}; Busy: {2}; Description: {3}.' -f $probe.StatusEvents, $probe.StatusValueEvents, $probe.BusyEvents, $probe.DescriptionEvents)
        $busyEvents = $probe.BusyEvents
        $descriptionEvents = $probe.DescriptionEvents
        $ui.ActivitySpinner.IsBusy = $false
        Assert-Editor (($ui.ActivitySpinner.AccessibilityObject.State -band [Windows.Forms.AccessibleStates]::Busy) -eq 0) 'Idle activity must clear the accessible busy state.'
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        while (($probe.BusyEvents -eq $busyEvents -or $probe.DescriptionEvents -eq $descriptionEvents) -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents() }
        Assert-Editor ($probe.BusyEvents -gt $busyEvents -and $probe.DescriptionEvents -gt $descriptionEvents) 'Returning to idle must notify accessibility clients of both state and description changes.'
    }
    finally { $probe.Dispose() }
    foreach ($pointSize in @(18, 12)) {
        $oldFont = $form.Font
        $settings = New-EeaSettings
        $settings.TextSize = $pointSize
        Set-EeaFormPreferences -Form $form -Settings $settings
        $disposed = $false
        try { $null = $oldFont.GetHeight([single]96) } catch [ArgumentException] { $disposed = $true }
        Assert-Editor ($disposed -and $form.Font.GetHeight([single]96) -gt 0 -and [object]::ReferenceEquals($ui.SettingsMenu.Font, $form.Font)) 'Replacing an owned form font must dispose the old font after updating its consumers.'
    }
    $form.ActiveControl = $ui.UrlInput
    $compactWorkArea = New-Object Drawing.Rectangle(-10000, -10000, 900, 650)
    Update-EeaSetupDisplay -Form $form -WorkingArea $compactWorkArea
    Assert-Editor ($compactWorkArea.Contains($form.Bounds) -and $form.ActiveControl -eq $ui.UrlInput) 'A working-area transition must keep setup visible without moving keyboard focus.'
    $stableBounds = $form.Bounds
    Update-EeaSetupDisplay -Form $form -WorkingArea $compactWorkArea
    Assert-Editor ($form.Bounds -eq $stableBounds) 'Repeated events on the same display must not cause layout growth or movement.'
    Assert-Editor ($ui.DedicatedProfileCheck.Checked -and $ui.LaunchModeCombo.SelectedIndex -eq 0 -and -not $ui.AlwaysOnTopCheck.Checked) 'New apps must default to a dedicated profile, remembered bounds, and ordinary z-order.'
    $ui.NameInput.Text = 'Unsaved draft'
    $ui.UrlInput.Text = 'https://example.net/'
    $ui.AlwaysOnTopCheck.Checked = $true
    $ui.NewButton.PerformClick()
    Assert-Editor ($ui.NameInput.Text -ceq 'Unsaved draft' -and $ui.AlwaysOnTopCheck.Checked -and $script:DiscardRequests -eq 1) 'Declining New must preserve all unsaved website and window choices.'
    $ui.AppList.SelectedIndex = 0
    Assert-Editor ($ui.AppList.SelectedIndex -eq -1 -and $ui.NameInput.Text -ceq 'Unsaved draft' -and $script:DiscardRequests -eq 2) 'Declining selection must restore the previous selection without altering the draft.'
    foreach ($button in @($ui.ImportButton, $ui.FavoritesButton, $ui.CheckButton)) { $button.PerformClick() }
    Assert-Editor ($script:DiscardRequests -eq 5 -and $ui.NameInput.Text -ceq 'Unsaved draft') 'Tools that refresh the app list must obtain discard consent before opening dialogs.'
    $form.Close()
    Assert-Editor ($form.Visible -and -not $form.IsDisposed -and $ui.NameInput.Text -ceq 'Unsaved draft') 'Declining Close must keep the setup window and draft alive.'
    $script:DiscardApproved = $true
    $ui.NewButton.PerformClick()
    Assert-Editor ($ui.NameInput.Text -ceq '' -and -not $ui.AlwaysOnTopCheck.Checked -and $ui.DedicatedProfileCheck.Checked) 'Approved New must reset all local window choices.'
    $script:DiscardApproved = $false
    $before = $script:DiscardRequests
    $ui.AppList.SelectedIndex = 1
    Assert-Editor ($script:DiscardRequests -eq $before -and -not $ui.DedicatedProfileCheck.Checked -and $ui.LaunchModeCombo.SelectedIndex -eq 1 -and -not $ui.AlwaysOnTopCheck.Enabled) 'Selecting a clean shared-profile app must preserve its route without prompting or enabling unsupported topmost behavior.'
    $ui.AppList.SelectedIndex = 0
    Assert-EditorMnemonics $form
    $ui.AlwaysOnTopCheck.Checked = $true
    $ui.SaveButton.PerformClick()
    $saved = Read-EeaManifest $context 'First app'
    Assert-Editor ((Get-EeaStateAlwaysOnTop $saved) -and (Get-EeaStateLaunchMode $saved) -ceq 'RememberLast' -and (Get-EeaChecks -AppNames 'First app' -Context $context).Status -ceq 'Healthy') 'Saving Always on top must generate a healthy owned launcher.'
    $before = $script:DiscardRequests
    $ui.AppList.SelectedIndex = 1
    $ui.AppList.SelectedIndex = 0
    Assert-Editor ($script:DiscardRequests -eq $before -and $ui.AlwaysOnTopCheck.Checked) 'A successful save must establish a clean baseline and reload the saved topmost choice.'
    $ui.LaunchModeCombo.SelectedIndex = 2
    Assert-Editor (-not $ui.AlwaysOnTopCheck.Enabled -and -not $ui.AlwaysOnTopCheck.Checked) 'Full screen must disable and clear unsupported Always on top.'
    $ui.AppList.SelectedIndex = 1
    Assert-Editor ($ui.AppList.SelectedIndex -eq 0 -and $ui.LaunchModeCombo.SelectedIndex -eq 2) 'Changing only window mode must count as an unsaved edit.'
    $script:DiscardApproved = $true
    $ui.AppList.SelectedIndex = 1
    $script:DiscardApproved = $false
    $ui.DedicatedProfileCheck.Checked = $true
    $ui.NewButton.PerformClick()
    Assert-Editor ($ui.NameInput.Text -ceq 'Shared app' -and $ui.DedicatedProfileCheck.Checked) 'Changing only profile mode must count as an unsaved edit.'
    $script:DiscardApproved = $true
    $ui.NewButton.PerformClick()
    $ui.AppList.SelectedIndex = 0
    $script:DiscardApproved = $false
    $iconPath = Join-Path $testRoot 'draft.ico'
    New-EeaIcon -Path $iconPath -AppName 'Draft icon'
    Set-EeaEditorIcon -Form $form -IconData ([IO.File]::ReadAllBytes($iconPath))
    $ui.NewButton.PerformClick()
    Assert-Editor ($null -ne $ui.WebsiteIconData -and $ui.NameInput.Text -ceq 'First app') 'An icon-only edit must not be silently discarded.'
    $script:DiscardApproved = $true
    $form.Close()
    Assert-Editor $form.IsDisposed 'Approved Close must release the setup window.'
    Write-Host ('PASS: Draft protection for New, selection, tools and Close; profile/window/topmost/icon changes; clean saved baselines on PowerShell ' + $PSVersionTable.PSVersion + '.')
}
finally {
    if ($null -ne $form) { $form.Dispose() }
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}