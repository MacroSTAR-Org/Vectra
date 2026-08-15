# Regenerates the app/tray icons from the Vectra logo.
#
# The source logo has a white background (~69% white pixels) with a light
# blue-purple glyph (avg RGB 210,211,251).  A white square would look awful as
# a taskbar/tray icon, so this keys out near-white pixels to transparent,
# keeps the light glyph, and packs a multi-size PNG-based ICO.
#
# Usage: powershell -File tool/make_icons.ps1
# ASCII-only comments: PowerShell 5.1 reads BOM-less .ps1 as ANSI(936).
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$src = (Get-ChildItem (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\Vectra_LOGO*.png') | Select-Object -First 1).FullName
if (-not $src) { throw 'logo not found in Downloads' }
$bmp = [System.Drawing.Bitmap]::FromFile($src)
Write-Host ("source: {0} {1}x{2}" -f $src, $bmp.Width, $bmp.Height)

# Key out near-white (RGB all >= 236) and opaque -> transparent.
# The glyph's R=210 stays far below 236, so it is never erased; only the
# antialiasing fringe between glyph and white loses a little softness.
$threshold = 236
for ($y = 0; $y -lt $bmp.Height; $y++) {
  for ($x = 0; $x -lt $bmp.Width; $x++) {
    $c = $bmp.GetPixel($x, $y)
    if ($c.A -gt 128 -and $c.R -ge $threshold -and $c.G -ge $threshold -and $c.B -ge $threshold) {
      $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, 255, 255, 255))
    }
  }
}

function New-Ico([System.Drawing.Bitmap]$bmp, [int[]]$sizes, [string]$path) {
  $fs = [System.IO.File]::Create($path)
  $bw = New-Object System.IO.BinaryWriter($fs)
  $bw.Write([UInt16]0)
  $bw.Write([UInt16]1)
  $bw.Write([UInt16]$sizes.Count)
  $offset = 6 + 16 * $sizes.Count
  $pngs = New-Object System.Collections.ArrayList
  foreach ($s in $sizes) {
    $small = New-Object System.Drawing.Bitmap([int]$s, [int]$s)
    $g = [System.Drawing.Graphics]::FromImage($small)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($bmp, 0, 0, [int]$s, [int]$s)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $small.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    [void]$pngs.Add($ms.ToArray())
    $ms.Dispose()
    $small.Dispose()
  }
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $bw.Write([Byte]$dim)
    $bw.Write([Byte]$dim)
    $bw.Write([Byte]0)
    $bw.Write([Byte]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]32)
    $bw.Write([UInt32]$pngs[$i].Length)
    $bw.Write([UInt32]$offset)
    $offset += $pngs[$i].Length
  }
  foreach ($png in $pngs) { $bw.Write($png) }
  $bw.Close()
  $fs.Close()
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
New-Ico $bmp $sizes (Join-Path $root 'windows\runner\resources\app_icon.ico')
New-Ico $bmp $sizes (Join-Path $root 'assets\tray.ico')
$bmp.Dispose()
Write-Host "icons written"
