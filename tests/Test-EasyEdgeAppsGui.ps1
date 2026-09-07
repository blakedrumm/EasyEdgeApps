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
            $textSize = [Windows.Forms.TextRenderer]::MeasureText($childControl.Text.Replace('&', ''), $childControl.Font)
            Assert-Gui ($textSize.Width -le $childControl.ClientSize.Width) ('Button text clipping: ' + $childControl.Text)
        }
        Assert-ControlLayout $childControl
    }
}

try {
    $form = New-EeaSetupForm -Context $context
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object Drawing.Point(-10000, -10000)
    $form.ShowInTaskbar = $false
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $ui = $form.Tag
    Assert-Gui ($ui.AppList.Items.Count -eq 0) 'New setup should have no websites.'
    Assert-Gui (-not (Test-Path -LiteralPath $context.Root)) 'Opening setup must not create app data.'
    Assert-Gui ($null -ne $form.AcceptButton -and $null -ne $form.CancelButton) 'Enter and Escape need default actions.'
    $ui.NameInput.Text = 'My News'
    $ui.UrlInput.Text = 'https://example.com/#/home'
    $ui.SaveButton.PerformClick()
    Assert-Gui ($ui.StatusLabel.Text -eq 'Saved: My News') 'The Add website button must complete installation.'
    Assert-Gui ($ui.AppList.Items.Count -eq 1) 'The saved website must appear in the list.'
    Assert-Gui ($ui.AppList.GetItemText($ui.AppList.Items[0]) -eq 'My News') 'Website list must show the friendly name.'
    Assert-Gui ($ui.NameInput.ReadOnly -and $ui.OpenButton.Enabled -and $ui.RemoveButton.Enabled) 'Selection must enable the correct actions.'
    Assert-Gui ($null -ne $ui.IconPreview.Image) 'A generated icon must render in the setup window.'
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
        foreach ($requiredControl in @($ui.NameInput, $ui.UrlInput, $ui.SaveButton, $ui.OpenButton, $ui.RemoveButton)) {
            $ui.EditorViewport.ScrollControlIntoView($requiredControl)
            [Windows.Forms.Application]::DoEvents()
            $controlBounds = $ui.EditorViewport.RectangleToClient($requiredControl.RectangleToScreen($requiredControl.ClientRectangle))
            Assert-Gui ($ui.EditorViewport.ClientRectangle.Contains($controlBounds)) ('Required control must be reachable: ' + $requiredControl.Text)
        }
        if ($ScreenshotDirectory) {
            [void][IO.Directory]::CreateDirectory($ScreenshotDirectory)
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
    Write-Host "PASS: Native setup add, select, update, preview, keyboard defaults, reset, and confirmation outcomes on PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    if ($null -ne $form) { $form.Close(); $form.Dispose() }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}