@echo off
setlocal
if defined VSCMD_ARG_TGT_ARCH if /i not "%VSCMD_ARG_TGT_ARCH%"=="x64" exit /b 1
if defined VCINSTALLDIR goto build
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" exit /b 1
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%i"
if not defined VSROOT exit /b 1
call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
:build
pushd "%~dp0.."
if not exist build mkdir build
cl /nologo /std:c++17 /O1 /MT /EHsc /W4 /WX /utf-8 /Brepro src\UsbTetherHelper.cpp /Fe:build\UsbTetherHelper.exe /Fo:build\UsbTetherHelper.obj /link /Brepro /SUBSYSTEM:WINDOWS /MACHINE:X64 cfgmgr32.lib shell32.lib advapi32.lib user32.lib
set "RESULT=%ERRORLEVEL%"
popd
exit /b %RESULT%
