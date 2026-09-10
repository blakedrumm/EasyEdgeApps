#requires -Version 5.1

[CmdletBinding()]
param([switch]$BothHosts, [string]$ScreenshotDirectory, [string]$ResultDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not $ResultDirectory) { $ResultDirectory = Join-Path $projectRoot ('artifacts\legacy-tests-' + [Guid]::NewGuid().ToString('N')) }
$ResultDirectory = [IO.Path]::GetFullPath($ResultDirectory)
if (-not $ResultDirectory.StartsWith((Join-Path $projectRoot 'artifacts\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep isolated test results under repository artifacts.' }
[void][IO.Directory]::CreateDirectory($ResultDirectory)
$temporaryDirectory = Join-Path $projectRoot ('artifacts\t-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($temporaryDirectory)
$results = New-Object 'Collections.Generic.List[object]'
foreach ($sourceFile in @(Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter '*.ps1' -File)) {
    $parseTokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($sourceFile.FullName, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
}
Write-Host "PASS: All PowerShell source parses on $($PSVersionTable.PSVersion)."

$hostPaths = if ($BothHosts) { @((Get-Command powershell.exe -ErrorAction Stop).Source, (Get-Command pwsh.exe -ErrorAction Stop).Source) }
    else { @((Get-Process -Id $PID).Path) }
$suites = @('Test-EasyEdgeApps.ps1', 'Test-EasyEdgeAppsJson.ps1', 'Test-EasyEdgeAppsFavorites.ps1',
    'Test-EasyEdgeAppsWebsiteIcon.ps1', 'Test-EasyEdgeAppsSettings.ps1', 'Test-EasyEdgeAppsUpdates.ps1', 'Test-EasyEdgeAppsTaskbar.ps1',
    'Test-EasyEdgeAppsFreshSession.ps1',
    'Test-EasyEdgeAppsWindowState.ps1', 'Test-EasyEdgeAppsLaunchSettings.ps1', 'Test-EasyEdgeAppsEditorState.ps1',
    'Test-EasyEdgeAppsKitWindowTransitions.ps1',
    'Test-EasyEdgeAppsReleaseTools.ps1',
    'Test-EasyEdgeAppsKits.ps1', 'Test-EasyEdgeAppsCrypto.ps1', 'Test-EasyEdgeAppsKitFiles.ps1',
    'Test-EasyEdgeAppsCli.ps1', 'Test-EasyEdgeAppsGui.ps1', 'Test-EasyEdgeAppsToolsGui.ps1')
foreach ($hostPath in $hostPaths) {
    $hostName = [IO.Path]::GetFileNameWithoutExtension($hostPath)
    foreach ($suite in $suites) {
        $options = @('-NoLogo', '-NoProfile', '-STA', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot $suite))
        if ($suite -in @('Test-EasyEdgeAppsGui.ps1', 'Test-EasyEdgeAppsToolsGui.ps1')) {
            $options += @('-MaximumWindowWidth', '1024', '-MaximumWindowHeight', '768')
            if ($ScreenshotDirectory) {
                $capturePath = Join-Path (Join-Path $ScreenshotDirectory $hostName) ([IO.Path]::GetFileNameWithoutExtension($suite))
                $options += @('-ScreenshotDirectory', $capturePath)
            }
        }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $hostPath
        $start.Arguments = [string]::Join(' ', [string[]]@($options | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }))
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['TEMP'] = $temporaryDirectory
        $start.EnvironmentVariables['TMP'] = $temporaryDirectory
        if ($hostName -eq 'powershell') { $start.EnvironmentVariables['PSModulePath'] = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\Modules' }
        else { $start.EnvironmentVariables.Remove('PSModulePath') }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $process = [Diagnostics.Process]::Start($start)
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $log = Join-Path $ResultDirectory ($hostName + '-' + [IO.Path]::GetFileNameWithoutExtension($suite) + '.log')
        try {
            if (-not $process.WaitForExit(300000)) { $process.Kill(); [void]$process.WaitForExit(10000); throw "$suite exceeded its isolated five-minute deadline in $hostName." }
            [IO.File]::WriteAllText($log, $standardOutput.GetAwaiter().GetResult() + $standardError.GetAwaiter().GetResult(), (New-Object Text.UTF8Encoding($false)))
            $results.Add([ordered]@{ Host = $hostName; Suite = $suite; ExitCode = $process.ExitCode; Milliseconds = $clock.ElapsedMilliseconds; Log = [IO.Path]::GetFileName($log) })
            [IO.File]::WriteAllText((Join-Path $ResultDirectory 'results.json'), (ConvertTo-Json -InputObject $results.ToArray() -Depth 4), (New-Object Text.UTF8Encoding($false)))
            if ($process.ExitCode -ne 0) { throw "$suite failed in $hostName. See $log" }
            Write-Host ("PASS: {0} / {1} ({2} ms)" -f $hostName, $suite, $clock.ElapsedMilliseconds)
        }
        finally { $process.Dispose() }
    }
    Write-Host "PASS: All $($suites.Count) isolated suites completed in $hostName."
}