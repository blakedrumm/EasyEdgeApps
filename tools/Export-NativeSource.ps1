#requires -Version 5.1

[CmdletBinding()]
param([switch]$Verify)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'EasyEdgeApps.ps1')
$source = Get-EeaSessionLauncherSource -Website 'https://example.invalid/' -EdgePath 'C:\EasyEdgeApps\msedge.exe' -AppName 'Compiled website'
$replacements = [ordered]@{
    '[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]' = ''
    'public static class EeaFreshSession' = 'public static partial class EeaFreshSession'
    'private const bool FreshMode = true;' = 'private static bool FreshMode = true;'
    'private const int WindowMode = 1;' = 'private static int WindowMode = 1;'
    'private const bool AlwaysOnTop = false;' = 'private static bool AlwaysOnTop = false;'
    'private static int Main(string[] arguments)' = 'public static int RunConfigured(string[] arguments)'
    'string edge = Encoding.UTF8.GetString(Convert.FromBase64String("QzpcRWFzeUVkZ2VBcHBzXG1zZWRnZS5leGU="));' = 'string edge = Configuration.EdgePath;'
    'string website = Encoding.UTF8.GetString(Convert.FromBase64String("aHR0cHM6Ly9leGFtcGxlLmludmFsaWQv"));' = 'string website = Configuration.Url;'
    'string name = Encoding.UTF8.GetString(Convert.FromBase64String("Q29tcGlsZWQgd2Vic2l0ZQ=="));' = 'string name = Configuration.Name;'
}
foreach ($entry in $replacements.GetEnumerator()) {
    if (-not $source.Contains($entry.Key)) { throw ('Native extraction anchor changed: ' + $entry.Key) }
    $source = $source.Replace($entry.Key, $entry.Value)
}
$source = $source.Replace('Assembly.GetExecutingAssembly().Location', 'LauncherFile')
$source = $source.Replace('if (!FreshMode) { RunPersistent', 'if (!Configuration.DedicatedProfile && !FreshMode) { RunShared(edge, website); return 0; }' + "`n            " + 'if (!FreshMode) { RunPersistent')
$source = $source.Replace("`r`n", "`n")
$path = Join-Path $root 'src\EasyEdgeApps.SiteLauncher\Native.generated.cs'
if ($Verify) {
    if (-not [IO.File]::Exists($path) -or [IO.File]::ReadAllText($path).Replace("`r`n", "`n") -cne $source) { throw 'Compiled native source differs from the documented extraction. Regenerate and review it.' }
}
else { [IO.File]::WriteAllText($path, $source, (New-Object Text.UTF8Encoding($false))) }
Write-Host 'PASS: Native controller extraction matches the current PowerShell implementation and explicit configuration adaptations.'

$uiSourceNodes = @((Get-Command Initialize-EeaSpaceBackground).ScriptBlock.Ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public sealed class StarfieldRenderer : IDisposable')
}, $true))
if ($uiSourceNodes.Count -ne 1) { throw 'The original starfield source must have exactly one extraction anchor.' }
$uiSource = $uiSourceNodes[0].Value.Replace("`r`n", "`n")
$rendererEnd = $uiSource.IndexOf('    public sealed class StarfieldForm : Form', [StringComparison]::Ordinal)
if ($rendererEnd -lt 0 -or -not $uiSource.Contains("namespace EasyEdgeApps`n")) { throw 'The original renderer boundary changed. Review the source transplant.' }
$rendererSource = "#nullable disable`n" + $uiSource.Substring(0, $rendererEnd).Replace("namespace EasyEdgeApps`n", "namespace EasyEdgeApps.Windows`n") + "}`n"
$rendererPath = Join-Path $root 'src\EasyEdgeApps.Windows\StarfieldRenderer.generated.cs'
if ($Verify) {
    if (-not [IO.File]::Exists($rendererPath) -or [IO.File]::ReadAllText($rendererPath).Replace("`r`n", "`n") -cne $rendererSource) { throw 'Compiled starfield source differs from the original renderer. Regenerate and review it.' }
}
else { [IO.File]::WriteAllText($rendererPath, $rendererSource, (New-Object Text.UTF8Encoding($false))) }
Write-Host 'PASS: Compiled starfield renderer matches the original implementation.'