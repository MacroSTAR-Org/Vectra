# Captures a burst of frames of the AI sidebar area, to check the enter animation.
#
# The slide-in is 260ms, so a single screenshot proves nothing -- by the time a
# fresh PowerShell process starts, the animation is over.  This grabs frames
# from one already-warm process at ~35ms intervals.
#
# Usage: burst.ps1 -Out prefix [-Frames 10]
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI(936).
param(
  [Parameter(Mandatory=$true)][string]$Out,
  [int]$Frames = 10,
  [int]$IntervalMs = 35
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class B {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
}
"@
[void][B]::SetProcessDpiAwarenessContext([IntPtr](-4))

# The sidebar lives on the right edge; grab a strip wide enough to see it slide.
$x = 1900; $y = 15; $w = 660; $h = 300
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$sz = New-Object System.Drawing.Size($w, $h)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $Frames; $i++) {
  $g.CopyFromScreen($x, $y, 0, 0, $sz)
  $bmp.Save(("{0}_{1:d2}.png" -f $Out, $i), [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host ("frame {0:d2} at {1} ms" -f $i, $sw.ElapsedMilliseconds)
  Start-Sleep -Milliseconds $IntervalMs
}
$g.Dispose()
$bmp.Dispose()
