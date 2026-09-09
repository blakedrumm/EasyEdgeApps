#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ScreenshotDirectory,
    [int]$MaximumWindowWidth = 0,
    [int]$MaximumWindowHeight = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.GuiTests.' + [Guid]::NewGuid().ToString('N'))
$context = [pscustomobject]@{
    Root = Join-Path $testRoot 'LocalAppData\EasyEdgeApps'
    Desktop = Join-Path $testRoot 'Desktop'
    Programs = Join-Path $testRoot 'Programs\Easy Edge Apps'
}
$form = $null
$script:ApproveChange = $false
$script:ExplorerRequests = New-Object 'Collections.Generic.List[object]'
$script:FailExplorer = $false
$script:PinRequests = New-Object 'Collections.Generic.List[string]'
$script:FailPinRequest = $false

function Request-EeaTaskbarPin {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$AppName, $Context)
    if ($script:FailPinRequest) { throw 'Synthetic Windows pin failure.' }
    Assert-Gui (Get-EeaStateTaskbar (Read-EeaManifest $Context $AppName)) 'Pin requests must follow a saved taskbar app, not unsaved editor data.'
    $script:PinRequests.Add($AppName)
    $process = [pscustomobject]@{ HasExited = $false; ExitCode = 0; Disposed = $false; FailRefresh = $false; CloseAccepted = $true; Killed = $false }
    $process | Add-Member ScriptMethod Refresh { if ($this.FailRefresh) { throw 'Synthetic process inspection failure.' } }
    $process | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    $process | Add-Member ScriptMethod CloseMainWindow { if ($this.CloseAccepted) { $this.HasExited = $true; $this.ExitCode = 3 }; return $this.CloseAccepted }
    $process | Add-Member ScriptMethod Kill { $this.Killed = $true; $this.HasExited = $true; $this.ExitCode = 3 }
    return $process
}

function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string]$ArgumentList)
    Assert-Gui ($FilePath -ceq (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe')) 'GUI tests must never launch an unmocked application.'
    if ($script:FailExplorer) { throw 'Synthetic Explorer failure.' }
    $script:ExplorerRequests.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = $ArgumentList })
}

function Confirm-EeaChange {
    param($Form, [string]$Message, [string]$Title)
    return $script:ApproveChange
}

function Show-EeaFormError {
    param($Form, $Failure)
    $Form.Tag.StatusLabel.Text = 'FAILED: ' + $Failure.Exception.Message
}

function Assert-Gui {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-GuiTaskbar {
    param($Form, $Context)
    $ui = $Form.Tag
    $paths = Get-EeaPaths $Context 'My News'
    $manifestHash = (Get-FileHash -LiteralPath $paths.Manifest).Hash
    Assert-Gui ($ui.TaskbarCheck.Image.Tag -ceq 'Pin' -and $ui.TaskbarCheck.AccessibleName -ceq 'Request a taskbar pin for this website') 'Taskbar must be an accessible placement checkbox with its pin icon.'
    $ui.TaskbarCheck.Checked = $true
    Assert-Gui ($ui.StartMenuCheck.Checked -and -not $ui.StartMenuCheck.Enabled) 'A taskbar request must retain the Start menu entry required by Windows.'
    Assert-Gui ((Get-FileHash -LiteralPath $paths.Manifest).Hash -ceq $manifestHash -and $script:PinRequests.Count -eq 0) 'Selecting the checkbox alone must not save or request a pin.'
    $ui.SaveButton.PerformClick()
    Assert-Gui (-not (Get-EeaStateTaskbar (Read-EeaManifest $Context 'My News')) -and $script:PinRequests.Count -eq 0) 'Declining the dedicated-profile confirmation must leave the existing website unchanged.'
    $previousApproval = $script:ApproveChange
    $script:ApproveChange = $true
    try {
        foreach ($exitCode in @(0, 1, 3, 4)) {
            $ui.SaveButton.PerformClick()
            $process = $ui.PinProcess
            Assert-Gui ($null -ne $process -and -not $ui.SaveButton.Enabled -and $ui.PinTimer.Enabled -and (Get-EeaStateTaskbar (Read-EeaManifest $Context 'My News'))) 'Saving a taskbar app must wait asynchronously for Windows, after persisting the selected website.'
            foreach ($control in @($ui.AppList, $ui.NewButton, $ui.OpenButton, $ui.RemoveButton, $ui.ImportButton, $ui.FavoritesButton, $ui.CheckButton, $ui.GetIconButton)) {
                Assert-Gui (-not $control.Enabled) 'Conflicting website actions must be unavailable while Windows pin approval is pending.'
            }
            $requestCount = $script:PinRequests.Count
            $ui.SaveButton.PerformClick()
            $ui.RemoveButton.PerformClick()
            Assert-Gui ($script:PinRequests.Count -eq $requestCount -and $null -ne (Read-EeaManifest $Context 'My News')) 'A pending pin must not allow duplicate requests or removal of its saved app.'
            $process.ExitCode = $exitCode
            $process.HasExited = $true
            Complete-EeaTaskbarPin $Form
            Assert-Gui ($process.Disposed -and $null -eq $ui.PinProcess -and $ui.SaveButton.Enabled -and -not $ui.PinTimer.Enabled) 'A completed pin request must restore controls and release its process handle.'
            if ($exitCode -eq 0) { Assert-Gui ($ui.StatusLabel.Text -ceq 'Pinned to taskbar: My News') 'Only a successful Windows result may report a completed pin.' }
            else { Assert-Gui (-not $ui.StatusLabel.Text.StartsWith('Pinned')) 'Declined or unavailable Windows pinning must not be reported as pinned.' }
        }
        $ui.SaveButton.PerformClick()
        $process = $ui.PinProcess
        $process.FailRefresh = $true
        Complete-EeaTaskbarPin $Form
        Assert-Gui ($process.Killed -and $process.Disposed -and $null -eq $ui.PinProcess -and $ui.SaveButton.Enabled -and $ui.RemoveButton.Enabled -and $ui.StatusLabel.Text -ceq 'Saved. Taskbar pin result could not be confirmed.') 'A failed process inspection must not leave setup stuck or report a successful pin.'
        foreach ($closeAccepted in @($true, $false)) {
            $closingForm = New-EeaSetupForm -Context $Context
            try {
                $closingForm.StartPosition = [Windows.Forms.FormStartPosition]::Manual
                $closingForm.Location = New-Object Drawing.Point(-10000, -10000)
                $closingForm.ShowInTaskbar = $false
                $closingForm.Show()
                $closingForm.Tag.AppList.SelectedIndex = 0
                $closingForm.Tag.SaveButton.PerformClick()
                $closingProcess = $closingForm.Tag.PinProcess
                $closingProcess.CloseAccepted = $closeAccepted
                $closingForm.Close()
                Assert-Gui ($closingForm.Visible -and $closingForm.Tag.CloseAfterPinRequest) 'Closing during pin approval must keep the message loop alive for asynchronous cancellation.'
                if (-not $closeAccepted) { $closingForm.Tag.PinCloseDeadline = [DateTime]::UtcNow.AddSeconds(-1) }
                Complete-EeaTaskbarPin $closingForm
                Assert-Gui ($closingForm.IsDisposed -and $closingProcess.Disposed -and $closingProcess.Killed -eq (-not $closeAccepted)) 'Closing setup must release the pin helper even when its window is not ready to receive a close message.'
            }
            finally { $closingForm.Dispose() }
        }
        $ui.NewButton.PerformClick()
        Assert-Gui (-not $ui.TaskbarCheck.Checked) 'New websites must not inherit a previous taskbar choice.'
        $ui.TaskbarCheck.Checked = $true
        $originalPreferences = $ui.Settings
        $placementPreferences = ConvertTo-EeaSettings $originalPreferences
        $placementPreferences.DefaultStartMenu = $false
        try {
            Set-EeaFormPreferences -Form $Form -Settings $placementPreferences
            Assert-Gui ($ui.TaskbarCheck.Checked -and $ui.StartMenuCheck.Checked -and -not $ui.StartMenuCheck.Enabled) 'Changing default placement must preserve the required Start menu entry for an unsaved taskbar app.'
        }
        finally {
            $ui.TaskbarCheck.Checked = $false
            Set-EeaFormPreferences -Form $Form -Settings $originalPreferences
        }
        $ui.AppList.SelectedIndex = 0
        Assert-Gui $ui.TaskbarCheck.Checked 'Selecting a saved taskbar app must restore its checkbox.'
        $script:FailPinRequest = $true
        $ui.SaveButton.PerformClick()
        Assert-Gui ($ui.SaveButton.Enabled -and $ui.StatusLabel.Text -ceq 'FAILED: Synthetic Windows pin failure.' -and (Get-EeaStateTaskbar (Read-EeaManifest $Context 'My News'))) 'A Windows pin failure must preserve the saved app and allow further editing.'
        $script:FailPinRequest = $false
        $ui.TaskbarCheck.Checked = $false
        $ui.SaveButton.PerformClick()
        Assert-Gui (-not (Get-EeaStateTaskbar (Read-EeaManifest $Context 'My News')) -and $ui.StartMenuCheck.Enabled) 'Approved opt-out must restore ordinary placement controls without claiming Windows unpinned the app.'
    }
    finally { $script:FailPinRequest = $false; $script:ApproveChange = $previousApproval }
    $ui.StatusLabel.Text = 'Saved: My News'
    Write-Host 'PASS: Taskbar checkbox, profile consent, required Start entry, asynchronous pin success/decline/unavailability, save preservation, reset, selection, and opt-out without changing the actual taskbar.'
}

function New-GuiIconRequest {
    param([byte[]]$IconData, [switch]$Fail, [string]$ResolvedWebsite, [string]$FailureCode)
    $pipeline = [pscustomobject]@{ Bytes = $IconData; Fail = [bool]$Fail; Disposed = $false; Website = $ResolvedWebsite; FailureCode = $FailureCode }
    $pipeline | Add-Member ScriptMethod EndInvoke {
        param($Pending)
        if ($this.Fail) { throw 'Synthetic website icon failure.' }
        return [pscustomobject]@{ Bytes = $this.Bytes; SourceUrl = 'https://example.com/favicon.ico'; Website = $this.Website; FailureCode = $this.FailureCode }
    }
    $pipeline | Add-Member ScriptMethod Stop { }
    $pipeline | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    return [pscustomobject]@{ Website = ''; PowerShell = $pipeline; AsyncResult = [pscustomobject]@{ IsCompleted = $false }; Cancellation = (New-Object Threading.CancellationTokenSource); Discard = $false; ResolveOnly = $false }
}

function Start-EeaWebsiteIconRequest {
    param([string]$Website, [switch]$ResolveOnly)
    $address = ConvertTo-EeaWebsite $Website -AllowMissingScheme
    Assert-Gui ($null -ne $script:NextIconRequest) 'GUI tests must never use a live website icon service.'
    $script:NextIconRequest.Website = $address
    $script:NextIconRequest.ResolveOnly = [bool]$ResolveOnly
    if (-not $script:NextIconRequest.PowerShell.Website) { $script:NextIconRequest.PowerShell.Website = $address }
    return $script:NextIconRequest
}

function Test-GuiWebsiteIcon {
    param($Form, $Context)
    $ui = $Form.Tag
    $paths = Get-EeaPaths $Context 'My News'
    $originalUrl = $ui.UrlInput.Text
    $originalHash = (Get-FileHash -LiteralPath $paths.Icon).Hash
    $iconData = ConvertTo-EeaWebsiteIcon (Read-EeaCustomIcon $paths.Icon)
    $ui.UrlInput.Text = 'file:///C:/private'
    $ui.GetIconButton.PerformClick()
    Assert-Gui ($null -eq $ui.IconRequest -and $ui.StatusLabel.Text.StartsWith('FAILED:')) 'Invalid website addresses must fail before starting network lookup.'
    $ui.UrlInput.Text = $originalUrl
    $script:NextIconRequest = New-GuiIconRequest $iconData
    $request = $script:NextIconRequest
    $idleButtonBounds = $ui.GetIconButton.Bounds
    $ui.GetIconButton.PerformClick()
    Assert-Gui ($null -ne $ui.IconRequest -and -not $ui.GetIconButton.Enabled -and $ui.CancelIconButton.Enabled -and -not $ui.SaveButton.Enabled -and $ui.UrlInput.Enabled) 'Lookup must expose cancellation and keep the editor responsive while waiting.'
    Assert-Gui ($null -ne $ui.PSObject.Properties['ActivitySpinner']) 'Website lookup must expose a loading spinner.'
    Assert-Gui ($ui.ActivitySpinner.IsBusy -and $ui.ActivitySpinner.Visible -and $ui.GetIconButton.Bounds -eq $idleButtonBounds) 'The spinner must show immediately without shifting the lookup buttons.'
    $spinnerBitmap = New-Object Drawing.Bitmap($ui.ActivitySpinner.Width, $ui.ActivitySpinner.Height)
    try {
        $spinnerBounds = New-Object Drawing.Rectangle([Drawing.Point]::Empty, $spinnerBitmap.Size)
        $ui.ActivitySpinner.DrawToBitmap($spinnerBitmap, $spinnerBounds)
        $firstSpinner = [Convert]::ToBase64String((Get-GuiBitmapBytes $spinnerBitmap))
        $firstFrame = $ui.ActivitySpinner.AnimationFrame
        $spinnerClock = [Diagnostics.Stopwatch]::StartNew()
        while ($ui.ActivitySpinner.AnimationFrame -eq $firstFrame -and $spinnerClock.ElapsedMilliseconds -lt 2000) { [Windows.Forms.Application]::DoEvents() }
        $spinnerClock.Stop()
        $ui.ActivitySpinner.DrawToBitmap($spinnerBitmap, $spinnerBounds)
        Assert-Gui ($ui.ActivitySpinner.AnimationFrame -gt $firstFrame -and [Convert]::ToBase64String((Get-GuiBitmapBytes $spinnerBitmap)) -cne $firstSpinner) 'The request timer must visibly animate the spinner while work is pending.'
    }
    finally { $spinnerBitmap.Dispose() }
    Assert-Gui ((Get-FileHash -LiteralPath $paths.Icon).Hash -ceq $originalHash) 'Starting lookup must not change the saved icon.'
    $request.AsyncResult.IsCompleted = $true
    Complete-EeaWebsiteIconLookup $Form
    Assert-Gui ($null -eq $ui.IconRequest -and $request.PowerShell.Disposed -and $ui.SaveButton.Enabled -and $ui.GetIconButton.Enabled -and -not $ui.CancelIconButton.Enabled) 'Completed lookups must restore controls and dispose the worker.'
    Assert-Gui (-not $ui.ActivitySpinner.IsBusy -and -not $ui.IconTimer.Enabled -and $ui.GetIconButton.Bounds -eq $idleButtonBounds) 'Successful lookup must stop the spinner without shifting the buttons.'
    Assert-Gui ($null -ne $ui.WebsiteIconData -and $ui.IconLabel.Text -ceq 'Website icon' -and $ui.IconPreview.Image.Width -eq 96) 'A retrieved website icon must be previewed in memory.'
    Assert-Gui ((Get-FileHash -LiteralPath $paths.Icon).Hash -ceq $originalHash) 'Retrieving an icon must not save it before explicit approval.'
    $ui.SaveButton.PerformClick()
    $saved = Read-EeaManifest $Context 'My News'
    Assert-Gui ($saved.IconKind -ceq 'Custom' -and $saved.IconHash -ceq (Get-EeaByteHash $iconData)) 'Save must persist retrieved icon bytes through the existing validated installation path.'
    foreach ($outcome in @('Failure', 'Cancel', 'Address', 'New')) {
        $script:NextIconRequest = New-GuiIconRequest $iconData -Fail:($outcome -eq 'Failure')
        $request = $script:NextIconRequest
        $ui.GetIconButton.PerformClick()
        if ($outcome -eq 'Cancel') { $ui.CancelIconButton.PerformClick() }
        if ($outcome -eq 'Address') { $ui.UrlInput.Text = 'https://different.example/' }
        if ($outcome -eq 'New') { Reset-EeaEditor $Form }
        if ($outcome -ne 'Failure') { Assert-Gui $request.Cancellation.IsCancellationRequested 'Cancellation, address changes, and a new editor must cancel pending lookup.' }
        $request.AsyncResult.IsCompleted = $true
        Complete-EeaWebsiteIconLookup $Form
        Assert-Gui ($null -eq $ui.WebsiteIconData -and $request.PowerShell.Disposed) 'Failures and stale results must never replace the current icon.'
        Assert-Gui (-not $ui.ActivitySpinner.IsBusy -and -not $ui.IconTimer.Enabled) 'Failure, cancellation, and stale-result cleanup must stop the spinner.'
        Assert-Gui ((Read-EeaManifest $Context 'My News').IconHash -ceq $saved.IconHash) 'A failed or cancelled lookup must leave the saved icon unchanged.'
        if ($outcome -eq 'New') { Assert-Gui ($null -eq $ui.IconPreview.Image) 'A stale lookup must not put the previous site icon into a new editor.'; $ui.AppList.SelectedIndex = 0 }
        $ui.UrlInput.Text = $originalUrl
    }
    foreach ($failureCode in @('Blocked', 'NotFound', 'Unsupported', 'Transport', 'Timeout', 'untrusted-private-message')) {
        $script:NextIconRequest = New-GuiIconRequest $iconData -FailureCode $failureCode
        $request = $script:NextIconRequest
        $ui.GetIconButton.PerformClick()
        $request.AsyncResult.IsCompleted = $true
        Complete-EeaWebsiteIconLookup $Form
        Assert-Gui ($null -eq $ui.WebsiteIconData -and (Read-EeaManifest $Context 'My News').IconHash -ceq $saved.IconHash -and $request.PowerShell.Disposed -and $ui.SaveButton.Enabled) 'Categorized failures must preserve the icon and restore editor controls.'
        Assert-Gui ($ui.StatusLabel.Text -ceq (Get-EeaWebsiteIconFailureMessage $failureCode) -and -not $ui.StatusLabel.Text.Contains('untrusted')) 'The status must use allowlisted failure text, never worker-provided prose.'
        if ($failureCode -eq 'Blocked') { Assert-Gui ($ui.StatusLabel.Text.Contains('Choose icon')) 'Blocked retrieval must identify the manual icon alternative.' }
    }
    Set-EeaEditorIcon -Form $Form -IconData $iconData
    $ui.ClearIconButton.PerformClick()
    Assert-Gui ($null -eq $ui.WebsiteIconData -and $ui.IconLabel.Text -ceq 'Saved icon' -and $null -ne $ui.IconPreview.Image) 'Use saved icon must discard the retrieved image and restore the saved preview.'
    $bareWebsite = $originalUrl.Substring('https://'.Length)
    $httpWebsite = 'http://' + $bareWebsite
    foreach ($resolvedWebsite in @($originalUrl, $httpWebsite)) {
        $ui.UrlInput.Text = $bareWebsite
        $script:NextIconRequest = New-GuiIconRequest $iconData -ResolvedWebsite $resolvedWebsite
        $request = $script:NextIconRequest
        $ui.GetIconButton.PerformClick()
        Assert-Gui ($ui.ActivitySpinner.IsBusy -and $null -ne $ui.IconRequest) 'Schemeless icon lookup must run asynchronously with visible activity.'
        $request.AsyncResult.IsCompleted = $true
        Complete-EeaWebsiteIconLookup $Form
        Assert-Gui ($ui.UrlInput.Text -ceq $resolvedWebsite -and $null -ne $ui.WebsiteIconData -and -not $ui.ActivitySpinner.IsBusy) 'Resolved HTTPS or HTTP must appear in the address field before the downloaded icon can be saved.'
        if ($resolvedWebsite.StartsWith('http://')) { Assert-Gui ($ui.StatusLabel.Text -match 'HTTP.*unencrypted') 'HTTP fallback must be clearly identified as unencrypted.' }
    }
    $ui.ClearIconButton.PerformClick()
    $ui.UrlInput.Text = $bareWebsite
    $script:NextIconRequest = New-GuiIconRequest $iconData -ResolvedWebsite $originalUrl
    $request = $script:NextIconRequest
    $ui.SaveButton.PerformClick()
    Assert-Gui ($request.ResolveOnly -and $ui.ActivitySpinner.IsBusy -and -not $ui.SaveButton.Enabled) 'Saving a schemeless address must resolve it asynchronously without retrieving an icon.'
    $request.AsyncResult.IsCompleted = $true
    Complete-EeaWebsiteIconLookup $Form
    Assert-Gui ((Read-EeaManifest $Context 'My News').Url -ceq $originalUrl -and $ui.StatusLabel.Text.StartsWith('Saved:') -and -not $ui.ActivitySpinner.IsBusy) 'Successful resolution must resume the explicitly requested save.'
    $ui.UrlInput.Text = $bareWebsite
    $script:NextIconRequest = New-GuiIconRequest $iconData -ResolvedWebsite $originalUrl
    $request = $script:NextIconRequest
    $savedNotes = $ui.NotesInput.Text
    $ui.SaveButton.PerformClick()
    $ui.NotesInput.Text = 'Still editing after save was requested.'
    $request.AsyncResult.IsCompleted = $true
    Complete-EeaWebsiteIconLookup $Form
    Assert-Gui ((Read-EeaManifest $Context 'My News').Notes -ceq $savedNotes -and -not $ui.StatusLabel.Text.StartsWith('Saved:')) 'Edits made during resolution must not be saved by an older pending action.'
    $ui.NotesInput.Text = $savedNotes
    $savedSessionChoice = Get-EeaStateFreshSession (Read-EeaManifest $Context 'My News')
    $ui.UrlInput.Text = $bareWebsite
    $script:NextIconRequest = New-GuiIconRequest $iconData -ResolvedWebsite $originalUrl
    $request = $script:NextIconRequest
    $ui.SaveButton.PerformClick()
    $ui.FreshSessionCheck.Checked = -not $savedSessionChoice
    $request.AsyncResult.IsCompleted = $true
    Complete-EeaWebsiteIconLookup $Form
    Assert-Gui ((Get-EeaStateFreshSession (Read-EeaManifest $Context 'My News')) -eq $savedSessionChoice -and -not $ui.StatusLabel.Text.StartsWith('Saved:')) 'Changing the privacy choice during address resolution must invalidate the pending save.'
    $ui.FreshSessionCheck.Checked = $savedSessionChoice
    $savedTaskbarChoice = Get-EeaStateTaskbar (Read-EeaManifest $Context 'My News')
    $ui.UrlInput.Text = $bareWebsite
    $script:NextIconRequest = New-GuiIconRequest $iconData -ResolvedWebsite $originalUrl
    $request = $script:NextIconRequest
    $requestCount = $script:PinRequests.Count
    $ui.SaveButton.PerformClick()
    $ui.TaskbarCheck.Checked = -not $savedTaskbarChoice
    $request.AsyncResult.IsCompleted = $true
    Complete-EeaWebsiteIconLookup $Form
    Assert-Gui ((Get-EeaStateTaskbar (Read-EeaManifest $Context 'My News')) -eq $savedTaskbarChoice -and $script:PinRequests.Count -eq $requestCount -and -not $ui.StatusLabel.Text.StartsWith('Saved:')) 'Changing taskbar intent during address resolution must invalidate the pending save without requesting a pin.'
    $ui.TaskbarCheck.Checked = $savedTaskbarChoice
    $previousApproval = $script:ApproveChange
    try {
        $script:ApproveChange = $false
        $ui.UrlInput.Text = $httpWebsite
        $ui.SaveButton.PerformClick()
        Assert-Gui ((Read-EeaManifest $Context 'My News').Url -ceq $originalUrl) 'Declining the unencrypted HTTP warning must leave saved shortcuts unchanged.'
        $script:ApproveChange = $true
        $ui.SaveButton.PerformClick()
        Assert-Gui ((Read-EeaManifest $Context 'My News').Url -ceq $httpWebsite) 'Explicit approval must allow an HTTP address to be saved and read back.'
        $ui.UrlInput.Text = $originalUrl
        $ui.SaveButton.PerformClick()
    }
    finally { $script:ApproveChange = $previousApproval }
    $script:NextIconRequest = $null
    Write-Host 'PASS: Website icon retrieval, preview, explicit save, cancellation, failure preservation, stale-result rejection, and saved-icon restoration without live network access.'
}

function Invoke-GuiTextKey {
    param($TextBox, [int]$KeyData)
    $keyEvent = New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]$KeyData)
    $onKeyDown = [Windows.Forms.Control].GetMethod('OnKeyDown', [Reflection.BindingFlags]'Instance, NonPublic')
    [void]$onKeyDown.Invoke($TextBox, [object[]]@($keyEvent.PSObject.BaseObject))
    return $keyEvent
}

function Get-GuiBitmapBytes {
    param($Bitmap)
    $data = $Bitmap.LockBits((New-Object Drawing.Rectangle([Drawing.Point]::Empty, $Bitmap.Size)), [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    try {
        $bytes = New-Object byte[] ([Math]::Abs($data.Stride) * $Bitmap.Height)
        [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        return ,$bytes
    }
    finally { $Bitmap.UnlockBits($data) }
}

function Test-GuiNativeTypeReload {
    if (-not ('EasyEdgeApps.StarfieldRenderer' -as [type])) {
        Add-Type -TypeDefinition 'namespace EasyEdgeApps { public sealed class StarfieldRenderer { } }' -ErrorAction Stop
    }
    $checkBox = New-EeaCheckBox 'Motion' -Icon Motion
    try {
        $uiNamespace = Initialize-EeaSpaceBackground
        Assert-Gui ($checkBox -is [Windows.Forms.CheckBox] -and $checkBox.GetType().Namespace -ceq $uiNamespace) 'An older renderer already in memory must not prevent the current checkbox from loading.'
        foreach ($typeName in @('StarfieldRenderer', 'StarfieldForm', 'SpaceTableLayoutPanel', 'SpaceFlowLayoutPanel', 'SpacePanel', 'LoadingSpinner', 'IconCheckBox')) {
            Assert-Gui ($null -ne (($uiNamespace + '.' + $typeName) -as [type])) ('The current UI assembly must include ' + $typeName)
        }
        Assert-Gui ((Initialize-EeaSpaceBackground) -ceq $uiNamespace) 'Identical UI source must reuse its loaded assembly.'
        $definition = (Get-Command Initialize-EeaSpaceBackground).Definition
        $changedDefinition = $definition.Replace('private bool disposed;', "private bool disposed;`n")
        Assert-Gui ($changedDefinition -cne $definition) 'The reload test must change the embedded UI source.'
        $newNamespace = & ([scriptblock]::Create($changedDefinition))
        Assert-Gui ($newNamespace -cne $uiNamespace -and $null -ne (($newNamespace + '.IconCheckBox') -as [type])) 'Changed UI source must load a complete new version without restarting PowerShell.'
        Assert-Gui ((Initialize-EeaSpaceBackground) -ceq $uiNamespace) 'A separate source version must not change the original initializer or its cached types.'
        Write-Host 'PASS: Older partial UI assemblies, repeated initialization, and changed-source reload in the same PowerShell process.'
    }
    finally { $checkBox.Dispose() }
}

function Test-GuiSpaceRenderer {
    $uiNamespace = Initialize-EeaSpaceBackground
    $renderer = New-Object ($uiNamespace + '.StarfieldRenderer')
    $bitmap = New-Object Drawing.Bitmap(960, 640, [Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $center = New-Object Drawing.PointF(0.5, 0.5)
        $renderer.Render($graphics, $bitmap.Size, 0, $center, 0)
        $first = Get-GuiBitmapBytes $bitmap
        $renderer.Render($graphics, $bitmap.Size, 1, $center, 0)
        $later = Get-GuiBitmapBytes $bitmap
        $renderer.Render($graphics, $bitmap.Size, 0, (New-Object Drawing.PointF(0.85, 0.2)), 0)
        $ignoredPointer = Get-GuiBitmapBytes $bitmap
        Assert-Gui ([Convert]::ToBase64String($hash.ComputeHash($first)) -ceq [Convert]::ToBase64String($hash.ComputeHash($ignoredPointer))) 'Zero pointer influence must ignore the mouse completely.'
        $renderer.Render($graphics, $bitmap.Size, 0, (New-Object Drawing.PointF(0.85, 0.2)), 1)
        $hovered = Get-GuiBitmapBytes $bitmap
        $motionChanges = 0
        $hoverChanges = 0
        $brightSamples = 0
        $stationarySamples = 0
        $sectorSamples = New-Object int[] 16
        for ($vertical = 0; $vertical -lt $bitmap.Height; $vertical += 3) {
            for ($horizontal = 0; $horizontal -lt $bitmap.Width; $horizontal += 3) {
                $offset = ($vertical * $bitmap.Width + $horizontal) * 4
                if ([BitConverter]::ToInt32($first, $offset) -ne [BitConverter]::ToInt32($later, $offset)) { $motionChanges++ }
                if ([BitConverter]::ToInt32($first, $offset) -ne [BitConverter]::ToInt32($hovered, $offset)) { $hoverChanges++ }
                if ($first[$offset + 1] -gt 65) {
                    $brightSamples++
                    $sector = [int][Math]::Floor($vertical * 4.0 / $bitmap.Height) * 4 + [int][Math]::Floor($horizontal * 4.0 / $bitmap.Width)
                    $sectorSamples[$sector]++
                    if ($later[$offset + 1] -gt 65) { $stationarySamples++ }
                }
            }
        }
        $averageSectorSamples = $brightSamples / 16.0
        foreach ($sectorSample in $sectorSamples) {
            Assert-Gui ($sectorSample -gt $averageSectorSamples / 3 -and $sectorSample -lt $averageSectorSamples * 2) 'Stars must be scattered across the viewport without a concentrated galaxy core or empty outer regions.'
        }
        Assert-Gui ($motionChanges -gt 1000 -and $brightSamples -gt 100 -and $stationarySamples -lt $brightSamples * 0.35) 'Stars must drift noticeably within one second without mouse input, not only change brightness.'
        Assert-Gui ($hoverChanges -gt 1000) 'Pointer movement must add a separate layered parallax response.'
        $renderer.Render($graphics, $bitmap.Size, 0, $center, 0)
        $repeated = Get-GuiBitmapBytes $bitmap
        Assert-Gui ([Convert]::ToBase64String($hash.ComputeHash($first)) -ceq [Convert]::ToBase64String($hash.ComputeHash($repeated))) 'Rendering the same paused state must be stable.'
        foreach ($size in @((New-Object Drawing.Size(480, 320)), (New-Object Drawing.Size(1920, 1080)))) {
            $resized = New-Object Drawing.Bitmap($size.Width, $size.Height)
            $resizedGraphics = [Drawing.Graphics]::FromImage($resized)
            try {
                $renderer.Render($resizedGraphics, $size, 8, $center, 0)
                $resizedBytes = Get-GuiBitmapBytes $resized
                $quadrantSamples = New-Object int[] 4
                for ($vertical = 0; $vertical -lt $size.Height; $vertical += 8) {
                    for ($horizontal = 0; $horizontal -lt $size.Width; $horizontal += 8) {
                        $offset = ($vertical * $size.Width + $horizontal) * 4
                        if ($resizedBytes[$offset + 1] -gt 65) {
                            $quadrant = [int][Math]::Floor($vertical * 2.0 / $size.Height) * 2 + [int][Math]::Floor($horizontal * 2.0 / $size.Width)
                            $quadrantSamples[$quadrant]++
                        }
                    }
                }
                foreach ($quadrantSample in $quadrantSamples) {
                    Assert-Gui ($quadrantSample -gt 3) 'Scattered stars must remain visible across every quadrant of compact and full-HD viewports.'
                }
            }
            finally { $resizedGraphics.Dispose(); $resized.Dispose() }
        }
        Write-Host 'PASS: Scattered stars without a galaxy core, autonomous drift, independent parallax, stable pause frames, and compact/full-HD rendering.'
    }
    finally { $hash.Dispose(); $graphics.Dispose(); $bitmap.Dispose(); $renderer.Dispose(); $renderer.Dispose() }
}

function Invoke-GuiFormEvent {
    param($Form, [string]$Method)
    $methodInfo = $Form.GetType().GetMethod($Method, [Reflection.BindingFlags]'Instance, NonPublic')
    [void]$methodInfo.Invoke($Form, [object[]]@([EventArgs]::Empty))
}

function Test-GuiSpaceComposition {
    param($Form)
    $originalSize = $Form.ClientSize
    $Form.MotionEnabled = $false
    try {
        foreach ($size in @((New-Object Drawing.Size(1936, 1089)), (New-Object Drawing.Size(3840, 2160)))) {
            $Form.ClientSize = $size
            $Form.PerformLayout()
            $Form.RefreshScene()
            $bitmap = New-Object Drawing.Bitmap($size.Width, $size.Height)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $surface = $Form.Tag.EditorViewport
            $fragment = New-Object Drawing.Bitmap($surface.Width, $surface.Height)
            $fragmentGraphics = [Drawing.Graphics]::FromImage($fragment)
            try {
                Assert-Gui ($Form.PaintScene($Form, $graphics)) 'A realized large window must have a paintable background.'
                foreach ($corner in @((New-Object Drawing.Point(0, 0)), (New-Object Drawing.Point(($size.Width - 1), ($size.Height - 1))))) {
                    Assert-Gui ($bitmap.GetPixel($corner.X, $corner.Y).A -eq 255) 'Scaled starfield edges must remain fully opaque.'
                }
                $clip = New-Object Drawing.Rectangle(13, 17, 96, 80)
                $sentinel = [Drawing.Color]::Magenta
                $fragmentGraphics.Clear($sentinel)
                $originalInterpolation = $fragmentGraphics.InterpolationMode
                $originalOffset = $fragmentGraphics.PixelOffsetMode
                $originalCompositing = $fragmentGraphics.CompositingMode
                Assert-Gui ($Form.PaintScene($surface, $fragmentGraphics, $clip)) 'Partial invalidation must paint the requested scene fragment.'
                Assert-Gui ($fragmentGraphics.InterpolationMode -eq $originalInterpolation -and $fragmentGraphics.PixelOffsetMode -eq $originalOffset -and $fragmentGraphics.CompositingMode -eq $originalCompositing) 'Background painting must restore graphics state for foreground controls.'
                Assert-Gui ($fragment.GetPixel(0, 0).ToArgb() -eq $sentinel.ToArgb() -and $fragment.GetPixel($clip.Right, $clip.Bottom).ToArgb() -eq $sentinel.ToArgb()) 'Partial painting must not touch pixels outside the invalid rectangle.'
                $origin = $Form.PointToClient($surface.PointToScreen([Drawing.Point]::Empty))
                for ($vertical = $clip.Top; $vertical -lt $clip.Bottom; $vertical += 3) {
                    for ($horizontal = $clip.Left; $horizontal -lt $clip.Right; $horizontal += 3) {
                        Assert-Gui ($fragment.GetPixel($horizontal, $vertical).ToArgb() -eq $bitmap.GetPixel($origin.X + $horizontal, $origin.Y + $vertical).ToArgb()) 'Nested and clipped surfaces must sample the same scene pixels without seams.'
                    }
                }
                $paintField = $Form.GetType().GetField('paintMilliseconds', [Reflection.BindingFlags]'Instance, NonPublic')
                Assert-Gui ($null -ne $paintField -and $paintField.GetValue($Form) -gt 0) 'The frame budget must account for actual background painting as well as generation.'
                $paintField.SetValue($Form, [double]40)
                $Form.RefreshScene()
                $timer = $Form.GetType().GetField('animationTimer', [Reflection.BindingFlags]'Instance, NonPublic').GetValue($Form)
                Assert-Gui ($timer.Interval -eq 100 -and $paintField.GetValue($Form) -eq 0) 'An expensive painted frame must back off within the existing interval limit and reset its cost for the next frame.'
            }
            finally { $fragmentGraphics.Dispose(); $fragment.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
        }
    }
    finally { $Form.ClientSize = $originalSize }
    Write-Host 'PASS: Above-cap and 4K scene opacity, clipped paint, panel alignment, and graphics-state restoration.'
}

function Test-GuiSpaceLifecycle {
    param($Form)
    $preferences = $Form.GetType().GetMethod('ApplyPreferences', [Reflection.BindingFlags]'Instance, NonPublic')
    try {
        [void]$preferences.Invoke($Form, [object[]]@($false, $true, $false))
        $Form.MotionEnabled = $true
        Invoke-GuiFormEvent $Form 'OnActivated'
        Assert-Gui $Form.IsAnimationRunning 'An active window must animate without requiring mouse events.'
        $initialTime = $Form.SceneTime
        $advanceClock = [Diagnostics.Stopwatch]::StartNew()
        while ($Form.SceneTime -le $initialTime -and $advanceClock.ElapsedMilliseconds -lt 2000 -and $Form.IsAnimationRunning) {
            [Windows.Forms.Application]::DoEvents()
        }
        $advanceClock.Stop()
        Assert-Gui ($Form.SceneTime -gt $initialTime) ('The timer must advance the scene independently of the mouse. Running: ' + $Form.IsAnimationRunning + '; elapsed milliseconds: ' + $advanceClock.ElapsedMilliseconds)
        $Form.Tag.MotionCheck.Checked = $false
        Assert-Gui (-not $Form.MotionEnabled -and -not $Form.IsAnimationRunning) 'The Motion checkbox must pause the timer.'
        Assert-Gui (-not (Get-EeaSettings -Context $Form.Tag.Context).MotionEnabled) 'An explicit Motion toggle must persist the paused preference.'
        $Form.Tag.MotionCheck.Checked = $true
        $settingsPath = Join-Path $Form.Tag.Context.Root 'settings.json'
        $settingsHash = (Get-FileHash -LiteralPath $settingsPath).Hash
        Invoke-GuiFormEvent $Form 'OnMouseLeave'
        Invoke-GuiFormEvent $Form 'OnDeactivate'
        Assert-Gui $Form.IsAnimationRunning 'A visible window must keep animating after the mouse leaves and focus moves elsewhere.'
        $initialTime = $Form.SceneTime
        $advanceClock.Restart()
        while ($Form.SceneTime -le $initialTime -and $advanceClock.ElapsedMilliseconds -lt 2000 -and $Form.IsAnimationRunning) {
            [Windows.Forms.Application]::DoEvents()
        }
        $advanceClock.Stop()
        Assert-Gui ($Form.SceneTime -gt $initialTime) 'The scene must advance in a visible, unfocused window without mouse input.'
        Invoke-GuiFormEvent $Form 'OnActivated'
        Invoke-GuiFormEvent $Form 'OnResizeBegin'
        Assert-Gui (-not $Form.IsAnimationRunning) 'Live resizing must pause animation.'
        Invoke-GuiFormEvent $Form 'OnResizeEnd'
        Assert-Gui $Form.IsAnimationRunning 'Animation must resume when resizing ends.'
        $Form.WindowState = [Windows.Forms.FormWindowState]::Minimized
        [Windows.Forms.Application]::DoEvents()
        Assert-Gui (-not $Form.IsAnimationRunning) 'Minimized windows must stop the animation timer.'
        $Form.WindowState = [Windows.Forms.FormWindowState]::Normal
        Invoke-GuiFormEvent $Form 'OnActivated'
        $Form.Hide()
        Assert-Gui (-not $Form.IsAnimationRunning) 'Hidden windows must stop the animation timer.'
        $Form.Show()
        Invoke-GuiFormEvent $Form 'OnActivated'
        Assert-Gui $Form.IsAnimationRunning 'A restored active window must resume animation.'
        [void]$preferences.Invoke($Form, [object[]]@($false, $false, $false))
        Assert-Gui ($Form.SceneEnabled -and -not $Form.MotionAvailable -and -not $Form.IsAnimationRunning -and -not $Form.Tag.MotionCheck.Enabled) 'Reduced-motion preferences must preserve a still background and disable animation.'
        [void]$preferences.Invoke($Form, [object[]]@($false, $true, $true))
        Assert-Gui (-not $Form.MotionAvailable -and -not $Form.IsAnimationRunning) 'Remote sessions must use a still background.'
        [void]$preferences.Invoke($Form, [object[]]@($true, $true, $false))
        Assert-Gui (-not $Form.SceneEnabled -and -not $Form.IsAnimationRunning -and $Form.BackColor -eq [Drawing.SystemColors]::Window -and $Form.Tag.NameInput.BackColor -eq [Drawing.SystemColors]::Window) 'High contrast must remove decorative rendering and restore system-colored controls.'
        Assert-Gui $Form.MotionEnabled 'Accessibility changes must not overwrite the user motion preference.'
        Assert-Gui ((Get-EeaSettings -Context $Form.Tag.Context).MotionEnabled -and (Get-FileHash -LiteralPath $settingsPath).Hash -ceq $settingsHash) 'Programmatic accessibility synchronization must not rewrite the saved Motion preference.'
        Write-Host 'PASS: Animation without mouse input or focus, pause/resume, resize/hidden/minimized suspension, and simulated accessibility/remote preferences.'
    }
    finally { $Form.RefreshPreferences(); $Form.MotionEnabled = $false }
}

function Assert-ControlLayout {
    param($Control)
    foreach ($childControl in $Control.Controls) {
        if (-not $childControl.Visible) { continue }
        Assert-Gui ($childControl.Width -gt 0 -and $childControl.Height -gt 0) ('Empty control: ' + $childControl.Text)
        if ($Control -isnot [Windows.Forms.FlowLayoutPanel] -and -not $Control.AutoScroll) {
            $layoutDetail = '{0} in {1}: {2}, parent client {3}' -f $childControl.GetType().Name, $Control.GetType().Name, $childControl.Bounds, $Control.ClientSize
            Assert-Gui ($childControl.Right -le $Control.ClientSize.Width + 2) ('Right clipping: ' + $layoutDetail)
            Assert-Gui ($childControl.Bottom -le $Control.ClientSize.Height + 2) ('Bottom clipping: ' + $layoutDetail)
        }
        elseif ($Control -is [Windows.Forms.ScrollableControl] -and $Control.AutoScroll) {
            if ($childControl.Bottom -gt $Control.ClientSize.Height + 2) {
                Assert-Gui $Control.VerticalScroll.Visible 'Overflowing content must have a usable vertical scrollbar.'
            }
        }
        if ($childControl -is [Windows.Forms.Button]) {
            Assert-Gui ($null -ne $childControl.Image -and $childControl.Image.Width -ge 16) ('Missing command icon: ' + $childControl.Text)
            $textSize = [Windows.Forms.TextRenderer]::MeasureText($childControl.Text.Replace('&', ''), $childControl.Font)
            Assert-Gui ($textSize.Width + $childControl.Image.Width + $childControl.Padding.Horizontal -le $childControl.ClientSize.Width) ('Button icon/text clipping: ' + $childControl.Text)
        }
        if ($childControl -is [Windows.Forms.Label] -and $childControl.Text -cne 'Easy Edge Apps') {
            Assert-Gui ($childControl.Tag -is [Drawing.Image] -and $childControl.Padding.Left -gt $childControl.Tag.Width -and $childControl.Height -ge $childControl.Tag.Height) ('Label icon must have a separate text margin: ' + $childControl.Text)
        }
        if ($childControl -is [Windows.Forms.CheckBox]) {
            Assert-Gui ($null -ne $childControl.Image) ('Missing selection icon: ' + $childControl.Text)
            $textSize = [Windows.Forms.TextRenderer]::MeasureText($childControl.Text.Replace('&', ''), $childControl.Font)
            Assert-Gui ($textSize.Width + $childControl.Image.Width + 18 -le $childControl.ClientSize.Width) ('Clipped checkbox icon or caption: ' + $childControl.Text)
        }
        Assert-ControlLayout $childControl
    }
}

function Test-GuiSavedStartup {
    $startupContext = [pscustomobject]@{
        Root = Join-Path $testRoot 'StartupSettings'
        Desktop = Join-Path $testRoot 'StartupDesktop'
        Programs = Join-Path $testRoot 'StartupPrograms'
    }
    foreach ($pointSize in @(12, 14, 16, 18)) {
        $settings = New-EeaSettings
        $settings.TextSize = $pointSize
        $settings.MotionEnabled = $false
        $null = Save-EeaSettings -Settings $settings -Context $startupContext -Confirm:$false
        $startup = New-EeaSetupForm -Context $startupContext
        try {
            $startup.StartPosition = [Windows.Forms.FormStartPosition]::Manual
            $startup.Location = New-Object Drawing.Point(-10000, -10000)
            $startup.ShowInTaskbar = $false
            $startup.Show()
            [Windows.Forms.Application]::DoEvents()
            $viewport = $startup.Tag.EditorViewport
            $workArea = [Windows.Forms.Screen]::FromControl($startup).WorkingArea
            Assert-Gui ($startup.Width -le $workArea.Width -and $startup.Height -le $workArea.Height) 'Saved-font startup must fit the current monitor working area.'
            Assert-Gui ($startup.ActiveControl -eq $startup.Tag.NameInput) 'Fresh startup must put keyboard focus in the website name.'
            $requiredGrowth = [Math]::Max(0, $viewport.AutoScrollMinSize.Height - $viewport.ClientSize.Height)
            if ($startup.Height + $requiredGrowth -lt $workArea.Height) {
                Assert-Gui (-not $viewport.VerticalScroll.Visible) ('Saved-font startup must avoid scrolling when the screen has room: ' + $pointSize)
                $saveBounds = $viewport.RectangleToClient($startup.Tag.SaveButton.RectangleToScreen($startup.Tag.SaveButton.ClientRectangle))
                Assert-Gui ($viewport.ClientRectangle.Contains($saveBounds)) 'The primary action must be visible immediately after saved-font startup.'
            }
            $smallArea = New-Object Drawing.Rectangle(-10000, -10000, 900, 650)
            Set-EeaSetupWindowSize -Form $startup -WorkingArea $smallArea -Center
            Assert-Gui ($smallArea.Contains($startup.Bounds)) 'A smaller working area must clamp minimum size and keep the whole window reachable.'
            Assert-Gui $viewport.VerticalScroll.Visible 'Compact displays must retain the editor scrolling fallback.'
            $startup.ActiveControl = $startup.Tag.UrlInput
            $settings.TextSize = 18
            Set-EeaFormPreferences -Form $startup -Settings $settings
            Assert-Gui ($startup.Width -le $workArea.Width -and $startup.Height -le $workArea.Height -and $startup.ActiveControl -eq $startup.Tag.UrlInput) 'Preference scaling must fit the monitor without moving keyboard focus.'
        }
        finally { $startup.Dispose() }
    }
    Write-Host 'PASS: Saved-font startup, monitor bounds, initial focus, compact scrolling, and preference resizing.'
}

try {
    Test-GuiNativeTypeReload
    Test-GuiSavedStartup
    $form = New-EeaSetupForm -Context $context
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object Drawing.Point(-10000, -10000)
    $form.ShowInTaskbar = $false
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $ui = $form.Tag
    Assert-Gui (-not (Test-Path -LiteralPath $context.Root)) 'Opening setup must not create app data.'
    Assert-Gui (-not $ui.TaskbarCheck.Checked) 'Taskbar placement must be opt-in for a new website.'
    Assert-Gui (-not $ui.FreshSessionCheck.Checked -and $ui.FreshSessionCheck.AccessibleDescription.Contains('cookies, cache') -and $ui.FreshSessionCheck.Image.Tag -ceq 'Privacy') 'Fresh sessions must be an accessible, clearly described opt-in website setting.'
    Assert-Gui ($script:PinRequests.Count -eq 0) 'Opening setup must not request a taskbar pin.'
    Test-GuiSpaceRenderer
    Test-GuiSpaceComposition $form
    Test-GuiSpaceLifecycle $form
    Assert-Gui ($ui.AppList.Items.Count -eq 0) 'New setup should have no websites.'
    Assert-Gui ($null -ne $form.Icon -and $form.Icon.Width -eq 64 -and $ui.BrandPicture.Image.Width -eq 64) 'Use the embedded logo for the application icon and header.'
    $coloredPixels = 0
    for ($pixelY = 0; $pixelY -lt 64; $pixelY++) {
        for ($pixelX = 0; $pixelX -lt 64; $pixelX++) {
            $pixel = $ui.BrandPicture.Image.GetPixel($pixelX, $pixelY)
            if ($pixel.A -gt 128 -and $pixel.B -gt $pixel.R + 40) { $coloredPixels++ }
        }
    }
    Assert-Gui ($coloredPixels -gt 1000) 'The supplied blue and cyan logo must render visibly, not a blank or fallback icon.'
    $symbolPixels = 0
    for ($pixelY = 0; $pixelY -lt $ui.ExportButton.Image.Height; $pixelY++) {
        for ($pixelX = 0; $pixelX -lt $ui.ExportButton.Image.Width; $pixelX++) {
            if ($ui.ExportButton.Image.GetPixel($pixelX, $pixelY).A -gt 0) { $symbolPixels++ }
        }
    }
    Assert-Gui ($symbolPixels -gt 10) 'Windows command icons must render nonblank pixels.'
    Assert-Gui ($ui.SaveButton.BackColor -eq [Drawing.SystemColors]::Highlight -and $ui.SaveButton.ForeColor -eq [Drawing.SystemColors]::HighlightText) 'The primary action must use accessible Windows selection colors.'
    Assert-Gui ($null -ne $form.AcceptButton -and $null -ne $form.CancelButton) 'Enter and Escape need default actions.'
    $wordBackspace = [Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Back
    foreach ($textInput in @($ui.NameInput, $ui.UrlInput, $ui.NotesInput)) {
        $textInput.Text = 'First second'
        $textInput.Select($textInput.TextLength, 0)
        $keyEvent = Invoke-GuiTextKey $textInput $wordBackspace
        Assert-Gui ($keyEvent.SuppressKeyPress -and $textInput.Text -ceq 'First ' -and $textInput.SelectionStart -eq 6) 'Ctrl+Backspace must delete the previous word and suppress the native control character in every setup input.'
        Assert-Gui $textInput.CanUndo 'Word deletion must remain undoable.'
        $textInput.Undo()
        Assert-Gui ($textInput.Text -ceq 'First second') 'Undo must restore the deleted word.'
    }
    foreach ($case in @(
        [pscustomobject]@{ Text = ''; Start = 0; Length = 0; Expected = ''; Caret = 0 },
        [pscustomobject]@{ Text = 'First second'; Start = 0; Length = 0; Expected = 'First second'; Caret = 0 },
        [pscustomobject]@{ Text = '   '; Start = 3; Length = 0; Expected = ''; Caret = 0 },
        [pscustomobject]@{ Text = 'First second   '; Start = 15; Length = 0; Expected = 'First '; Caret = 6 },
        [pscustomobject]@{ Text = 'First second third'; Start = 9; Length = 0; Expected = 'First ond third'; Caret = 6 },
        [pscustomobject]@{ Text = 'First second third'; Start = 6; Length = 6; Expected = 'First  third'; Caret = 6 },
        [pscustomobject]@{ Text = ('First ' + [char]0x7f + [char]0x7f); Start = 8; Length = 0; Expected = 'First '; Caret = 6 }
    )) {
        $ui.NameInput.Text = $case.Text
        $ui.NameInput.Select($case.Start, $case.Length)
        $keyEvent = Invoke-GuiTextKey $ui.NameInput $wordBackspace
        Assert-Gui ($keyEvent.SuppressKeyPress -and $ui.NameInput.Text -ceq $case.Expected -and $ui.NameInput.SelectionStart -eq $case.Caret -and $ui.NameInput.SelectionLength -eq 0) 'Word deletion must handle empty text, start of text, whitespace, mid-word carets, selections, and existing control characters.'
    }
    $ui.NotesInput.Text = "First line`r`nSecond`tword"
    $ui.NotesInput.Select($ui.NotesInput.TextLength, 0)
    $null = Invoke-GuiTextKey $ui.NotesInput $wordBackspace
    Assert-Gui ($ui.NotesInput.Text -ceq "First line`r`nSecond`t") 'Multiline word deletion must preserve unrelated lines and tabs.'
    $ui.NameInput.Text = 'First' + [char]0xa0 + [char]0xe9 + [char]0x301 + [char]0xd83d + [char]0xde00 + [char]0x3000
    $ui.NameInput.Select($ui.NameInput.TextLength, 0)
    $null = Invoke-GuiTextKey $ui.NameInput $wordBackspace
    Assert-Gui ($ui.NameInput.Text -ceq ('First' + [char]0xa0)) 'Word deletion must handle Unicode whitespace and keep unrelated combining marks and surrogate pairs intact.'
    $ui.NameInput.Text = 'First second'
    $ui.NameInput.Select(6, 6)
    $ui.NameInput.ReadOnly = $true
    $keyEvent = Invoke-GuiTextKey $ui.NameInput $wordBackspace
    Assert-Gui ($keyEvent.SuppressKeyPress -and $ui.NameInput.Text -ceq 'First second') 'Read-only app names must never be changed by word deletion.'
    $ui.NameInput.ReadOnly = $false
    foreach ($keyData in @([Windows.Forms.Keys]::Back, ([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Alt -bor [Windows.Forms.Keys]::Back))) {
        $keyEvent = Invoke-GuiTextKey $ui.NameInput $keyData
        Assert-Gui (-not $keyEvent.SuppressKeyPress -and $ui.NameInput.Text -ceq 'First second') 'Ordinary Backspace and Alt-modified keys must remain native.'
    }
    Write-Host 'PASS: Ctrl+Backspace word deletion, selections, caret bounds, read-only inputs, multiline text, undo, and control-character suppression.'
    $ui.NameInput.Text = 'My News'
    $ui.UrlInput.Text = 'https://example.com/#/home'
    $ui.NotesInput.Text = 'Plain-text helper notes.'
    $ui.SaveButton.PerformClick()
    Assert-Gui ($ui.StatusLabel.Text -eq 'Saved: My News') 'The Add website button must complete installation.'
    Assert-Gui ($ui.AppList.Items.Count -eq 1) 'The saved website must appear in the list.'
    Assert-Gui ((Read-EeaManifest $context 'My News').Notes -ceq 'Plain-text helper notes.') 'Helper notes must be saved through the normal editor.'
    Assert-Gui ($ui.AppList.GetItemText($ui.AppList.Items[0]) -eq 'My News') 'Website list must show the friendly name.'
    Assert-Gui ($ui.NameInput.ReadOnly -and $ui.OpenButton.Enabled -and $ui.RemoveButton.Enabled) 'Selection must enable the correct actions.'
    Assert-Gui ($ui.SaveButton.Image.Tag -ceq 'Save') 'Selecting a saved app must show the save command icon.'
    Assert-Gui ($null -ne $ui.IconPreview.Image) 'A generated icon must render in the setup window.'
    Test-GuiTaskbar -Form $form -Context $context
    Test-GuiWebsiteIcon -Form $form -Context $context
    $ui.UrlInput.Text = 'https://example.com/updated#/home'
    $ui.SaveButton.PerformClick()
    Assert-Gui ((Read-EeaManifest $context 'My News').Url -eq 'https://example.com/updated#/home') 'Save changes must update the website.'
    $ui.FreshSessionCheck.Checked = $true
    $ui.SaveButton.PerformClick()
    Assert-Gui (-not (Get-EeaStateFreshSession (Read-EeaManifest $context 'My News'))) 'Declining the session-mode confirmation must preserve normal browsing.'
    $script:ApproveChange = $true
    $ui.SaveButton.PerformClick()
    Assert-Gui ((Get-EeaStateFreshSession (Read-EeaManifest $context 'My News')) -and $ui.FreshSessionCheck.Checked) 'Approved fresh-session changes must persist and reload into the editor.'
    $ui.NewButton.PerformClick()
    Assert-Gui (-not $ui.FreshSessionCheck.Checked) 'New websites must not inherit another website session choice.'
    $ui.AppList.SelectedIndex = 0
    Assert-Gui ($ui.FreshSessionCheck.Checked) 'Selecting a saved fresh-session website must restore its checkbox.'
    $ui.FreshSessionCheck.Checked = $false
    $ui.SaveButton.PerformClick()
    Assert-Gui (-not (Get-EeaStateFreshSession (Read-EeaManifest $context 'My News'))) 'Approved opt-out must restore the ordinary launch path.'
    $script:ApproveChange = $false
    Write-Host 'PASS: Fresh-session opt-in, declined/approved mode changes, saved selection, reset, and opt-out.'
    $ui.RemoveButton.PerformClick()
    Assert-Gui ($ui.AppList.Items.Count -eq 1) 'Declining removal must keep the saved website.'
    Assert-Gui ($null -ne (Read-EeaManifest $context 'My News')) 'Declining removal must keep saved settings.'
    foreach ($pointSize in @(12, 18, 24)) {
        $form.Font = New-Object Drawing.Font('Segoe UI', $pointSize)
        $form.PerformAutoScale()
        if ($MaximumWindowWidth -gt 0 -and $MaximumWindowHeight -gt 0) {
            $form.MaximumSize = New-Object Drawing.Size($MaximumWindowWidth, $MaximumWindowHeight)
            Assert-Gui ($form.Width -le $MaximumWindowWidth -and $form.Height -le $MaximumWindowHeight) 'The test window must respect the requested screen limit.'
        }
        $form.PerformLayout()
        [Windows.Forms.Application]::DoEvents()
        Assert-ControlLayout $form
        $brandBounds = $form.RectangleToClient($ui.BrandPicture.RectangleToScreen($ui.BrandPicture.ClientRectangle))
        Assert-Gui ($form.ClientRectangle.Contains($brandBounds)) 'The application logo must stay visible at large text sizes.'
        if ($pointSize -eq 12) {
            $ui.EditorViewport.AutoScrollPosition = New-Object Drawing.Point(0, 0)
            [Windows.Forms.Application]::DoEvents()
            $heightLimit = [Windows.Forms.Screen]::FromControl($form).WorkingArea.Height
            if ($MaximumWindowHeight -gt 0) { $heightLimit = [Math]::Min($heightLimit, $MaximumWindowHeight) }
            $requiredGrowth = [Math]::Max(0, $ui.EditorViewport.AutoScrollMinSize.Height - $ui.EditorViewport.ClientSize.Height)
            if ($form.Height + $requiredGrowth -gt $heightLimit) {
                Assert-Gui ($form.Height -eq $heightLimit -and $ui.EditorViewport.VerticalScroll.Visible) 'A compact default layout must use the available height and retain scrolling.'
                Write-Host ('PASS: Compact default layout retains scrolling within the ' + $heightLimit + '-pixel height limit.')
            }
            else {
                foreach ($control in @($ui.TaskbarCheck, $ui.FreshSessionCheck, $ui.SaveButton, $ui.OpenButton, $ui.RemoveButton)) {
                    $bounds = $ui.EditorViewport.RectangleToClient($control.RectangleToScreen($control.ClientRectangle))
                    Assert-Gui ($ui.EditorViewport.ClientRectangle.Contains($bounds)) ('Default layout must show the privacy choice and website actions without scrolling when space permits: ' + $control.Text)
                }
            }
        }
        foreach ($requiredControl in @($ui.NameInput, $ui.UrlInput, $ui.NotesInput, $ui.DesktopCheck, $ui.StartMenuCheck, $ui.TaskbarCheck, $ui.FreshSessionCheck, $ui.DedicatedProfileCheck, $ui.LaunchModeCombo, $ui.AlwaysOnTopCheck, $ui.GetIconButton, $ui.CancelIconButton, $ui.ChooseIconButton, $ui.ClearIconButton, $ui.SaveButton, $ui.OpenButton, $ui.RemoveButton)) {
            $ui.EditorViewport.ScrollControlIntoView($requiredControl)
            [Windows.Forms.Application]::DoEvents()
            $controlBounds = $ui.EditorViewport.RectangleToClient($requiredControl.RectangleToScreen($requiredControl.ClientRectangle))
            Assert-Gui ($ui.EditorViewport.ClientRectangle.Contains($controlBounds)) ('Required control must be reachable: ' + $requiredControl.Text)
        }
        foreach ($toolButton in @($ui.ExportButton, $ui.ImportButton, $ui.FavoritesButton, $ui.CheckButton, $ui.CloseButton, $ui.MotionCheck, $ui.SettingsButton)) {
            $buttonBounds = $form.RectangleToClient($toolButton.RectangleToScreen($toolButton.ClientRectangle))
            Assert-Gui ($form.ClientRectangle.Contains($buttonBounds)) ('Tool command must be visible: ' + $toolButton.Text)
        }
        if ($ScreenshotDirectory) {
            [void][IO.Directory]::CreateDirectory($ScreenshotDirectory)
            $ui.EditorViewport.AutoScrollPosition = New-Object Drawing.Point(0, 0)
            [Windows.Forms.Application]::DoEvents()
            $capture = New-Object Drawing.Bitmap($form.Width, $form.Height)
            try {
                $form.DrawToBitmap($capture, (New-Object Drawing.Rectangle(0, 0, $capture.Width, $capture.Height)))
                $capture.Save((Join-Path $ScreenshotDirectory ("setup-font-$pointSize.png")), [Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $capture.Dispose() }
        }
        $savedStatus = $ui.StatusLabel.Text
        $ui.StatusLabel.Text = 'Saved. Windows could not offer a taskbar pin.'
        $form.PerformLayout()
        [Windows.Forms.Application]::DoEvents()
        Assert-ControlLayout $form
        foreach ($requiredControl in @($ui.NotesInput, $ui.TaskbarCheck, $ui.SaveButton)) {
            $ui.EditorViewport.ScrollControlIntoView($requiredControl)
            [Windows.Forms.Application]::DoEvents()
            $controlBounds = $ui.EditorViewport.RectangleToClient($requiredControl.RectangleToScreen($requiredControl.ClientRectangle))
            Assert-Gui ($ui.EditorViewport.ClientRectangle.Contains($controlBounds)) ('Taskbar instructions must preserve control reachability: ' + $requiredControl.Text)
        }
        $ui.StatusLabel.Text = $savedStatus
        Write-Host "PASS: Native setup layout at $pointSize-point text."
    }
    $ui.NewButton.PerformClick()
    Assert-Gui (-not $ui.NameInput.ReadOnly -and $ui.NameInput.Text -eq '') 'New website must reset the editor.'
    Assert-Gui ($ui.SaveButton.Image.Tag -ceq 'Add') 'A new app must restore the add command icon.'
    Assert-Gui (-not $ui.OpenButton.Enabled -and -not $ui.RemoveButton.Enabled -and -not $ui.TaskbarCheck.Checked) 'New website must not act on the previous selection.'
    $ui.NameInput.Text = 'My News'
    $ui.UrlInput.Text = 'https://example.com/unwanted-change'
    $ui.SaveButton.PerformClick()
    Assert-Gui ((Read-EeaManifest $context 'My News').Url -eq 'https://example.com/updated#/home') 'Declining replacement must preserve the existing website.'
    $ui.AppList.SelectedIndex = 0
    Assert-Gui ($ui.AppList.SelectedIndex -eq -1 -and $ui.UrlInput.Text -ceq 'https://example.com/unwanted-change') 'Declining selection must preserve the rejected replacement draft.'
    $script:ApproveChange = $true
    $ui.AppList.SelectedIndex = 0
    $ui.RemoveButton.PerformClick()
    Assert-Gui ($ui.AppList.Items.Count -eq 0) 'Confirmed removal must refresh the list.'
    Assert-Gui (-not $ui.TaskbarCheck.Checked) 'Removing a website must clear its taskbar choice from the editor.'
    Assert-Gui ($null -eq (Read-EeaManifest $context 'My News')) 'Confirmed removal must remove owned settings.'
    $ui.UrlInput.Text = 'https://example.com/'
    $script:NextIconRequest = New-GuiIconRequest ([byte[]]@(0))
    $request = $script:NextIconRequest
    $ui.GetIconButton.PerformClick()
    $form.Close()
    Assert-Gui ($form.Visible -and $ui.CloseAfterIconLookup -and $request.Cancellation.IsCancellationRequested) 'Closing during a lookup must cancel it without blocking the window message loop.'
    $request.AsyncResult.IsCompleted = $true
    Complete-EeaWebsiteIconLookup $form
    Assert-Gui ($form.IsDisposed -and $request.PowerShell.Disposed -and $null -eq $ui.IconRequest) 'A cancelled closing lookup must release its worker and close the form.'
    Write-Host "PASS: Native setup add, select, update, preview, keyboard defaults, reset, and confirmation outcomes on PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    if ($null -ne $form) {
        $form.Close()
        $form.Dispose()
        Assert-Gui (-not $form.IsAnimationRunning) 'Disposing setup must stop the animation timer.'
        foreach ($fieldName in @('renderer', 'frame')) {
            $field = $form.GetType().GetField($fieldName, [Reflection.BindingFlags]'Instance, NonPublic')
            Assert-Gui ($null -eq $field.GetValue($form)) 'Disposing setup must release its rendering resources.'
        }
    }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}