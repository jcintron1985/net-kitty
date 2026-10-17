#requires -Version 5.1
[CmdletBinding()]
param([string]$PngPath, [string]$IconPath)
$ErrorActionPreference = 'Stop'
if (-not $PngPath) { $PngPath = Join-Path $PSScriptRoot 'NetKitty.png' }
if (-not $IconPath) { $IconPath = Join-Path $PSScriptRoot 'NetKitty.ico' }
Add-Type -AssemblyName System.Drawing
# Format conversion only. Preserve the generated artwork and alpha in each Windows icon size.
$source = [Drawing.Image]::FromFile($PngPath)
$images = @(); $sizes = @(16,20,24,32,40,48,64,128,256)
try {
    foreach ($size in $sizes) {
        $bitmap = [Drawing.Bitmap]::new($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $memory = [IO.MemoryStream]::new()
        try {
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.DrawImage($source,0,0,$size,$size)
            $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png)
            $images += ,$memory.ToArray()
        } finally { $graphics.Dispose(); $bitmap.Dispose(); $memory.Dispose() }
    }
    $stream = [IO.File]::Create($IconPath); $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $encodedSize = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
            $writer.Write([byte]$encodedSize); $writer.Write([byte]$encodedSize); $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
            $offset += $images[$i].Length
        }
        foreach ($bytes in $images) { $writer.Write([byte[]]$bytes) }
    } finally { $writer.Dispose() }
} finally { $source.Dispose() }
Write-Output "Created Windows icon: $IconPath"
