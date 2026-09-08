#requires -Version 5.1

[CmdletBinding()]
param([switch]$Interactive, [string]$ResumeTestRoot, [string]$ResumeAppName)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $Interactive -or $PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Run this manual Windows pin acceptance test with powershell.exe -STA and -Interactive.' }
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
Add-Type -AssemblyName System.Windows.Forms
$tokens = $null
$parseErrors = $null
$browserTest = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-EasyEdgeAppsFreshSessionBrowser.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The shared synthetic browser fixture does not parse.' }
$fixture = $browserTest.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public sealed class FreshSessionHttpProbe') }, $true)
if ($null -eq $fixture) { throw 'The shared synthetic browser fixture is missing.' }
Add-Type -ReferencedAssemblies System, System.Core, System.Drawing -TypeDefinition $fixture.Value
$taskbarType = Initialize-EeaTaskbarTypes
if (-not $taskbarType::SupportsPinRequests()) { throw 'This Windows installation does not support native desktop pin requests without an access token.' }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.TaskbarAcceptance.' + [Guid]::NewGuid().ToString('N'))
if ($ResumeTestRoot -or $ResumeAppName) {
    if (-not $ResumeTestRoot -or $ResumeAppName -cnotmatch '\AEasy Edge Apps Taskbar Check [a-f0-9]{8}\z' -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ResumeTestRoot)), [IO.Path]::GetTempPath().TrimEnd('\')) -or
        [IO.Path]::GetFileName($ResumeTestRoot) -cnotmatch '\AEasyEdgeApps\.TaskbarAcceptance\.[a-f0-9]{32}\z') { throw 'Resume requires the exact owned synthetic test folder and app name.' }
    $testRoot = [IO.Path]::GetFullPath($ResumeTestRoot)
}
$context = [pscustomobject]@{
    Root = Join-Path $testRoot 'Data'
    Desktop = Join-Path $testRoot 'Desktop'
    Programs = Join-Path ([Environment]::GetFolderPath('Programs')) 'Easy Edge Apps'
}
$appName = if ($ResumeAppName) { $ResumeAppName } else { 'Easy Edge Apps Taskbar Check ' + [Guid]::NewGuid().ToString('N').Substring(0, 8) }
$paths = Get-EeaPaths $context $appName
$server = New-Object FreshSessionHttpProbe
$pinProcess = $null
$pinStarted = [bool]$ResumeAppName
$installed = $false

function Get-TestPinState {
    $startInfo = New-Object Diagnostics.ProcessStartInfo($paths.Launcher, '--pin-state')
    $startInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'The test pin query did not complete.' }
        return $process.ExitCode
    }
    finally { $process.Dispose() }
}

try {
    if ($ResumeAppName) {
        $previousState = Read-EeaManifest $context $appName
        if ($null -eq $previousState -or -not (Get-EeaStateFreshSession $previousState) -or -not (Get-EeaStateTaskbar $previousState)) { throw 'The retained test app is not a verified fresh taskbar app.' }
    }
    $state = Install-EeaApp -AppName $appName -Website ($server.Origin + '/app') -FreshSession $true -Taskbar $true -Desktop $false -Context $context -Confirm:$false
    $installed = $true
    $initialPinState = Get-TestPinState
    if ($initialPinState -ne $(if ($ResumeAppName) { 0 } else { 3 })) { throw 'The synthetic app does not have the expected initial pin state.' }
    Write-Host ('Synthetic test app: ' + $appName)
    Write-Host 'Only this test app and its temporary Guest profile are used. Normal Edge data is not changed.'
    if (-not $ResumeAppName) { $pinProcess = Request-EeaTaskbarPin -AppName $appName -Context $context -Confirm:$false }
    $pinStarted = $true
    $null = Read-Host $(if ($ResumeAppName) { 'Click the existing synthetic taskbar pin to open its website, then press Enter' } else { 'Activate the test app, approve Windows taskbar pinning, click its new pinned icon, then press Enter' })
    if ($null -ne $pinProcess) {
        if (-not $pinProcess.WaitForExit(10000)) { throw 'The test pin request has not finished.' }
        Write-Host ('Pin request exit code: ' + $pinProcess.ExitCode)
    }
    $verifiedPinState = Get-TestPinState
    Write-Host ('Windows pin-state exit code: ' + $verifiedPinState)
    if ($verifiedPinState -ne 0) { throw 'Windows did not confirm the test taskbar pin.' }
    $report = ConvertFrom-EeaJson ($server.WaitForReport())
    if ($report.before.cookie -cne '' -or $null -ne $report.before.storage -or $report.cache -cne 'cache-1') { throw 'The pinned launch did not start with a fresh synthetic browser state.' }
    $sessionsRoot = Join-Path $paths.Directory 'Sessions'
    $directories = @([IO.Directory]::GetDirectories($sessionsRoot))
    if ($directories.Count -ne 1 -or -not [IO.Directory]::Exists((Join-Path $directories[0] 'Profile\Guest Profile'))) { throw 'The pinned shortcut did not use exactly one isolated Guest profile.' }
    $browsers = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($directories[0]) })
    $windows = @($browsers | ForEach-Object { [FreshSessionHttpProbe]::FindTestWindow($_.ProcessId) } | Where-Object { $_ -ne [IntPtr]::Zero })
    if ($windows.Count -ne 1 -or $taskbarType::GetWindowAppId($windows[0]) -cne ('EasyEdgeApps.Website.' + $paths.Id) -or $taskbarType::GetShortcutAppId($paths.StartMenu) -cne ('EasyEdgeApps.Website.' + $paths.Id)) { throw 'The pinned shortcut and its single browser app window do not share the exact website identity.' }
    Write-Host 'PASS: Windows approved the actual taskbar pin, and launching the pin opened one fresh Guest website window with the matching app identity.'
    $visualResult = Read-Host 'Unpin only the synthetic test app. Enter yes if it used one website icon, or no if an extra Edge entry appeared'
    if ((Get-TestPinState) -ne 3) { throw 'The synthetic app is still pinned. Its files will be retained so the pin remains usable.' }
    if ($visualResult -ine 'yes') { throw 'The visible taskbar grouping did not pass manual acceptance.' }
    Write-Host 'PASS: Manual single-icon taskbar grouping and Windows-confirmed removal of the synthetic pin.'
}
finally {
    if ($null -ne $pinProcess) {
        if (-not $pinProcess.HasExited) { $pinProcess.Kill(); [void]$pinProcess.WaitForExit(10000) }
        $pinProcess.Dispose()
    }
    $ownedLaunchers = @(Get-CimInstance Win32_Process -Filter "Name='fresh-session.exe'" | Where-Object { $_.ExecutablePath -and [StringComparer]::OrdinalIgnoreCase.Equals($_.ExecutablePath, $paths.Launcher) })
    foreach ($launcher in $ownedLaunchers) {
        try {
            $process = [Diagnostics.Process]::GetProcessById($launcher.ProcessId)
            try {
                $browsers = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($paths.Directory) })
                foreach ($browser in $browsers) { [void][FreshSessionHttpProbe]::CloseTestWindows($browser.ProcessId) }
                if (-not $process.WaitForExit(25000)) { $process.Kill(); [void]$process.WaitForExit(10000) }
            }
            finally { $process.Dispose() }
        }
        catch [ArgumentException] { }
    }
    $server.Dispose()
    $safeToRemove = -not $pinStarted
    if ($installed -and $pinStarted) {
        try { $safeToRemove = (Get-TestPinState) -eq 3 }
        catch { $safeToRemove = $false }
    }
    if ($installed -and $safeToRemove) {
        Remove-EeaApp -AppName $appName -Context $context -Confirm:$false
        if ([IO.Directory]::Exists($testRoot)) {
            try { [IO.Directory]::Delete($testRoot, $true) }
            catch { Write-Warning ('Synthetic profile cleanup remains at: ' + $testRoot) }
        }
    }
    elseif ($installed) { Write-Warning ('Test pin state is not confirmed unpinned. The owned test app remains at: ' + $paths.Directory) }
}