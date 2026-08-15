# Resolves a crash offset inside flutter_windows.dll to a function name and
# source line, using the PDB that ships in the Flutter SDK artifact cache.
#
# Windows Error Reporting only tells you "faulting module + offset"; without
# this you are reduced to guessing which code path crashed.
#
# Usage: symbolize.ps1 -Rva 0x3a9fa [-Dll <path to flutter_windows.dll>]
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI(936).
param(
  [Parameter(Mandatory=$true)][string]$Rva,
  [string]$Dll = "C:\src\flutter\bin\cache\artifacts\engine\windows-x64-release\flutter_windows.dll"
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path $Dll)) { throw "dll not found: $Dll" }

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct IMAGEHLP_LINE64 {
  public uint SizeOfStruct;
  public IntPtr Key;
  public uint LineNumber;
  public IntPtr FileName;
  public ulong Address;
}

public class Sym {
  [DllImport("dbghelp.dll", SetLastError=true)]
  public static extern bool SymInitialize(IntPtr hProcess, string UserSearchPath, bool fInvadeProcess);
  [DllImport("dbghelp.dll", SetLastError=true)]
  public static extern uint SymSetOptions(uint SymOptions);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Ansi)]
  public static extern ulong SymLoadModuleEx(IntPtr hProcess, IntPtr hFile, string ImageName,
      string ModuleName, ulong BaseOfDll, uint DllSize, IntPtr Data, uint Flags);
  [DllImport("dbghelp.dll", SetLastError=true)]
  public static extern bool SymFromAddr(IntPtr hProcess, ulong Address, out ulong Displacement, IntPtr Symbol);
  [DllImport("dbghelp.dll", SetLastError=true)]
  public static extern bool SymGetLineFromAddr64(IntPtr hProcess, ulong Address, out uint Displacement, ref IMAGEHLP_LINE64 Line);
  [DllImport("dbghelp.dll")] public static extern bool SymCleanup(IntPtr hProcess);
}
"@

$rvaVal = [Convert]::ToUInt64($Rva.Replace("0x",""), 16)
$base = [uint64]0x10000000
$proc = [IntPtr]0x1234   # any unique handle value works for a "fake" session

# SYMOPT_UNDNAME(2) | SYMOPT_LOAD_LINES(0x10) | SYMOPT_DEFERRED_LOADS(4)
# SYMOPT_UNDNAME(2) | SYMOPT_LOAD_LINES(0x10). No DEFERRED_LOADS: we want
# a failure to surface at load time instead of as a mystery 126 later.
[void][Sym]::SymSetOptions(2 -bor 0x10)
$dir = Split-Path -Parent $Dll
if (-not [Sym]::SymInitialize($proc, $dir, $false)) { throw "SymInitialize failed" }

$size32 = [uint32](Get-Item $Dll).Length
$loaded = [Sym]::SymLoadModuleEx($proc, [IntPtr]::Zero, $Dll, $null, $base, $size32, [IntPtr]::Zero, 0)
Write-Host ("SymLoadModuleEx -> 0x{0:X}  (dll {1} bytes)" -f $loaded, $size32)
if ($loaded -eq 0) { throw "SymLoadModuleEx failed (err $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }

# SYMBOL_INFO: fixed part is 88 bytes, then MaxNameLen chars inline
$maxName = 1024
$size = 88 + $maxName
$buf = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
[Runtime.InteropServices.Marshal]::WriteInt32($buf, 0, 88)          # SizeOfStruct
[Runtime.InteropServices.Marshal]::WriteInt32($buf, 84, $maxName)   # MaxNameLen

$disp = [uint64]0
$addr = $base + $rvaVal
if ([Sym]::SymFromAddr($proc, $addr, [ref]$disp, $buf)) {
  $name = [Runtime.InteropServices.Marshal]::PtrToStringAnsi([IntPtr]($buf.ToInt64() + 88))
  Write-Host ("RVA {0}  ->  {1}  (+{2} bytes)" -f $Rva, $name, $disp)
} else {
  Write-Host ("SymFromAddr failed: {0}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error())
}

$line = New-Object IMAGEHLP_LINE64
$line.SizeOfStruct = [uint32][Runtime.InteropServices.Marshal]::SizeOf($line)
$ldisp = [uint32]0
if ([Sym]::SymGetLineFromAddr64($proc, $addr, [ref]$ldisp, [ref]$line)) {
  $file = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($line.FileName)
  Write-Host ("source: {0}:{1}" -f $file, $line.LineNumber)
} else {
  Write-Host "no line info"
}

[Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
[void][Sym]::SymCleanup($proc)
