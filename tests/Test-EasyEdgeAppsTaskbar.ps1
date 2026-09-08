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
    param([string]$FilePath, [string]$ArgumentList)
    $script:ShellRequests.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = $ArgumentList })
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
    Write-Host ('PASS: Read-only taskbar pinning assistance, quoted Explorer selection, profile preservation, WhatIf, placement fallback, ownership checks, and recovery protection on PowerShell ' + $PSVersionTable.PSVersion + '.')
}
finally { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) } }