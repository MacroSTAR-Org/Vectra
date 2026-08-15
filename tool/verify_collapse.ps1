# Verifies that the expanded AI sidebar collapses back to the corner dock.
#
# It posts WM_ACTIVATE(WA_INACTIVE) to our own window -- the exact message
# Windows sends when the user clicks another program.  It is NOT synthetic
# system input: no SendInput, the real cursor and keyboard are never touched.
#
# Why not really steal the foreground: Windows refuses foreground steals from a
# background process, so a helper window just flashes the taskbar and the test
# comes out inconclusive (tried it).
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI(936).
Add-Type @"
using System;using System.Text;using System.Runtime.InteropServices;
public class C {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowRgn(IntPtr h, IntPtr rgn);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int a,int b,int c,int d);
  [DllImport("gdi32.dll")] public static extern int GetRgnBox(IntPtr rgn, out RECT r);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public struct RECT { public int L,T,R,B; }
}
"@
[void][C]::SetProcessDpiAwarenessContext([IntPtr](-4))

$procs = Get-Process -Name vectra -ErrorAction SilentlyContinue
if (-not $procs) { Write-Host "FAIL app is not running"; exit 1 }
$script:pids = @($procs.Id)

# $script: on both sides.  A delegate body runs in its own scope, so writing
# $script:hwnd there and reading a function-local $hwnd here silently yields
# zero -- the same trap that once made me conclude "the packaged exe opens no
# windows" when the windows were right there.
$script:hwnd = [IntPtr]::Zero
$cb = [C+EnumProc]{ param($h,$l)
  $pp = 0
  [void][C]::GetWindowThreadProcessId($h, [ref]$pp)
  if ($script:pids -contains $pp) {
    $t = New-Object Text.StringBuilder 256
    [void][C]::GetWindowText($h, $t, 256)
    if ($t.ToString() -eq "VectraSidebar") { $script:hwnd = $h }
  }
  return $true
}
[void][C]::EnumWindows($cb, [IntPtr]::Zero)
if ($script:hwnd -eq [IntPtr]::Zero) { Write-Host "FAIL sidebar window not found"; exit 1 }

# Collapsed == the window region is clipped to the dock square.
# The window itself never changes size (resizing it corrupted Flutter's
# render surface), so the region is the only thing that tells them apart.
function RegionBox {
  $rgn = [C]::CreateRectRgn(0,0,1,1)
  $kind = [C]::GetWindowRgn($script:hwnd, $rgn)
  if ($kind -eq 0) { [void][C]::DeleteObject($rgn); return $null }
  $b = New-Object C+RECT
  [void][C]::GetRgnBox($rgn, [ref]$b)
  [void][C]::DeleteObject($rgn)
  return @{ W = ($b.R - $b.L); H = ($b.B - $b.T) }
}

$before = RegionBox
if ($before -ne $null) {
  Write-Host ("SKIP already collapsed (region {0}x{1}); expand it first" -f $before.W, $before.H)
  exit 2
}
Write-Host "before: expanded (no window region)"

# WA_INACTIVE = 0
[void][C]::PostMessage($script:hwnd, 0x0006, [IntPtr]0, [IntPtr]0)
# 260ms exit animation + slack
Start-Sleep -Milliseconds 900

$after = RegionBox
if ($after -eq $null) {
  Write-Host "FAIL still expanded: losing focus did not collapse the sidebar"
  exit 1
}
Write-Host ("after : collapsed (region {0}x{1})" -f $after.W, $after.H)
Write-Host "PASS sidebar collapsed back to the corner dock after losing focus"
exit 0
