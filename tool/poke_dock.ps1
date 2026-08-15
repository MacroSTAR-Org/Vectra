# Expands the AI sidebar by posting a click straight to our own FLUTTERVIEW.
#
# This is NOT synthetic system input: no SendInput, the real cursor never moves
# and the user's keyboard is never touched.  It just posts window messages to a
# window this app owns, which is the only way to exercise the "click the dock"
# path without hijacking the mouse.
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI(936).
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class P {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public struct RECT { public int L,T,R,B; }
}
"@
[void][P]::SetProcessDpiAwarenessContext([IntPtr](-4))

$procs = Get-Process -Name vectra -ErrorAction SilentlyContinue
if (-not $procs) { Write-Host "app is not running"; exit 1 }
$script:pids = @($procs.Id)

$script:top = [IntPtr]::Zero
$cb = [P+EnumProc]{ param($h,$l)
  $pp = 0
  [void][P]::GetWindowThreadProcessId($h, [ref]$pp)
  if ($script:pids -contains $pp) {
    $t = New-Object Text.StringBuilder 256
    [void][P]::GetWindowText($h, $t, 256)
    if ($t.ToString() -eq "VectraSidebar") { $script:top = $h }
  }
  return $true
}
[void][P]::EnumWindows($cb, [IntPtr]::Zero)
if ($script:top -eq [IntPtr]::Zero) { Write-Host "sidebar window not found"; exit 1 }

$script:view = [IntPtr]::Zero
$cb2 = [P+EnumProc]{ param($h,$l) $script:view = $h; return $true }
[void][P]::EnumChildWindows($script:top, $cb2, [IntPtr]::Zero)

$r = New-Object P+RECT
[void][P]::GetWindowRect($script:view, [ref]$r)
$w = $r.R - $r.L
$h = $r.B - $r.T
Write-Host ("view {0}x{1}" -f $w, $h)

# The window is always full sidebar size; the dock lives in its bottom-right
# corner (same constants as drop_dock.dart / sidebar_window.cpp).
$scale = 1.5
if ($w -gt 200) {
  $cx = [int]($w - (14 + 28) * $scale)
  $cy = [int]($h - (4 + 28) * $scale)
} else {
  $cx = [int]($w / 2)
  $cy = [int]($h / 2)
}
$lp = [IntPtr](($cy -shl 16) -bor $cx)
[void][P]::PostMessage($script:view, 0x0200, [IntPtr]0, $lp)          # WM_MOUSEMOVE
Start-Sleep -Milliseconds 80
[void][P]::PostMessage($script:view, 0x0201, [IntPtr]1, $lp)          # WM_LBUTTONDOWN
Start-Sleep -Milliseconds 60
[void][P]::PostMessage($script:view, 0x0202, [IntPtr]0, $lp)          # WM_LBUTTONUP
Write-Host "posted click at client ($cx,$cy)"
