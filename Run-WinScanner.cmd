@echo off
REM Launches WinScanner.ps1 from the same folder.
REM Uses -ExecutionPolicy Bypass for this single run only (does not change
REM any system-wide PowerShell settings).

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinScanner.ps1"

echo.
pause
