#requires -Version 5.1

[CmdletBinding()]
param([switch]$Persistent, [switch]$ExerciseEscape, [switch]$ManualEscape, [switch]$BeforeDiscovery)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($BeforeDiscovery -and -not $ExerciseEscape) { throw '-BeforeDiscovery requires -ExerciseEscape.' }
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\WindowProbe.cs')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.WindowBrowser.' + [Guid]::NewGuid().ToString('N'))
$sessions = New-Object 'Collections.Generic.List[object]'
$launcher = Join-Path $testRoot 'fresh-session.exe'

function Wait-WindowProbe {
    param([scriptblock]$Condition, [string]$Failure, [int]$Seconds = 8)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        [Windows.Forms.Application]::DoEvents()
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($sessions.Count -gt 0 -and $sessions[$sessions.Count - 1].Window -ne [IntPtr]::Zero) {
        $failedSession = $sessions[$sessions.Count - 1]
        Write-Host ([EeaWindowProbe]::Describe($failedSession.Window))
    }
    throw $Failure
}

function Open-WindowProbe {
    $session = [pscustomobject]@{ Process = (Start-Process -FilePath $launcher -PassThru); Job = ''; Window = [IntPtr]::Zero }
    $sessions.Add($session)
    Wait-WindowProbe -Seconds 25 -Failure 'The disposable website window did not open.' -Condition {
        if ($session.Process.HasExited) { throw 'The disposable launcher exited before opening its window.' }
        if ($Persistent) { $session.Job = 'Local\EasyEdgeApps-App-' + $script:WindowAppId }
        else {
            $sessionsRoot = Join-Path $testRoot 'Sessions'
            if (-not [IO.Directory]::Exists($sessionsRoot)) { return $false }
            $directories = [IO.Directory]::GetDirectories($sessionsRoot)
            if ($directories.Length -ne 1) { return $false }
            $session.Job = 'Local\EasyEdgeApps-Fresh-' + [IO.Path]::GetFileName($directories[0])
        }
        $windows = [EeaWindowProbe]::Find($session.Job)
        if ($windows.Length -ne 1) { return $false }
        $session.Window = $windows[0]
        return $true
    }
    return $session
}

function Close-WindowProbe {
    param($Session)
    [EeaWindowProbe]::Close($Session.Job, $Session.Window)
    $exited = $Session.Process.WaitForExit(25000)
    if (-not $exited -or $Session.Process.ExitCode -ne 0) {
        $remainingWindows = @([EeaWindowProbe]::Find($Session.Job))
        foreach ($remainingWindow in $remainingWindows) { Write-Host ([EeaWindowProbe]::Describe($remainingWindow)) }
        $exitStatus = if ($exited) { [string]$Session.Process.ExitCode } else { 'still running' }
        throw ('The disposable window did not close and clean its session. Launcher: {0}; remaining owned windows: {1}.' -f $exitStatus, $remainingWindows.Count)
    }
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    New-EeaIcon -Path (Join-Path $testRoot 'icon.ico') -AppName 'Window test'
    $parameters = @{ Path = $launcher; Website = 'http://127.0.0.1:9/'; EdgePath = (Find-EeaEdge); AppName = 'Window test'; FreshSession = (-not $Persistent) }
    Write-EeaSessionLauncher @parameters -LaunchMode RememberLast -AlwaysOnTop $true
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($launcher))
    $launcherType = $assembly.GetType('EeaFreshSession')
    $script:WindowAppId = $launcherType::AppId((Join-Path $testRoot 'Sessions'))
    $first = Open-WindowProbe
    Wait-WindowProbe { [EeaWindowProbe]::IsTopmost($first.Window) } 'Always on top was not applied to the owned window.'
    $work = [EeaWindowProbe]::WorkArea($first.Window)
    $expected = [int[]]@(($work[0] + 40), ($work[1] + 40), ([Math]::Min(900, $work[2] - 80)), ([Math]::Min(600, $work[3] - 80)))
    [EeaWindowProbe]::Resize($first.Job, $first.Window, $expected[0], $expected[1], $expected[2], $expected[3])
    Wait-WindowProbe { ([EeaWindowProbe]::Bounds($first.Window) -join ',') -ceq ($expected -join ',') } 'The owned resize fixture did not reach its intended bounds.'
    Close-WindowProbe $first
    if (-not [IO.File]::Exists((Join-Path $testRoot '.eea-window'))) { throw 'Closing a resized app did not retain its local placement.' }
    $second = Open-WindowProbe
    Wait-WindowProbe { ([EeaWindowProbe]::Bounds($second.Window) -join ',') -ceq ($expected -join ',') } 'The reopened app did not restore its last window bounds.'
    Wait-WindowProbe { [EeaWindowProbe]::IsTopmost($second.Window) } 'Always on top did not survive reopening.'
    Close-WindowProbe $second
    Write-Host 'PASS: Real owned window size and position restore independently of browser data; Always on top survives reopening.'
    Write-EeaSessionLauncher @parameters -LaunchMode Maximized -AlwaysOnTop $false
    $maximized = Open-WindowProbe
    Wait-WindowProbe { [EeaWindowProbe]::IsZoomed($maximized.Window) } 'The explicit maximized app did not open maximized.'
    if ([EeaWindowProbe]::IsTopmost($maximized.Window)) { throw 'An app with Always on top off unexpectedly remained topmost.' }
    Close-WindowProbe $maximized
    Write-Host 'PASS: Maximized launch overrides placement, and Always on top can be disabled.'
    $rejected = $false
    try { $null = Get-EeaSessionLauncherSource -Website $parameters.Website -EdgePath $parameters.EdgePath -LaunchMode FullScreen -AlwaysOnTop $true }
    catch { $rejected = $_.Exception.Message -like 'Always on top is available*' }
    if (-not $rejected) { throw 'Unsupported fullscreen/topmost combinations must be rejected explicitly.' }
    if ($BeforeDiscovery) {
        $windowSource = Get-EeaWindowSource
        if ([regex]::Matches($windowSource, [regex]::Escape('timer.Start();')).Count -ne 1) { throw 'The initial window-discovery test injection is no longer valid.' }
        $script:WindowProbeSource = $windowSource.Replace('timer.Start();', 'if (mode != 2) timer.Start();')
        $originalWindowSource = ${function:Get-EeaWindowSource}
        try {
            Set-Item -Path Function:Get-EeaWindowSource -Value { return $script:WindowProbeSource }
            Write-EeaSessionLauncher @parameters -LaunchMode FullScreen -AlwaysOnTop $false
        }
        finally {
            Set-Item -Path Function:Get-EeaWindowSource -Value $originalWindowSource
            Remove-Variable -Name WindowProbeSource -Scope Script
        }
    }
    else { Write-EeaSessionLauncher @parameters -LaunchMode FullScreen -AlwaysOnTop $false }
    $full = Open-WindowProbe
    Wait-WindowProbe { [EeaWindowProbe]::IsFullScreen($full.Window) } 'The full-screen app did not fill its monitor.'
    if ($ExerciseEscape) {
        [EeaWindowProbe]::Key($full.Job, $full.Window, 27)
        Wait-WindowProbe { -not [EeaWindowProbe]::IsFullScreen($full.Window) } 'Escape did not exit the foreground owned full-screen window.'
        Write-Host 'PASS: Foreground-verified Escape input exited the owned full-screen window.'
        if ($BeforeDiscovery) { Write-Host 'PASS: Escape worked before cached window discovery with the test launcher timer disabled.' }
    }
    elseif ($ManualEscape) {
        Write-Host 'MANUAL CHECK: Click the synthetic Window test app and press Escape. Do not use F11 or close it yet.'
        Wait-WindowProbe -Seconds 90 -Condition { -not [EeaWindowProbe]::IsFullScreen($full.Window) } -Failure 'Manual Escape acceptance did not complete.'
        Write-Host 'PASS: The manual full-screen exit was observed; operator must confirm Escape was the key used.'
    }
    else { Write-Host 'PASS: Full-screen bounds and topmost incompatibility verified. Keyboard acceptance requires -ExerciseEscape or -ManualEscape.' }
    Close-WindowProbe $full
}
finally {
    foreach ($session in $sessions) {
        if (-not $session.Process.HasExited) {
            foreach ($window in [EeaWindowProbe]::Find($session.Job)) { [EeaWindowProbe]::Close($session.Job, $window) }
            if (-not $session.Process.WaitForExit(25000)) { $session.Process.Kill(); $session.Process.WaitForExit() }
        }
        $session.Process.Dispose()
    }
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}