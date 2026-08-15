# Captures a window's own pixels with PrintWindow, ignoring what covers it.
#
# Why this exists: the widgets window is pinned to the BOTTOM of the z-order on
# purpose, so a normal screen grab of that area returns whatever app happens to
# be in front.  PrintWindow asks the window to render itself, so occlusion and
# even being off-screen stop mattering.
#
# Usage: shot_window.ps1 -Title Vectra -Out out.png [-X 0 -Y 0 -W 0 -H 0]
# X/Y/W/H optionally crop the result, in window-relative physical pixels.
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI(936).
param(
  [Parameter(Mandatory=$true)][string]$Title,
  [Parameter(Mandatory=$true)][string]$Out,
  [int]$X = 0, [int]$Y = 0, [int]$W = 0, [int]$H = 0
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class PW {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public struct RECT { public int L,T,R,B; }
}
"@
[void][PW]::SetProcessDpiAwarenessContext([IntPtr](-4))

$script:target = [IntPtr]::Zero
$script:want = $Title
$cb = [PW+EnumProc]{ param($h,$l)
  $t = New-Object Text.StringBuilder 256
  [void][PW]::GetWindowText($h, $t, 256)
  if ($t.ToString() -eq $script:want) { $script:target = $h }
  return $true
}
[void][PW]::EnumWindows($cb, [IntPtr]::Zero)
if ($script:target -eq [IntPtr]::Zero) { throw "window not found: $Title" }

$r = New-Object PW+RECT
[void][PW]::GetWindowRect($script:target, [ref]$r)
$fullW = $r.R - $r.L
$fullH = $r.B - $r.T

$bmp = New-Object System.Drawing.Bitmap $fullW, $fullH
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# 2 = PW_RENDERFULLCONTENT, required for DirectComposition/Flutter surfaces
$ok = [PW]::PrintWindow($script:target, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()
if (-not $ok) { Write-Host "warning: PrintWindow returned false" }

if ($W -gt 0 -and $H -gt 0) {
  $rect = New-Object System.Drawing.Rectangle $X, $Y, $W, $H
  $crop = $bmp.Clone($rect, $bmp.PixelFormat)
  $crop.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $crop.Dispose()
  Write-Host ("saved {0}  window {1}x{2}, cropped {3},{4} {5}x{6}" -f $Out,$fullW,$fullH,$X,$Y,$W,$H)
} else {
  $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host ("saved {0}  window {1}x{2}" -f $Out, $fullW, $fullH)
}
$bmp.Dispose()
