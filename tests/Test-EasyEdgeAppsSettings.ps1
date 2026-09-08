#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.SettingsTests.' + [Guid]::NewGuid().ToString('N'))
$context = [pscustomobject]@{ Root = (Join-Path $testRoot 'Data'); Desktop = (Join-Path $testRoot 'Desktop'); Programs = (Join-Path $testRoot 'Programs') }

function Assert-Settings {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-SettingsRejected {
    param([scriptblock]$Operation)
    $rejected = $false
    try { $null = & $Operation }
    catch { $rejected = $true }
    Assert-Settings $rejected 'Malformed application settings must be rejected.'
}

try {
    $settings = Get-EeaSettings -Context $context
    Assert-Settings (-not [IO.Directory]::Exists($testRoot)) 'Reading default settings must create no files or folders.'
    Assert-Settings (-not $settings.AutomaticUpdateChecks -and -not $settings.DebugLogging -and $settings.DefaultEdgeProfile -ceq '') 'Automatic network checks, logging, and forced profiles must be opt-in.'
    Assert-Settings ($settings.DefaultDesktop -and $settings.DefaultStartMenu -and $settings.MotionEnabled -and $settings.TextSize -eq 12) 'Existing placement, motion, and text defaults must remain compatible.'
    $null = Save-EeaSettings -Settings $settings -Context $context -WhatIf
    Write-EeaDebugLog -Event SetupOpened -Settings $settings -Context $context
    Assert-Settings (-not [IO.Directory]::Exists($testRoot)) 'WhatIf and disabled diagnostics must create no storage.'
    foreach ($profileDirectory in @('', 'Default', 'Profile 1', 'Profile 999999')) {
        Assert-Settings ((ConvertTo-EeaProfileDirectory $profileDirectory) -ceq $profileDirectory) 'Valid profile directory identifiers must be retained exactly.'
    }
    foreach ($profileDirectory in @('..\Other', 'C:\Edge', 'Profile 1" --disable-web-security', 'default', 'Profile 1234567', 'Default ', "Default`n", "Profile 1`n", "`n")) {
        Assert-SettingsRejected { ConvertTo-EeaProfileDirectory $profileDirectory }
    }
    foreach ($mutation in @(
        { param($candidate) $candidate.AutomaticUpdateChecks = 'true' },
        { param($candidate) $candidate.SchemaVersion = '1' },
        { param($candidate) $candidate.SchemaVersion = 2 },
        { param($candidate) $candidate.DefaultDesktop = $false; $candidate.DefaultStartMenu = $false },
        { param($candidate) $candidate.DefaultEdgeProfile = '--inprivate' },
        { param($candidate) $candidate.TextSize = 1 },
        { param($candidate) $candidate | Add-Member -NotePropertyName UpdateUrl -NotePropertyValue 'https://other.example/' },
        { param($candidate) $candidate.PSObject.Properties.Remove('DebugLogging') }
    )) {
        $candidate = New-EeaSettings
        & $mutation $candidate
        Assert-SettingsRejected { ConvertTo-EeaSettings $candidate }
    }
    $settingsPath = Join-Path $context.Root 'settings.json'
    $settings.DefaultEdgeProfile = 'Profile 1'
    $settings.TextSize = 16
    $null = Save-EeaSettings -Settings $settings -Context $context -Confirm:$false
    $loaded = Get-EeaSettings -Context $context
    Assert-Settings ($loaded.DefaultEdgeProfile -ceq 'Profile 1' -and $loaded.TextSize -eq 16) 'Validated settings must round-trip through the bounded JSON reader.'
    $settings.DebugLogging = $true
    $null = Save-EeaSettings -Settings $settings -Context $context -Confirm:$false
    Assert-Settings ((Get-EeaSettings -Context $context).DebugLogging -and @(Get-ChildItem -LiteralPath $context.Root -Filter '*.tmp').Count -eq 0) 'Atomic replacement must save changed preferences without leftover temporary files.'
    Write-EeaDebugLog -Event Error -Outcome Failed -ErrorType 'System.InvalidOperationException' -Context $context
    $logPath = Join-Path $context.Root 'Logs\debug.jsonl'
    $entry = ConvertFrom-EeaJson ([IO.File]::ReadAllText($logPath))
    Assert-Settings ($entry.Event -ceq 'Error' -and $entry.ErrorType -ceq 'System.InvalidOperationException' -and @($entry.PSObject.Properties).Count -eq 6) 'Logs must contain only fixed diagnostic fields, not website or user content.'
    Assert-SettingsRejected { Write-EeaDebugLog -Event Error -ErrorType 'https://example.com/private?token=secret' -Context $context }
    Assert-SettingsRejected { Write-EeaDebugLog -Event Error -ErrorType "InvalidOperationException`n" -Context $context }
    [IO.File]::WriteAllText($logPath, (' ' * 262144))
    Write-EeaDebugLog -Event AppSaved -Context $context
    Assert-Settings ((Get-Item -LiteralPath $logPath).Length -lt 1024 -and [IO.File]::Exists((Join-Path $context.Root 'Logs\debug.previous.jsonl'))) 'Debug logs must rotate at the fixed size bound.'
    $unrelated = Join-Path $context.Root 'Logs\keep.txt'
    [IO.File]::WriteAllText($unrelated, 'Synthetic unrelated file.')
    Clear-EeaDebugLogs -Context $context -WhatIf
    Assert-Settings ([IO.File]::Exists($logPath)) 'Log cleanup WhatIf must preserve logs.'
    Clear-EeaDebugLogs -Context $context -Confirm:$false
    Assert-Settings (-not [IO.File]::Exists($logPath) -and [IO.File]::Exists($unrelated) -and [IO.File]::Exists($settingsPath)) 'Log cleanup must preserve preferences and unrelated files.'
    $savedApp = Install-EeaApp -AppName 'Profile test' -Website 'https://example.com/' -Context $context -Confirm:$false
    $appPaths = Get-EeaPaths $context $savedApp.Name
    Assert-Settings ($savedApp.EdgeProfile -ceq 'Profile 1' -and (Read-EeaShortcut $appPaths.Desktop).Arguments -ceq '--app="https://example.com/" --start-maximized --profile-directory="Profile 1"') 'New shortcuts must record and launch the configured default profile safely.'
    $settings.DefaultEdgeProfile = 'Profile 2'
    $null = Save-EeaSettings -Settings $settings -Context $context -Confirm:$false
    [IO.File]::Delete($appPaths.Desktop)
    $savedApp = Install-EeaApp -AppName 'Profile test' -Website 'https://example.com/updated' -Context $context -Confirm:$false
    Assert-Settings ($savedApp.EdgeProfile -ceq 'Profile 1' -and (Test-EeaOwnedShortcut $appPaths.Desktop $savedApp $appPaths)) 'Changed defaults must not break ownership or change an existing app profile during repair.'
    $kit = New-EeaKit -Context $context
    Assert-Settings ($null -eq $kit.Apps[0].PSObject.Properties['EdgeProfile']) 'Portable kits must not carry machine-local Edge profile preferences.'
    $savedApp = Install-EeaApp -AppName 'Profile test' -Website 'https://example.com/updated' -EdgeProfile '' -Context $context -Confirm:$false
    Assert-Settings ((Get-EeaStateProfile $savedApp) -ceq '' -and (Read-EeaShortcut $appPaths.Desktop).Arguments -ceq '--app="https://example.com/updated" --start-maximized') 'An explicit empty profile must restore Edge-controlled profile selection.'
    Assert-SettingsRejected { Install-EeaApp -AppName 'Unsafe profile' -Website 'https://example.com/' -EdgeProfile 'Default" --disable-web-security' -Context $context -Confirm:$false }
    Remove-EeaApp -AppName 'Profile test' -Context $context -Confirm:$false
    [IO.File]::WriteAllText($settingsPath, '{"Product":"EasyEdgeApps.Settings","Product":"duplicate"}')
    Assert-SettingsRejected { Get-EeaSettings -Context $context }
    [IO.File]::WriteAllText($settingsPath, (' ' * 16385))
    Assert-SettingsRejected { Get-EeaSettings -Context $context }
    Write-Host ('PASS: Settings defaults, validation, atomic saves, safe profile identifiers, private rotating diagnostics, and selective cleanup on PowerShell ' + $PSVersionTable.PSVersion + '.')
}
finally { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) } }