@echo off
setlocal
cd /d "%~dp0"

set "KSP_DEP_ROOT=%LOCALAPPDATA%\Kirby's Sweets Party\dependencies"
set "KSP_NODE="
if exist "%KSP_DEP_ROOT%\node-path.txt" set /p "KSP_NODE="<"%KSP_DEP_ROOT%\node-path.txt"
if defined KSP_NODE if not exist "%KSP_NODE%" set "KSP_NODE="
if defined KSP_NODE "%KSP_NODE%" -e "const v=process.versions.node.split('.');process.exit(v[0]*1000+v[1]>=20019?0:1)" >nul 2>nul
if defined KSP_NODE if errorlevel 1 set "KSP_NODE="
if not defined KSP_NODE if exist "%ProgramFiles%\nodejs\node.exe" set "KSP_NODE=%ProgramFiles%\nodejs\node.exe"
if not defined KSP_NODE for /f "delims=" %%I in ('where node 2^>nul') do if not defined KSP_NODE set "KSP_NODE=%%I"
if defined KSP_NODE "%KSP_NODE%" -e "const v=process.versions.node.split('.');process.exit(v[0]*1000+v[1]>=20019?0:1)" >nul 2>nul
if defined KSP_NODE if errorlevel 1 set "KSP_NODE="

if defined KSP_NODE goto launch_game

echo Preparing the game tools outside the game folder...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-dependencies.ps1" -NeedNode -Diagnose
if errorlevel 1 goto dependency_repair_failed

set "KSP_NODE="
if exist "%KSP_DEP_ROOT%\node-path.txt" set /p "KSP_NODE="<"%KSP_DEP_ROOT%\node-path.txt"
if defined KSP_NODE if not exist "%KSP_NODE%" set "KSP_NODE="
if defined KSP_NODE "%KSP_NODE%" -e "const v=process.versions.node.split('.');process.exit(v[0]*1000+v[1]>=20019?0:1)" >nul 2>nul
if defined KSP_NODE if errorlevel 1 set "KSP_NODE="
if not defined KSP_NODE goto node_repair_failed

:launch_game
"%KSP_NODE%" "%~dp0host.mjs" %*
if errorlevel 1 goto host_failed

endlocal
exit /b 0

:host_failed
set "KSP_HOST_EXIT=%ERRORLEVEL%"
echo.
echo Game startup KSP-HOST-001
echo The local game host stopped with Windows exit code %KSP_HOST_EXIT%.
echo The detailed cause appears directly above this message.
echo Launch again after following that recovery guidance.
pause
endlocal
exit /b %KSP_HOST_EXIT%

:dependency_repair_failed
echo.
echo Dependency repair KSP-LAUNCH-101
echo The dependency installer reported the exact cause and recovery steps above.
echo Its diagnostic record is stored here:
echo %KSP_DEP_ROOT%\dependency-error.json
echo Its full activity log is stored here:
echo %KSP_DEP_ROOT%\dependency-install.log
pause
endlocal
exit /b 1

:node_repair_failed
echo.
echo Dependency validation KSP-LAUNCH-102
echo Setup completed but a compatible Node.js runtime could not be verified.
echo Launch again to repeat discovery and automatic repair.
echo Diagnostic folder:
echo %KSP_DEP_ROOT%
pause
endlocal
exit /b 1
