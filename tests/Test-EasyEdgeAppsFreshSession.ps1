#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.FreshSessionTests.' + [Guid]::NewGuid().ToString('N'))

function Assert-FreshSession {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-FreshSessionRejected {
    param([scriptblock]$Operation)
    $rejected = $false
    try { $null = & $Operation } catch { $rejected = $true }
    Assert-FreshSession $rejected 'Unsafe or changed session data must be rejected.'
}

function Start-Process {
    param([string]$FilePath, [string]$ArgumentList, $ErrorAction)
    $script:LastLaunch = [pscustomobject]@{ Path = $FilePath; Arguments = $ArgumentList }
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $launcherPath = Join-Path $testRoot 'fresh-session.exe'
    Write-EeaSessionLauncher -Path $launcherPath -Website 'https://example.com/?query=a%22b#/home' -EdgePath (Find-EeaEdge)
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($launcherPath))
    Assert-FreshSession ($null -ne $assembly.GetType('EeaFreshSession')) 'The self-contained native session launcher must compile.'
    $sessionsRoot = Join-Path $testRoot 'Sessions'
    $firstSession = [EeaFreshSession]::CreateSession($sessionsRoot)
    $secondSession = [EeaFreshSession]::CreateSession($sessionsRoot)
    Assert-FreshSession ($firstSession -cne $secondSession) 'Every launch must receive a unique session directory.'
    $lease = [IO.File]::Open((Join-Path $firstSession '.eea-session'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        Assert-FreshSession (-not [EeaFreshSession]::TryCleanup($sessionsRoot, $firstSession)) 'An active session lease must prevent cleanup.'
        Assert-FreshSession ([EeaFreshSession]::TryCleanup($sessionsRoot, $secondSession)) 'An abandoned owned session must be removable independently.'
        Assert-FreshSession ([IO.Directory]::Exists($firstSession)) 'Cleaning another session must preserve the active one.'
    }
    finally { $lease.Dispose() }
    $profileRoot = Join-Path $firstSession 'Profile'
    [void][IO.Directory]::CreateDirectory($profileRoot)
    [IO.File]::WriteAllText((Join-Path $profileRoot 'Cookies'), 'Synthetic cookie fixture.')
    Assert-FreshSession ([EeaFreshSession]::TryCleanup($sessionsRoot, $firstSession)) 'Owned synthetic cookies and profile files must be removed after the lease closes.'
    $unrelated = Join-Path $sessionsRoot ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($unrelated)
    [IO.File]::WriteAllText((Join-Path $unrelated 'keep.txt'), 'Unrelated fixture.')
    Assert-FreshSession (-not [EeaFreshSession]::TryCleanup($sessionsRoot, $unrelated) -and [IO.File]::Exists((Join-Path $unrelated 'keep.txt'))) 'Unmarked directories must never be deleted.'
    Assert-FreshSession (-not [EeaFreshSession]::TryCleanup($sessionsRoot, $testRoot)) 'Cleanup must not escape the computed sessions root.'
    $invalidMarkerSession = [EeaFreshSession]::CreateSession($sessionsRoot)
    $invalidMarkerPath = Join-Path $invalidMarkerSession '.eea-session'
    [IO.File]::WriteAllText($invalidMarkerPath, 'EasyEdgeApps.FreshSession:2')
    Assert-FreshSession (-not [EeaFreshSession]::TryCleanup($sessionsRoot, $invalidMarkerSession) -and [IO.File]::Exists($invalidMarkerPath)) 'An unrecognized marker must never authorize cleanup.'
    [IO.File]::WriteAllText($invalidMarkerPath, 'EasyEdgeApps.FreshSession:1')
    Assert-FreshSession ([EeaFreshSession]::TryCleanup($sessionsRoot, $invalidMarkerSession)) 'The exact owned marker must remain usable.'
    $arguments = [EeaFreshSession]::Arguments('https://example.com/?query=a%22b#/home', (Join-Path $testRoot 'Profile with spaces'))
    Assert-FreshSession ($arguments.Contains('--user-data-dir="') -and $arguments.Contains('--disable-background-mode') -and -not $arguments.Contains('--profile-directory')) 'Fresh launches must isolate user data without requesting a normal profile.'
    $processSession = [EeaFreshSession]::CreateSession($sessionsRoot)
    $markerPath = Join-Path $processSession 'completed.txt'
    $commandPath = Join-Path $env:WINDIR 'System32\cmd.exe'
    [EeaFreshSession]::RunProcess($commandPath, ('/d /c "echo done>""' + $markerPath + '"""'), $processSession)
    Assert-FreshSession ([IO.File]::Exists($markerPath)) 'The job must launch the assigned process and wait for completion.'
    Assert-FreshSession ([EeaFreshSession]::TryCleanup($sessionsRoot, $processSession)) 'Completed job data must be removable.'
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $processFixture = Join-Path $testRoot 'process-fixture.exe'
    & $compiler /nologo /target:exe /platform:x64 ('/reference:' + $launcherPath) ('/out:' + $processFixture) (Join-Path $PSScriptRoot 'fixtures\FreshSessionProcess.cs')
    Assert-FreshSession ($LASTEXITCODE -eq 0) 'The isolated child-process fixture must compile.'
    & $processFixture verify $sessionsRoot
    Assert-FreshSession ($LASTEXITCODE -eq 0) 'Session jobs must preserve complete child-tree lifetime and support interruption cleanup.'
    $lockedSession = [EeaFreshSession]::CreateSession($sessionsRoot)
    $lockedFile = Join-Path $lockedSession 'Cookies'
    $lock = [IO.File]::Open($lockedFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert-FreshSession (-not [EeaFreshSession]::TryCleanup($sessionsRoot, $lockedSession)) 'Locked files must leave a recognizable session for later cleanup.'
        Assert-FreshSession ([IO.File]::Exists((Join-Path $lockedSession '.eea-session'))) 'Failed cleanup must retain its ownership marker.'
    }
    finally { $lock.Dispose() }
    Assert-FreshSession ([EeaFreshSession]::TryCleanup($sessionsRoot, $lockedSession)) 'Cleanup must be retryable after a temporary file lock ends.'
    $linkedSession = [EeaFreshSession]::CreateSession($sessionsRoot)
    $junction = Join-Path $linkedSession 'Profile'
    $null = New-Item -ItemType Junction -Path $junction -Target $unrelated
    try {
        Assert-FreshSession (-not [EeaFreshSession]::TryCleanup($sessionsRoot, $linkedSession) -and [IO.File]::Exists((Join-Path $unrelated 'keep.txt'))) 'Session cleanup must never follow a junction into unrelated files.'
        Assert-FreshSessionRejected { [EeaFreshSession]::CreateSession((Join-Path $junction 'More')) }
    }
    finally { [IO.Directory]::Delete($junction, $false) }
    Assert-FreshSession ([EeaFreshSession]::TryCleanup($sessionsRoot, $linkedSession)) 'An owned session must remain removable after its unsafe link is removed.'
    foreach ($unsafeWebsite in @('file:///C:/Windows', 'https://user:password@example.com/', 'https://example.com/" --injected')) {
        Assert-FreshSessionRejected { [EeaFreshSession]::Arguments($unsafeWebsite, $testRoot) }
    }
    $context = [pscustomobject]@{ Root = (Join-Path $testRoot 'Data'); Desktop = (Join-Path $testRoot 'Desktop'); Programs = (Join-Path $testRoot 'Programs') }
    $null = Install-EeaApp -AppName 'Fresh test' -Website 'https://example.com/' -FreshSession $true -Context $context -WhatIf
    Assert-FreshSession (-not [IO.Directory]::Exists($context.Root)) 'Fresh-session WhatIf must not compile or create any app data.'
    $saved = Install-EeaApp -AppName 'Fresh test' -Website 'https://example.com/' -EdgeProfile 'Profile 1' -FreshSession $true -Context $context -Confirm:$false
    $paths = Get-EeaPaths $context $saved.Name
    $shortcut = Read-EeaShortcut $paths.Desktop
    Assert-FreshSession ($saved.SchemaVersion -eq 2 -and (Get-EeaStateFreshSession $saved) -and $saved.EdgeProfile -ceq 'Profile 1') 'Fresh apps must use a fail-closed schema while retaining the normal-profile choice.'
    Assert-FreshSession ($shortcut.TargetPath -ieq $paths.Launcher -and $shortcut.Arguments -ceq '' -and (Test-EeaOwnedShortcut $paths.Desktop $saved $paths)) 'Fresh shortcuts must target only their owned no-argument native launcher.'
    $manifestBytes = [IO.File]::ReadAllBytes($paths.Manifest)
    try {
        foreach ($mutation in @(
            { param($candidate) $candidate.SchemaVersion = '2' },
            { param($candidate) $candidate.SchemaVersion = 1 },
            { param($candidate) $candidate.FreshSession = $false },
            { param($candidate) $candidate.FreshSession = 'true' },
            { param($candidate) $candidate.PSObject.Properties.Remove('FreshSession') },
            { param($candidate) $candidate.LauncherHash = 'invalid' },
            { param($candidate) $candidate.PSObject.Properties.Remove('LauncherSourceHash') }
        )) {
            $candidate = ConvertFrom-EeaJson ([Text.Encoding]::UTF8.GetString($manifestBytes))
            & $mutation $candidate
            [IO.File]::WriteAllText($paths.Manifest, ($candidate | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
            Assert-FreshSessionRejected { Start-EeaApp -AppName $saved.Name -Context $context -Confirm:$false }
        }
    }
    finally { [IO.File]::WriteAllBytes($paths.Manifest, $manifestBytes) }
    $script:LastLaunch = $null
    Start-EeaApp -AppName $saved.Name -Context $context -Confirm:$false
    Assert-FreshSession ($script:LastLaunch.Path -ceq $paths.Launcher -and -not $script:LastLaunch.Arguments) 'Opening a fresh app must use the verified native launcher without command-line input.'
    $saved = Install-EeaApp -AppName $saved.Name -Website 'https://example.com/updated' -Context $context -Confirm:$false
    Assert-FreshSession ((Get-EeaStateFreshSession $saved) -and $saved.Url.EndsWith('/updated')) 'Omitted session options must preserve the saved fresh-session choice on update.'
    $beforeFailure = Get-EeaAppSnapshot -Paths $paths -EdgePath $saved.EdgePath
    $script:OriginalSessionWriter = ${function:Write-EeaSessionLauncher}
    try {
        function Write-EeaSessionLauncher { param($Path, $Website, $EdgePath) throw 'Synthetic compiler failure.' }
        Assert-FreshSessionRejected { Install-EeaApp -AppName $saved.Name -Website 'https://example.com/compiler-failure' -Context $context -Confirm:$false }
    }
    finally { Set-Item -LiteralPath Function:\Write-EeaSessionLauncher -Value $script:OriginalSessionWriter }
    Assert-FreshSession ((Get-EeaAppSnapshot -Paths $paths -EdgePath $saved.EdgePath) -ceq $beforeFailure) 'Compiler failure must preserve all saved app bytes.'
    $script:OriginalSessionAtomicWriter = ${function:Write-EeaAtomicFile}
    $script:FailSessionShortcut = $paths.Desktop
    try {
        function Write-EeaAtomicFile {
            param($Source, $Destination)
            if ($Destination -ceq $script:FailSessionShortcut -and $Source.EndsWith('Desktop.lnk')) { throw 'Synthetic session transaction failure.' }
            & $script:OriginalSessionAtomicWriter -Source $Source -Destination $Destination
        }
        Assert-FreshSessionRejected { Install-EeaApp -AppName $saved.Name -Website 'https://example.com/rollback-failure' -Context $context -Confirm:$false }
    }
    finally { Set-Item -LiteralPath Function:\Write-EeaAtomicFile -Value $script:OriginalSessionAtomicWriter }
    Assert-FreshSession ((Get-EeaAppSnapshot -Paths $paths -EdgePath $saved.EdgePath) -ceq $beforeFailure) 'A failed shortcut write must roll back the changed session executable, icon, and manifest.'
    $launcherLease = [IO.File]::Open($paths.Launcher, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Assert-FreshSessionRejected { Install-EeaApp -AppName $saved.Name -Website 'https://example.com/in-use' -Context $context -Confirm:$false }
        Assert-FreshSession ((Get-EeaAppSnapshot -Paths $paths -EdgePath $saved.EdgePath) -ceq $beforeFailure) 'An in-use launcher must prevent an update without changing saved files.'
        Assert-FreshSessionRejected { Remove-EeaApp -AppName $saved.Name -Context $context -Confirm:$false }
        Assert-FreshSession ((Get-EeaAppSnapshot -Paths $paths -EdgePath $saved.EdgePath) -ceq $beforeFailure) 'Failed in-use removal must restore the owned shortcuts and preserve the website.'
    }
    finally { $launcherLease.Dispose() }
    [IO.File]::Delete($paths.Launcher)
    Assert-FreshSessionRejected { Start-EeaApp -AppName $saved.Name -Context $context -Confirm:$false }
    Assert-FreshSession ((Get-EeaChecks -AppNames $saved.Name -Context $context).Status -ceq 'Repairable') 'Missing launchers must be repairable without a normal-profile launch fallback.'
    $repair = Repair-EeaApps -AppNames $saved.Name -Context $context -Confirm:$false
    Assert-FreshSession ($repair.Completed -and [IO.File]::Exists($paths.Launcher) -and (Get-EeaStateFreshSession (Read-EeaManifest $context $saved.Name))) 'Repair must restore the launcher and preserve the session choice.'
    $kit = New-EeaKit -Context $context
    Assert-FreshSession ($kit.SchemaVersion -eq 2 -and $kit.Apps[0].FreshSession -and $null -eq $kit.Apps[0].PSObject.Properties['LauncherHash'] -and $null -eq $kit.Apps[0].PSObject.Properties['EdgeProfile']) 'Portable session choices require version 2 without executable, profile, or browser data.'
    $destination = [pscustomobject]@{ Root = (Join-Path $testRoot 'Destination\Data'); Desktop = (Join-Path $testRoot 'Destination\Desktop'); Programs = (Join-Path $testRoot 'Destination\Programs') }
    $imported = Import-EeaKit -Kit $kit -Context $destination -Confirm:$false
    Assert-FreshSession ($imported.Completed -and (Get-EeaStateFreshSession (Read-EeaManifest $destination $saved.Name))) 'Kit imports must recreate the fresh-session launcher locally.'
    Assert-FreshSession ((Get-EeaKitPreview -Kit $kit -Context $destination).Action -ceq 'Unchanged') 'Fresh-session kit imports must remain idempotent.'
    $legacyKit = ConvertFrom-EeaJson ($kit | ConvertTo-Json -Depth 8)
    $legacyKit.SchemaVersion = 1
    Assert-FreshSessionRejected { ConvertTo-EeaKit $legacyKit }
    $legacyKit.Apps[0].PSObject.Properties.Remove('FreshSession')
    $legacyKit.Apps[0].Notes = 'Legacy imported edit.'
    $legacyResult = Import-EeaKit -Kit $legacyKit -Context $destination -Confirm:$false
    Assert-FreshSession ($legacyResult.Completed -and (Get-EeaStateFreshSession (Read-EeaManifest $destination $saved.Name))) 'A legacy kit must not silently disable existing fresh sessions.'
    $normalKit = ConvertFrom-EeaJson ($kit | ConvertTo-Json -Depth 8)
    $normalKit.Apps[0].FreshSession = $false
    Assert-FreshSession ((Get-EeaKitPreview -Kit $normalKit -Context $destination).Detail.Contains('FRESH SESSIONS DISABLED')) 'Preview must explicitly disclose a requested return to persistent browsing.'
    $normalResult = Import-EeaKit -Kit $normalKit -Context $destination -Confirm:$false
    Assert-FreshSession ($normalResult.Completed -and -not (Get-EeaStateFreshSession (Read-EeaManifest $destination $saved.Name))) 'An approved explicit version-2 session choice must apply.'
    foreach ($invalidChoice in @('true', 1, $null)) {
        $normalKit.Apps[0].FreshSession = $invalidChoice
        Assert-FreshSessionRejected { ConvertTo-EeaKit $normalKit }
    }
    $launcherBytes = [IO.File]::ReadAllBytes($paths.Launcher)
    [IO.File]::WriteAllText($paths.Launcher, 'Unrelated executable fixture.')
    Assert-FreshSessionRejected { Start-EeaApp -AppName $saved.Name -Context $context -Confirm:$false }
    Assert-FreshSessionRejected { Install-EeaApp -AppName $saved.Name -Website $saved.Url -Context $context -Confirm:$false }
    Assert-FreshSessionRejected { Remove-EeaApp -AppName $saved.Name -Context $context -Confirm:$false }
    [IO.File]::WriteAllBytes($paths.Launcher, $launcherBytes)
    $saved = Install-EeaApp -AppName $saved.Name -Website $saved.Url -FreshSession $false -Context $context -Confirm:$false
    Assert-FreshSession ($saved.SchemaVersion -eq 1 -and -not (Get-EeaStateFreshSession $saved) -and -not [IO.File]::Exists($paths.Launcher)) 'Explicit opt-out must remove only the owned launcher and restore normal manifest compatibility.'
    Assert-FreshSession ((Read-EeaShortcut $paths.Desktop).Arguments.Contains('--profile-directory="Profile 1"')) 'Disabling fresh sessions must restore the previously saved normal-profile choice.'
    Remove-EeaApp -AppName $saved.Name -Context $context -Confirm:$false
    Write-Host ('PASS: Native session compilation, fresh identities, quoted arguments, process jobs, exclusive leases, and owned-only cleanup on PowerShell ' + $PSVersionTable.PSVersion + '.')
}
finally {
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}