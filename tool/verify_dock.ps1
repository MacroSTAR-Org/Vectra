# Read-only verification of the AI drop dock (the sidebar window's collapsed state).
#
# ASCII only on purpose: PowerShell 5.1 reads a BOM-less .ps1 as ANSI(936),
# which mangles UTF-8 Chinese into invalid tokens (same trap as MSVC needing /utf-8).
#
# No synthetic mouse/keyboard input: it only asks the OS about window state.
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class V {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint c);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
  [DllImport("user32.dll")] public static extern IntPtr GetProp(IntPtr h, string s);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int GetWindowRgn(IntPtr h, IntPtr rgn);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int a,int b,int c,int d);
  [DllImport("gdi32.dll")] public static extern int GetRgnBox(IntPtr rgn, out RECT r);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public struct RECT { public int L,T,R,B; }
  public struct POINT { public int X,Y; }
}
"@
# -4 = PER_MONITOR_AWARE_V2. Without it every coordinate below is scaled fiction
# (that is exactly what silently broke the screenshot script for weeks).
[void][V]::SetProcessDpiAwarenessContext([IntPtr](-4))

$wa = New-Object V+RECT
[void][V]::SystemParametersInfo(0x30, 0, [ref]$wa, 0)   # SPI_GETWORKAREA
$scale = [V]::GetDpiForSystem() / 96.0
Write-Host ("workarea = {0},{1} .. {2},{3}   scale={4}" -f $wa.L,$wa.T,$wa.R,$wa.B,$scale)

# Same constants as drop_dock.dart and sidebar_window.cpp
$size   = [int](56 * $scale)
$margin = [int](14 * $scale)
$expLeft = $wa.R - $margin - $size
$expTop  = $wa.B - $margin - $size
Write-Host ("dock expected at {0},{1} size {2}x{2}" -f $expLeft, $expTop, $size)

$procs = Get-Process -Name vectra -ErrorAction SilentlyContinue
if (-not $procs) { Write-Host "FAIL app is not running"; exit 1 }
$pids = @($procs.Id)

$sidebar = [IntPtr]::Zero
$cb = [V+EnumProc]{ param($h,$l)
  $pp = 0
  [void][V]::GetWindowThreadProcessId($h, [ref]$pp)
  if ($pids -contains $pp) {
    $t = New-Object Text.StringBuilder 256
    [void][V]::GetWindowText($h, $t, 256)
    if ($t.ToString() -eq "VectraSidebar") { $script:sidebar = $h }
  }
  return $true
}
[void][V]::EnumWindows($cb, [IntPtr]::Zero)

$fail = 0
if ($sidebar -eq [IntPtr]::Zero) { Write-Host "FAIL sidebar window not found"; exit 1 }

$r = New-Object V+RECT
[void][V]::GetWindowRect($sidebar, [ref]$r)
$vis = [V]::IsWindowVisible($sidebar)
$ex  = [V]::GetWindowLongPtr($sidebar, -20).ToInt64()   # GWL_EXSTYLE
$topmost = ($ex -band 0x8) -ne 0                        # WS_EX_TOPMOST
Write-Host ("sidebar window: {0},{1} {2}x{3} visible={4} topmost={5} exstyle=0x{6:X}" -f $r.L,$r.T,($r.R-$r.L),($r.B-$r.T),$vis,$topmost,$ex)

if ($vis) { Write-Host "PASS collapsed dock is visible" } else { Write-Host "FAIL dock is hidden"; $fail = 1 }
if ($topmost) { Write-Host "PASS dock is topmost (reachable no matter what covers the desktop)" } else { Write-Host "FAIL dock is not topmost"; $fail = 1 }

# Collapsing does NOT shrink the window -- resizing it corrupted Flutter's
# render surface (content came out squeezed with the header pushed off screen).
# The window stays full sidebar size and the window REGION is clipped to the
# dock square instead, so that region is what has to be checked.
$rgn = [V]::CreateRectRgn(0,0,1,1)
$kind = [V]::GetWindowRgn($sidebar, $rgn)
if ($kind -eq 0) {
  Write-Host "FAIL no window region set (collapsed state should be clipped to the dock)"
  $fail = 1
} else {
  $rb = New-Object V+RECT
  [void][V]::GetRgnBox($rgn, [ref]$rb)
  # region coords are window-relative
  $gl = $r.L + $rb.L
  $gt = $r.T + $rb.T
  $gw = $rb.R - $rb.L
  $gh = $rb.B - $rb.T
  Write-Host ("region box (screen) {0},{1} {2}x{3}" -f $gl,$gt,$gw,$gh)
  if ([Math]::Abs($gw - $size) -le 2 -and [Math]::Abs($gh - $size) -le 2) {
    Write-Host "PASS clipped region matches the Dart/native dock size"
  } else { Write-Host "FAIL dock region size mismatch"; $fail = 1 }
  if ([Math]::Abs($gl - $expLeft) -le 2 -and [Math]::Abs($gt - $expTop) -le 2) {
    Write-Host "PASS dock sits at the work-area bottom-right"
  } else { Write-Host "FAIL dock region is not where it should be"; $fail = 1 }
}
[void][V]::DeleteObject($rgn)

# The OLE drop target lives on the FLUTTERVIEW child: that is the window
# WindowFromPoint returns, and OLE asks exactly that window.
$view = [IntPtr]::Zero
$cb2 = [V+EnumProc]{ param($h,$l) $script:view = $h; return $true }
[void][V]::EnumChildWindows($sidebar, $cb2, [IntPtr]::Zero)
$prop = [V]::GetProp($view, "OleDropTargetInterface")
if ($prop -ne 0) { Write-Host "PASS drop target registered on FLUTTERVIEW" } else { Write-Host "FAIL no drop target"; $fail = 1 }

# Who actually owns the pixel at the dock center, and does the area just left
# of it fall through?  The second half is the point of clipping the region:
# the window spans the whole right strip, but only the dock square may eat clicks.
$p = New-Object V+POINT
$p.X = $expLeft + $size/2
$p.Y = $expTop + $size/2
$h = [V]::WindowFromPoint($p)
$cn = New-Object Text.StringBuilder 256
[void][V]::GetClassName($h, $cn, 256)
$hp = 0
[void][V]::GetWindowThreadProcessId($h, [ref]$hp)
Write-Host ("point ({0},{1}) -> {2} pid={3}" -f $p.X,$p.Y,$cn.ToString(),$hp)
if ($pids -contains $hp) { Write-Host "PASS dock center belongs to us even with other windows on screen" } else { Write-Host "FAIL something covers the dock"; $fail = 1 }

$p2 = New-Object V+POINT
$p2.X = $expLeft - 150
$p2.Y = $expTop + $size/2
$h2 = [V]::WindowFromPoint($p2)
$hp2 = 0
[void][V]::GetWindowThreadProcessId($h2, [ref]$hp2)
$cn2 = New-Object Text.StringBuilder 256
[void][V]::GetClassName($h2, $cn2, 256)
Write-Host ("point ({0},{1}) -> {2} pid={3}" -f $p2.X,$p2.Y,$cn2.ToString(),$hp2)
if ($pids -contains $hp2) {
  Write-Host "FAIL the full-height window is eating clicks outside the dock"
  $fail = 1
} else {
  Write-Host "PASS clicks left of the dock fall through (region clipping works)"
}

exit $fail
