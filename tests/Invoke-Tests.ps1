#requires -Version 5.1

[CmdletBinding()]
param([switch]$BothHosts, [string]$ScreenshotDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$projectRoot = Split-Path $PSScriptRoot -Parent
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
        & $hostPath @options
        if ($LASTEXITCODE -ne 0) { throw "$suite failed in $hostName." }
    }
    Write-Host "PASS: All $($suites.Count) isolated suites completed in $hostName."
}