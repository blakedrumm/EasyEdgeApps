#requires -Version 5.1

[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PackageDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.IO.Compression.FileSystem
$projectRoot = Split-Path $PSScriptRoot -Parent
$packages = @(
    @{ Id = 'system.buffers'; Version = '4.5.1'; Hash = 'c30b3dd2c7e2f4cee4b823d692fd42118309b42ab1f5007f923d329a5b0d6b12'; Assemblies = @{ Framework = 'lib/net461/System.Buffers.dll' } },
    @{ Id = 'system.numerics.vectors'; Version = '4.5.0'; Hash = 'a9d49320581fda1b4f4be6212c68c01a22cdf228026099c20a8eabefcf90f9cf'; Assemblies = @{ Framework = 'lib/net46/System.Numerics.Vectors.dll' } },
    @{ Id = 'system.runtime.compilerservices.unsafe'; Version = '4.5.3'; Hash = '96764c52a44ee1161151e48ef07489f72047a851cb55b99e9f01d6908536d1a9'; Assemblies = @{ Framework = 'lib/net461/System.Runtime.CompilerServices.Unsafe.dll' } },
    @{ Id = 'system.memory'; Version = '4.5.5'; Hash = '10f43da352a29fb2b3188e4edd4dcf5100194c8b526e4f61fe2e2b5623775a22'; Assemblies = @{ Framework = 'lib/net461/System.Memory.dll' } },
    @{ Id = 'excss'; Version = '4.2.3'; Hash = '33f1fa3f9a7baaa745cff7e0008d8c301590ee778dfc6222798492c718ec33d2'; Assemblies = @{ Framework = 'lib/net48/ExCSS.dll'; Modern = 'lib/netcoreapp3.1/ExCSS.dll' } },
    @{ Id = 'svg'; Version = '3.4.8'; Hash = '6eb79306106d3353e3c946191960267d673a319887da36ec2ba7b49c2de913af'; Assemblies = @{ Framework = 'lib/net462/Svg.dll'; Modern = 'lib/netcoreapp3.1/Svg.dll' } }
)
$assemblyRecords = New-Object 'Collections.Generic.List[object]'
$notices = New-Object 'Collections.Generic.List[string]'
$notices.Add('# Third-Party Notices')
$notices.Add('The application is MIT-licensed. The following unmodified libraries are embedded for local SVG icon rendering; their respective licenses and notices apply to those libraries. No package downloads occur at runtime.')
$hasher = [Security.Cryptography.SHA256]::Create()
try {
    foreach ($package in $packages) {
        $packagePath = Join-Path $PackageDirectory ($package.Id + '.' + $package.Version + '.nupkg')
        if ((Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $package.Hash) { throw ('Unexpected package hash: ' + $package.Id) }
        $notices.Add('## ' + $package.Id + ' ' + $package.Version)
        $notices.Add('Source: https://www.nuget.org/packages/' + $package.Id + '/' + $package.Version + "`n`nPackage SHA256: " + $package.Hash)
        $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
        try {
            foreach ($target in @('Framework', 'Modern')) {
                if (-not $package.Assemblies.ContainsKey($target)) { continue }
                $entry = $archive.GetEntry($package.Assemblies[$target])
                if ($null -eq $entry) { throw ('Missing assembly: ' + $package.Assemblies[$target]) }
                $stream = $entry.Open()
                $bytes = New-Object IO.MemoryStream
                try { $stream.CopyTo($bytes); $assemblyBytes = $bytes.ToArray() }
                finally { $stream.Dispose(); $bytes.Dispose() }
                $assemblyRecords.Add([ordered]@{
                    Target = $target; Name = [IO.Path]::GetFileNameWithoutExtension($entry.FullName)
                    Hash = [BitConverter]::ToString($hasher.ComputeHash($assemblyBytes)).Replace('-', '').ToLowerInvariant()
                    Bytes = [Convert]::ToBase64String($assemblyBytes)
                })
            }
            foreach ($noticeName in @('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT')) {
                $entry = $archive.GetEntry($noticeName)
                if ($null -eq $entry) { continue }
                $reader = New-Object IO.StreamReader($entry.Open())
                try { $notices.Add($reader.ReadToEnd().Trim()) }
                finally { $reader.Dispose() }
            }
        }
        finally { $archive.Dispose() }
        if ($package.Id -in @('svg', 'excss')) {
            $noticePath = Join-Path $PackageDirectory ($package.Id + '.LICENSE.txt')
            if (-not [IO.File]::Exists($noticePath)) { throw ('Retain the upstream license at ' + $noticePath) }
            $notices.Add([IO.File]::ReadAllText($noticePath).Trim())
        }
    }
    $noticeText = ($notices -join "`n`n").Replace("`r`n", "`n") + "`n"
    $payload = [ordered]@{ Assemblies = $assemblyRecords.ToArray(); Notices = $noticeText } | ConvertTo-Json -Depth 8 -Compress
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $compressed = New-Object IO.MemoryStream
    try {
        $gzip = [IO.Compression.GZipStream]::new($compressed, [IO.Compression.CompressionMode]::Compress, $true)
        try { $gzip.Write($payloadBytes, 0, $payloadBytes.Length) }
        finally { $gzip.Dispose() }
        $encoded = [Convert]::ToBase64String($compressed.ToArray())
    }
    finally { $compressed.Dispose() }
    $scriptPath = Join-Path $projectRoot 'EasyEdgeApps.ps1'
    $text = [IO.File]::ReadAllText($scriptPath)
    $tokens = $null
    $errors = $null
    $syntaxTree = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'The application must parse before updating the generated SVG runtime.' }
    $functions = @($syntaxTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-EeaSvgRuntimePayload' }, $true))
    if ($functions.Count -ne 1) { throw 'Expected exactly one SVG payload function.' }
    $assignments = @($functions[0].FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'encodedSvgRuntime' }, $true))
    if ($assignments.Count -ne 1) { throw 'Expected exactly one SVG payload literal.' }
    $extent = $assignments[0].Right.Extent
    $updated = $text.Substring(0, $extent.StartOffset) + "'" + $encoded + "'" + $text.Substring($extent.EndOffset)
    [IO.File]::WriteAllText($scriptPath, $updated, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $projectRoot 'THIRD-PARTY-NOTICES.md'), $noticeText, (New-Object Text.UTF8Encoding($false)))
    Write-Host ('Embedded {0} verified assemblies and retained license notices.' -f $assemblyRecords.Count)
}
finally { $hasher.Dispose() }