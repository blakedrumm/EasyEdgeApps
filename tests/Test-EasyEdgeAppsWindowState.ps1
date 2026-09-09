#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.WindowState.' + [Guid]::NewGuid().ToString('N'))

function Assert-WindowState {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $launcher = Join-Path $testRoot 'fresh-session.exe'
    Write-EeaSessionLauncher -Path $launcher -Website 'https://example.com/' -EdgePath (Find-EeaEdge) -LaunchMode RememberLast
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($launcher))
    $stateType = $assembly.GetType('EasyEdgeApps.Windowing.Placement')
    Assert-WindowState ($null -ne $stateType) 'The launcher must contain the owned window placement implementation.'
    $work = [int[]]@(-1920, 40, 1920, 1040)
    $normal = $stateType::Normalize([int[]]@(-1800, 60, 900, 700, 1), $work)
    Assert-WindowState (($normal -join ',') -ceq '-1800,60,900,700,1') 'Valid negative-monitor coordinates must be preserved.'
    $clamped = $stateType::Normalize([int[]]@(12000, -20000, 6000, 5000, 3), $work)
    Assert-WindowState (($clamped -join ',') -ceq '-1920,40,1920,1040,3') 'Removed-monitor and oversize placement must fit the selected work area.'
    foreach ($invalid in @([int[]]@(0, 0, -1, 500, 1), [int[]]@(0, 0, 500, 500, 2), [int[]]@([int]::MaxValue, 0, 500, 500, 1), [int[]]@(0, 0, 500, 0, 1))) {
        Assert-WindowState ($null -eq $stateType::Normalize($invalid, $work)) 'Invalid geometry must be rejected without overflow or minimized restoration.'
    }
    $small = $stateType::Normalize([int[]]@(0, 0, 1, 1, 1), [int[]]@(0, 0, 320, 200))
    Assert-WindowState (($small -join ',') -ceq '0,0,320,200,1') 'Minimum dimensions must never exceed a genuinely small work area.'
    $path = Join-Path $testRoot '.eea-window'
    $appId = 'EasyEdgeApps.Website.' + ('a' * 64)
    Assert-WindowState ($stateType::Write($path, $appId, $normal)) 'Valid local placement must be atomically saved.'
    Assert-WindowState (($stateType::Read($path, $appId) -join ',') -ceq ($normal -join ',')) 'Placement must round-trip independently of browser data.'
    Assert-WindowState ($null -eq $stateType::Read($path, ('EasyEdgeApps.Website.' + ('b' * 64)))) 'Placement must be bound to the website identity.'
    $locked = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { Assert-WindowState (-not $stateType::Write($path, $appId, $normal)) 'A locked placement file must not block or overwrite the owner.' }
    finally { $locked.Dispose() }
    [IO.File]::WriteAllText($path, 'Unrecognized file')
    Assert-WindowState ($null -eq $stateType::Read($path, $appId)) 'Malformed placement must fall back safely.'
    Assert-WindowState (-not $stateType::Write($path, $appId, $normal)) 'Unrecognized existing files must not be overwritten.'
    Assert-WindowState ([IO.File]::ReadAllText($path) -ceq 'Unrecognized file') 'Unrecognized bytes must remain intact.'
    $missing = Join-Path $testRoot 'removed\.eea-window'
    Assert-WindowState (-not $stateType::Write($missing, $appId, $normal) -and -not [IO.Directory]::Exists((Join-Path $testRoot 'removed'))) 'A late geometry write must never recreate a removed app folder.'
    $controller = $assembly.GetType('EasyEdgeApps.Windowing.Controller')
    Assert-WindowState ($null -ne $controller) 'The launcher must contain the owned window controller.'
    Assert-WindowState ($controller::ShouldHandleEscape(0, 0x100, 27, $true, $true, $false)) 'Unmodified Escape in the owned fullscreen window must be handled.'
    foreach ($case in @(@(-1, 0x100, 27, $true, $true, $false), @(0, 0x101, 27, $true, $true, $false), @(0, 0x100, 65, $true, $true, $false), @(0, 0x100, 27, $false, $true, $false), @(0, 0x100, 27, $true, $false, $false), @(0, 0x100, 27, $true, $true, $true))) {
        Assert-WindowState (-not $controller::ShouldHandleEscape($case[0], $case[1], $case[2], $case[3], $case[4], $case[5])) 'Unrelated, modified, released, or non-fullscreen input must pass through.'
    }
    Write-Host 'PASS: Owned placement format, bounds, atomic persistence, input scope, and safe fallback.'
}
finally { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) } }