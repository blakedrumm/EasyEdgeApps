#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.KitTests.' + [Guid]::NewGuid().ToString('N'))
$script:KitResults = New-Object 'Collections.Generic.List[object]'

function Assert-Kit {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-KitRejected {
    param([scriptblock]$Operation, [string]$Message = '*')
    $failure = $null
    try { & $Operation | Out-Null } catch { $failure = $_ }
    Assert-Kit ($null -ne $failure) 'Invalid input must be rejected.'
    Assert-Kit ($failure.Exception.Message -like $Message) ('Unexpected failure: ' + $failure.Exception.Message)
}

function Test-KitCase {
    param([string]$Label, [scriptblock]$Operation)
    try { & $Operation; $script:KitResults.Add([pscustomobject]@{ Test = $Label; Passed = $true; Detail = '' }) }
    catch { $script:KitResults.Add([pscustomobject]@{ Test = $Label; Passed = $false; Detail = $_.Exception.Message }) }
}

function New-KitTestContext {
    param([string]$Label)
    return [pscustomobject]@{ Root = (Join-Path $testRoot "$Label\Data"); Desktop = (Join-Path $testRoot "$Label\Desktop"); Programs = (Join-Path $testRoot "$Label\Programs") }
}

function Copy-TestKit {
    param($Kit)
    return ($Kit | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
}

try {
    $source = New-KitTestContext 'Source'
    $destination = New-KitTestContext 'Destination'
    Test-KitCase 'Notes and generated icons survive export and import' {
        $null = Install-EeaApp -AppName 'My News' -Website 'https://example.com/#/home' -Notes "Helper notes`r`nPlain text <only>." -Desktop $false -Context $source -Confirm:$false
        $script:Kit = New-EeaKit -KitName 'Family websites' -Notes 'Share with the helper privately.' -Context $source
        Assert-Kit ($script:Kit.Apps[0].Icon.Kind -ceq 'Generated') 'New automatic icons should be reproducible, not source paths.'
        Assert-Kit (-not (($script:Kit | ConvertTo-Json -Depth 8).Contains($source.Root))) 'A kit cannot contain machine-specific paths.'
        $result = Import-EeaKit -Kit $script:Kit -Context $destination -Confirm:$false
        Assert-Kit $result.Completed 'The kit should import.'
        $saved = Read-EeaManifest $destination 'My News'
        Assert-Kit ($saved.Notes -ceq "Helper notes`r`nPlain text <only>." -and -not $saved.Desktop -and $saved.StartMenu) 'Preserve notes and placements.'
    }
    Test-KitCase 'Explicit HTTP addresses survive kit import and export' {
        $httpContext = New-KitTestContext 'Http'
        $httpKit = Copy-TestKit $script:Kit
        $httpKit.Apps[0].Url = 'http://example.com:8080/local?view=large#/home'
        $result = Import-EeaKit -Kit $httpKit -Context $httpContext -Confirm:$false
        Assert-Kit $result.Completed 'A reviewed HTTP kit should import without probing or rewriting its URL.'
        $exported = New-EeaKit -Context $httpContext
        Assert-Kit ($exported.Apps[0].Url -ceq $httpKit.Apps[0].Url) 'HTTP addresses must stay explicit and portable.'
        $paths = Get-EeaPaths $httpContext 'My News'
        $shortcut = Read-EeaShortcut $paths.StartMenu
        Assert-Kit ($shortcut.Arguments -ceq (Get-EeaArguments $httpKit.Apps[0].Url)) 'The imported shortcut must launch the approved HTTP address directly.'
    }
    Test-KitCase 'Repeated import is unchanged and byte-identical' {
        $paths = Get-EeaPaths $destination 'My News'
        $hash = (Get-FileHash -LiteralPath $paths.Manifest).Hash
        $result = Import-EeaKit -Kit $script:Kit -Context $destination -Confirm:$false
        Assert-Kit ($result.Completed -and $result.Results[0].Status -eq 'Unchanged') 'Identical imports should not update files.'
        Assert-Kit ((Get-FileHash -LiteralPath $paths.Manifest).Hash -ceq $hash -and @(Get-EeaApps -Context $destination).Count -eq 1) 'No duplicate app or metadata churn.'
    }
    Test-KitCase 'Custom icons are embedded and portable without their source file' {
        $iconPath = Join-Path $testRoot 'custom.ico'
        New-EeaIcon -Path $iconPath -AppName 'Custom source'
        $iconHash = (Get-FileHash -LiteralPath $iconPath).Hash.ToLowerInvariant()
        $null = Install-EeaApp -AppName 'Calendar' -Website 'https://example.org/calendar' -CustomIcon $iconPath -Context $source -Confirm:$false
        $customKit = New-EeaKit -AppNames @('Calendar') -Context $source
        [IO.File]::Delete($iconPath)
        Assert-Kit ($customKit.Apps[0].Icon.Kind -eq 'Embedded') 'Custom icons must contain validated bytes.'
        $result = Import-EeaKit -Kit $customKit -Context $destination -Confirm:$false
        Assert-Kit $result.Completed 'Import cannot depend on the original custom file.'
        Assert-Kit ((Read-EeaManifest $destination 'Calendar').IconHash -ceq $iconHash) 'Custom icon bytes must survive transfer.'
    }
    Test-KitCase 'Legacy settings without notes or icon kind remain usable' {
        $paths = Get-EeaPaths $source 'Calendar'
        $state = Read-EeaManifest $source 'Calendar'
        $state.PSObject.Properties.Remove('Notes')
        $state.PSObject.Properties.Remove('IconKind')
        [IO.File]::WriteAllText($paths.Manifest, ($state | ConvertTo-Json))
        $legacyKit = New-EeaKit -AppNames @('Calendar') -Context $source
        Assert-Kit ($legacyKit.Apps[0].Notes -ceq '' -and $legacyKit.Apps[0].Icon.Kind -eq 'Embedded') 'Legacy icon provenance must not be guessed.'
    }
    Test-KitCase 'Preview highlights URL and destination-domain changes' {
        $changed = Copy-TestKit $script:Kit
        $changed.Apps[0].Url = 'https://example.net/new?view=large#/home'
        $importPreview = @(Get-EeaKitPreview -Kit $changed -Context $destination)
        Assert-Kit ($importPreview[0].Action -eq 'Update' -and $importPreview[0].DomainChanged -and $importPreview[0].CurrentUrl -eq 'https://example.com/#/home') 'Show old and new destinations before approval.'
    }
    Test-KitCase 'Read-only checks and WhatIf leave no persistent changes' {
        $empty = New-KitTestContext 'WhatIf'
        $null = Get-EeaChecks -Context $empty
        $null = Get-EeaKitPreview -Kit $script:Kit -Context $empty
        $null = Import-EeaKit -Kit $script:Kit -Context $empty -WhatIf
        Assert-Kit (-not (Test-Path -LiteralPath (Join-Path $testRoot 'WhatIf'))) 'Preview must not create any directory.'
        $paths = Get-EeaPaths $destination 'My News'
        [IO.File]::Delete($paths.StartMenu)
        $null = Repair-EeaApps -AppNames @('My News') -Context $destination -WhatIf
        Assert-Kit (-not [IO.File]::Exists($paths.StartMenu)) 'Repair WhatIf must leave missing files missing.'
    }
    Test-KitCase 'Repair restores missing shortcuts and icons without testing websites' {
        $paths = Get-EeaPaths $destination 'My News'
        [IO.File]::Delete($paths.Icon)
        $check = Get-EeaChecks -AppNames @('My News') -Context $destination
        Assert-Kit ($check.CanRepair -and $check.Issues.Count -eq 2) 'Report both missing files.'
        $result = Repair-EeaApps -AppNames @('My News') -Context $destination -Confirm:$false
        Assert-Kit ($result.Completed -and $result.Results[0].Status -eq 'Repaired') 'Repair should complete.'
        Assert-Kit ((Get-EeaChecks -AppNames @('My News') -Context $destination).Status -eq 'Healthy') 'Owned files should check healthy.'
    }
    Test-KitCase 'Corrupted settings remain visible to Check without becoming filesystem instructions' {
        $paths = Get-EeaPaths $destination 'Calendar'
        $original = [IO.File]::ReadAllBytes($paths.Manifest)
        try {
            [IO.File]::WriteAllText($paths.Manifest, '{"Name":"..\\Outside"}')
            $checks = @(Get-EeaChecks -Context $destination)
            Assert-Kit (@($checks | Where-Object { $_.Status -eq 'Conflict' }).Count -eq 1) 'One corrupted app must not hide the healthy app.'
            $result = Repair-EeaApps -AppNames @('Calendar') -Context $destination -Confirm:$false
            Assert-Kit (-not $result.Completed) 'Do not repair from damaged settings.'
        }
        finally { [IO.File]::WriteAllBytes($paths.Manifest, $original) }
    }
    Test-KitCase 'Unrelated collisions block the whole preflight without writes' {
        $collision = New-KitTestContext 'Collision'
        [void][IO.Directory]::CreateDirectory($collision.Programs)
        $foreign = Join-Path $collision.Programs 'My News.lnk'
        [IO.File]::WriteAllText($foreign, 'Unrelated shortcut')
        $result = Import-EeaKit -Kit $script:Kit -Context $collision -Confirm:$false
        Assert-Kit (-not $result.Completed -and $result.Results[0].Status -eq 'Conflict') 'A collision must prevent import.'
        Assert-Kit ([IO.File]::ReadAllText($foreign) -ceq 'Unrelated shortcut' -and -not (Test-Path -LiteralPath $collision.Root)) 'Preserve all unrelated files.'
    }
    Test-KitCase 'A stale preview is rejected after local files change' {
        $changed = Copy-TestKit $script:Kit
        $changed.Apps[0].Url = 'https://example.com/changed'
        $importPreview = @(Get-EeaKitPreview -Kit $changed -Context $destination)
        $null = Install-EeaApp -AppName 'My News' -Website 'https://example.com/other' -Context $destination -Confirm:$false
        Assert-KitRejected { Import-EeaKit -Kit $changed -ExpectedPreview $importPreview -Context $destination -Confirm:$false } '*changed after the preview*'
    }
    Test-KitCase 'Entire kit validation rejects unsafe data before installation' {
        foreach ($mutation in @(
            { param($candidate) $candidate.SchemaVersion = '1' },
            { param($candidate) $candidate.SchemaVersion = 2 },
            { param($candidate) $candidate.Apps[0].Desktop = 'false' },
            { param($candidate) $candidate.Apps[0].Url = 'ftp://example.com/' },
            { param($candidate) $candidate.Apps[0].Name = '..\Outside' },
            { param($candidate) $candidate.Apps[0] | Add-Member -NotePropertyName Path -NotePropertyValue 'C:\Outside' },
            { param($candidate) $candidate.Apps[0].Notes = 'a' * 4001 },
            { param($candidate) $candidate.Apps[0].Icon.Version = 2 },
            { param($candidate) $candidate.Apps = @($candidate.Apps[0], $candidate.Apps[0]) }
        )) {
            $invalid = Copy-TestKit $script:Kit
            & $mutation $invalid
            $empty = New-KitTestContext 'Invalid'
            Assert-KitRejected { Import-EeaKit -Kit $invalid -Context $empty -Confirm:$false }
            Assert-Kit (-not (Test-Path -LiteralPath $empty.Root)) 'Invalid input must leave installation unchanged.'
        }
    }
    Test-KitCase 'Malformed and oversized embedded icons are rejected' {
        $invalid = Copy-TestKit $script:Kit
        $bytes = [byte[]](1, 2, 3, 4)
        $invalid.Apps[0].Icon = [pscustomobject]@{ Kind = 'Embedded'; Data = [Convert]::ToBase64String($bytes); Sha256 = (Get-EeaByteHash $bytes) }
        Assert-KitRejected { ConvertTo-EeaKit $invalid }
        Assert-KitRejected { ConvertFrom-EeaBase64 ('A' * (2MB)) -MaximumBytes 1MB }
    }
    Test-KitCase 'Pending recovery blocks import and repair without removing recovery data' {
        $pending = Join-Path $destination.Root '.pending'
        [void][IO.Directory]::CreateDirectory($pending)
        try {
            $check = Get-EeaChecks -Context $destination
            Assert-Kit ($check.Status -eq 'Blocked') 'Pending recovery must be reported.'
            Assert-Kit (-not (Import-EeaKit -Kit $script:Kit -Context $destination -Confirm:$false).Completed) 'Import must respect recovery.'
            Assert-Kit (-not (Repair-EeaApps -AppNames @('My News') -Context $destination -Confirm:$false).Completed) 'Repair must respect recovery.'
            Assert-Kit ([IO.Directory]::Exists($pending)) 'Do not discard recovery data.'
        }
        finally { [IO.Directory]::Delete($pending, $true) }
    }
    Test-KitCase 'Repair preserves externally modified shortcuts and icons' {
        $tampered = New-KitTestContext 'Tampered repair'
        $null = Install-EeaApp -AppName 'My News' -Website 'https://example.com/' -Context $tampered -Confirm:$false
        $tamperedPaths = Get-EeaPaths $tampered 'My News'
        foreach ($slot in @('Desktop', 'Icon')) {
            $originalBytes = [IO.File]::ReadAllBytes($tamperedPaths.$slot)
            try {
                [IO.File]::WriteAllText($tamperedPaths.$slot, 'Externally modified fixture')
                $modifiedHash = (Get-FileHash -LiteralPath $tamperedPaths.$slot).Hash
                $check = Get-EeaChecks -AppNames @('My News') -Context $tampered
                Assert-Kit ($check.Status -eq 'Conflict' -and -not $check.CanRepair) 'Modified files must not be offered for automatic repair.'
                Assert-Kit (-not (Repair-EeaApps -AppNames @('My News') -Context $tampered -Confirm:$false).Completed) 'Explicit repair approval must not override ownership conflicts.'
                Assert-Kit ((Get-FileHash -LiteralPath $tamperedPaths.$slot).Hash -ceq $modifiedHash) 'Preserve every externally modified artifact.'
            }
            finally { [IO.File]::WriteAllBytes($tamperedPaths.$slot, $originalBytes) }
        }
    }
    Test-KitCase 'Missing Edge blocks repair without changing saved apps' {
        $script:OriginalEdgeFinder = ${function:Find-EeaEdge}
        try {
            function Find-EeaEdge { throw 'Synthetic Edge-unavailable condition.' }
            $beforeHash = (Get-FileHash -LiteralPath (Get-EeaPaths $destination 'My News').Manifest).Hash
            Assert-Kit ((Get-EeaChecks -AppNames @('My News') -Context $destination).Status -eq 'Blocked') 'Missing Edge is distinct from a damaged shortcut.'
            Assert-Kit (-not (Repair-EeaApps -AppNames @('My News') -Context $destination -Confirm:$false).Completed) 'Repair must not guess an executable path.'
            Assert-Kit ((Get-FileHash -LiteralPath (Get-EeaPaths $destination 'My News').Manifest).Hash -ceq $beforeHash) 'Missing Edge must not change saved settings.'
        }
        finally { Set-Item -Path Function:Find-EeaEdge -Value $script:OriginalEdgeFinder }
    }
    Test-KitCase 'Batch failures report succeeded, failed and not attempted apps accurately' {
        $batch = Copy-TestKit $script:Kit
        $batch.Apps = @(foreach ($appName in @('First', 'Second', 'Third')) {
            $app = $script:Kit.Apps[0] | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            $app.Name = $appName
            $app
        })
        $batchContext = New-KitTestContext 'Batch'
        $script:OriginalKitWriter = ${function:Write-EeaAtomicFile}
        $script:KitFailurePath = (Get-EeaPaths $batchContext 'Second').StartMenu
        try {
            function Write-EeaAtomicFile {
                param([string]$Source, [string]$Destination)
                if ($Destination -eq $script:KitFailurePath) { throw 'Injected batch write failure.' }
                & $script:OriginalKitWriter -Source $Source -Destination $Destination
            }
            $result = Import-EeaKit -Kit $batch -Context $batchContext -Confirm:$false
            Assert-Kit (-not $result.Completed -and ($result.Results.Status -join ',') -eq 'Added,Failed,Not attempted') 'Never imply a whole-kit rollback.'
            Assert-Kit (@(Get-EeaApps -Context $batchContext).Count -eq 1) 'Only the first app should remain.'
            Assert-Kit (-not [IO.File]::Exists((Get-EeaPaths $batchContext 'Second').Icon)) 'Failed app changes must roll back.'
        }
        finally { Set-Item -Path Function:Write-EeaAtomicFile -Value $script:OriginalKitWriter }
    }
}
finally { if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force } }

foreach ($result in $script:KitResults) { Write-Host (('FAIL', 'PASS')[[int]$result.Passed] + ': ' + $result.Test) }
$failures = @($script:KitResults | Where-Object { -not $_.Passed })
if ($failures.Count -gt 0) { $failures | Format-List Test, Detail; throw "$($failures.Count) App Kit tests failed." }
Write-Host "PASS: $($script:KitResults.Count) App Kit and repair tests on PowerShell $($PSVersionTable.PSVersion)."