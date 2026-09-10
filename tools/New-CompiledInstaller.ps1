#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PayloadDirectory, [Parameter(Mandatory = $true)][string]$BuildDirectory,
    [Parameter(Mandatory = $true)][string]$OutputPath, [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$LegacyBuildDirectory)

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$build = [IO.Path]::GetFullPath($BuildDirectory)
foreach ($path in @($payload, $build, [IO.Path]::GetFullPath($OutputPath), [IO.Path]::GetFullPath($LegacyBuildDirectory))) {
    if (-not $path.StartsWith((Join-Path $repository 'artifacts\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Packaging paths must remain under this repository artifacts directory.' }
}
if ([IO.File]::Exists($OutputPath)) { throw 'Preserve the previous installer; choose a new output path.' }
$namespace = 'http://wixtoolset.org/schemas/v4/wxs'
$document = New-Object Xml.XmlDocument
function Add-WixElement {
    param([Xml.XmlNode]$Parent, [string]$Name, [hashtable]$Attributes)
    $element = $document.CreateElement($Name, $namespace)
    foreach ($key in $Attributes.Keys) { $element.SetAttribute($key, [string]$Attributes[$key]) }
    [void]$Parent.AppendChild($element)
    return ,$element
}
function Get-PayloadId {
    param([string]$Relative)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes('EasyEdgeApps.Compiled:' + $Relative.ToLowerInvariant()))).Replace('-', '').ToLowerInvariant().Substring(0, 32) }
    finally { $hasher.Dispose() }
}
$wix = Add-WixElement $document 'Wix' @{}
$package = Add-WixElement $wix 'Package' @{ Name = 'Easy Edge Apps'; Manufacturer = 'blakedrumm'; Version = $Version; Language = '1033'; Scope = 'perUser'; InstallerVersion = '500'; UpgradeCode = '{9D0AF71A-353C-4A88-A171-16249356093F}' }
$null = Add-WixElement $package 'MajorUpgrade' @{ DowngradeErrorMessage = 'A newer version of Easy Edge Apps is already installed.'; Schedule = 'afterInstallInitialize' }
$null = Add-WixElement $package 'MediaTemplate' @{ EmbedCab = 'yes' }
$property = Add-WixElement $package 'Property' @{ Id = 'WINDOWSBUILDNUMBER' }
$null = Add-WixElement $property 'RegistrySearch' @{ Id = 'WindowsBuildNumber'; Root = 'HKLM'; Key = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'; Name = 'CurrentBuildNumber'; Type = 'raw'; Bitness = 'always64' }
$null = Add-WixElement $package 'Launch' @{ Condition = 'Installed OR (VersionNT64 AND WINDOWSBUILDNUMBER >= 22000)'; Message = 'Easy Edge Apps requires 64-bit Windows 11.' }
$null = Add-WixElement $package 'Icon' @{ Id = 'AppIcon'; SourceFile = (Join-Path $repository 'src\EasyEdgeApps.Manager\Assets\Brand.ico') }
$null = Add-WixElement $package 'Property' @{ Id = 'ARPPRODUCTICON'; Value = 'AppIcon' }
$null = Add-WixElement $package 'Property' @{ Id = 'ARPHELPLINK'; Value = 'https://github.com/blakedrumm/EasyEdgeApps/issues' }
$property = Add-WixElement $package 'Property' @{ Id = 'INSTALLFOLDER'; Secure = 'yes' }
$null = Add-WixElement $property 'RegistrySearch' @{ Id = 'PreviousInstallFolder'; Root = 'HKCU'; Key = 'Software\EasyEdgeApps\Installer'; Name = 'InstallFolder'; Type = 'raw' }
$local = Add-WixElement $package 'StandardDirectory' @{ Id = 'LocalAppDataFolder' }
$programs = Add-WixElement $local 'Directory' @{ Id = 'LocalPrograms'; Name = 'Programs' }
$install = Add-WixElement $programs 'Directory' @{ Id = 'INSTALLFOLDER'; Name = 'Easy Edge Apps' }
$null = Add-WixElement $package 'StandardDirectory' @{ Id = 'ProgramMenuFolder' }
$feature = Add-WixElement $package 'Feature' @{ Id = 'Application'; Title = 'Easy Edge Apps'; Level = '1' }
$directories = @{ '' = $install }
$removed = New-Object 'Collections.Generic.HashSet[string]'
$legacyComponents = @{
    'EasyEdgeApps.exe' = @('LauncherComponent', '{D8C0BB4A-B1B8-4416-8B7F-022879D3F733}', 'LauncherFile', 'InstallFolder')
    'EasyEdgeApps.ps1' = @('ScriptComponent', '{EBD072F4-7F82-481D-8910-46B4EF20A255}', 'ApplicationScript', 'Script')
    'LICENSE' = @('LicenseComponent', '{D05137E2-F77F-4C86-A686-1FDBF5EC36B3}', 'ApplicationLicense', 'License')
    'THIRD-PARTY-NOTICES.md' = @('NoticesComponent', '{CFDE7826-16CC-464C-848C-3826DD0F9712}', 'ApplicationNotices', 'Notices')
}
foreach ($file in @(Get-ChildItem -LiteralPath $payload -Recurse -File | Sort-Object FullName)) {
    if ($file.FullName.Length -ge 260) { throw 'The compiled payload path is too long for the WiX native cabinet tool. Use a shorter checkout and artifacts output directory.' }
    $relative = $file.FullName.Substring($payload.Length + 1)
    $parentPath = [IO.Path]::GetDirectoryName($relative)
    if (-not $parentPath) { $parentPath = '' }
    $current = ''
    $parent = $install
    foreach ($segment in @($parentPath.Split('\') | Where-Object { $_.Length -gt 0 })) {
        $current = if ($current) { $current + '\' + $segment } else { $segment }
        if (-not $directories.ContainsKey($current)) { $directories[$current] = Add-WixElement $parent 'Directory' @{ Id = ('D_' + (Get-PayloadId $current)); Name = $segment } }
        $parent = $directories[$current]
    }
    $identity = Get-PayloadId $relative
    $componentId = 'C_' + $identity
    $fileId = 'F_' + $identity
    $guid = ([Guid]::ParseExact($identity, 'N')).ToString('B').ToUpperInvariant()
    $registryName = 'Compiled_' + $identity
    if ($legacyComponents.ContainsKey($relative)) {
        $componentId, $guid, $fileId, $registryName = $legacyComponents[$relative]
    }
    $component = Add-WixElement $parent 'Component' @{ Id = $componentId; Guid = $guid }
    $null = Add-WixElement $component 'File' @{ Id = $fileId; Source = $file.FullName }
    $null = Add-WixElement $component 'RegistryValue' @{ Root = 'HKCU'; Key = 'Software\EasyEdgeApps\Installer'; Name = $registryName; Value = $(if ($relative -eq 'EasyEdgeApps.exe') { '[INSTALLFOLDER]' } else { '1' }); Type = $(if ($relative -eq 'EasyEdgeApps.exe') { 'string' } else { 'integer' }); KeyPath = 'yes' }
    if ($removed.Add($parent.GetAttribute('Id'))) { $null = Add-WixElement $component 'RemoveFolder' @{ Id = 'R_' + $identity; Directory = $parent.GetAttribute('Id'); On = 'uninstall' } }
    if ($relative -eq 'EasyEdgeApps.exe') {
        $null = Add-WixElement $component 'Shortcut' @{ Id = 'SetupShortcut'; Directory = 'ProgramMenuFolder'; Name = 'Easy Edge Apps'; Target = '[INSTALLFOLDER]EasyEdgeApps.Manager.exe'; WorkingDirectory = 'INSTALLFOLDER'; Icon = 'AppIcon' }
        $null = Add-WixElement $component 'Shortcut' @{ Id = 'LegacySetupShortcut'; Directory = 'ProgramMenuFolder'; Name = 'Easy Edge Apps (PowerShell)'; Target = '[INSTALLFOLDER]EasyEdgeApps.exe'; WorkingDirectory = 'INSTALLFOLDER'; Icon = 'AppIcon' }
    }
    $null = Add-WixElement $feature 'ComponentRef' @{ Id = $componentId }
}
$ui = $document.CreateElement('ui', 'WixUI', 'http://wixtoolset.org/schemas/v4/wxs/ui')
$ui.SetAttribute('Id', 'WixUI_Minimal')
[void]$package.AppendChild($ui)
$null = Add-WixElement $package 'UIRef' @{ Id = 'WixUI_ErrorProgressText' }
$null = Add-WixElement $package 'WixVariable' @{ Id = 'WixUILicenseRtf'; Value = (Join-Path $LegacyBuildDirectory 'license.rtf') }
$sourcePath = Join-Path $build 'compiled.wxs'
$document.Save($sourcePath)
$extension = Join-Path $repository '.wix\extensions\WixToolset.UI.wixext\5.0.2\wixext5\WixToolset.UI.wixext.dll'
Push-Location $repository
try {
    & dotnet tool run wix build $sourcePath -arch x64 -culture en-US -ext $extension -intermediateFolder (Join-Path $build 'wix') -pdbtype none -out $OutputPath -wx
    if ($LASTEXITCODE -ne 0) { throw 'Compiled per-user MSI validation failed.' }
    Write-Host ('PASS: Built unsigned compiled per-user MSI without installation: ' + $OutputPath)
}
finally { Pop-Location }