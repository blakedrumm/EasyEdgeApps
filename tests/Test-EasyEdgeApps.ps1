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
    Test-Case 'Unrelated shortcut collision is preserved' {
        $foreignPath = Join-Path $context.Desktop 'Other News.lnk'
        [IO.File]::WriteAllText($foreignPath, 'An unrelated file')
        Assert-Rejected { Install-EeaApp -AppName 'Other News' -Website 'https://example.org/' -Context $context -Confirm:$false } '*already exists*'
        Assert-Equal ([IO.File]::ReadAllText($foreignPath)) 'An unrelated file'
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