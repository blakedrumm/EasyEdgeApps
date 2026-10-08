#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')

$script:TestResults = New-Object 'Collections.Generic.List[object]'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.Tests.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

function Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -cne $Expected) { throw "Expected [$Expected], received [$Actual]." }
}

function Assert-Rejected {
    param([scriptblock]$Operation, [string]$ExpectedMessage = '*')
    $caughtError = $null
    try { & $Operation | Out-Null } catch { $caughtError = $_ }
    if ($null -eq $caughtError) { throw 'The operation should have been rejected.' }
    if ($caughtError.Exception.Message -notlike $ExpectedMessage) {
        throw "Unexpected failure: $($caughtError.Exception.Message)"
    }
}

function Test-Case {
    param([string]$Label, [scriptblock]$Operation)
    try {
        & $Operation
        $script:TestResults.Add([pscustomobject]@{ Test = $Label; Passed = $true; Detail = '' })
    }
    catch {
        $script:TestResults.Add([pscustomobject]@{ Test = $Label; Passed = $false; Detail = $_.Exception.Message })
    }
}

try {
    Test-Case 'Canonical HTTPS keeps query and fragment' {
        Assert-Equal (ConvertTo-EeaWebsite 'HTTPS://EXAMPLE.COM:443/account?view=large&sort=new#/inbox') 'https://example.com/account?view=large&sort=new#/inbox'
    }
    Test-Case 'Explicit HTTP keeps its scheme and safe launch arguments' {
        Assert-Equal (ConvertTo-EeaWebsite 'HTTP://EXAMPLE.COM:80/account?view=large#/inbox') 'http://example.com/account?view=large#/inbox'
        Assert-Equal (Get-EeaArguments 'http://example.com/?query=%22%20%26#/home') '--app="http://example.com/?query=%22%20%26#/home" --start-maximized'
    }
    Test-Case 'Unsafe URL schemes and credentials are rejected' {
        foreach ($invalidUrl in @('ftp://example.com', 'file:///C:/Windows', 'javascript:alert(1)', 'https://user:password@example.com', 'http://user:password@example.com', '//example.com', 'https://')) {
            Assert-Rejected { ConvertTo-EeaWebsite $invalidUrl }
        }
    }
    Test-Case 'Quotes, backslashes, whitespace and argument injection are rejected' {
        foreach ($invalidUrl in @('https://example.com/" --disable-web-security', 'https://example.com\test', "https://example.com/`n--inprivate", 'https://example.com/a b')) {
            Assert-Rejected { ConvertTo-EeaWebsite $invalidUrl }
        }
    }
    Test-Case 'Encoded punctuation is website data, not shell code' {
        Assert-Equal (Get-EeaArguments 'https://example.com/?query=%22%20%26%20%25#/home') '--app="https://example.com/?query=%22%20%26%20%25#/home" --start-maximized'
    }
    Test-Case 'Friendly names and case-insensitive identity' {
        Assert-Equal (ConvertTo-EeaName '  My News  ') 'My News'
        Assert-Equal (Get-EeaId 'My News') (Get-EeaId 'MY NEWS')
        Assert-Equal (Get-EeaId 'My News').Length 64
    }
    Test-Case 'Unsafe file names are rejected' {
        foreach ($invalidName in @('', ' ', '..', '../news', 'News: Latest', 'NUL.txt', 'COM1', 'News.', ('a' * 61), "News$([char]0x202e)")) {
            Assert-Rejected { ConvertTo-EeaName $invalidName }
        }
    }
    Test-Case 'Letters capitalized differently by PowerShell editions are detected exactly' {
        $georgianMail = [string]::Concat([char[]]@(0x10E4, 0x10DD, 0x10E1, 0x10E2, 0x10D0))
        foreach ($editionSpecific in @($georgianMail, ('Micro' + [char]0x00B5), ('Long ' + [char]0x017F))) { Assert-Equal (Test-EeaEditionSpecificName $editionSpecific) $true }
        foreach ($portable in @('My Mail', ('Caf' + [char]0x00E9), ('Greek ' + [char]0x039C + [char]0x03BC), ('Cyrillic ' + [char]0x0524))) { Assert-Equal (Test-EeaEditionSpecificName $portable) $false }
    }
    Test-Case 'New edition-specific names are refused only by PowerShell 7' {
        $editionContext = [pscustomobject]@{ Root = (Join-Path $testRoot 'EditionNames\Data'); Desktop = (Join-Path $testRoot 'EditionNames\Desktop'); Programs = (Join-Path $testRoot 'EditionNames\Programs') }
        $georgianMail = [string]::Concat([char[]]@(0x10E4, 0x10DD, 0x10E1, 0x10E2, 0x10D0))
        if ($PSVersionTable.PSEdition -ceq 'Core') {
            Assert-Rejected { Install-EeaApp -AppName $georgianMail -Website 'https://example.com/' -DedicatedProfile $false -Context $editionContext -Confirm:$false } '*save differently*'
            Assert-Equal @(Get-EeaApps -Context $editionContext).Count 0
        }
        else {
            $saved = Install-EeaApp -AppName $georgianMail -Website 'https://example.com/' -DedicatedProfile $false -Context $editionContext -Confirm:$false
            Assert-Equal $saved.Name $georgianMail
            Remove-EeaApp -AppName $georgianMail -Context $editionContext -Confirm:$false
        }
    }
    Test-Case 'A website saved by another PowerShell edition is reported specifically' {
        $editionContext = [pscustomobject]@{ Root = (Join-Path $testRoot 'OtherEdition\Data'); Desktop = (Join-Path $testRoot 'OtherEdition\Desktop'); Programs = (Join-Path $testRoot 'OtherEdition\Programs') }
        $probe = Install-EeaApp -AppName 'Edition probe' -Website 'https://example.com/' -DedicatedProfile $false -Context $editionContext -Confirm:$false
        $probePaths = Get-EeaPaths $editionContext 'Edition probe'
        $foreignId = 'f' * 64
        $foreignDirectory = Join-Path $probePaths.AppsRoot $foreignId
        [void][IO.Directory]::CreateDirectory($foreignDirectory)
        $foreignState = Read-EeaManifest $editionContext 'Edition probe'
        $foreignState.Id = $foreignId
        $foreignState.Name = [string]::Concat([char[]]@(0x10E4, 0x10DD, 0x10E1, 0x10E2, 0x10D0))
        [IO.File]::WriteAllText((Join-Path $foreignDirectory 'app.json'), ($foreignState | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        Assert-Rejected { Get-EeaApps -Context $editionContext } '*different PowerShell edition*'
        $foreignState.Name = 'Not this folder'
        [IO.File]::WriteAllText((Join-Path $foreignDirectory 'app.json'), ($foreignState | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        Assert-Rejected { Get-EeaApps -Context $editionContext } '*damaged settings*'
        [IO.Directory]::Delete($foreignDirectory, $true)
        Assert-Equal @(Get-EeaApps -Context $editionContext)[0].Name $probe.Name
    }
    Test-Case 'Real Windows shortcut roundtrip preserves safe arguments' {
        $shortcutPath = Join-Path $testRoot 'My News.lnk'
        $targetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
        $arguments = Get-EeaArguments 'https://example.com/?first=1&second=%22value%22#/inbox'
        Write-EeaShortcut -Path $shortcutPath -Target $targetPath -Arguments $arguments -Description 'EasyEdgeApps:test' -Icon ($targetPath + ',0')
        $shortcutInfo = Read-EeaShortcut $shortcutPath
        Assert-Equal $shortcutInfo.Arguments $arguments
        Assert-Equal $shortcutInfo.Description 'EasyEdgeApps:test'
        Assert-Equal ([StringComparer]::OrdinalIgnoreCase.Equals($shortcutInfo.TargetPath, $targetPath)) $true
    }
    $context = [pscustomobject]@{
        Root = Join-Path $testRoot 'LocalAppData\EasyEdgeApps'
        Desktop = Join-Path $testRoot 'Redirected Desktop'
        Programs = Join-Path $testRoot 'Start Menu\Easy Edge Apps'
    }
    Test-Case 'WhatIf creates no folders or shortcuts' {
        Install-EeaApp -AppName 'My News' -Website 'https://example.com/' -Context $context -WhatIf
        Assert-Equal (Test-Path -LiteralPath $context.Root) $false
        Assert-Equal (Test-Path -LiteralPath $context.Desktop) $false
        Assert-Equal (Test-Path -LiteralPath $context.Programs) $false
    }
    Test-Case 'Install creates two direct Edge shortcuts and a valid local icon' {
        $installed = Install-EeaApp -AppName 'My News' -Website 'https://example.com/#/home' -Context $context -Confirm:$false
        $paths = Get-EeaPaths $context 'My News'
        Assert-Equal $installed.Name 'My News'
        Assert-Equal (Test-EeaOwnedShortcut $paths.Desktop $installed $paths) $true
        Assert-Equal (Test-EeaOwnedShortcut $paths.StartMenu $installed $paths) $true
        Assert-Equal ([IO.File]::Exists($paths.Icon)) $true
        $iconBytes = Read-EeaCustomIcon $paths.Icon
        Assert-Equal ($iconBytes.Length -gt 100) $true
        Assert-EeaReady $context
    }
    Test-Case 'The generated icon decodes into a preview bitmap' {
        $paths = Get-EeaPaths $context 'My News'
        $previewBitmap = Get-EeaIconPreview $paths.Icon
        try {
            Assert-Equal $previewBitmap.Width 96
            $pixelColors = New-Object 'Collections.Generic.HashSet[int]'
            for ($pixelRow = 0; $pixelRow -lt 96; $pixelRow += 8) {
                for ($pixelColumn = 0; $pixelColumn -lt 96; $pixelColumn += 8) {
                    [void]$pixelColors.Add($previewBitmap.GetPixel($pixelColumn, $pixelRow).ToArgb())
                }
            }
            Assert-Equal ($pixelColors.Count -gt 1) $true
        }
        finally {
            $previewBitmap.Dispose()
        }
    }
    Test-Case 'Update reuses the same identity and repairs a missing shortcut' {
        $paths = Get-EeaPaths $context 'My News'
        [IO.File]::Delete($paths.Desktop)
        $updated = Install-EeaApp -AppName 'My News' -Website 'https://example.com/new?size=large#/home' -Context $context -Confirm:$false
        Assert-Equal $updated.Url 'https://example.com/new?size=large#/home'
        Assert-Equal (Test-EeaOwnedShortcut $paths.Desktop $updated $paths) $true
        Assert-Equal @(Get-EeaApps -Context $context).Count 1
    }
    Test-Case 'Kit previews call out an HTTPS to HTTP downgrade' {
        $downgrade = [pscustomobject]@{ Product = 'EasyEdgeApps.AppKit'; SchemaVersion = 1; Name = 'Downgrade'; Apps = @([pscustomobject]@{ Name = 'My News'; Url = 'http://example.com/new?size=large#/home'; Desktop = $true; StartMenu = $true; Icon = [pscustomobject]@{ Kind = 'Generated'; Version = 1 } }) }
        $row = @(Get-EeaKitPreview -Kit $downgrade -Context $context)[0]
        Assert-Equal $row.Action 'Update'
        Assert-Equal ($row.Detail -like 'CONNECTION CHANGES from HTTPS to HTTP*') $true
    }
    Test-Case 'Repeated names in one check are inspected once' {
        Assert-Equal @(Get-EeaChecks -AppNames @('My News', 'my news', ' MY NEWS ') -Context $context).Count 1
    }
    Test-Case 'Reserved Favorites titles stay within the name limit' {
        $favoriteName = ConvertTo-EeaFavoriteName -Title ('CON.' + ('x' * 56)) -Website 'https://example.com/'
        Assert-Equal ($favoriteName.Length -le 60) $true
        Assert-Equal $favoriteName.StartsWith('Website CON.') $true
    }
    Test-Case 'Empty exports and empty settings files explain themselves' {
        $emptyContext = [pscustomobject]@{ Root = (Join-Path $testRoot 'EmptyData'); Desktop = (Join-Path $testRoot 'EmptyDesktop'); Programs = (Join-Path $testRoot 'EmptyPrograms') }
        Assert-Rejected { New-EeaKit -Context $emptyContext } '*No saved websites*'
        [void][IO.Directory]::CreateDirectory($emptyContext.Root)
        [IO.File]::WriteAllBytes((Join-Path $emptyContext.Root 'settings.json'), [byte[]]@())
        Assert-Rejected { Get-EeaSettings -Context $emptyContext } '*empty or damaged*'
    }
    Test-Case 'Unrelated shortcut collision is preserved' {
        $foreignPath = Join-Path $context.Desktop 'Other News.lnk'
        [IO.File]::WriteAllText($foreignPath, 'An unrelated file')
        Assert-Rejected { Install-EeaApp -AppName 'Other News' -Website 'https://example.org/' -Context $context -Confirm:$false } '*already exists*'
        Assert-Equal ([IO.File]::ReadAllText($foreignPath)) 'An unrelated file'
    }
    Test-Case 'Missing settings never authorize retained app data adoption' {
        $retainedPaths = Get-EeaPaths $context 'Retained data'
        [void][IO.Directory]::CreateDirectory((Join-Path $retainedPaths.Directory 'AppProfile'))
        $sentinel = Join-Path $retainedPaths.Directory 'AppProfile\Cookies'
        [IO.File]::WriteAllText($sentinel, 'Synthetic retained private data')
        $originalHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
        Assert-Rejected { Install-EeaApp -AppName 'Retained data' -Website 'https://example.com/' -Context $context -Confirm:$false } '*retained or unrecognized files*'
        Assert-Equal (Test-Path -LiteralPath $retainedPaths.Manifest) $false
        Assert-Equal (Test-Path -LiteralPath $retainedPaths.Desktop) $false
        Assert-Equal (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash $originalHash
    }
    Test-Case 'External shortcut edits block both update and removal' {
        $paths = Get-EeaPaths $context 'My News'
        $originalBytes = [IO.File]::ReadAllBytes($paths.Desktop)
        try {
            Write-EeaShortcut -Path $paths.Desktop -Target (Find-EeaEdge) -Arguments '--inprivate' -Description 'Not owned' -Icon ((Find-EeaEdge) + ',0')
            Assert-Rejected { Install-EeaApp -AppName 'My News' -Website 'https://example.org/' -Context $context -Confirm:$false } '*changed outside*'
            Assert-Rejected { Remove-EeaApp -AppName 'My News' -Context $context -Confirm:$false } '*changed outside*'
            Assert-Equal (Read-EeaShortcut $paths.Desktop).Arguments '--inprivate'
        }
        finally { [IO.File]::WriteAllBytes($paths.Desktop, $originalBytes) }
    }
    Test-Case 'Tampered saved identity is rejected without changing shortcuts' {
        $paths = Get-EeaPaths $context 'My News'
        $originalManifest = [IO.File]::ReadAllBytes($paths.Manifest)
        $originalShortcutHash = (Get-FileHash -LiteralPath $paths.Desktop).Hash
        try {
            $tampered = Read-EeaManifest $context 'My News'
            $tampered.Id = '0' * 64
            [IO.File]::WriteAllText($paths.Manifest, ($tampered | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
            Assert-Rejected { Remove-EeaApp -AppName 'My News' -Context $context -Confirm:$false } '*saved settings*'
            Assert-Equal (Get-FileHash -LiteralPath $paths.Desktop).Hash $originalShortcutHash
        }
        finally { [IO.File]::WriteAllBytes($paths.Manifest, $originalManifest) }
    }
    Test-Case 'A failure after one shortcut update rolls back previous files' {
        $paths = Get-EeaPaths $context 'My News'
        $beforeDesktop = (Get-FileHash -LiteralPath $paths.Desktop).Hash
        $beforeManifest = (Get-FileHash -LiteralPath $paths.Manifest).Hash
        $script:OriginalAtomicWriter = ${function:Write-EeaAtomicFile}
        $script:FailDestination = $paths.StartMenu
        try {
            function Write-EeaAtomicFile {
                param([string]$Source, [string]$Destination)
                if ($Destination -eq $script:FailDestination) { throw 'Injected transaction failure.' }
                & $script:OriginalAtomicWriter -Source $Source -Destination $Destination
            }
            Assert-Rejected { Install-EeaApp -AppName 'My News' -Website 'https://example.com/changed' -Context $context -Confirm:$false } '*Injected transaction failure*'
            Assert-Equal (Get-FileHash -LiteralPath $paths.Desktop).Hash $beforeDesktop
            Assert-Equal (Get-FileHash -LiteralPath $paths.Manifest).Hash $beforeManifest
            Assert-EeaReady $context
        }
        finally { Set-Item -Path Function:Write-EeaAtomicFile -Value $script:OriginalAtomicWriter }
    }
    Test-Case 'A replacement that removes its destination before failing is restored' {
        $paths = Get-EeaPaths $context 'My News'
        $beforeStartMenu = (Get-FileHash -LiteralPath $paths.StartMenu).Hash
        $beforeManifest = (Get-FileHash -LiteralPath $paths.Manifest).Hash
        $script:OriginalAtomicWriter = ${function:Write-EeaAtomicFile}
        $script:FailDestination = $paths.StartMenu
        $script:InjectedFailures = 0
        try {
            function Write-EeaAtomicFile {
                param([string]$Source, [string]$Destination)
                if ($Destination -eq $script:FailDestination -and $script:InjectedFailures -eq 0) {
                    $script:InjectedFailures++
                    [IO.File]::Delete($Destination)
                    throw 'Injected replacement failure after removing the destination.'
                }
                & $script:OriginalAtomicWriter -Source $Source -Destination $Destination
            }
            Assert-Rejected { Install-EeaApp -AppName 'My News' -Website 'https://example.com/changed' -Context $context -Confirm:$false } '*Injected replacement failure*'
            Assert-Equal ([IO.File]::Exists($paths.StartMenu)) $true
            Assert-Equal (Get-FileHash -LiteralPath $paths.StartMenu).Hash $beforeStartMenu
            Assert-Equal (Get-FileHash -LiteralPath $paths.Manifest).Hash $beforeManifest
            Assert-EeaReady $context
        }
        finally { Set-Item -Path Function:Write-EeaAtomicFile -Value $script:OriginalAtomicWriter }
    }
    Test-Case 'Atomic replacement waits briefly for a transient file lock' {
        $lockRoot = Join-Path $testRoot 'TransientLock'
        [void][IO.Directory]::CreateDirectory($lockRoot)
        $destinationPath = Join-Path $lockRoot 'locked.txt'
        $sourcePath = Join-Path $lockRoot 'source.txt'
        [IO.File]::WriteAllText($destinationPath, 'Original value')
        [IO.File]::WriteAllText($sourcePath, 'Replacement value')
        $holder = [IO.File]::Open($destinationPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $started = New-Object Threading.ManualResetEventSlim($false)
        $releaser = [PowerShell]::Create()
        try {
            [void]$releaser.AddScript({ param($Stream, $Started) $Started.Set(); Start-Sleep -Milliseconds 250; $Stream.Dispose() }).AddArgument($holder).AddArgument($started)
            $pending = $releaser.BeginInvoke()
            Assert-Equal ($started.Wait(30000)) $true
            Write-EeaAtomicFile -Source $sourcePath -Destination $destinationPath
            [void]$releaser.EndInvoke($pending)
            Assert-Equal ([IO.File]::ReadAllText($destinationPath)) 'Replacement value'
            Assert-Equal @([IO.Directory]::GetFiles($lockRoot, '.EasyEdgeApps.*.tmp')).Count 0
        }
        finally {
            $releaser.Dispose()
            $holder.Dispose()
            $started.Dispose()
        }
    }
    Test-Case 'Completed temporary files do not block reading saved websites' {
        $pendingPath = Join-Path $context.Root '.pending'
        [void][IO.Directory]::CreateDirectory($pendingPath)
        [IO.File]::WriteAllText((Join-Path $pendingPath 'complete.txt'), 'EasyEdgeApps:complete:1')
        Assert-Equal @(Get-EeaApps -Context $context).Count 1
        Install-EeaApp -AppName 'My News' -Website 'https://example.com/new?size=large#/home' -Context $context -Confirm:$false | Out-Null
        Assert-EeaReady $context
    }
    Test-Case 'Committed changes survive access-denied temporary cleanup and retry safely' {
        $cleanupContext = [pscustomobject]@{ Root = Join-Path $testRoot 'CompletedCleanup'; Desktop = $context.Desktop; Programs = $context.Programs }
        $pendingPath = Join-Path $cleanupContext.Root '.pending'
        $readOnlyPath = Join-Path $pendingPath 'staged\read-only.tmp'
        $destinationPath = Join-Path $cleanupContext.Root 'committed.txt'
        try {
            Invoke-EeaTransaction -Context $cleanupContext -WarningAction SilentlyContinue -Prepare {
                param($StagePath)
                $sourcePath = Join-Path $StagePath 'change.txt'
                [IO.File]::WriteAllText($sourcePath, 'Committed value')
                [IO.File]::WriteAllText($readOnlyPath, 'Temporary residue')
                [IO.File]::SetAttributes($readOnlyPath, [IO.FileAttributes]::ReadOnly)
                [pscustomobject]@{ Path = $destinationPath; Source = $sourcePath }
            }
            Assert-Equal ([IO.File]::ReadAllText($destinationPath)) 'Committed value'
            Assert-Equal ([IO.File]::ReadAllText((Join-Path $pendingPath 'complete.txt'))) 'EasyEdgeApps:complete:1'
            Assert-EeaReady $cleanupContext
            [IO.File]::SetAttributes($readOnlyPath, [IO.FileAttributes]::Normal)
            Invoke-EeaTransaction -Context $cleanupContext -Prepare { param($StagePath) }
            Assert-Equal ([IO.Directory]::Exists($pendingPath)) $false
            Assert-Equal ([IO.File]::ReadAllText($destinationPath)) 'Committed value'
        }
        finally {
            if ([IO.File]::Exists($readOnlyPath)) { [IO.File]::SetAttributes($readOnlyPath, [IO.FileAttributes]::Normal) }
            if ([IO.Directory]::Exists($pendingPath)) { [IO.Directory]::Delete($pendingPath, $true) }
        }
    }
    Test-Case 'A failed cleanup retry keeps the completed change marker' {
        $retryContext = [pscustomobject]@{ Root = Join-Path $testRoot 'FailedCleanupRetry'; Desktop = $context.Desktop; Programs = $context.Programs }
        $pendingPath = Join-Path $retryContext.Root '.pending'
        $destinationPath = Join-Path $retryContext.Root 'committed.txt'
        $script:LockedResidue = $null
        try {
            Invoke-EeaTransaction -Context $retryContext -WarningAction SilentlyContinue -Prepare {
                param($StagePath)
                $sourcePath = Join-Path $StagePath 'change.txt'
                [IO.File]::WriteAllText($sourcePath, 'Committed value')
                $script:LockedResidue = [IO.File]::Open((Join-Path $StagePath 'locked.tmp'), [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                [pscustomobject]@{ Path = $destinationPath; Source = $sourcePath }
            }
            Assert-Rejected { Invoke-EeaTransaction -Context $retryContext -Prepare { param($StagePath) } } '*still using temporary files*'
            Assert-Equal ([IO.File]::ReadAllText((Join-Path $pendingPath 'complete.txt'))) 'EasyEdgeApps:complete:1'
            Assert-EeaReady $retryContext
            $script:LockedResidue.Dispose()
            Invoke-EeaTransaction -Context $retryContext -Prepare { param($StagePath) }
            Assert-Equal ([IO.Directory]::Exists($pendingPath)) $false
            Assert-Equal ([IO.File]::ReadAllText($destinationPath)) 'Committed value'
        }
        finally {
            if ($null -ne $script:LockedResidue) { $script:LockedResidue.Dispose() }
            if ([IO.Directory]::Exists($pendingPath)) { [IO.Directory]::Delete($pendingPath, $true) }
        }
    }
    Test-Case 'Read-only residue from a completed change does not block the next change' {
        $residueContext = [pscustomobject]@{ Root = Join-Path $testRoot 'ReadOnlyResidue'; Desktop = $context.Desktop; Programs = $context.Programs }
        $pendingPath = Join-Path $residueContext.Root '.pending'
        $readOnlyPath = Join-Path $pendingPath 'staged\read-only.tmp'
        $destinationPath = Join-Path $residueContext.Root 'committed.txt'
        try {
            Invoke-EeaTransaction -Context $residueContext -WarningAction SilentlyContinue -Prepare {
                param($StagePath)
                $sourcePath = Join-Path $StagePath 'change.txt'
                [IO.File]::WriteAllText($sourcePath, 'Committed value')
                [IO.File]::WriteAllText($readOnlyPath, 'Temporary residue')
                [IO.File]::SetAttributes($readOnlyPath, [IO.FileAttributes]::ReadOnly)
                [pscustomobject]@{ Path = $destinationPath; Source = $sourcePath }
            }
            Assert-Equal ([IO.File]::ReadAllText((Join-Path $pendingPath 'complete.txt'))) 'EasyEdgeApps:complete:1'
            Invoke-EeaTransaction -Context $residueContext -Prepare { param($StagePath) }
            Assert-Equal ([IO.Directory]::Exists($pendingPath)) $false
            Assert-Equal ([IO.File]::ReadAllText($destinationPath)) 'Committed value'
        }
        finally {
            if ([IO.File]::Exists($readOnlyPath)) { [IO.File]::SetAttributes($readOnlyPath, [IO.FileAttributes]::Normal) }
            if ([IO.Directory]::Exists($pendingPath)) { [IO.Directory]::Delete($pendingPath, $true) }
        }
    }
    Test-Case 'Stopping during a change rolls back files that were already replaced' {
        $stopRoot = Join-Path $testRoot 'StoppedChange'
        $runner = [PowerShell]::Create()
        try {
            [void]$runner.AddScript({
                param($ScriptPath, $Root)
                $ErrorActionPreference = 'Stop'
                . $ScriptPath
                $stopContext = [pscustomobject]@{ Root = (Join-Path $Root 'Data'); Desktop = (Join-Path $Root 'Desktop'); Programs = (Join-Path $Root 'Programs') }
                [void][IO.Directory]::CreateDirectory($stopContext.Root)
                $firstPath = Join-Path $stopContext.Root 'first.txt'
                $secondPath = Join-Path $stopContext.Root 'second.txt'
                [IO.File]::WriteAllText($firstPath, 'Original first')
                [IO.File]::WriteAllText($secondPath, 'Original second')
                $originalWriter = ${function:Write-EeaAtomicFile}
                $signalPath = Join-Path $Root 'first-replaced.txt'
                $calls = @{ Count = 0 }
                Set-Item -Path Function:Write-EeaAtomicFile -Value {
                    param($Source, $Destination)
                    & $originalWriter $Source $Destination
                    $calls.Count++
                    if ($calls.Count -eq 1) {
                        [IO.File]::WriteAllText($signalPath, 'replaced')
                        Start-Sleep -Seconds 30
                    }
                }
                Invoke-EeaTransaction -Context $stopContext -Prepare {
                    param($StagePath)
                    $firstSource = Join-Path $StagePath 'first.txt'
                    $secondSource = Join-Path $StagePath 'second.txt'
                    [IO.File]::WriteAllText($firstSource, 'Changed first')
                    [IO.File]::WriteAllText($secondSource, 'Changed second')
                    [pscustomobject]@{ Path = $firstPath; Source = $firstSource }
                    [pscustomobject]@{ Path = $secondPath; Source = $secondSource }
                }
            }).AddArgument((Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')).AddArgument($stopRoot)
            $pending = $runner.BeginInvoke()
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not [IO.File]::Exists((Join-Path $stopRoot 'first-replaced.txt')) -and -not $pending.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Assert-Equal ([IO.File]::Exists((Join-Path $stopRoot 'first-replaced.txt'))) $true
            $runner.Stop()
            try { [void]$runner.EndInvoke($pending) } catch { }
            $stopContext = [pscustomobject]@{ Root = (Join-Path $stopRoot 'Data'); Desktop = (Join-Path $stopRoot 'Desktop'); Programs = (Join-Path $stopRoot 'Programs') }
            Assert-Equal ([IO.File]::ReadAllText((Join-Path $stopContext.Root 'first.txt'))) 'Original first'
            Assert-Equal ([IO.File]::ReadAllText((Join-Path $stopContext.Root 'second.txt'))) 'Original second'
            Assert-EeaReady $stopContext
        }
        finally { $runner.Dispose() }
    }
    Test-Case 'Stopping while an interrupted step is being undone still restores it' {
        $stopRoot = Join-Path $testRoot 'StoppedUndo'
        $runner = [PowerShell]::Create()
        try {
            [void]$runner.AddScript({
                param($ScriptPath, $Root)
                $ErrorActionPreference = 'Stop'
                . $ScriptPath
                $stopContext = [pscustomobject]@{ Root = (Join-Path $Root 'Data'); Desktop = (Join-Path $Root 'Desktop'); Programs = (Join-Path $Root 'Programs') }
                [void][IO.Directory]::CreateDirectory($stopContext.Root)
                $targetPath = Join-Path $stopContext.Root 'target.txt'
                [IO.File]::WriteAllText($targetPath, 'Original target')
                $originalWriter = ${function:Write-EeaAtomicFile}
                $signalPath = Join-Path $Root 'restoring.txt'
                $calls = @{ Count = 0 }
                Set-Item -Path Function:Write-EeaAtomicFile -Value {
                    param($Source, $Destination)
                    $calls.Count++
                    if ($calls.Count -eq 1) {
                        [IO.File]::Delete($Destination)
                        throw 'Injected failure after removing the destination.'
                    }
                    if ($calls.Count -eq 2) {
                        [IO.File]::WriteAllText($signalPath, 'restoring')
                        Start-Sleep -Seconds 30
                    }
                    & $originalWriter $Source $Destination
                }
                Invoke-EeaTransaction -Context $stopContext -Prepare {
                    param($StagePath)
                    $targetSource = Join-Path $StagePath 'target.txt'
                    [IO.File]::WriteAllText($targetSource, 'Changed target')
                    [pscustomobject]@{ Path = $targetPath; Source = $targetSource }
                }
            }).AddArgument((Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')).AddArgument($stopRoot)
            $pending = $runner.BeginInvoke()
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not [IO.File]::Exists((Join-Path $stopRoot 'restoring.txt')) -and -not $pending.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Assert-Equal ([IO.File]::Exists((Join-Path $stopRoot 'restoring.txt'))) $true
            $runner.Stop()
            try { [void]$runner.EndInvoke($pending) } catch { }
            $dataRoot = Join-Path $stopRoot 'Data'
            $targetPath = Join-Path $dataRoot 'target.txt'
            $restored = [IO.File]::Exists($targetPath) -and [IO.File]::ReadAllText($targetPath) -ceq 'Original target'
            $recoverable = [IO.File]::Exists((Join-Path $dataRoot '.pending\journal.json')) -and [IO.File]::Exists((Join-Path $dataRoot '.pending\0.backup'))
            Assert-Equal ($restored -or $recoverable) $true
        }
        finally { $runner.Dispose() }
    }
    Test-Case 'Atomic replacement refuses to overwrite a file changed while it waited' {
        $lockRoot = Join-Path $testRoot 'ChangedWhileLocked'
        [void][IO.Directory]::CreateDirectory($lockRoot)
        $destinationPath = Join-Path $lockRoot 'locked.txt'
        $sourcePath = Join-Path $lockRoot 'source.txt'
        [IO.File]::WriteAllText($destinationPath, 'Original value')
        [IO.File]::WriteAllText($sourcePath, 'Replacement value')
        $holder = [IO.File]::Open($destinationPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $started = New-Object Threading.ManualResetEventSlim($false)
        $writer = [PowerShell]::Create()
        try {
            [void]$writer.AddScript({
                param($Stream, $Started, $Path)
                $Started.Set()
                Start-Sleep -Milliseconds 300
                $outside = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes('Outside value')
                    $outside.SetLength(0)
                    $outside.Write($bytes, 0, $bytes.Length)
                }
                finally { $outside.Dispose() }
                Start-Sleep -Milliseconds 200
                $Stream.Dispose()
            }).AddArgument($holder).AddArgument($started).AddArgument($destinationPath)
            $pending = $writer.BeginInvoke()
            Assert-Equal ($started.Wait(30000)) $true
            Assert-Rejected { Write-EeaAtomicFile -Source $sourcePath -Destination $destinationPath } '*changed outside*'
            [void]$writer.EndInvoke($pending)
            Assert-Equal ([IO.File]::ReadAllText($destinationPath)) 'Outside value'
            Assert-Equal @([IO.Directory]::GetFiles($lockRoot, '.EasyEdgeApps.*.tmp')).Count 0
        }
        finally {
            $writer.Dispose()
            $holder.Dispose()
            $started.Dispose()
        }
    }
    Test-Case 'An interrupted transaction blocks further changes and keeps recovery files' {
        $interruptedContext = [pscustomobject]@{
            Root = Join-Path $testRoot 'Interrupted'
            Desktop = $context.Desktop
            Programs = $context.Programs
        }
        $pendingPath = Join-Path $interruptedContext.Root '.pending'
        [void][IO.Directory]::CreateDirectory($pendingPath)
        try {
            Assert-Rejected { Install-EeaApp -AppName 'My News' -Website 'https://example.com/' -Context $interruptedContext -Confirm:$false } '*needs recovery*'
            Assert-Equal (Test-Path -LiteralPath $pendingPath) $true
        }
        finally { [IO.Directory]::Delete($pendingPath) }
    }
    Test-Case 'A change in progress is not reported as needing recovery' {
        $busyContext = [pscustomobject]@{ Root = Join-Path $testRoot 'ChangeInProgress'; Desktop = $context.Desktop; Programs = $context.Programs }
        $pendingPath = Join-Path $busyContext.Root '.pending'
        [void][IO.Directory]::CreateDirectory($pendingPath)
        $holder = [PowerShell]::Create()
        $acquired = New-Object Threading.ManualResetEventSlim($false)
        $release = New-Object Threading.ManualResetEventSlim($false)
        try {
            [void]$holder.AddScript({
                param($Name, $Acquired, $Release)
                $mutex = New-Object Threading.Mutex($false, $Name)
                try {
                    if ($mutex.WaitOne(30000)) {
                        $Acquired.Set()
                        [void]$Release.Wait(60000)
                        $mutex.ReleaseMutex()
                    }
                }
                finally { $mutex.Dispose() }
            }).AddArgument((Get-EeaMutexName)).AddArgument($acquired).AddArgument($release)
            $pending = $holder.BeginInvoke()
            Assert-Equal ($acquired.Wait(30000)) $true
            Assert-Rejected { Get-EeaApps -Context $busyContext } '*in progress*'
            $release.Set()
            [void]$holder.EndInvoke($pending)
            Assert-Rejected { Get-EeaApps -Context $busyContext } '*needs recovery*'
        }
        finally {
            $release.Set()
            $holder.Dispose()
            $acquired.Dispose()
            $release.Dispose()
            [IO.Directory]::Delete($pendingPath)
        }
    }
    Test-Case 'Remove WhatIf keeps installed files' {
        $paths = Get-EeaPaths $context 'My News'
        Remove-EeaApp -AppName 'My News' -Context $context -WhatIf
        Assert-Equal ([IO.File]::Exists($paths.Manifest)) $true
        Assert-Equal ([IO.File]::Exists($paths.Desktop)) $true
    }
    Test-Case 'Saved paths cannot redirect removal to an unrelated file' {
        $victimPath = Join-Path $testRoot 'Unrelated.txt'
        [IO.File]::WriteAllText($victimPath, 'Do not remove')
        $installed = Install-EeaApp -AppName 'Path Test' -Website 'https://example.com/' -Context $context -Confirm:$false
        $paths = Get-EeaPaths $context 'Path Test'
        $installed | Add-Member -NotePropertyName DesktopPath -NotePropertyValue $victimPath
        $installed | Add-Member -NotePropertyName InstallDirectory -NotePropertyValue $testRoot
        [IO.File]::WriteAllText($paths.Manifest, ($installed | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Remove-EeaApp -AppName 'Path Test' -Context $context -Confirm:$false
        Assert-Equal ([IO.File]::ReadAllText($victimPath)) 'Do not remove'
    }
    Test-Case 'International names normalize consistently and survive UTF-8 settings' {
        $accentedName = 'Caf' + [char]0xe9
        $decomposedName = 'Cafe' + [char]0x301
        Assert-Equal (Get-EeaId $accentedName) (Get-EeaId $decomposedName)
        $installed = Install-EeaApp -AppName $decomposedName -Website 'https://example.com/' -Context $context -Confirm:$false
        Assert-Equal $installed.Name $accentedName
        $paths = Get-EeaPaths $context $accentedName
        $manifestBytes = [IO.File]::ReadAllBytes($paths.Manifest)
        Assert-Equal ($manifestBytes[0] -eq 0xef -and $manifestBytes[1] -eq 0xbb -and $manifestBytes[2] -eq 0xbf) $false
        Assert-Equal (Read-EeaManifest $context $accentedName).Name $accentedName
        Remove-EeaApp -AppName $accentedName -Context $context -Confirm:$false
    }
    Test-Case 'Apps named outside the Windows code page stay manageable' {
        $worldContext = [pscustomobject]@{ Root = (Join-Path $testRoot 'WorldNames\Data'); Desktop = (Join-Path $testRoot 'WorldNames\Desktop'); Programs = (Join-Path $testRoot 'WorldNames\Programs') }
        $worldNames = @(
            [string]::Concat([char[]]@(0x041F, 0x043E, 0x0447, 0x0442, 0x0430)),
            [string]::Concat([char[]]@(0x90AE, 0x4EF6)),
            ([char]::ConvertFromUtf32(0x1F4E7) + ' Mail')
        )
        foreach ($worldName in $worldNames) {
            $saved = Install-EeaApp -AppName $worldName -Website 'https://example.com/' -DedicatedProfile $false -Context $worldContext -Confirm:$false
            $worldPaths = Get-EeaPaths $worldContext $worldName
            Assert-Equal (Test-EeaOwnedShortcut $worldPaths.Desktop $saved $worldPaths) $true
            Assert-Equal (Test-EeaOwnedShortcut $worldPaths.StartMenu $saved $worldPaths) $true
            Assert-Equal @(Get-EeaChecks -AppNames @($worldName) -Context $worldContext)[0].Status 'Healthy'
            $updated = Install-EeaApp -AppName $worldName -Website 'https://example.com/updated' -Context $worldContext -Confirm:$false
            Assert-Equal $updated.Url 'https://example.com/updated'
            Remove-EeaApp -AppName $worldName -Context $worldContext -Confirm:$false
            Assert-Equal ([IO.File]::Exists($worldPaths.Desktop)) $false
            Assert-Equal ([IO.File]::Exists($worldPaths.Manifest)) $false
        }
    }
    Test-Case 'The Unicode shortcut reader agrees with Windows Script Host' {
        $readerRoot = Join-Path $testRoot 'ShortcutReader'
        [void][IO.Directory]::CreateDirectory($readerRoot)
        $shortcutPath = Join-Path $readerRoot 'Reader check.lnk'
        $targetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
        Write-EeaShortcut -Path $shortcutPath -Target $targetPath -Arguments (Get-EeaArguments 'https://example.com/?a=1&b=%22two%22#/x') -Description 'EasyEdgeApps:reader' -Icon ($targetPath + ',0') -WindowStyle 1
        $scriptHost = Read-EeaShortcut $shortcutPath
        $unicode = (Initialize-EeaShortcutReader)::Read($shortcutPath)
        foreach ($field in @('TargetPath', 'Arguments', 'Description', 'IconLocation', 'WorkingDirectory', 'WindowStyle')) {
            Assert-Equal ([string]$unicode.$field) ([string]$scriptHost.$field)
        }
    }
    Test-Case 'Changing placement removes only the previously owned shortcut' {
        Install-EeaApp -AppName 'Placement' -Website 'https://example.com/' -Context $context -Confirm:$false | Out-Null
        $paths = Get-EeaPaths $context 'Placement'
        $updated = Install-EeaApp -AppName 'Placement' -Website 'https://example.com/' -Desktop $false -Context $context -Confirm:$false
        Assert-Equal ([IO.File]::Exists($paths.Desktop)) $false
        Assert-Equal (Test-EeaOwnedShortcut $paths.StartMenu $updated $paths) $true
        Assert-Rejected { Install-EeaApp -AppName 'Placement' -Website 'https://example.com/' -Desktop $false -StartMenu $false -Context $context -Confirm:$false } '*Choose Desktop*'
        Remove-EeaApp -AppName 'Placement' -Context $context -Confirm:$false
    }
    Test-Case 'Changed saved icons are preserved instead of overwritten' {
        Install-EeaApp -AppName 'Icon Test' -Website 'https://example.com/' -Context $context -Confirm:$false | Out-Null
        $paths = Get-EeaPaths $context 'Icon Test'
        $originalIcon = [IO.File]::ReadAllBytes($paths.Icon)
        try {
            [IO.File]::WriteAllText($paths.Icon, 'A changed icon')
            Assert-Rejected { Remove-EeaApp -AppName 'Icon Test' -Context $context -Confirm:$false } '*saved icon was changed*'
            Assert-Equal ([IO.File]::ReadAllText($paths.Icon)) 'A changed icon'
        }
        finally { [IO.File]::WriteAllBytes($paths.Icon, $originalIcon) }
        Remove-EeaApp -AppName 'Icon Test' -Context $context -Confirm:$false
    }
    Test-Case 'A junction cannot redirect managed storage' {
        $foreignFolder = Join-Path $testRoot 'Foreign Folder'
        $junctionRoot = Join-Path $testRoot 'Junction Root'
        [void][IO.Directory]::CreateDirectory($foreignFolder)
        $junctionContext = [pscustomobject]@{ Root = $junctionRoot; Desktop = $context.Desktop; Programs = $context.Programs }
        New-Item -ItemType Junction -Path $junctionRoot -Target $foreignFolder | Out-Null
        try {
            Assert-Rejected { Install-EeaApp -AppName 'Junction Test' -Website 'https://example.com/' -Context $junctionContext -Confirm:$false } '*symbolic link or junction*'
            Assert-Equal ([IO.Directory]::GetFileSystemEntries($foreignFolder).Length) 0
        }
        finally { [IO.Directory]::Delete($junctionRoot, $false) }
    }
    Test-Case 'Concurrent setup in another process is rejected without writes' {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try { $mutexName = 'Local\EasyEdgeApps-' + $identity.User.Value }
        finally { $identity.Dispose() }
        $mutex = New-Object Threading.Mutex($false, $mutexName)
        $locked = $mutex.WaitOne(0)
        $job = $null
        try {
            Assert-Equal $locked $true
            $scriptPath = Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1'
            $job = Start-Job -ScriptBlock {
                param($ScriptPath, $Context)
                $ErrorActionPreference = 'Stop'
                . $ScriptPath
                try {
                    Install-EeaApp -AppName 'Concurrent Test' -Website 'https://example.com/' -Context $Context -Confirm:$false | Out-Null
                    return 'Unexpected success'
                }
                catch { return $_.Exception.Message }
            } -ArgumentList $scriptPath, $context
            $jobResult = Receive-Job -Job $job -Wait -ErrorAction Stop
            Assert-Equal ($jobResult -like '*Another Easy Edge Apps change is in progress*') $true
            Assert-Equal ($null -eq (Read-EeaManifest $context 'Concurrent Test')) $true
        }
        finally {
            if ($null -ne $job) { Remove-Job -Job $job -Force }
            if ($locked) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    Test-Case 'Removal preserves unknown files and unrelated shortcuts' {
        $paths = Get-EeaPaths $context 'My News'
        $personalFile = Join-Path $paths.Directory 'keep-me.txt'
        [IO.File]::WriteAllText($personalFile, 'Keep this file')
        Remove-EeaApp -AppName 'My News' -Context $context -Confirm:$false
        Assert-Equal ([IO.File]::Exists($paths.Manifest)) $false
        Assert-Equal ([IO.File]::Exists($paths.Desktop)) $false
        Assert-Equal ([IO.File]::Exists($paths.StartMenu)) $false
        Assert-Equal ([IO.File]::ReadAllText($personalFile)) 'Keep this file'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $context.Desktop 'Other News.lnk'))) 'An unrelated file'
        Assert-Equal @(Get-EeaApps -Context $context).Count 0
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

$failures = @($script:TestResults | Where-Object { -not $_.Passed })
foreach ($result in $script:TestResults) {
    $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ($status + ': ' + $result.Test)
}
if ($failures.Count -gt 0) {
    $failures | Format-List Test, Detail
    throw "$($failures.Count) of $($script:TestResults.Count) tests failed."
}
Write-Host "PASS: $($script:TestResults.Count) tests on PowerShell $($PSVersionTable.PSVersion)."