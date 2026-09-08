#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.Taskbar Tests.' + [Guid]::NewGuid().ToString('N'))
$context = [pscustomobject]@{ Root = (Join-Path $testRoot 'Data'); Desktop = (Join-Path $testRoot 'Desktop'); Programs = (Join-Path $testRoot 'Programs') }
$script:ShellRequests = New-Object 'Collections.Generic.List[object]'

function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
    $script:ShellRequests.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = $ArgumentList })
    if ($PassThru) { return [pscustomobject]@{ FilePath = $FilePath; Arguments = $ArgumentList } }
}

function Assert-Taskbar {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-TaskbarRejected {
    param([scriptblock]$Operation)
    $requestCount = $script:ShellRequests.Count
    $rejected = $false
    try { $null = & $Operation }
    catch { $rejected = $true }
    Assert-Taskbar ($rejected -and $script:ShellRequests.Count -eq $requestCount) 'An unavailable or unsafe shortcut must fail without opening Explorer.'
}

try {
    Assert-TaskbarRejected { Show-EeaTaskbarShortcut -AppName 'Not saved' -Context $context -Confirm:$false }
    Assert-Taskbar (-not [IO.Directory]::Exists($testRoot)) 'Pinning an unsaved website must create no data.'
    $appName = 'News, tools & more'
    $state = Install-EeaApp -AppName $appName -Website 'https://example.com/path?topic=news#latest' -EdgeProfile 'Profile 1' -Context $context -Confirm:$false
    $paths = Get-EeaPaths $context $appName
    $taskbarType = Initialize-EeaTaskbarTypes
    $identityShortcut = Join-Path $testRoot 'Identity.lnk'
    Write-EeaShortcut -Path $identityShortcut -Target $state.EdgePath -Arguments (Get-EeaArguments $state.Url -EdgeProfile 'Profile 1') -Description 'Synthetic taskbar identity test.' -Icon ($paths.Icon + ',0')
    $beforeIdentity = Read-EeaShortcut $identityShortcut
    $appId = 'EasyEdgeApps.Website.' + $paths.Id
    Assert-Taskbar ($taskbarType::GetShortcutAppId($identityShortcut) -ceq '') 'An ordinary shortcut must not acquire an app identity implicitly.'
    $taskbarType::SetShortcutAppId($identityShortcut, $appId)
    Assert-Taskbar ($taskbarType::GetShortcutAppId($identityShortcut) -ceq $appId) 'The Windows property store must retain the exact website app identity.'
    $afterIdentity = Read-EeaShortcut $identityShortcut
    foreach ($field in @('TargetPath', 'Arguments', 'Description', 'IconLocation', 'WorkingDirectory')) {
        Assert-Taskbar ($beforeIdentity.$field -ceq $afterIdentity.$field) ('Taskbar identity must preserve shortcut ' + $field + '.')
    }
    Add-Type -AssemblyName System.Windows.Forms
    $ownedWindow = New-Object Windows.Forms.Form
    try {
        $taskbarType::SetWindowIdentity($ownedWindow.Handle, $appId, $paths.Launcher, $appName, $paths.Icon)
        Assert-Taskbar ($taskbarType::GetWindowAppId($ownedWindow.Handle) -ceq $appId) 'An owned window and its shortcut must support the same stable app identity.'
    }
    finally { $ownedWindow.Dispose() }
    Write-Host 'PASS: Real shortcut and owned-window AppUserModelID round trips preserve existing shortcut fields.'
    $supportsPinRequests = $taskbarType::SupportsPinRequests()
    Assert-Taskbar ($supportsPinRequests -is [bool]) 'Pin capability detection must return a Boolean without requesting a pin.'
    if ($supportsPinRequests) {
        $pinClientType = $taskbarType.GetNestedType('PinClient')
        $pinClient = $null
        try { $pinClient = [Activator]::CreateInstance($pinClientType) }
        catch {
            if ($_.Exception.GetBaseException().HResult -ne -2147024891) { throw }
            Write-Host 'SKIP: This Windows session denies taskbar-manager activation (E_ACCESSDENIED). Owned shortcut tests and the launcher unavailable-result check still run.'
        }
        if ($null -ne $pinClient) {
            $pinCheck = $null
            try {
                Assert-Taskbar ($pinClient.IsPinningAllowed -is [bool]) 'The Windows pin-eligibility contract must be callable.'
                $pinCheck = $pinClient.CheckPinned()
                $deadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not $pinCheck.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents() }
                Assert-Taskbar ($pinCheck.IsCompleted -and $pinCheck.Result -is [bool]) 'The read-only Windows pinned-state operation must complete.'
            }
            finally { if ($null -ne $pinCheck) { $pinCheck.Dispose() }; $pinClient.Dispose() }
            Write-Host 'PASS: Native desktop pin capability, eligibility, and asynchronous read-only state checks without a pin request.'
        }
    }
    $manifestHash = (Get-FileHash -LiteralPath $paths.Manifest).Hash
    $iconHash = (Get-FileHash -LiteralPath $paths.Icon).Hash
    $startHash = (Get-FileHash -LiteralPath $paths.StartMenu).Hash
    $desktopHash = (Get-FileHash -LiteralPath $paths.Desktop).Hash
    $null = Show-EeaTaskbarShortcut -AppName $appName -Context $context -WhatIf
    Assert-Taskbar ($script:ShellRequests.Count -eq 0) 'WhatIf must not open Explorer or change the taskbar.'
    $selected = Show-EeaTaskbarShortcut -AppName $appName -Context $context -Confirm:$false
    Assert-Taskbar ($selected -ceq $paths.StartMenu -and $script:ShellRequests.Count -eq 1) 'Pinning assistance must prefer the owned Start menu shortcut.'
    $request = $script:ShellRequests[0]
    Assert-Taskbar ($request.FilePath -ceq (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -and $request.Arguments -ceq ('/select,"{0}"' -f $paths.StartMenu)) 'Explorer must use its absolute Windows path and one quoted shortcut selection, including spaces and punctuation.'
    Assert-Taskbar ((Get-FileHash -LiteralPath $paths.Manifest).Hash -ceq $manifestHash -and (Get-FileHash -LiteralPath $paths.Icon).Hash -ceq $iconHash -and (Get-FileHash -LiteralPath $paths.StartMenu).Hash -ceq $startHash -and (Get-FileHash -LiteralPath $paths.Desktop).Hash -ceq $desktopHash) 'Pinning assistance must not rewrite saved data, icons, profile arguments, or shortcuts.'
    Assert-Taskbar ((Read-EeaShortcut $selected).Arguments -ceq (Get-EeaArguments $state.Url -EdgeProfile 'Profile 1')) 'The selected shortcut must retain the website address and saved Edge profile.'
    [IO.File]::Delete($paths.StartMenu)
    Assert-Taskbar ((Show-EeaTaskbarShortcut -AppName $appName -Context $context -Confirm:$false) -ceq $paths.Desktop) 'A missing Start menu shortcut must fall back to the owned Desktop shortcut.'
    [IO.File]::WriteAllText($paths.StartMenu, 'Synthetic unrelated shortcut.')
    Assert-Taskbar ((Show-EeaTaskbarShortcut -AppName $appName -Context $context -Confirm:$false) -ceq $paths.Desktop) 'A changed Start menu shortcut must never be selected for pinning.'
    [IO.File]::Delete($paths.Desktop)
    Assert-TaskbarRejected { Show-EeaTaskbarShortcut -AppName $appName -Context $context -Confirm:$false }
    [IO.File]::Delete($paths.StartMenu)
    $null = Install-EeaApp -AppName $appName -Website $state.Url -Desktop $true -StartMenu $false -Context $context -Confirm:$false
    Assert-Taskbar ((Show-EeaTaskbarShortcut -AppName $appName -Context $context -Confirm:$false) -ceq $paths.Desktop) 'Desktop-only websites must support the same pinning assistance.'
    $null = Install-EeaApp -AppName $appName -Website $state.Url -Desktop $false -StartMenu $true -Context $context -Confirm:$false
    Assert-Taskbar ((Show-EeaTaskbarShortcut -AppName $appName -Context $context -Confirm:$false) -ceq $paths.StartMenu) 'Start-menu-only websites must support the same pinning assistance.'
    [void][IO.Directory]::CreateDirectory((Join-Path $context.Root '.pending'))
    Assert-TaskbarRejected { Show-EeaTaskbarShortcut -AppName $appName -Context $context -Confirm:$false }
    Assert-Taskbar ($null -eq $state.PSObject.Properties['Taskbar']) 'Windows-owned pin state must not be represented as a saved placement flag.'
    [IO.Directory]::Delete((Join-Path $context.Root '.pending'))
    $taskbarApp = Install-EeaApp -AppName 'Dedicated taskbar app' -Website 'https://example.com/' -Taskbar $true -EdgeProfile 'Profile 1' -Context $context -Confirm:$false
    $taskbarPaths = Get-EeaPaths $context $taskbarApp.Name
    Assert-Taskbar ($taskbarApp.SchemaVersion -eq 3 -and (Get-EeaStateTaskbar $taskbarApp) -and -not (Get-EeaStateFreshSession $taskbarApp)) 'Taskbar opt-in must select a persistent app launcher, not fresh browsing or claimed Windows pin state.'
    Assert-Taskbar ((Read-EeaShortcut $taskbarPaths.StartMenu).TargetPath -ieq $taskbarPaths.Launcher -and $taskbarType::GetShortcutAppId($taskbarPaths.StartMenu) -ceq ('EasyEdgeApps.Website.' + $taskbarPaths.Id)) 'Taskbar shortcuts must use their dedicated executable and exact per-website identity.'
    Assert-Taskbar ((Get-EeaChecks -AppNames $taskbarApp.Name -Context $context).Status -ceq 'Healthy') 'A new taskbar app must have current owned launcher metadata.'
    $queryInfo = New-Object Diagnostics.ProcessStartInfo($taskbarPaths.Launcher, '--pin-state')
    $queryInfo.UseShellExecute = $false
    $queryProcess = [Diagnostics.Process]::Start($queryInfo)
    try {
        Assert-Taskbar ($queryProcess.WaitForExit(15000) -and $queryProcess.ExitCode -in @(3, 4)) 'An unpinned synthetic launcher must query Windows without creating a browser or a pin.'
        Assert-Taskbar (-not [IO.Directory]::Exists((Join-Path $taskbarPaths.Directory 'AppProfile')) -and -not [IO.Directory]::Exists((Join-Path $taskbarPaths.Directory 'Sessions'))) 'A pin-state query must not create browser data.'
    }
    finally { if (-not $queryProcess.HasExited) { $queryProcess.Kill() }; $queryProcess.Dispose() }
    $requestCount = $script:ShellRequests.Count
    if ($supportsPinRequests) {
        $null = Request-EeaTaskbarPin -AppName $taskbarApp.Name -Context $context -WhatIf
        Assert-Taskbar ($script:ShellRequests.Count -eq $requestCount) 'Pin WhatIf must not start the launcher or ask Windows.'
        $pin = Request-EeaTaskbarPin -AppName $taskbarApp.Name -Context $context -Confirm:$false
        Assert-Taskbar ($pin.FilePath -ceq $taskbarPaths.Launcher -and $pin.Arguments -ceq '--pin') 'Pinning must request only the saved website identity through its verified launcher.'
    }
    $taskbarApp = Install-EeaApp -AppName $taskbarApp.Name -Website 'https://example.com/updated' -Context $context -Confirm:$false
    Assert-Taskbar (Get-EeaStateTaskbar $taskbarApp) 'Omitting the taskbar choice must preserve the dedicated app on update.'
    $kit = New-EeaKit -AppNames $taskbarApp.Name -Context $context
    Assert-Taskbar ($null -eq $kit.Apps[0].PSObject.Properties['Taskbar']) 'Machine-local taskbar choices and pin state must not travel in App Kits.'
    $requestCount = $script:ShellRequests.Count
    $conflictingKit = ConvertFrom-EeaJson ($kit | ConvertTo-Json -Depth 8)
    $conflictingKit.Apps[0].StartMenu = $false
    $beforeConflict = Get-EeaAppSnapshot -Paths $taskbarPaths -EdgePath $taskbarApp.EdgePath
    Assert-Taskbar ((Get-EeaKitPreview -Kit $conflictingKit -Context $context).Action -ceq 'Conflict') 'An import that removes a taskbar app Start entry must be blocked during preview.'
    $conflictingImport = Import-EeaKit -Kit $conflictingKit -Context $context -Confirm:$false
    Assert-Taskbar (-not $conflictingImport.Completed -and (Get-EeaAppSnapshot -Paths $taskbarPaths -EdgePath $taskbarApp.EdgePath) -ceq $beforeConflict) 'A conflicting kit must preserve all dedicated app files without partial updates.'
    $kit.Apps[0].Notes = 'A portable edit without taskbar pin intent.'
    $import = Import-EeaKit -Kit $kit -Context $context -Confirm:$false
    Assert-Taskbar ($import.Completed -and (Get-EeaStateTaskbar (Read-EeaManifest $context $taskbarApp.Name)) -and $script:ShellRequests.Count -eq $requestCount) 'Ordinary kit edits must preserve destination taskbar mode without requesting a Windows pin.'
    $profileRoot = Join-Path $taskbarPaths.Directory 'AppProfile'
    $launcherAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($taskbarPaths.Launcher))
    $launcherType = $launcherAssembly.GetType('EeaFreshSession')
    $profileLease = $launcherType::OpenAppProfile($profileRoot)
    try { [IO.File]::WriteAllText((Join-Path $profileRoot 'Cookies'), 'Synthetic retained taskbar data.') }
    finally { $profileLease.Dispose() }
    [IO.File]::Delete($taskbarPaths.Launcher)
    $repair = Repair-EeaApps -AppNames $taskbarApp.Name -Context $context -Confirm:$false
    Assert-Taskbar ($repair.Completed -and (Get-EeaStateTaskbar (Read-EeaManifest $context $taskbarApp.Name))) 'Repair must preserve dedicated persistent app mode without asking Windows to pin.'
    Assert-Taskbar ($script:ShellRequests.Count -eq $requestCount -and [IO.File]::ReadAllText((Join-Path $profileRoot 'Cookies')) -ceq 'Synthetic retained taskbar data.') 'Repair must neither request a pin nor modify persistent app data.'
    $taskbarType::SetShortcutAppId($taskbarPaths.StartMenu, ('EasyEdgeApps.Website.' + ('0' * 64)))
    Assert-Taskbar (-not (Test-EeaOwnedShortcut $taskbarPaths.StartMenu $taskbarApp $taskbarPaths)) 'Changing a taskbar identity must break shortcut ownership.'
    $taskbarType::SetShortcutAppId($taskbarPaths.StartMenu, ('EasyEdgeApps.Website.' + $taskbarPaths.Id))
    $taskbarApp = Install-EeaApp -AppName $taskbarApp.Name -Website $taskbarApp.Url -Taskbar $false -Context $context -Confirm:$false
    Assert-Taskbar ($taskbarApp.SchemaVersion -eq 1 -and (Read-EeaShortcut $taskbarPaths.StartMenu).Arguments.Contains('--profile-directory="Profile 1"')) 'Explicit taskbar opt-out must restore the saved normal-profile route.'
    Remove-EeaApp -AppName $taskbarApp.Name -Context $context -Confirm:$false
    Assert-Taskbar ([IO.File]::ReadAllText((Join-Path $profileRoot 'Cookies')) -ceq 'Synthetic retained taskbar data.') 'Taskbar opt-out and removal must preserve the separate persistent browser profile.'
    Write-Host 'PASS: Taskbar app opt-in, exact launcher and shortcut identities, supported pin request, WhatIf, update preservation, repair, kit exclusion, tampering, and explicit opt-out.'
    Write-Host ('PASS: Read-only taskbar pinning assistance, quoted Explorer selection, profile preservation, WhatIf, placement fallback, ownership checks, and recovery protection on PowerShell ' + $PSVersionTable.PSVersion + '.')
}
finally { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) } }