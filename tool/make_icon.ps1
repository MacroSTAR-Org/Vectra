# Generates a multi-size .ico (16..256) from a transparent PNG, written by hand
# because System.Drawing cannot save .ico directly.
#
# Usage: make_icon.ps1 -Png <input.png> -Out <output.ico>
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI(936).
param(
  [Parameter(Mandatory=$true)][string]$Png,
  [Parameter(Mandatory=$true)][string]$Out
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Bitmap]::FromFile($Png)
$sizes = @(16, 24, 32, 48, 64, 128, 256)

# Reserve space for the header + N entries; write them after we know the offsets.
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([uint16]0)          # reserved
$bw.Write([uint16]1)          # type = icon
$bw.Write([uint16]$sizes.Count)
$entries = @()
foreach ($s in $sizes) { $entries += 0 }

for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]
  $bmp = New-Object System.Drawing.Bitmap $s, $s
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($src, 0, 0, $s, $s)
  $g.Dispose()

  if ($s -eq 256) {
    # 256px: store as PNG bytes (standard for Vista+)
    $pngMs = New-Object System.IO.MemoryStream
    $bmp.Save($pngMs, [System.Drawing.Imaging.ImageFormat]::Png)
    $data = $pngMs.ToArray()
    $pngMs.Dispose()
  } else {
    # small sizes: store as a 32-bit DIB (BITMAPINFOHEADER + BGRA, bottom-up)
    $dib = New-Object System.IO.MemoryStream
    $dibW = New-Object System.IO.BinaryWriter($dib)
    $dibW.Write([uint32]40)                     # BITMAPINFOHEADER size
    $dibW.Write([int32]$s)                      # width
    $dibW.Write([int32]($s * 2))                # height (doubled: XOR + AND masks)
    $dibW.Write([uint16]1)                      # planes
    $dibW.Write([uint16]32)                     # bit count
    $dibW.Write([uint32]0)                      # compression = BI_RGB
    $dibW.Write([uint32]0)                      # image size
    $dibW.Write([int32]0)                       # x ppm
    $dibW.Write([int32]0)                       # y ppm
    $dibW.Write([uint32]0)                      # colors used
    $dibW.Write([uint32]0)                      # important colors
    # bottom-up BGRA rows
    for ($y = $s - 1; $y -ge 0; $y--) {
      for ($x = 0; $x -lt $s; $x++) {
        $c = $bmp.GetPixel($x, $y)
        $dibW.Write([byte]$c.B); $dibW.Write([byte]$c.G)
        $dibW.Write([byte]$c.R); $dibW.Write([byte]$c.A)
      }
    }
    # AND mask (all zeros = no transparency holes)
    for ($y = 0; $y -lt $s; $y++) { for ($x = 0; $x -lt [Math]::Ceiling($s/8.0)*8; $x++) { $dibW.Write([byte]0) } }
    $data = $dib.ToArray()
    $dibW.Dispose(); $dib.Dispose()
  }
  $bmp.Dispose()
  $entries[$i] = $data
}

# Patch the entry table now that we know every blob's size and offset.
$offset = 6 + 16 * $sizes.Count
$fs = [System.IO.File]::Create($Out)
$fs.Write($ms.ToArray(), 0, [int]$ms.Length)
$ms.Dispose(); $bw.Dispose()
$fs.Seek(6, [System.IO.SeekOrigin]::Begin)
$bw2 = New-Object System.IO.BinaryWriter($fs)
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]
  $data = $entries[$i]
  $bw2.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))  # width (0 = 256)
  $bw2.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))  # height
  $bw2.Write([byte]0)                                      # palette
  $bw2.Write([byte]0)                                      # reserved
  $bw2.Write([uint16]1)                                    # planes
  $bw2.Write([uint16]32)                                   # bit count
  $bw2.Write([uint32]$data.Length)                         # blob size
  $bw2.Write([uint32]$offset)                              # blob offset
  $offset += $data.Length
}
$bw2.Flush()
# append the blobs
foreach ($data in $entries) { $fs.Write($data, 0, $data.Length) }
$fs.Close()
Write-Host ("wrote {0} ({1} sizes: {2})" -f $Out, $sizes.Count, ($sizes -join ','))
$src.Dispose()
