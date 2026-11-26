@echo off
rem pcdiag launcher.
rem Keep this file ASCII-only and without BOM: cmd.exe reads .cmd files in the
rem OEM code page and treats a UTF-8 BOM as part of the first command.
setlocal

rem A 32-bit parent process on 64-bit Windows is redirected from System32 to
rem SysWOW64 and would start 32-bit PowerShell. Sysnative points to the real
rem 64-bit System32 and exists only for 32-bit processes.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

if exist "%PS%" goto :check_version
echo Windows PowerShell not found. pcdiag needs PowerShell 5.1.
set "RC=1"
goto :end

:check_version
rem Exit code = major*10 + minor, e.g. 51 for 5.1. PowerShell 1.0 has no
rem $PSVersionTable and returns 0 or 1, which is also below 51.
"%PS%" -NoLogo -NoProfile -NonInteractive -Command "exit [int]($PSVersionTable.PSVersion.Major * 10 + $PSVersionTable.PSVersion.Minor)"
set "PSV=%ERRORLEVEL%"
if %PSV% GEQ 51 goto :run
set /a PSMAJ=PSV/10
set /a PSMIN=PSV%%10
echo This PC has Windows PowerShell %PSMAJ%.%PSMIN%, pcdiag needs 5.1 or newer.
echo Install Windows Management Framework 5.1 or check the PC manually.
set "RC=1"
goto :end

:run
rem %~dp0 is an absolute path, so this also works from a UNC share.
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-PcDiag.ps1" %*
set "RC=%ERRORLEVEL%"

:end
rem Pause only when started by double-click, so the window does not vanish.
echo %CMDCMDLINE% | find /i "%~nx0" >nul && pause
exit /b %RC%
