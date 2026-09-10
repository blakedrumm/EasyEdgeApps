#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'EasyEdgeApps.ps1')
$destination = Join-Path $repository 'src\EasyEdgeApps.Manager\Assets'
[void][IO.Directory]::CreateDirectory($destination)
$brand = Get-EeaBrandIcon
$bitmap = $null
$stream = $null
try {
    $stream = [IO.File]::Create((Join-Path $destination 'Brand.ico'))
    $brand.Save($stream)
    $stream.Dispose()
    $stream = $null
    $bitmap = $brand.ToBitmap()
    $bitmap.Save((Join-Path $destination 'Brand.png'), [Drawing.Imaging.ImageFormat]::Png)
    $colors = New-Object 'System.Collections.Generic.HashSet[int]'
    for ($row = 0; $row -lt $bitmap.Height; $row++) {
        for ($column = 0; $column -lt $bitmap.Width; $column++) { [void]$colors.Add($bitmap.GetPixel($column, $row).ToArgb()) }
    }
    if ($colors.Count -lt 8) { throw 'The original brand asset rendered blank.' }
    Write-Host ('PASS: Original brand rendered as ICO and PNG with ' + $colors.Count + ' pixel colors.')
}
finally {
    if ($null -ne $stream) { $stream.Dispose() }
    if ($null -ne $bitmap) { $bitmap.Dispose() }
    $brand.Dispose()
}