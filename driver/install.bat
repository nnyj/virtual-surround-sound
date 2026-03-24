@echo off

@REM Elevate script as admin and pass arguments and preventing loop
setlocal DisableDelayedExpansion
set _elev=
set _args=%*
if defined _args set _args=%_args:"=%
if defined _args (for %%A in (%_args%) do (if /i "%%A"=="-el" set _elev=1))
set "nul=>nul 2>&1"
set "_psc=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "_PSarg="""%~f0""" -el %_args%"
setlocal EnableDelayedExpansion
%nul% reg query HKU\S-1-5-19 || (
  if not defined _elev %nul% %_psc% "start cmd.exe -arg '/c \"!_PSarg:'=''!\"' -verb runas" && exit /b
  echo This script require administrator privileges.
  echo To do so, right click on this script and select 'Run as administrator'.
  pause & exit/b
)

"%~dp0apoDriverPackage\Sonar.AgsSetup.exe" "Game" "ChatRender" "ChatCapture" "Media" "Aux"

"%~dp0Sonar.DevInst.exe" add --device-hwid "ROOT\VEN_SSGG&DEV_0001" --inf "%~dp0vad\SteelSeries-Sonar-VAD.inf" --inf "%~dp0apoDriverPackage\Sonar.Apo.inf" --inf "%~dp0vad\SteelSeries-Sonar-VAD-Extension.inf"

"%~dp0Sonar.DevInst.exe" register --cat="sonar.apo.cat" --com="Sonar.APO.dll" --com="Sonar.APOAPI.dll" --inf "%~dp0apoDriverPackage\Sonar.Apo.inf"
