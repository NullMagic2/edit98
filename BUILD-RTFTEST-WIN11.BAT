@echo off
setlocal

set "PPCROSS=C:\FPC\3.2.2\bin\i386-win32\ppcross8086.exe"
if exist "%PPCROSS%" goto build

where ppcross8086.exe >nul 2>&1
if errorlevel 1 goto missing
set "PPCROSS=ppcross8086.exe"

:build
echo Using: %PPCROSS%
echo Cleaning stale compiler units...
del /q *.o *.ppu *.a 2>nul
"%PPCROSS%" -Tmsdos -WmLarge -Cp8086 -O1 -CX -XX -g- RTFTEST.PAS
if errorlevel 1 goto failed
echo.
echo Built RTFTEST.EXE. Run: RTFTEST RTF_SAMPLE.RTF
exit /b 0

:missing
echo ERROR: ppcross8086.exe was not found.
echo Install Free Pascal 3.2.2 Win32 and then its matching i8086-msdos cross-compiler.
echo Expected default location:
echo   C:\FPC\3.2.2\bin\i386-win32\ppcross8086.exe
exit /b 1

:failed
echo.
echo Build failed. Review the compiler messages above.
exit /b 1
