#requires -Version 5.1

[CmdletBinding()]
param([string]$OutputDirectory, [switch]$SkipRestore)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'artifacts' }
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) { throw 'Build the installer on 64-bit Windows.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Run this build with powershell.exe or pwsh.exe -STA.' }
. (Join-Path $projectRoot 'EasyEdgeApps.ps1')
$version = (Get-EeaVersion).ToString(3)
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($outputRoot)
$buildRoot = Join-Path $outputRoot ('build-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($buildRoot)
$msiPath = Join-Path $outputRoot ('EasyEdgeApps-' + $version + '-x64.msi')
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) { throw 'The Windows .NET Framework C# compiler is required.' }
Push-Location $projectRoot
try {
    if (-not $SkipRestore) {
        & dotnet tool restore --tool-manifest (Join-Path $projectRoot '.config\dotnet-tools.json')
        if ($LASTEXITCODE -ne 0) { throw 'Could not restore the pinned WiX tool.' }
        & dotnet tool run wix extension add WixToolset.UI.wixext/5.0.2
        if ($LASTEXITCODE -ne 0) { throw 'Could not restore the pinned WiX UI extension.' }
    }
    $toolVersion = & dotnet tool run wix --version
    if ($LASTEXITCODE -ne 0 -or $toolVersion -notmatch '^5\.0\.2') { throw 'The installer requires the pinned WiX 5.0.2 tool.' }
    $uiExtension = Join-Path $projectRoot '.wix\extensions\WixToolset.UI.wixext\5.0.2\wixext5\WixToolset.UI.wixext.dll'
    if (-not [IO.File]::Exists($uiExtension)) { throw 'Restore the pinned WiX 5.0.2 UI extension before building.' }
    $notices = [IO.File]::ReadAllText((Join-Path $projectRoot 'THIRD-PARTY-NOTICES.md')) + "`r`n`r`n" + [IO.File]::ReadAllText((Join-Path $projectRoot 'installer\WiX-Notices.txt'))
    [IO.File]::WriteAllText((Join-Path $buildRoot 'THIRD-PARTY-NOTICES.md'), $notices, (New-Object Text.UTF8Encoding($false)))
    $brandIcon = Get-EeaBrandIcon
    $iconStream = [IO.File]::Create((Join-Path $buildRoot 'app.ico'))
    try { $brandIcon.Save($iconStream) }
    finally { $iconStream.Dispose(); $brandIcon.Dispose() }
    Add-Type -AssemblyName System.Windows.Forms
    $licenseBox = New-Object Windows.Forms.RichTextBox
    try {
        $licenseBox.Text = [IO.File]::ReadAllText((Join-Path $projectRoot 'LICENSE'))
        [IO.File]::WriteAllText((Join-Path $buildRoot 'license.rtf'), $licenseBox.Rtf, [Text.Encoding]::ASCII)
    }
    finally { $licenseBox.Dispose() }
    $assemblyInfo = @"
using System.Reflection;
[assembly: AssemblyTitle("Easy Edge Apps")]
[assembly: AssemblyProduct("Easy Edge Apps")]
[assembly: AssemblyCompany("blakedrumm")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
"@
    [IO.File]::WriteAllText((Join-Path $buildRoot 'AssemblyInfo.cs'), $assemblyInfo, (New-Object Text.UTF8Encoding($false)))
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ ('/out:' + (Join-Path $buildRoot 'EasyEdgeApps.exe')) ('/win32icon:' + (Join-Path $buildRoot 'app.ico')) ('/win32manifest:' + (Join-Path $projectRoot 'installer\Launcher.manifest')) /reference:System.Windows.Forms.dll (Join-Path $projectRoot 'installer\Launcher.cs') (Join-Path $buildRoot 'AssemblyInfo.cs')
    if ($LASTEXITCODE -ne 0) { throw 'The Windows application launcher did not compile.' }
    & dotnet tool run wix build (Join-Path $projectRoot 'installer\EasyEdgeApps.wxs') -arch x64 -culture en-US -ext $uiExtension -d ('AppVersion=' + $version) -d ('SourceRoot=' + $projectRoot) -d ('BuildRoot=' + $buildRoot) -intermediateFolder (Join-Path $buildRoot 'wix') -pdbtype none -out $msiPath -wx
    if ($LASTEXITCODE -ne 0) { throw 'The MSI build or Windows Installer validation failed.' }
    Write-Host ('Built per-user MSI: ' + $msiPath)
    return [pscustomobject]@{ Path = $msiPath; Version = $version; Sha256 = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash.ToLowerInvariant(); BuildRoot = $buildRoot }
}
finally { Pop-Location }