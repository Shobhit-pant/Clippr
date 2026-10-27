# Rebuilds clippr.ico from the app's PNG artwork.
# Usage: powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1
#        powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1 -Source C:\path\clippr.png
param(
    [string]$Source = (Join-Path (Split-Path -Parent $PSScriptRoot) 'clippr.png')
)

Add-Type -AssemblyName System.Drawing

$OutDir = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Source)) {
    throw "Icon source not found: $Source"
}

function Get-IconDib([System.Drawing.Bitmap]$bmp) {
    $size = $bmp.Width
    $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    $data = $bmp.LockBits(
        $rect,
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $absStride = [Math]::Abs($stride)
        $raw = New-Object byte[] ($absStride * $size)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    } finally {
        $bmp.UnlockBits($data)
    }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        # BITMAPINFOHEADER
        $bw.Write([uint32]40)
        $bw.Write([int32]$size)
        $bw.Write([int32]($size * 2))   # XOR image + AND mask
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]0)            # BI_RGB
        $bw.Write([uint32]($size * $size * 4))
        $bw.Write([int32]0)
        $bw.Write([int32]0)
        $bw.Write([uint32]0)
        $bw.Write([uint32]0)

        # XOR bitmap, bottom-up BGRA rows.
        $rowBytes = $size * 4
        for ($y = $size - 1; $y -ge 0; $y--) {
            $offset = if ($stride -gt 0) { $y * $stride } else { ($size - 1 - $y) * $absStride }
            $bw.Write($raw, $offset, $rowBytes)
        }

        # 1bpp AND mask, padded to 32-bit rows. The alpha channel carries
        # transparency for 32bpp icons, so the mask can stay all zero.
        $maskRow = [int]([Math]::Ceiling($size / 32.0) * 4)
        $mask = New-Object byte[] ($maskRow * $size)
        $bw.Write($mask, 0, $mask.Length)
        $bw.Flush()
        return $ms.ToArray()
    } finally {
        $bw.Dispose()
        $ms.Dispose()
    }
}

$sizes = @(16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
$sourceImage = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source))
$frames = New-Object System.Collections.ArrayList

try {
    foreach ($size in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $attr = New-Object System.Drawing.Imaging.ImageAttributes
        $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $g.DrawImage($sourceImage, (New-Object System.Drawing.Rectangle(0, 0, $size, $size)), 0, 0, $sourceImage.Width, $sourceImage.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
        $attr.Dispose()
        $g.Dispose()

        $dib = Get-IconDib $bmp
        [void]$frames.Add($dib)
        $bmp.Dispose()
    }
} finally {
    $sourceImage.Dispose()
}

$icoPath = Join-Path $OutDir 'clippr.ico'
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + (16 * $sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]
    $wb = if ($sz -ge 256) { 0 } else { $sz }
    $len = $frames[$i].Length
    $bw.Write([byte]$wb); $bw.Write([byte]$wb)
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$len)
    $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($f in $frames) { $bw.Write([byte[]]$f) }
$bw.Flush(); $bw.Dispose(); $fs.Dispose()

Write-Output "ICO: $icoPath"
Write-Output "Source: $Source"
Write-Output "Frames: $($sizes.Count) (DIB/32bpp)"
