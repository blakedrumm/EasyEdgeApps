#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('..\artifacts\test-kit-window-' + [Guid]::NewGuid().ToString('N'))))
$failures = New-Object 'Collections.Generic.List[string]'

function Assert-KitWindow {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $failures.Add($Message) }
}

try {
    foreach ($windowCase in @('FullScreen', 'AlwaysOnTop')) {
        foreach ($freshField in @('False', 'Omitted')) {
            $label = $windowCase + '-' + $freshField
            $caseRoot = Join-Path $testRoot $label
            $context = [pscustomobject]@{ Root = (Join-Path $caseRoot 'Data'); Desktop = (Join-Path $caseRoot 'Desktop'); Programs = (Join-Path $caseRoot 'Programs') }
            $null = Install-EeaApp -AppName 'Alpha' -Website 'https://example.com/before' -Context $context -Confirm:$false
            $windowParameters = if ($windowCase -eq 'FullScreen') { @{ LaunchMode = 'FullScreen'; AlwaysOnTop = $false } }
                else { @{ LaunchMode = 'RememberLast'; AlwaysOnTop = $true } }
            $null = Install-EeaApp -AppName 'Bravo' -Website 'https://example.org/' -FreshSession $true -DedicatedProfile $false -Taskbar $false @windowParameters -Context $context -Confirm:$false
            $kit = New-EeaKit -AppNames @('Alpha', 'Bravo') -Context $context
            $kit.SchemaVersion = 2
            $kit.Apps = @($kit.Apps | Sort-Object Name)
            $kit.Apps[0].Url = 'https://example.com/after'
            $kit.Apps[1].PSObject.Properties.Remove('FreshSession')
            if ($freshField -eq 'False') { $kit.Apps[1] | Add-Member -NotePropertyName FreshSession -NotePropertyValue $false }
            $paths = @((Get-EeaPaths $context 'Alpha'), (Get-EeaPaths $context 'Bravo'))
            $before = @{}
            foreach ($appPaths in $paths) {
                foreach ($slot in @('Manifest', 'Icon', 'Launcher', 'Desktop', 'StartMenu')) {
                    if ([IO.File]::Exists($appPaths.$slot)) { $before[$appPaths.$slot] = (Get-FileHash -LiteralPath $appPaths.$slot).Hash }
                }
            }
            $importPreview = @(Get-EeaKitPreview -Kit $kit -Context $context)
            $result = Import-EeaKit -Kit $kit -ExpectedPreview $importPreview -Context $context -Confirm:$false
            Write-Host ($label + ': preview=' + ($importPreview.Action -join ',') + '; apply=' + ($result.Results.Status -join ','))
            Assert-KitWindow ($importPreview[1].Action -ceq 'Conflict') "$label must conflict before approval."
            Assert-KitWindow ($importPreview[1].Detail -like '*dedicated or Fresh*') "$label must explain the required explicit profile/window choice."
            Assert-KitWindow (-not $result.Completed -and $result.Results[0].Status -ceq 'Not attempted' -and $result.Results[1].Status -ceq 'Conflict') "$label must prevent all selected changes."
            foreach ($filePath in $before.Keys) {
                Assert-KitWindow ((Get-FileHash -LiteralPath $filePath).Hash -ceq $before[$filePath]) "$label changed a selected app before a predictable failure: $([IO.Path]::GetFileName($filePath))."
            }
            $saved = Read-EeaManifest $context 'Bravo'
            Assert-KitWindow ($saved.FreshSession -and -not $saved.DedicatedProfile -and $saved.LaunchMode -ceq $windowParameters.LaunchMode -and $saved.AlwaysOnTop -eq $windowParameters.AlwaysOnTop) "$label must not coerce local settings."

            $kit.SchemaVersion = 1
            foreach ($app in $kit.Apps) { $app.PSObject.Properties.Remove('FreshSession') }
            $kit.Apps[1].Notes = 'Schema one preserves local Fresh and window settings.'
            $legacyPreview = @(Get-EeaKitPreview -Kit $kit -Context $context)
            $legacyResult = Import-EeaKit -Kit $kit -ExpectedPreview $legacyPreview -Context $context -Confirm:$false
            $saved = Read-EeaManifest $context 'Bravo'
            Assert-KitWindow ($legacyResult.Completed -and $saved.FreshSession -and -not $saved.DedicatedProfile -and $saved.LaunchMode -ceq $windowParameters.LaunchMode -and $saved.AlwaysOnTop -eq $windowParameters.AlwaysOnTop) "$label schema-1 import must preserve all destination-local choices."
            [IO.File]::Delete($paths[1].Desktop)
            $repairResult = Repair-EeaApps -AppNames @('Bravo') -Context $context -Confirm:$false
            Assert-KitWindow $repairResult.Completed "$label repair must preserve a valid Fresh-owned window configuration."
        }
    }
    if ($failures.Count -gt 0) { throw ($failures -join "`n") }
    Write-Host 'PASS: FullScreen/topmost, schema-2 false/omitted, schema-1 preservation, repair, and whole-selected-batch preflight.'
}
finally { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) } }