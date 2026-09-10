#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory, [switch]$SkipInstaller)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repository = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repository 'artifacts\compiled' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith((Join-Path $repository 'artifacts\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Build local packages only under this repository artifacts directory.' }
$build = Join-Path $output ('build-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $build 'portable'
[void][IO.Directory]::CreateDirectory($payload)
$version = '2.0.0'
$label = '2.0.0-preview.1'
Push-Location $repository
try {
    & dotnet restore ./EasyEdgeApps.slnx --locked-mode
    if ($LASTEXITCODE -ne 0) { throw 'Locked compiled dependency restore failed.' }
    & (Join-Path $PSScriptRoot 'Export-NativeSource.ps1') -Verify
    if (-not $?) { throw 'Native source parity verification failed.' }
    & (Join-Path $PSScriptRoot 'Export-BrandAssets.ps1')
    if (-not $?) { throw 'Original brand generation failed.' }
    & dotnet build ./src/EasyEdgeApps.SiteLauncher/EasyEdgeApps.SiteLauncher.csproj -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
    & dotnet publish ./src/EasyEdgeApps.SiteLauncher/EasyEdgeApps.SiteLauncher.csproj -c Release -f net10.0-windows10.0.19041.0 -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o ./artifacts/launcher-net10-comparison
    if ($LASTEXITCODE -ne 0) { throw 'Self-contained LTS launcher publishing failed.' }
    & dotnet publish ./src/EasyEdgeApps.Manager/EasyEdgeApps.Manager.csproj -c Release -p:Platform=x64 -o $payload
    if ($LASTEXITCODE -ne 0) { throw 'Self-contained WinUI publishing failed.' }
    & dotnet publish ./src/EasyEdgeApps.Cli/EasyEdgeApps.Cli.csproj -c Release -r win-x64 --self-contained true -o $payload
    if ($LASTEXITCODE -ne 0) { throw 'Self-contained CLI publishing failed.' }
    & dotnet publish ./src/EasyEdgeApps.ImageWorker/EasyEdgeApps.ImageWorker.csproj -c Release -r win-x64 --self-contained true -o $payload
    if ($LASTEXITCODE -ne 0) { throw 'Self-contained image worker publishing failed.' }
    $legacyOutput = Join-Path $build 'legacy'
    $legacyResults = @(& (Join-Path $PSScriptRoot 'Build-Installer.ps1') -OutputDirectory $legacyOutput)
    if (-not $?) { throw 'Preserved PowerShell distribution build failed.' }
    $legacy = @($legacyResults | Where-Object { $null -ne $_.PSObject.Properties['BuildRoot'] })
    if ($legacy.Count -ne 1) { throw 'The legacy build did not return exactly one artifact record.' }
    $legacy = $legacy[0]
    Copy-Item -LiteralPath (Join-Path $legacy.BuildRoot 'EasyEdgeApps.exe') -Destination (Join-Path $payload 'EasyEdgeApps.exe')
    Copy-Item -LiteralPath (Join-Path $repository 'EasyEdgeApps.ps1') -Destination $payload
    Copy-Item -LiteralPath (Join-Path $legacy.BuildRoot 'THIRD-PARTY-NOTICES.md') -Destination $payload
    $compiledNotice = [IO.File]::ReadAllText((Join-Path $repository 'docs\Compiled-Third-Party-Notices.md'))
    [IO.File]::AppendAllText((Join-Path $payload 'THIRD-PARTY-NOTICES.md'), "`r`n`r`n" + $compiledNotice, (New-Object Text.UTF8Encoding($false)))
    & (Join-Path $PSScriptRoot 'Export-CompiledNotices.ps1') -OutputDirectory (Join-Path $payload 'Licenses')
    if (-not $?) { throw 'Exact restored package notice retention failed.' }
    $files = @(Get-ChildItem -LiteralPath $payload -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{ Path = $_.FullName.Substring($payload.Length + 1).Replace('\', '/'); Size = $_.Length; Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $indexPath = Join-Path $build 'release-index.json'
    [IO.File]::WriteAllText($indexPath, ([ordered]@{ Product = 'EasyEdgeApps.Package'; SchemaVersion = 1; Version = $version; Architecture = 'x64'; Files = $files } | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
    & dotnet build ./src/EasyEdgeApps.PackageIndex/EasyEdgeApps.PackageIndex.csproj -c Release ('-p:ReleaseIndexPath=' + $indexPath) -o (Join-Path $build 'index')
    if ($LASTEXITCODE -ne 0) { throw 'Package index compilation failed.' }
    Copy-Item -LiteralPath (Join-Path $build 'index\EasyEdgeApps.PackageIndex.dll') -Destination $payload
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $output ('EasyEdgeApps-' + $label + '-x64.zip')
    if ([IO.File]::Exists($zipPath)) { throw 'The output archive already exists. Choose a new artifacts output directory to preserve previous evidence.' }
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    $msiPath = $null
    if (-not $SkipInstaller) {
        $msiPath = Join-Path $output ('EasyEdgeApps-' + $label + '-x64.msi')
        & (Join-Path $PSScriptRoot 'New-CompiledInstaller.ps1') -PayloadDirectory $payload -BuildDirectory $build -OutputPath $msiPath -Version $version -LegacyBuildDirectory $legacy.BuildRoot
        if (-not $?) { throw 'Compiled MSI build failed.' }
    }
    $artifacts = @($zipPath)
    if ($msiPath) { $artifacts += $msiPath }
    $sums = @($artifacts | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($_) })
    [IO.File]::WriteAllLines((Join-Path $output 'SHA256SUMS.txt'), $sums, (New-Object Text.UTF8Encoding($false)))
    $bytes = [long](Get-ChildItem -LiteralPath $payload -Recurse -File | Measure-Object Length -Sum).Sum
    $result = [ordered]@{ Version = $label; SigningStatus = 'UNSIGNED TEST ARTIFACTS: checksums are not publisher authentication'; PortableDirectory = $payload; Zip = $zipPath; Msi = $msiPath; PayloadBytes = $bytes; LauncherBytes = (Get-Item -LiteralPath (Join-Path $payload 'WebsiteLauncher\fresh-session.exe')).Length }
    [IO.File]::WriteAllText((Join-Path $output 'build-result.json'), ($result | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Write-Host ($result | ConvertTo-Json)
}
finally { Pop-Location }