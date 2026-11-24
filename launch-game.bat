@echo off
setlocal EnableExtensions DisableDelayedExpansion
pushd "%~dp0" || exit /b 1

if not exist "%~dp0host.mjs" goto build_missing
if not exist "%~dp0web\index.html" goto build_missing

if not defined LOCALAPPDATA if defined USERPROFILE set "LOCALAPPDATA=%USERPROFILE%\AppData\Local"
set "KSP_DEP_ROOT=%LOCALAPPDATA%\Kirby's Sweets Party\dependencies"
set "KSP_PS_DIR=%SystemRoot%\System32\WindowsPowerShell\v1.0"
set "PATH=%KSP_PS_DIR%;%SystemRoot%\System32;%PATH%"
set "NODE_OPTIONS="
set "KSP_NODE="
set "KSP_NODE_CANDIDATE=%ProgramFiles%\nodejs\node.exe"
call :use_node_candidate
if defined KSP_NODE goto launch_game
for /f "delims=" %%I in ('where.exe "$PATH:node.exe" 2^>nul') do (
  set "KSP_NODE_CANDIDATE=%%I"
  call :use_node_candidate
  if defined KSP_NODE goto launch_game
)

if not exist "%~dp0install-dependencies.ps1" goto installer_missing
if not exist "%KSP_PS_DIR%\powershell.exe" goto powershell_missing
echo Preparing the game tools outside the game folder...
"%KSP_PS_DIR%\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-dependencies.ps1" -RunPreparedGame %*
if "%ERRORLEVEL%"=="79" goto dependency_repair_failed
if not "%ERRORLEVEL%"=="0" goto host_failed
goto finished

:launch_game
"%KSP_NODE%" "%~dp0host.mjs" %*
if not "%ERRORLEVEL%"=="0" goto host_failed

:finished
popd
endlocal
exit /b 0

:use_node_candidate
if not defined KSP_NODE_CANDIDATE exit /b 0
if not exist "%KSP_NODE_CANDIDATE%" exit /b 0
if not exist "%KSP_PS_DIR%\powershell.exe" goto native_node_check
if not exist "%~dp0install-dependencies.ps1" goto native_node_check
"%KSP_PS_DIR%\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-dependencies.ps1" -CheckSystemNode >nul 2>nul
if "%ERRORLEVEL%"=="37" exit /b 0
if not "%ERRORLEVEL%"=="0" goto native_node_check
set "KSP_NODE=%KSP_NODE_CANDIDATE%"
exit /b 0

:native_node_check
"%KSP_NODE_CANDIDATE%" -e "const [major, minor] = process.versions.node.split('.').map(Number); process.exit(major > 20 || (major === 20 && minor >= 19) ? 0 : 1)" >nul 2>nul
if "%ERRORLEVEL%"=="0" set "KSP_NODE=%KSP_NODE_CANDIDATE%"
exit /b 0

:build_missing
echo.
echo Game startup KSP-LAUNCH-103
if not exist "%~dp0host.mjs" echo Missing host.mjs
if not exist "%~dp0web\index.html" echo Missing web\index.html
if not exist "%~dp0..\package.json" goto portable_missing
if not exist "%~dp0..\package-lock.json" goto portable_missing
if not exist "%~dp0..\tools\build-portable.mjs" goto portable_missing
for %%I in ("%~dp0..") do set "KSP_SOURCE_ROOT=%%~fI"
echo Build this source checkout from Command Prompt with Node.js 20.19.0 or newer and npm on PATH.
echo   cd /d "%KSP_SOURCE_ROOT%"
echo   npm.cmd ci
echo   npm.cmd run build:portable
echo Run launch-game.bat again after the build completes.
pause
popd
exit /b 1

:portable_missing
echo Extract a complete copy of the playable game and launch it from the extracted folder.
pause
popd
exit /b 1

:installer_missing
echo.
echo Dependency setup KSP-DEP-003
echo Restore install-dependencies.ps1 in the game folder or extract a complete copy of the playable game.
pause
popd
exit /b 1

:powershell_missing
echo Windows PowerShell is missing and the launcher could not find a compatible Node.js installation.
echo Restore Windows PowerShell or install Node.js 20.19.0 or newer for Windows.
pause
popd
exit /b 1

:host_failed
set "KSP_HOST_EXIT=%ERRORLEVEL%"
echo.
echo Game startup KSP-HOST-001
echo The local game host stopped with Windows exit code %KSP_HOST_EXIT%.
echo The detailed cause appears directly above this message.
echo Launch again after following that recovery guidance.
pause
popd
endlocal & exit /b %KSP_HOST_EXIT%

:dependency_repair_failed
echo.
echo Dependency repair KSP-LAUNCH-101
echo The dependency installer reported the exact cause and recovery steps above.
echo Its diagnostic record is stored here:
echo "%KSP_DEP_ROOT%\dependency-error.json"
echo Its full activity log is stored here:
echo "%KSP_DEP_ROOT%\dependency-install.log"
pause
popd
endlocal
exit /b 1
