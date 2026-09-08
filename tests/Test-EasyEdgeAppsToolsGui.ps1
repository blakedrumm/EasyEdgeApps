#requires -Version 5.1

[CmdletBinding()]
param([string]$ScreenshotDirectory, [int]$MaximumWindowWidth = 1024, [int]$MaximumWindowHeight = 768)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.ToolsGuiTests.' + [Guid]::NewGuid().ToString('N'))
$forms = New-Object 'Collections.Generic.List[object]'
$script:ApproveChange = $false
$script:KitFileChoice = $null
$script:PathRequests = 0
$script:LastDialogError = ''
$script:NextUpdateRequest = $null
$script:UpdateRequestsStarted = 0

function New-ToolUpdateRequest {
    param([string]$Version = '1.4.0', [switch]$Fail)
    $release = [pscustomobject]@{ tag_name = ('v' + $Version); html_url = ('https://github.com/blakedrumm/EasyEdgeApps/releases/tag/v' + $Version); draft = $false; prerelease = $false }
    $pipeline = [pscustomobject]@{ Info = (ConvertTo-EeaUpdateInfo $release); Fail = [bool]$Fail; Disposed = $false }
    $pipeline | Add-Member ScriptMethod EndInvoke { param($Pending) if ($this.Fail) { throw 'Synthetic update check failure.' }; return $this.Info }
    $pipeline | Add-Member ScriptMethod Stop { }
    $pipeline | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    return [pscustomobject]@{ PowerShell = $pipeline; AsyncResult = [pscustomobject]@{ IsCompleted = $false }; Cancellation = (New-Object Threading.CancellationTokenSource) }
}

function Start-EeaUpdateRequest {
    Assert-ToolGui ($null -ne $script:NextUpdateRequest) 'GUI tests must not use the live update service.'
    $script:UpdateRequestsStarted++
    return $script:NextUpdateRequest
}

function Assert-ToolGui {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Confirm-EeaChange {
    param($Form, [string]$Message, [string]$Title)
    return $script:ApproveChange
}

function Show-EeaFormError {
    param($Form, $Failure)
    $script:LastDialogError = $Failure.Exception.Message
    $Form.Tag.StatusLabel.Text = 'FAILED: ' + $script:LastDialogError
}

function Select-EeaKitPath {
    param($Form, [switch]$Save, [string]$FileName)
    $script:PathRequests++
    return $script:KitFileChoice
}

function New-ToolTestContext {
    param([string]$Label)
    return [pscustomobject]@{ Root = (Join-Path $testRoot "$Label\Data"); Desktop = (Join-Path $testRoot "$Label\Desktop"); Programs = (Join-Path $testRoot "$Label\Programs") }
}

function Assert-ToolTextKeys {
    param($Control)
    foreach ($child in $Control.Controls) {
        if ($child -is [Windows.Forms.TextBox]) {
            $originalText = $child.Text
            $originalStart = $child.SelectionStart
            $originalLength = $child.SelectionLength
            $originalMask = $child.UseSystemPasswordChar
            try {
                $child.Text = 'First second'
                $child.Select($child.TextLength, 0)
                $keyEvent = New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Back)
                $onKeyDown = [Windows.Forms.Control].GetMethod('OnKeyDown', [Reflection.BindingFlags]'Instance, NonPublic')
                [void]$onKeyDown.Invoke($child, [object[]]@($keyEvent.PSObject.BaseObject))
                $expected = if ($child.ReadOnly) { 'First second' } else { 'First ' }
                Assert-ToolGui ($keyEvent.SuppressKeyPress -and $child.Text -ceq $expected -and $child.UseSystemPasswordChar -eq $originalMask) 'Dialog textboxes must handle Ctrl+Backspace without inserting control characters, editing read-only details, or changing password masking.'
            }
            finally {
                $child.Text = $originalText
                $child.Select($originalStart, $originalLength)
            }
        }
        elseif ($child -isnot [Windows.Forms.DataGridView]) { Assert-ToolTextKeys $child }
    }
}

function Show-ToolTestForm {
    param($Form)
    $forms.Add($Form)
    Assert-ToolGui ((-not [Windows.Forms.VisualStyles.VisualStyleInformation]::IsEnabledByUser) -or [Windows.Forms.Application]::RenderWithVisualStyles) 'Dialogs must enable Windows visual styles when the active theme supports them.'
    Assert-ToolGui ($null -ne $Form.Icon -and $Form.Icon.Width -eq 64) 'Every application dialog must use the embedded logo icon.'
    $Form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $Form.Location = New-Object Drawing.Point(-10000, -10000)
    $Form.ShowInTaskbar = $false
    $Form.Show()
    [Windows.Forms.Application]::DoEvents()
    Assert-ToolTextKeys $Form
}

function Assert-ToolControlLayout {
    param($Control)
    foreach ($child in $Control.Controls) {
        if (-not $child.Visible) { continue }
        Assert-ToolGui ($child.Width -gt 0 -and $child.Height -gt 0) ('Empty control: ' + $child.AccessibleName)
        if ($Control -isnot [Windows.Forms.FlowLayoutPanel] -and -not $Control.AutoScroll) {
            $detail = '{0} in {1}: {2}, parent {3}' -f $child.GetType().Name, $Control.GetType().Name, $child.Bounds, $Control.ClientSize
            Assert-ToolGui ($child.Right -le $Control.ClientSize.Width + 2 -and $child.Bottom -le $Control.ClientSize.Height + 2) ('Clipped control: ' + $detail)
        }
        if ($child -is [Windows.Forms.Button]) {
            Assert-ToolGui ($null -ne $child.Image -and $child.Image.Width -ge 16) ('Missing dialog command icon: ' + $child.Text)
            $textSize = [Windows.Forms.TextRenderer]::MeasureText($child.Text.Replace('&', ''), $child.Font)
            Assert-ToolGui ($textSize.Width + $child.Image.Width + $child.Padding.Horizontal -le $child.ClientSize.Width) ('Clipped button icon or label: ' + $child.Text)
        }
        if ($child -is [Windows.Forms.Label] -and $child.Text -cne 'Easy Edge Apps') {
            Assert-ToolGui ($child.Tag -is [Drawing.Image] -and $child.Padding.Left -gt $child.Tag.Width -and $child.Height -ge $child.Tag.Height) ('Label icon overlaps its text area: ' + $child.Text)
        }
        if ($child -is [Windows.Forms.CheckBox]) { Assert-ToolGui ($null -ne $child.Image) ('Missing dialog selection icon: ' + $child.Text) }
        if ($child -isnot [Windows.Forms.DataGridView]) { Assert-ToolControlLayout $child }
    }
}

function Test-ToolFormLayout {
    param($Form, [string]$Label)
    foreach ($pointSize in @(12, 18, 24)) {
        $Form.Font = New-Object Drawing.Font('Segoe UI', $pointSize)
        $Form.PerformAutoScale()
        $Form.MaximumSize = New-Object Drawing.Size($MaximumWindowWidth, $MaximumWindowHeight)
        $Form.PerformLayout()
        [Windows.Forms.Application]::DoEvents()
        Assert-ToolControlLayout $Form
        if ($null -ne $Form.Tag.PSObject.Properties['EditorViewport']) {
            foreach ($control in $Form.Tag.Editor.Controls) {
                if (-not $control.CanSelect) { continue }
                $Form.Tag.EditorViewport.ScrollControlIntoView($control)
                [Windows.Forms.Application]::DoEvents()
                $bounds = $Form.Tag.EditorViewport.RectangleToClient($control.RectangleToScreen($control.ClientRectangle))
                Assert-ToolGui ($Form.Tag.EditorViewport.ClientRectangle.Contains($bounds)) ('Unreachable dialog field: ' + $control.AccessibleName)
            }
        }
        foreach ($control in @($Form.Tag.ApplyButton, $Form.Tag.CloseButton)) {
            $bounds = $Form.RectangleToClient($control.RectangleToScreen($control.ClientRectangle))
            Assert-ToolGui ($Form.ClientRectangle.Contains($bounds)) ('Unreachable dialog action: ' + $control.Text)
        }
        if ($ScreenshotDirectory) {
            [void][IO.Directory]::CreateDirectory($ScreenshotDirectory)
            if ($null -ne $Form.Tag.PSObject.Properties['EditorViewport']) {
                $Form.Tag.EditorViewport.AutoScrollPosition = New-Object Drawing.Point(0, 0)
                [Windows.Forms.Application]::DoEvents()
            }
            $bitmap = New-Object Drawing.Bitmap($Form.Width, $Form.Height)
            try {
                $Form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
                $bitmap.Save((Join-Path $ScreenshotDirectory ("$Label-font-$pointSize.png")), [Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bitmap.Dispose() }
        }
    }
    $Form.Font = New-Object Drawing.Font('Segoe UI', 12)
    $Form.PerformAutoScale()
    [Windows.Forms.Application]::DoEvents()
    Write-Host "PASS: $Label dialog layout at 12, 18, and 24 points within 1024 by 768."
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $source = New-ToolTestContext 'Source'
    $destination = New-ToolTestContext 'Destination'
    $null = Install-EeaApp -AppName 'Family News' -Website 'https://example.com/news?view=large#/home' -Notes 'Private fixture notes.' -Context $source -Confirm:$false
    $kit = New-EeaKit -KitName 'Family websites' -Notes 'Synthetic helper notes.' -Context $source
    $exportForm = New-EeaExportForm -Context $source
    Show-ToolTestForm $exportForm
    $exportUi = $exportForm.Tag
    Assert-ToolGui ($exportUi.PasswordInput.UseSystemPasswordChar -and $exportUi.ConfirmationInput.UseSystemPasswordChar) 'Both export password fields must be masked.'
    Test-ToolFormLayout $exportForm 'export'
    $exportUi.PasswordInput.Text = 'A strong test passphrase!'
    $exportUi.ConfirmationInput.Text = 'A different test passphrase!'
    $exportUi.ApplyButton.PerformClick()
    Assert-ToolGui ($script:LastDialogError -eq 'The passwords do not match.' -and $script:PathRequests -eq 0) 'Password mismatch must stop before choosing or writing a file.'
    Assert-ToolGui ($exportUi.PasswordInput.TextLength -eq 0 -and $exportUi.ConfirmationInput.TextLength -eq 0) 'Clear password controls after failure.'
    $exportUi.PasswordInput.Text = 'A strong test passphrase!'
    $exportUi.ConfirmationInput.Text = 'A strong test passphrase!'
    $exportUi.ApplyButton.PerformClick()
    Assert-ToolGui ($script:PathRequests -eq 1 -and @(Get-ChildItem -LiteralPath $testRoot -Filter '*.eeakit.json').Count -eq 0) 'Cancelling file selection must not export anything.'
    $exportUi.FormatInput.SelectedIndex = 0
    $script:KitFileChoice = Join-Path $testRoot 'Readable.eeakit.json'
    $exportUi.ApplyButton.PerformClick()
    Assert-ToolGui ($script:PathRequests -eq 1 -and -not [IO.File]::Exists($script:KitFileChoice)) 'Declining plaintext privacy approval must preserve the destination.'
    $script:ApproveChange = $true
    $exportUi.ApplyButton.PerformClick()
    Assert-ToolGui ([IO.File]::Exists($script:KitFileChoice)) ('Approved standard export failed: ' + $exportUi.StatusLabel.Text)
    $exportUi.FormatInput.SelectedIndex = 1
    $exportUi.PasswordInput.Text = 'A strong test passphrase!'
    $exportUi.ConfirmationInput.Text = 'A strong test passphrase!'
    $script:KitFileChoice = Join-Path $testRoot 'Protected.eeakit.json'
    $exportUi.ApplyButton.PerformClick()
    Assert-ToolGui ([IO.File]::Exists($script:KitFileChoice)) ('Approved protected export failed: ' + $exportUi.StatusLabel.Text)
    $envelope = Read-EeaKitDocument $script:KitFileChoice
    Write-Host 'PASS: Dialog Ctrl+Backspace, masked export passwords, mismatch, file cancellation, readable-file consent, and standard/encrypted exports.'

    $unlockForm = New-EeaPasswordForm -Envelope $envelope
    Show-ToolTestForm $unlockForm
    Test-ToolFormLayout $unlockForm 'unlock'
    Assert-ToolGui ($unlockForm.Tag.PasswordInput.UseSystemPasswordChar -and -not $unlockForm.Tag.ApplyButton.Enabled) 'Unlock needs a masked password and must not act when empty.'
    $unlockForm.Tag.PasswordInput.Text = 'This is the wrong passphrase!'
    $unlockForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui ($script:LastDialogError -eq 'Incorrect password or damaged kit.' -and $null -eq $unlockForm.Tag.Kit) 'Wrong-password unlock must not return an installable kit.'
    Assert-ToolGui (-not (Test-Path -LiteralPath $destination.Root)) 'Failed unlock must not create installation state.'
    $unlockForm.Tag.PasswordInput.Text = 'A strong test passphrase!'
    $unlockForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui ($unlockForm.DialogResult -eq [Windows.Forms.DialogResult]::OK -and $unlockForm.Tag.Kit.Apps[0].Name -eq 'Family News') 'Successful unlock must return only the in-memory kit.'
    $cancelUnlock = New-EeaPasswordForm -Envelope $envelope
    $forms.Add($cancelUnlock)
    $cancelUnlock.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $cancelUnlock.Location = New-Object Drawing.Point(-10000, -10000)
    $cancelUnlock.ShowInTaskbar = $false
    $cancelUnlock.Add_Shown({ param($Sender, $EventArgs) $Sender.Tag.PasswordInput.Text = 'A strong test passphrase!'; $Sender.Tag.CloseButton.PerformClick() })
    $cancelResult = $cancelUnlock.ShowDialog()
    Assert-ToolGui ($cancelResult -eq [Windows.Forms.DialogResult]::Cancel -and $null -eq $cancelUnlock.Tag.Kit -and $cancelUnlock.Tag.PasswordInput.TextLength -eq 0) 'Cancel must return no kit and clear the password.'
    Write-Host 'PASS: Unlock failure, successful in-memory unlock, and cancellation without installation.'

    $importForm = New-EeaSelectionForm -Mode Import -Kit $kit -Context $destination
    Show-ToolTestForm $importForm
    Test-ToolFormLayout $importForm 'import'
    Assert-ToolGui ($importForm.Tag.Grid.Rows.Count -eq 1 -and -not $importForm.Tag.ApplyButton.Enabled) 'Import preview must start unselected.'
    Assert-ToolGui (-not (Test-Path -LiteralPath $destination.Root)) 'Opening import preview must not install.'
    $importForm.Tag.AllCheck.Checked = $true
    $script:ApproveChange = $false
    $importForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui (-not (Test-Path -LiteralPath $destination.Root)) 'Declining import must not create files.'
    $script:ApproveChange = $true
    $importForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui ($null -ne $importForm.Tag.Result -and $importForm.Tag.Result.Completed) ('Approved GUI import failed: ' + $importForm.Tag.StatusLabel.Text)
    Assert-ToolGui ($importForm.Tag.Grid.Rows[0].Cells['Status'].Value -eq 'Added') 'Import must show actual per-app outcomes.'
    Update-EeaSelectionForm $importForm
    Assert-ToolGui ($importForm.Tag.Grid.Rows[0].Cells['Status'].Value -eq 'Unchanged' -and -not $importForm.Tag.Grid.Rows[0].Tag.CanSelect) 'Repeated import must be unchanged.'
    $changedKit = $kit | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $changedKit.Apps[0].Url = 'https://example.org/different'
    $domainForm = New-EeaSelectionForm -Mode Import -Kit $changedKit -Context $destination
    Show-ToolTestForm $domainForm
    $domainForm.Tag.Grid.Rows[0].Selected = $true
    Assert-ToolGui ($domainForm.Tag.Grid.Rows[0].Cells['Status'].Value -like '*DOMAIN CHANGE*' -and $domainForm.Tag.Grid.Rows[0].Tag.Description.Contains($kit.Apps[0].Url)) 'Destination changes need an explicit label and exact previous address.'
    Write-Host 'PASS: Read-only import preview, declined/approved import, per-app results, idempotence, and domain-change warning.'

    $installedPaths = Get-EeaPaths $destination 'Family News'
    [IO.File]::Delete($installedPaths.Desktop)
    $checkForm = New-EeaSelectionForm -Mode Check -Context $destination
    Show-ToolTestForm $checkForm
    Test-ToolFormLayout $checkForm 'check'
    $checkForm.Tag.AllCheck.Checked = $true
    $script:ApproveChange = $false
    $checkForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui (-not [IO.File]::Exists($installedPaths.Desktop)) 'Declining repair must preserve the missing shortcut.'
    $script:ApproveChange = $true
    $checkForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui ($null -ne $checkForm.Tag.Result -and $checkForm.Tag.Result.Completed -and [IO.File]::Exists($installedPaths.Desktop)) ('Approved repair failed: ' + $checkForm.Tag.StatusLabel.Text)
    [IO.File]::Delete($installedPaths.Desktop)
    Update-EeaSelectionForm $checkForm
    $checkForm.Tag.AllCheck.Checked = $true
    $null = Install-EeaApp -AppName 'Family News' -Website 'https://example.com/newer' -Context $destination -Confirm:$false
    [IO.File]::Delete($installedPaths.Desktop)
    $checkForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui ($script:LastDialogError -like '*changed after the check*' -and -not [IO.File]::Exists($installedPaths.Desktop)) 'Stale repair approval must not apply newer settings.'
    [IO.File]::WriteAllText($installedPaths.Manifest, '{damaged settings')
    $damagedForm = New-EeaSetupForm -Context $destination
    Show-ToolTestForm $damagedForm
    Assert-ToolGui $damagedForm.Tag.CheckButton.Enabled 'Damaged settings must not make Check Apps inaccessible.'
    Update-EeaSelectionForm $checkForm
    Assert-ToolGui ($checkForm.Tag.Grid.Rows[0].Cells['Status'].Value -eq 'Conflict' -and -not $checkForm.Tag.ApplyButton.Enabled) 'Damaged settings must not offer blind repair.'
    Write-Host 'PASS: Declined/approved repair, stale check rejection, and accessible diagnostics for damaged settings.'

    $favoritesContext = New-ToolTestContext 'Favorites'
    $edgeRoot = Join-Path $testRoot 'Synthetic Edge'
    foreach ($profileName in @('Default', 'Profile 1')) { [void][IO.Directory]::CreateDirectory((Join-Path $edgeRoot $profileName)) }
    $barData = [pscustomobject]@{ roots = [pscustomobject]@{ bookmark_bar = [pscustomobject]@{ type = 'folder'; children = @(
        [pscustomobject]@{ type = 'url'; name = 'Local News'; url = 'https://example.com/news' },
        [pscustomobject]@{ type = 'folder'; name = 'Family folder'; children = @([pscustomobject]@{ type = 'url'; name = 'Calendar'; url = 'https://example.org/calendar' }) },
        [pscustomobject]@{ type = 'url'; name = 'Unavailable link'; url = 'javascript:void(0)' }
    ) } } }
    $bookmarkPath = Join-Path $edgeRoot 'Default\Bookmarks'
    [IO.File]::WriteAllText($bookmarkPath, ($barData | ConvertTo-Json -Depth 10))
    [IO.File]::WriteAllText((Join-Path $edgeRoot 'Profile 1\Bookmarks'), '{"roots":{"bookmark_bar":{"type":"folder","children":[]}}}')
    $bookmarkHash = (Get-FileHash -LiteralPath $bookmarkPath).Hash
    $favoritesForm = New-EeaSelectionForm -Mode Favorites -Context $favoritesContext -EdgeUserDataPath $edgeRoot
    Show-ToolTestForm $favoritesForm
    Test-ToolFormLayout $favoritesForm 'favorites'
    Assert-ToolGui ($favoritesForm.Tag.ProfileInput.Items.Count -eq 2 -and $favoritesForm.Tag.Grid.Rows.Count -eq 3) 'Offer local profiles and nested Favorites bar entries.'
    $favoritesForm.Tag.ProfileInput.SelectedIndex = 1
    Assert-ToolGui ($favoritesForm.Tag.Grid.Rows.Count -eq 0) 'Changing profiles must refresh the choices.'
    $favoritesForm.Tag.ProfileInput.SelectedIndex = 0
    $favoritesForm.Tag.AllCheck.Checked = $true
    Assert-ToolGui (@($favoritesForm.Tag.Grid.Rows | Where-Object { $_.Cells[0].Value }).Count -eq 2) 'Select all must leave unsupported entries unavailable.'
    $script:ApproveChange = $false
    $favoritesForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui (-not (Test-Path -LiteralPath $favoritesContext.Root)) 'Declined Favorites import must not install.'
    $script:ApproveChange = $true
    $favoritesForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui ($null -ne $favoritesForm.Tag.Result -and $favoritesForm.Tag.Result.Completed -and @(Get-EeaApps -Context $favoritesContext).Count -eq 2) ('Selected Favorites import failed: ' + $favoritesForm.Tag.StatusLabel.Text)
    Assert-ToolGui ((Get-FileHash -LiteralPath $bookmarkPath).Hash -ceq $bookmarkHash) 'Favorites GUI must never modify Edge bookmarks.'
    Update-EeaSelectionForm $favoritesForm
    $favoritesForm.Tag.AllCheck.Checked = $true
    Assert-ToolGui (-not $favoritesForm.Tag.ApplyButton.Enabled) 'Already imported Favorites must not be duplicated.'
    Write-Host "PASS: Profile selection, nested Favorites, unavailable links, explicit consent, and read-only Edge data on PowerShell $($PSVersionTable.PSVersion)."
    $settingsContext = New-ToolTestContext 'Settings'
    [void][IO.Directory]::CreateDirectory((Join-Path $edgeRoot 'Profile 2'))
    [IO.File]::WriteAllText((Join-Path $edgeRoot 'Profile 2\Preferences'), '{}')
    $settingsOwner = New-EeaSetupForm -Context $settingsContext -EdgeUserDataPath $edgeRoot
    Show-ToolTestForm $settingsOwner
    $settingsForm = New-EeaSettingsForm -OwnerForm $settingsOwner
    Show-ToolTestForm $settingsForm
    Assert-ToolGui ($script:UpdateRequestsStarted -eq 0 -and -not [IO.Directory]::Exists($settingsContext.Root)) 'Opening setup or Settings with default preferences must not write files or contact GitHub.'
    Assert-ToolGui ($settingsForm.Tag.UpdateLabel.Text -ceq 'Not checked yet.') 'Opening Settings must not imply that an update check has already happened.'
    Assert-ToolGui ($settingsForm.Tag.ProfileInput.Items.Count -eq 4) 'The default-profile picker must include local profiles without bookmarks and the Edge-controlled option.'
    $settingsForm.Tag.AutoUpdateCheck.Checked = $true
    $settingsForm.Tag.DebugCheck.Checked = $true
    $settingsForm.Close()
    Assert-ToolGui (-not [IO.Directory]::Exists($settingsContext.Root) -and -not $settingsOwner.Tag.Settings.AutomaticUpdateChecks) 'Cancelling Settings must discard unsaved toggles.'
    $settingsForm.Dispose()
    $settingsForm = New-EeaSettingsForm -OwnerForm $settingsOwner
    Show-ToolTestForm $settingsForm
    Test-ToolFormLayout $settingsForm 'settings'
    $settingsUi = $settingsForm.Tag
    $settingsUi.OpenLogsButton.PerformClick()
    Assert-ToolGui ($settingsUi.StatusLabel.Text -ceq 'No diagnostic logs yet.') 'Opening a missing log folder must not create files or launch Explorer.'
    foreach ($outcome in @('Available', 'Current', 'Failure', 'Cancel')) {
        $versionText = if ($outcome -eq 'Current') { (Get-EeaVersion).ToString() } else { '1.4.0' }
        $script:NextUpdateRequest = New-ToolUpdateRequest -Version $versionText -Fail:($outcome -eq 'Failure')
        $request = $script:NextUpdateRequest
        $settingsUi.CheckUpdatesButton.PerformClick()
        Assert-ToolGui ($settingsUi.UpdateSpinner.IsBusy -and -not $settingsUi.CheckUpdatesButton.Enabled -and $settingsUi.CancelUpdateButton.Enabled) 'Checking updates must show activity and expose cancellation.'
        if ($outcome -eq 'Cancel') { $settingsUi.CancelUpdateButton.PerformClick(); Assert-ToolGui $request.Cancellation.IsCancellationRequested 'Cancel must signal the pending update worker.' }
        $request.AsyncResult.IsCompleted = $true
        Complete-EeaFormUpdateCheck $settingsOwner
        Assert-ToolGui ($request.PowerShell.Disposed -and -not $settingsUi.UpdateSpinner.IsBusy -and $settingsUi.CheckUpdatesButton.Enabled -and -not $settingsOwner.Tag.UpdateTimer.Enabled) 'Every update outcome must dispose the worker and restore controls.'
        if ($outcome -eq 'Available') {
            Assert-ToolGui ($settingsUi.DownloadUpdateButton.Visible -and $settingsOwner.Tag.DownloadUpdateItem.Available -and $settingsUi.UpdateLabel.Text.Contains('1.4.0')) 'New releases must expose the official download action and version.'
            Test-ToolFormLayout $settingsForm 'settings-update'
        }
        if ($outcome -eq 'Current') { Assert-ToolGui (-not $settingsUi.DownloadUpdateButton.Visible -and $settingsUi.UpdateLabel.Text -ceq 'You have the latest version.') 'Current releases must show the up-to-date state without a download action.' }
        if ($outcome -eq 'Failure') { Assert-ToolGui ($settingsUi.UpdateLabel.Text.StartsWith('Could not check')) 'Failures must leave a retryable update status.' }
        if ($outcome -eq 'Cancel') { Assert-ToolGui ($settingsUi.UpdateLabel.Text -ceq 'Update check cancelled.') 'Cancelled checks must not offer stale pending release data.' }
    }
    $settingsUi.DesktopCheck.Checked = $false
    $settingsUi.StartMenuCheck.Checked = $false
    $settingsUi.ApplyButton.PerformClick()
    Assert-ToolGui ($settingsUi.StatusLabel.Text.StartsWith('FAILED:') -and -not [IO.File]::Exists((Join-Path $settingsContext.Root 'settings.json'))) 'Invalid placement settings must not be saved.'
    $settingsUi.StartMenuCheck.Checked = $true
    $settingsUi.ProfileInput.SelectedIndex = 2
    $settingsUi.MotionCheck.Checked = $false
    $settingsUi.DebugCheck.Checked = $true
    $settingsUi.TextSizeInput.SelectedItem = 14
    $settingsUi.ApplyButton.PerformClick()
    $savedSettings = Get-EeaSettings -Context $settingsContext
    Assert-ToolGui (-not $savedSettings.DefaultDesktop -and $savedSettings.DefaultEdgeProfile -ceq 'Profile 1' -and $savedSettings.DebugLogging -and $savedSettings.TextSize -eq 14) 'Saved Settings must retain the selected profile, placement, diagnostics, and text size.'
    Assert-ToolGui (-not $settingsOwner.MotionEnabled -and -not $settingsOwner.Tag.DesktopCheck.Checked -and $settingsOwner.Font.Size -eq 14 -and $settingsOwner.Tag.SettingsMenu.Font.Size -eq 14) 'Appearance and new-website placement preferences must apply to setup and its menu.'
    $fontDialog = New-EeaScrollDialog -Title 'Font test' -ActionText '&Close' -ActionIcon Close
    $forms.Add($fontDialog)
    $fontDialog.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $fontDialog.Location = New-Object Drawing.Point(-10000, -10000)
    $fontDialog.ShowInTaskbar = $false
    $script:ModalFontPoints = 0
    $fontDialog.Add_Shown({ param($Sender, $EventArgs) $script:ModalFontPoints = $Sender.Font.Size; $Sender.DialogResult = [Windows.Forms.DialogResult]::Cancel; $Sender.Close() })
    $null = Show-EeaModal -Owner $settingsOwner -Dialog $fontDialog
    Assert-ToolGui ($script:ModalFontPoints -eq 14) 'Owned modal dialogs must inherit the saved setup text size.'
    $logPath = Join-Path $settingsContext.Root 'Logs\debug.jsonl'
    $script:ApproveChange = $false
    $settingsUi.ClearLogsButton.PerformClick()
    Assert-ToolGui ([IO.File]::Exists($logPath)) 'Declining log cleanup must preserve diagnostic files.'
    $script:ApproveChange = $true
    $settingsUi.ClearLogsButton.PerformClick()
    Assert-ToolGui (-not [IO.File]::Exists($logPath)) 'Approved log cleanup must remove diagnostic files.'
    $settingsUi.AutoUpdateCheck.Checked = $true
    $requestCount = $script:UpdateRequestsStarted
    $settingsUi.ApplyButton.PerformClick()
    Assert-ToolGui ($script:UpdateRequestsStarted -eq $requestCount) 'Enabling automatic checks must respect a recent explicit check.'
    $stampLock = [IO.FileStream]::new((Join-Path $settingsContext.Root 'last-update-check.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        Start-EeaFormUpdateCheck -Form $settingsOwner -Automatic
        Assert-ToolGui ($script:UpdateRequestsStarted -eq $requestCount -and $null -eq $settingsOwner.Tag.UpdateRequest -and $settingsOwner.Tag.UpdateStatus -ceq 'Could not start the update check.') 'An unreadable update timestamp must leave setup usable without starting a request or raising an automatic-check dialog.'
    }
    finally { $stampLock.Dispose() }
    Set-EeaUpdateCheckTime -Context $settingsContext -UtcNow ([DateTime]::UtcNow.AddDays(-2))
    $script:NextUpdateRequest = New-ToolUpdateRequest
    $request = $script:NextUpdateRequest
    Start-EeaFormUpdateCheck -Form $settingsOwner -Automatic
    Assert-ToolGui ($script:UpdateRequestsStarted -eq $requestCount + 1) 'An enabled and due automatic check must start once.'
    $settingsUi.AutoUpdateCheck.Checked = $false
    $settingsUi.ApplyButton.PerformClick()
    Assert-ToolGui $request.Cancellation.IsCancellationRequested 'Disabling automatic updates must cancel its pending check.'
    $request.AsyncResult.IsCompleted = $true
    Complete-EeaFormUpdateCheck $settingsOwner
    $settingsForm.Close()
    $settingsForm.Dispose()
    $settingsOwner.Tag.Settings.DefaultEdgeProfile = 'Profile 99'
    $settingsForm = New-EeaSettingsForm -OwnerForm $settingsOwner
    Show-ToolTestForm $settingsForm
    Assert-ToolGui (-not $settingsForm.Tag.ProfileInput.SelectedItem.Available) 'A removed saved profile must be shown as unavailable, not silently replaced.'
    $settingsForm.Tag.ApplyButton.PerformClick()
    Assert-ToolGui ($settingsForm.Tag.StatusLabel.Text.StartsWith('FAILED:')) 'An unavailable profile must require an explicit replacement before saving settings.'
    $script:NextUpdateRequest = New-ToolUpdateRequest
    $request = $script:NextUpdateRequest
    Start-EeaFormUpdateCheck $settingsOwner
    $settingsOwner.Close()
    Assert-ToolGui ($request.Cancellation.IsCancellationRequested -and -not $settingsOwner.IsDisposed) 'Closing setup must cancel a pending check and await its cleanup.'
    $request.AsyncResult.IsCompleted = $true
    Complete-EeaFormUpdateCheck $settingsOwner
    Assert-ToolGui ($settingsOwner.IsDisposed -and $request.PowerShell.Disposed) 'Completed cancellation must permit setup to close without leaving an update worker.'
    $damagedContext = New-ToolTestContext 'Damaged preferences'
    [void][IO.Directory]::CreateDirectory($damagedContext.Root)
    $damagedPath = Join-Path $damagedContext.Root 'settings.json'
    [IO.File]::WriteAllText($damagedPath, '{damaged preferences')
    $damagedHash = (Get-FileHash -LiteralPath $damagedPath).Hash
    $damagedOwner = New-EeaSetupForm -Context $damagedContext -EdgeUserDataPath $edgeRoot
    Show-ToolTestForm $damagedOwner
    Assert-ToolGui ($damagedOwner.Tag.SettingsError -and -not $damagedOwner.Tag.Settings.AutomaticUpdateChecks -and (Get-FileHash -LiteralPath $damagedPath).Hash -ceq $damagedHash) 'Damaged preferences must fall back safely with a warning and no automatic repair or network check.'
    $damagedDialog = New-EeaSettingsForm -OwnerForm $damagedOwner
    Show-ToolTestForm $damagedDialog
    $damagedDialog.Tag.ApplyButton.PerformClick()
    Assert-ToolGui ((Get-EeaSettings -Context $damagedContext).Product -ceq 'EasyEdgeApps.Settings' -and -not $damagedOwner.Tag.SettingsError) 'Explicitly saving Settings must replace damaged preferences with a valid document and clear the warning state.'
    Write-Host 'PASS: Settings layout, save/cancel, local profiles, updates, automatic-check preferences, diagnostics, and closing cleanup without live network access.'
}
finally {
    foreach ($form in $forms) { if (-not $form.IsDisposed) { $form.Close(); $form.Dispose() } }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}