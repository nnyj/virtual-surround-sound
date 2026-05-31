@echo off
setlocal

set "task_name=vss-route"
set "task_xml=%~dp0vss-route.xml"
set "repo_dir=%~dp0.."
set "temp_xml=%TEMP%\%task_name%_%RANDOM%.xml"

@REM Task Scheduler XML needs absolute paths; template keeps repo portable.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$repo=(Resolve-Path $env:repo_dir).Path;" ^
  "$repo=[Security.SecurityElement]::Escape($repo);" ^
  "$xml=(Get-Content $env:task_xml -Raw).Replace('__repo_dir__',$repo);" ^
  "Set-Content $env:temp_xml $xml -Encoding Unicode"
if not errorlevel 1 schtasks /Create /TN "%task_name%" /XML "%temp_xml%" /F
set "status=%ERRORLEVEL%"
del "%temp_xml%" >nul 2>nul

echo.
if "%status%"=="0" (
  echo Imported: %task_name%
  echo Keep this folder. Task Scheduler points here.
) else (
  echo Import failed.
)
echo.
pause >nul
exit /b %status%
