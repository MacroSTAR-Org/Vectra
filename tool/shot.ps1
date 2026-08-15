# DPI-aware screen region capture.  Usage: shot.ps1 <out.png> [x y w h]
# Without a rect it captures the whole virtual screen.
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI(936).
# Being DPI-aware matters: without it a 2560x1440 screen at 150% is reported
# as 1707x960 and you silently capture only the top-left corner.
param(
  [Parameter(Mandatory=$true)][string]$Out,
  [int]$X = [int]::MinValue, [int]$Y = 0, [int]$W = 0, [int]$H = 0
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class S {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
"@
[void][S]::SetProcessDpiAwarenessContext([IntPtr](-4))

if ($X -eq [int]::MinValue) {
  $X = [S]::GetSystemMetrics(76); $Y = [S]::GetSystemMetrics(77)
  $W = [S]::GetSystemMetrics(78); $H = [S]::GetSystemMetrics(79)
}
$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size($W, $H)))
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host ("saved {0}  region {1},{2} {3}x{4}" -f $Out, $X, $Y, $W, $H)
