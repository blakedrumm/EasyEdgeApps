#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Drawing
$projectRoot = Split-Path $PSScriptRoot -Parent
$source = [Drawing.Bitmap]::FromFile((Join-Path $projectRoot 'docs\images\app-icon.png'))
$bitmap = New-Object Drawing.Bitmap(64, 64, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$iconStream = New-Object IO.MemoryStream
$writer = New-Object IO.BinaryWriter($iconStream)
$compressedStream = New-Object IO.MemoryStream
try {
    $minX = $source.Width
    $minY = $source.Height
    $maxX = -1
    $maxY = -1
    for ($pixelY = 0; $pixelY -lt $source.Height; $pixelY++) {
        for ($pixelX = 0; $pixelX -lt $source.Width; $pixelX++) {
            if ($source.GetPixel($pixelX, $pixelY).A -ge 128) {
                $minX = [Math]::Min($minX, $pixelX)
                $minY = [Math]::Min($minY, $pixelY)
                $maxX = [Math]::Max($maxX, $pixelX)
                $maxY = [Math]::Max($maxY, $pixelY)
            }
        }
    }
    if ($maxX -lt 0) { throw 'The source icon has no visible pixels.' }
    $side = [Math]::Max($maxX - $minX + 1, $maxY - $minY + 1) + 16
    $sourceLeft = [single](($minX + $maxX + 1 - $side) / 2)
    $sourceTop = [single](($minY + $maxY + 1 - $side) / 2)
    $sourceBounds = [Drawing.RectangleF]::new($sourceLeft, $sourceTop, [single]$side, [single]$side)
    $graphics.Clear([Drawing.Color]::Transparent)
    $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.DrawImage($source, (New-Object Drawing.RectangleF(0, 0, 64, 64)), $sourceBounds, [Drawing.GraphicsUnit]::Pixel)
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]1)
    $writer.Write([byte]64)
    $writer.Write([byte]64)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]16936)
    $writer.Write([uint32]22)
    $writer.Write([uint32]40)
    $writer.Write([int]64)
    $writer.Write([int]128)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]0)
    $writer.Write([uint32]16384)
    foreach ($unused in 1..4) { $writer.Write([uint32]0) }
    for ($pixelY = 63; $pixelY -ge 0; $pixelY--) {
        for ($pixelX = 0; $pixelX -lt 64; $pixelX++) {
            $pixel = $bitmap.GetPixel($pixelX, $pixelY)
            $writer.Write([byte]$pixel.B)
            $writer.Write([byte]$pixel.G)
            $writer.Write([byte]$pixel.R)
            $writer.Write([byte]$pixel.A)
        }
    }
    for ($pixelY = 63; $pixelY -ge 0; $pixelY--) {
        for ($byteIndex = 0; $byteIndex -lt 8; $byteIndex++) {
            $mask = 0
            for ($bitIndex = 0; $bitIndex -lt 8; $bitIndex++) {
                if ($bitmap.GetPixel($byteIndex * 8 + $bitIndex, $pixelY).A -eq 0) { $mask = $mask -bor (128 -shr $bitIndex) }
            }
            $writer.Write([byte]$mask)
        }
    }
    $writer.Flush()
    $gzip = [IO.Compression.GZipStream]::new($compressedStream, [IO.Compression.CompressionMode]::Compress, $true)
    try {
        $iconStream.Position = 0
        $iconStream.CopyTo($gzip)
    }
    finally { $gzip.Dispose() }
    $encoded = [Convert]::ToBase64String($compressedStream.ToArray())
    $scriptPath = Join-Path $projectRoot 'EasyEdgeApps.ps1'
    $text = [IO.File]::ReadAllText($scriptPath)
    $tokens = $null
    $errors = $null
    $syntaxTree = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'The application must parse before updating the generated icon.' }
    $iconFunctions = @($syntaxTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-EeaBrandIcon' }, $true))
    if ($iconFunctions.Count -ne 1) { throw 'Expected exactly one brand icon function.' }
    $assignments = @($iconFunctions[0].FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'encodedIcon' }, $true))
    if ($assignments.Count -ne 1) { throw 'Expected exactly one generated icon literal.' }
    $extent = $assignments[0].Right.Extent
    $updated = $text.Substring(0, $extent.StartOffset) + "'" + $encoded + "'" + $text.Substring($extent.EndOffset)
    [IO.File]::WriteAllText($scriptPath, $updated, (New-Object Text.UTF8Encoding($false)))
    Write-Host ('Embedded 64-pixel classic Windows icon: {0} compressed bytes.' -f $compressedStream.Length)
}
finally {
    $writer.Dispose()
    $iconStream.Dispose()
    $compressedStream.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
    $source.Dispose()
}