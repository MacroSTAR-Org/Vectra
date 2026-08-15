@echo off
rem ============================================================
rem  Build release + portable installer (no installer version)
rem
rem  Usage:
rem    build_release.bat           build release and package
rem    build_release.bat --skip    skip flutter build (use existing)
rem
rem  Output:
rem    Release folder: build\windows\x64\runner\Release\
rem    Portable:       installer\out\Vectra-<version>-portable.exe
rem
rem  The version comes from pubspec.yaml and nowhere else. `A.B.C+D` there
rem  becomes the four-part Windows version A.B.C.D used for the exe, the
rem  installer and the package filename.
rem ============================================================

setlocal enabledelayedexpansion

rem ---- paths ----
set "ROOT=%~dp0.."
set "RELEASE=%ROOT%\build\windows\x64\runner\Release"
set "REDIST=%ROOT%\windows\redist"
set "ISS_PORTABLE=%ROOT%\installer\vectra_portable.iss"
set "OUT_DIR=%ROOT%\installer\out"

rem ---- read version from pubspec.yaml (single source of truth) ----
set "PUBSPEC_VERSION="
for /f "tokens=2 delims= " %%v in ('findstr /b /c:"version:" "%ROOT%\pubspec.yaml"') do (
    if not defined PUBSPEC_VERSION set "PUBSPEC_VERSION=%%v"
)
if not defined PUBSPEC_VERSION (
    echo [ERROR] could not read version from pubspec.yaml
    exit /b 1
)
rem  0.1.1+120 -> 0.1.1.120
set "APP_VERSION=%PUBSPEC_VERSION:+=.%"
echo [ver] %APP_VERSION%  (from pubspec.yaml: %PUBSPEC_VERSION%)
set "OUT_PORTABLE=%OUT_DIR%\Vectra-%APP_VERSION%-portable.exe"

rem ---- find ISCC.exe ----
set "ISCC="
if exist "D:\Inno Setup 6\ISCC.exe" set "ISCC=D:\Inno Setup 6\ISCC.exe"
if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
if exist "C:\Program Files\Inno Setup 6\ISCC.exe" set "ISCC=C:\Program Files\Inno Setup 6\ISCC.exe"

if not defined ISCC (
    echo [ERROR] ISCC.exe not found. Install Inno Setup 6: https://jrsoftware.org/isdl.php
    exit /b 1
)

rem ---- build release ----
if /i not "%~1"=="--skip" (
    echo [1/3] flutter build windows --release ...
    pushd "%ROOT%"
    call flutter build windows --release --no-pub
    if errorlevel 1 (
        echo [ERROR] flutter build failed.
        popd
        exit /b 1
    )
    popd
) else (
    echo [1/3] flutter build skipped (--skip)
)

if not exist "%RELEASE%\vectra.exe" (
    echo [ERROR] %RELEASE%\vectra.exe not found.
    exit /b 1
)

rem ---- copy VC++ runtime next to the exe ----
rem App-local DLLs take precedence over System32. The system copy can be
rem downgraded by other installers (seen once: msvcp140.dll 14.00.24215.1
rem crashed every MSVC app), so always ship our own modern copy.
echo [2/3] Copying VC++ runtime DLLs ...
for %%f in (msvcp140.dll vcruntime140.dll vcruntime140_1.dll) do (
    copy /y "%REDIST%\%%f" "%RELEASE%\%%f" >nul
    if errorlevel 1 (
        echo [ERROR] failed to copy %%f
        exit /b 1
    )
)

rem ---- build portable installer ----
echo [3/3] Inno Setup portable ...
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
"%ISCC%" /DAppVersion=%APP_VERSION% "%ISS_PORTABLE%"
if errorlevel 1 (
    echo [ERROR] portable build failed.
    exit /b 1
)

echo.
echo Output:
echo   %RELEASE%\vectra.exe   (release folder, copy as-is)
echo   %OUT_PORTABLE%
endlocal
