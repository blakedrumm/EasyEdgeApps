#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.LaunchSettings.' + [Guid]::NewGuid().ToString('N'))
$context = [pscustomobject]@{ Root = (Join-Path $testRoot 'Data'); Desktop = (Join-Path $testRoot 'Desktop'); Programs = (Join-Path $testRoot 'Programs') }

function Assert-LaunchSetting {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    $state = Install-EeaApp -AppName 'Window modes' -Website 'https://example.com/' -Context $context -Confirm:$false
    Assert-LaunchSetting ($state.SchemaVersion -eq 4 -and $state.DedicatedProfile -and $state.LaunchMode -ceq 'RememberLast' -and -not $state.AlwaysOnTop) 'New apps must default to a dedicated profile and remembered window size.'
    $paths = Get-EeaPaths $context $state.Name
    Assert-LaunchSetting ((Read-EeaShortcut $paths.Desktop).WindowStyle -eq 1) 'A managed shortcut must not override remembered size by forcing maximization.'
    foreach ($mode in @('RememberLast', 'Maximized', 'FullScreen')) {
        $topmost = $mode -ne 'FullScreen'
        $state = Install-EeaApp -AppName $state.Name -Website $state.Url -LaunchMode $mode -AlwaysOnTop $topmost -Context $context -Confirm:$false
        Assert-LaunchSetting ($state.LaunchMode -ceq $mode -and $state.AlwaysOnTop -eq $topmost) 'Launch choices must round-trip exactly.'
        Assert-LaunchSetting ((Get-EeaChecks -AppNames $state.Name -Context $context).Status -ceq 'Healthy') 'Expected source hashes must include each launch preference.'
        $state = Install-EeaApp -AppName $state.Name -Website $state.Url -Notes 'Preserved choices' -Context $context -Confirm:$false
        Assert-LaunchSetting ($state.LaunchMode -ceq $mode -and $state.AlwaysOnTop -eq $topmost -and $state.DedicatedProfile) 'Omitted update parameters must preserve local preferences.'
        $kit = New-EeaKit -AppNames @($state.Name) -Context $context
        $json = $kit | ConvertTo-Json -Depth 8
        Assert-LaunchSetting ($json -notmatch 'LaunchMode|AlwaysOnTop|DedicatedProfile|eea-window') 'Local window and profile choices must not leak into existing portable kit schemas.'
        [IO.File]::Delete($paths.Desktop)
        $result = Repair-EeaApps -AppNames @($state.Name) -Context $context -Confirm:$false
        Assert-LaunchSetting $result.Completed 'Repair must accept the new local schema.'
        $state = Read-EeaManifest $context $state.Name
        Assert-LaunchSetting ($state.LaunchMode -ceq $mode -and $state.AlwaysOnTop -eq $topmost) 'Repair must retain window choices.'
    }
    $before = (Get-FileHash -LiteralPath $paths.Manifest).Hash
    $rejected = $false
    try { $null = Install-EeaApp -AppName $state.Name -Website $state.Url -AlwaysOnTop $true -Context $context -Confirm:$false }
    catch { $rejected = $_.Exception.Message -like 'Always on top is available*' }
    Assert-LaunchSetting ($rejected -and (Get-FileHash -LiteralPath $paths.Manifest).Hash -ceq $before) 'Full-screen/topmost conflict must be rejected without changing saved state.'
    $normal = Install-EeaApp -AppName 'Normal profile' -Website 'https://example.org/' -DedicatedProfile $false -LaunchMode Maximized -Context $context -Confirm:$false
    Assert-LaunchSetting (-not (Test-EeaStateUsesLauncher $normal)) 'Explicit normal browsing must not acquire an isolated profile.'
    $normal = Install-EeaApp -AppName $normal.Name -Website $normal.Url -Notes 'Still normal' -Context $context -Confirm:$false
    Assert-LaunchSetting (-not (Get-EeaStateDedicatedProfile $normal)) 'Existing normal apps must not silently convert on update.'
    foreach ($parameters in @(@{ AlwaysOnTop = $true }, @{ LaunchMode = 'FullScreen' })) {
        $rejected = $false
        try { $null = Install-EeaApp -AppName $normal.Name -Website $normal.Url @parameters -Context $context -Confirm:$false }
        catch { $rejected = $_.Exception.Message -like '*dedicated or Fresh*' }
        Assert-LaunchSetting $rejected 'Managed window controls require explicit owned-profile consent.'
    }
    Write-Host 'PASS: New defaults, explicit normal profile, window preference persistence, kit privacy, repair, and invalid combinations.'
}
finally { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) } }