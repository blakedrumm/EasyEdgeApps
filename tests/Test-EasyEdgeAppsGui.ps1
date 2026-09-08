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

function New-GuiIconRequest {
    param([byte[]]$IconData, [switch]$Fail)
    $pipeline = [pscustomobject]@{ Bytes = $IconData; Fail = [bool]$Fail; Disposed = $false }
    $pipeline | Add-Member ScriptMethod EndInvoke {
        param($Pending)
        if ($this.Fail) { throw 'Synthetic website icon failure.' }
        return [pscustomobject]@{ Bytes = $this.Bytes; SourceUrl = 'https://example.com/favicon.ico' }
    }
    $pipeline | Add-Member ScriptMethod Stop { }
    $pipeline | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    return [pscustomobject]@{ Website = ''; PowerShell = $pipeline; AsyncResult = [pscustomobject]@{ IsCompleted = $false }; Cancellation = (New-Object Threading.CancellationTokenSource); Discard = $false }
}

function Start-EeaWebsiteIconRequest {
    param([string]$Website)
    $address = ConvertTo-EeaWebsite $Website
    Assert-Gui ($null -ne $script:NextIconRequest) 'GUI tests must never use a live website icon service.'
    $script:NextIconRequest.Website = $address
    return $script:NextIconRequest
}

function Test-GuiWebsiteIcon {
    param($Form, $Context)
    $ui = $Form.Tag
    $paths = Get-EeaPaths $Context 'My News'
    $originalUrl = $ui.UrlInput.Text
    $originalHash = (Get-FileHash -LiteralPath $paths.Icon).Hash
    $iconData = ConvertTo-EeaWebsiteIcon (Read-EeaCustomIcon $paths.Icon)
    $ui.UrlInput.Text = 'http://example.com/'
    $ui.GetIconButton.PerformClick()
    Assert-Gui ($null -eq $ui.IconRequest -and $ui.StatusLabel.Text.StartsWith('FAILED:')) 'Invalid website addresses must fail before starting network lookup.'
    $ui.UrlInput.Text = $originalUrl
    $script:NextIconRequest = New-GuiIconRequest $iconData
    $request = $script:NextIconRequest
    $ui.GetIconButton.PerformClick()
    Assert-Gui ($null -ne $ui.IconRequest -and -not $ui.GetIconButton.Enabled -and $ui.CancelIconButton.Enabled -and -not $ui.SaveButton.Enabled -and $ui.UrlInput.Enabled) 'Lookup must expose cancellation and keep the editor responsive while waiting.'
    Assert-Gui ((Get-FileHash -LiteralPath $paths.Icon).Hash -ceq $originalHash) 'Starting lookup must not change the saved icon.'
    $request.AsyncResult.IsCompleted = $true
    Complete-EeaWebsiteIconLookup $Form
    Assert-Gui ($null -eq $ui.IconRequest -and $request.PowerShell.Disposed -and $ui.SaveButton.Enabled -and $ui.GetIconButton.Enabled -and -not $ui.CancelIconButton.Enabled) 'Completed lookups must restore controls and dispose the worker.'
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
        Assert-Gui ((Read-EeaManifest $Context 'My News').IconHash -ceq $saved.IconHash) 'A failed or cancelled lookup must leave the saved icon unchanged.'
        if ($outcome -eq 'New') { Assert-Gui ($null -eq $ui.IconPreview.Image) 'A stale lookup must not put the previous site icon into a new editor.'; $ui.AppList.SelectedIndex = 0 }
        $ui.UrlInput.Text = $originalUrl
    }
    Set-EeaEditorIcon -Form $Form -IconData $iconData
    $ui.ClearIconButton.PerformClick()
    Assert-Gui ($null -eq $ui.WebsiteIconData -and $ui.IconLabel.Text -ceq 'Saved icon' -and $null -ne $ui.IconPreview.Image) 'Use saved icon must discard the retrieved image and restore the saved preview.'
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
        foreach ($typeName in @('StarfieldRenderer', 'StarfieldForm', 'SpaceTableLayoutPanel', 'SpaceFlowLayoutPanel', 'SpacePanel', 'IconCheckBox')) {
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
        $renderer.Render($graphics, $bitmap.Size, 20, $center, 0)
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
        Assert-Gui ($motionChanges -gt 1000 -and $brightSamples -gt 100 -and $stationarySamples -lt $brightSamples * 0.7) 'Stars must visibly change position on their own, not only change brightness or wait for mouse input.'
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
        $Form.Tag.MotionCheck.Checked = $true
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

try {
    Test-GuiNativeTypeReload
    $form = New-EeaSetupForm -Context $context
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object Drawing.Point(-10000, -10000)
    $form.ShowInTaskbar = $false
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $ui = $form.Tag
    Test-GuiSpaceRenderer
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
    Assert-Gui (-not (Test-Path -LiteralPath $context.Root)) 'Opening setup must not create app data.'
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
    Test-GuiWebsiteIcon -Form $form -Context $context
    $ui.UrlInput.Text = 'https://example.com/updated#/home'
    $ui.SaveButton.PerformClick()
    Assert-Gui ((Read-EeaManifest $context 'My News').Url -eq 'https://example.com/updated#/home') 'Save changes must update the website.'
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
        foreach ($requiredControl in @($ui.NameInput, $ui.UrlInput, $ui.NotesInput, $ui.GetIconButton, $ui.CancelIconButton, $ui.ChooseIconButton, $ui.ClearIconButton, $ui.SaveButton, $ui.OpenButton, $ui.RemoveButton)) {
            $ui.EditorViewport.ScrollControlIntoView($requiredControl)
            [Windows.Forms.Application]::DoEvents()
            $controlBounds = $ui.EditorViewport.RectangleToClient($requiredControl.RectangleToScreen($requiredControl.ClientRectangle))
            Assert-Gui ($ui.EditorViewport.ClientRectangle.Contains($controlBounds)) ('Required control must be reachable: ' + $requiredControl.Text)
        }
        foreach ($toolButton in @($ui.ExportButton, $ui.ImportButton, $ui.FavoritesButton, $ui.CheckButton, $ui.CloseButton, $ui.MotionCheck)) {
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
        Write-Host "PASS: Native setup layout at $pointSize-point text."
    }
    $ui.NewButton.PerformClick()
    Assert-Gui (-not $ui.NameInput.ReadOnly -and $ui.NameInput.Text -eq '') 'New website must reset the editor.'
    Assert-Gui ($ui.SaveButton.Image.Tag -ceq 'Add') 'A new app must restore the add command icon.'
    Assert-Gui (-not $ui.OpenButton.Enabled -and -not $ui.RemoveButton.Enabled) 'New website must not act on the previous selection.'
    $ui.NameInput.Text = 'My News'
    $ui.UrlInput.Text = 'https://example.com/unwanted-change'
    $ui.SaveButton.PerformClick()
    Assert-Gui ((Read-EeaManifest $context 'My News').Url -eq 'https://example.com/updated#/home') 'Declining replacement must preserve the existing website.'
    $ui.AppList.SelectedIndex = 0
    $script:ApproveChange = $true
    $ui.RemoveButton.PerformClick()
    Assert-Gui ($ui.AppList.Items.Count -eq 0) 'Confirmed removal must refresh the list.'
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