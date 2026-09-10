#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repository = Split-Path $PSScriptRoot -Parent
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith((Join-Path $repository 'artifacts\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep generated license files inside repository artifacts.' }
if ([IO.Directory]::Exists($output)) { throw 'Generate notices into a new directory to avoid mixing package inventories.' }
$packages = New-Object 'Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
$assetsFiles = @(Get-ChildItem -Path (Join-Path $repository 'src\*\obj\project.assets.json') -File)
if ($assetsFiles.Count -lt 8) { throw 'Restore all compiled production projects before collecting their package notices.' }
foreach ($assetFile in $assetsFiles) {
    $assets = [IO.File]::ReadAllText($assetFile.FullName) | ConvertFrom-Json
    $folders = @($assets.packageFolders.PSObject.Properties.Name)
    $keys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($library in $assets.libraries.PSObject.Properties) {
        if ($library.Value.type -eq 'package') { [void]$keys.Add($library.Name) }
    }
    foreach ($framework in $assets.project.frameworks.PSObject.Properties) {
        if ($framework.Value.PSObject.Properties.Name -notcontains 'downloadDependencies') { continue }
        foreach ($dependency in $framework.Value.downloadDependencies) {
            if ($dependency.version -notmatch '^\[([^,\]]+)(?:,\s*\1)?\]$') { throw 'Runtime package version must be an exact restored version.' }
            [void]$keys.Add($dependency.name + '/' + $Matches[1])
        }
    }
    foreach ($key in $keys) {
        if ($packages.ContainsKey($key)) { continue }
        if ($key -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.+-]+$') { throw 'Unexpected restored package identity.' }
        $packagePath = $null
        foreach ($folder in $folders) {
            $candidate = Join-Path $folder ($key.ToLowerInvariant().Replace('/', '\'))
            if ([IO.Directory]::Exists($candidate)) { $packagePath = $candidate; break }
        }
        if (-not $packagePath) { throw ('Restored package content is unavailable: ' + $key) }
        $parts = $key.Split('/')
        $packages.Add($key, [pscustomobject]@{ Id = $parts[0]; Version = $parts[1]; Root = $packagePath })
    }
}
[void][IO.Directory]::CreateDirectory($output)
$inventory = New-Object 'Collections.Generic.List[object]'
foreach ($package in $packages.Values) {
    $specs = @(Get-ChildItem -LiteralPath $package.Root -Filter '*.nuspec' -File)
    if ($specs.Count -ne 1) { throw ('Expected one package manifest: ' + $package.Id) }
    $document = New-Object Xml.XmlDocument
    $document.XmlResolver = $null
    $document.Load($specs[0].FullName)
    $metadata = $document.SelectSingleNode('/*[local-name()="package"]/*[local-name()="metadata"]')
    $license = $metadata.SelectSingleNode('*[local-name()="license"]')
    $copyright = $metadata.SelectSingleNode('*[local-name()="copyright"]')
    $licenseUrl = $metadata.SelectSingleNode('*[local-name()="licenseUrl"]')
    $files = @(Get-ChildItem -LiteralPath $package.Root -File -Recurse | Where-Object { $_.Extension -eq '.nuspec' -or $_.Name -match '(?i)(licen[cs]e|copying|notice|copyright|third.?party)' })
    $copied = New-Object 'Collections.Generic.List[object]'
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($package.Root.Length + 1)
        $destination = Join-Path $output ($package.Id + '/' + $package.Version + '/' + $relative)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.File]::Copy($file.FullName, $destination, $false)
        $copied.Add([ordered]@{ Path = $destination.Substring($output.Length + 1).Replace('\', '/'); Size = $file.Length; Sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() })
    }
    $licenseKind = if ($null -ne $license) { $license.GetAttribute('type') } else { 'url' }
    $licenseValue = if ($null -ne $license) { $license.InnerText } elseif ($null -ne $licenseUrl) { $licenseUrl.InnerText } else { '' }
    if ($licenseKind -eq 'file' -and $files.FullName -notcontains (Join-Path $package.Root $licenseValue)) { throw ('A declared license file was not retained: ' + $package.Id) }
    if (-not $licenseValue -and $files.Count -le 1) { throw ('No declared license or license text was found: ' + $package.Id) }
    $inventory.Add([ordered]@{ Id = $package.Id; Version = $package.Version; LicenseKind = $licenseKind; DeclaredLicense = $licenseValue; Copyright = $(if ($null -ne $copyright) { $copyright.InnerText } else { '' }); Files = @($copied.ToArray()) })
}
[IO.File]::Copy((Join-Path $repository 'docs\Compiled-Third-Party-Notices.md'), (Join-Path $output 'Compiled-Third-Party-Notices.md'), $false)
[IO.File]::Copy((Join-Path $repository 'THIRD-PARTY-NOTICES.md'), (Join-Path $output 'Legacy-Third-Party-Notices.md'), $false)
[IO.File]::WriteAllText((Join-Path $output 'packages.json'), ($inventory.ToArray() | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host ('Retained package license metadata and supplied notice files for ' + $inventory.Count + ' exact restored production/build packages. No license URLs were downloaded.')