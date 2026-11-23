@echo off
setlocal EnableDelayedExpansion

@REM Dry-run, prints device and route, writes nothing: vss-device-select.bat auto "" "" "" dry-run
@REM Native on/off, elevates, user click only: vss-device-select.bat native on|off "<device id>"
set "sound_cli=soundvolumeview.exe"
set "apoDir=%~dp0..\apo"
set "nativeClsid={7C1E5A42-5D0B-4E0C-9B7A-6F3B2D9E8A11}"
set "defaultTarget=Speakers: High Definition Audio Device"
set "ahkKey=HKCU\SOFTWARE\VirtualSurroundSound\AHK"
set "cableFilter=VB-Audio Virtual Cable"
set "cableRender=VB-Audio Virtual Cable\Device\CABLE Input\Render"
set "renderKey=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render"
@REM MPC-BE audio time shift per target type, ms as unsigned DWORD. 0xfffffed3 = -301, measured on LinkBuds Clip
set "mpcKey=HKCU\Software\MPC-BE\Audio"
set "mpcShiftBluetooth=0xfffffed3"
set "mpcShiftWired=0"
set "mode=%~1"
set "eventState=%~3"
set "eventId=%~4"
set "dryRun=%~5"
if /I "%mode%"=="auto" goto auto_select
if /I "%mode%"=="native" goto native_toggle

:manual_select

:enumerate_devices
cls
@REM Enumerate and select audio devices
set "i=0"
echo Devices:
call :scan_render_devices list
set "choice="
set /P "choice=Enter desired option (or press Enter to refresh): "
if "%choice%"=="" goto enumerate_devices
if "!option[%choice%]!" equ "" goto enumerate_devices
set "name=!names[%choice%]!"
set "deviceName=!deviceNames[%choice%]!"
set "deviceid=!option[%choice%]!"
goto route_device

:auto_select
@REM Active events route exact endpoint; inactive events fall back only when current routed endpoint disappears.
if "%eventState%"=="1" if not "%eventId%"=="" (
  call :scan_render_devices id "%eventId%"
  if defined deviceid goto route_device
  @REM Hands-Free/control endpoints can activate after stereo; ignore if not selectable.
  exit /b 0
)
@REM Ignore unrelated inactive endpoint changes from Windows audio graph refresh.
if not "%eventState%"=="1" if not "%eventId%"=="" (
  set "currentDeviceId="
  for /f "tokens=2,*" %%a in ('reg query "%ahkKey%" /v AudioDeviceId 2^>nul ^| find "AudioDeviceId"') do set "currentDeviceId=%%b"
  if /I not "!currentDeviceId!"=="%eventId%" exit /b 0
)
for /f "tokens=2,*" %%a in ('reg query "%ahkKey%" /v PreviousAudioDeviceId 2^>nul ^| find "PreviousAudioDeviceId"') do call :scan_render_devices id "%%b"
if defined deviceid goto route_device
call :scan_render_devices target "%defaultTarget%"
if defined deviceid goto route_device
echo No matching render device found.
exit /b 1

:native_toggle
@REM The scheduled task never passes this mode, it runs LeastPrivilege and must not elevate.
set "nativeAction=%~2"
set "nativeDeviceId=%~3"
set "removeArg="
if /I "%nativeAction%"=="off" set "removeArg= -remove"
if /I not "%nativeAction%"=="on" if not defined removeArg (
  echo Usage: vss-device-select.bat native on^|off "<device id>"
  exit /b 1
)
if not exist "%apoDir%\install.ps1" (
  echo install.ps1 not found in %apoDir%
  exit /b 1
)
set "nativeEndpoint="
for /f "tokens=5 delims=." %%g in ("%nativeDeviceId%") do set "nativeEndpoint=%%g"
if not defined nativeEndpoint (
  echo Device id has no endpoint guid: %nativeDeviceId%
  exit /b 1
)
powershell -NoProfile -Command ^
  "$p=Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%apoDir%\install.ps1\" -endpoint %nativeEndpoint%%removeArg%';exit $p.ExitCode"
if errorlevel 1 (
  echo install.ps1 failed or was not elevated.
  exit /b 1
)
@REM Route as an active device event so default device, TargetDeviceId and TimeShift follow the new native state.
set "eventState=1"
set "eventId=%nativeDeviceId%"
goto auto_select

:scan_render_devices
@REM Scan selectable render endpoints from SoundVolumeView, excluding the virtual cable itself.
set "deviceid="
set "scanAction=%~1"
set "scanTarget=%~2"
for /f "tokens=1,2,3,4,5 delims=, skip=1" %%a in ('^""%sound_cli%" /scomma "" /Columns "Name,Type,Direction,DeviceName,ItemID" ^| more^"') do (
  if "%%b:%%c"=="Device:Render" if not "%%d"=="%cableFilter%" (
    if /I "!scanAction!"=="list" (
      set /A i+=1
      echo !i!. %%a: %%d
      set "names[!i!]=%%a"
      set "deviceNames[!i!]=%%d"
      set "option[!i!]=%%e"
    )
    if /I "!scanAction!"=="id" if /I "%%e"=="!scanTarget!" (
      set "name=%%a"
      set "deviceName=%%d"
      set "deviceid=%%e"
    )
    if /I "!scanAction!"=="target" (
      set "label=%%a: %%d"
      if not "!label:%scanTarget%=!"=="!label!" (
        set "name=%%a"
        set "deviceName=%%d"
        set "deviceid=%%e"
      )
    )
  )
)
exit /b

:route_device
echo.
echo Selected        : %name%: %deviceName%
echo Device ID       : %deviceid%
@REM Native route when the native APO sits in the stream effect slot of the target endpoint.
set "route=cable"
set "bluetooth=no"
for /f "tokens=5 delims=." %%g in ("%deviceid%") do (
  reg query "%renderKey%\%%g\FxProperties" /v "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},5" 2>nul | find /i "%nativeClsid%" >nul && set "route=native"
  reg query "%renderKey%\%%g\Properties" /v "{b3f8fa53-0004-438e-9003-51a46e139bfc},2" 2>nul | find "BTHENUM" >nul && set "bluetooth=yes"
)
echo Route           : %route%
echo Bluetooth       : %bluetooth%
if /I "%dryRun%"=="dry-run" exit /b 0

@REM Cable route: apps play to the cable, the forwarder plays to the target.
@REM Native route: apps play to the target itself. Empty TargetDeviceId stops the forwarder,
@REM else its stream would pass the native APO a second time.
set "targetId=%deviceid%"
set "defaultRender=%cableRender%"
set "mpcShift=%mpcShiftWired%"
if "%route%"=="cable" if "%bluetooth%"=="yes" set "mpcShift=%mpcShiftBluetooth%"
if "%route%"=="native" (
  set "targetId="
  set "defaultRender=%deviceid%"
)

@REM vss_apo.dll watches TargetDeviceId (RegNotifyChangeKeyValue) and re-points its sink live.
@REM Plain reg add requests KEY_WRITE and gets denied for non-admin; .NET open with exact rights works
@REM (install.ps1 grants Users QueryValues+SetValue on the key).
powershell -NoProfile -Command ^
  "$k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\VirtualSurroundSound'," ^
  "[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree," ^
  "[System.Security.AccessControl.RegistryRights]::QueryValues -bor [System.Security.AccessControl.RegistryRights]::SetValue);" ^
  "$k.SetValue('TargetDeviceId','%targetId%','String');$k.Close()"
if errorlevel 1 (
  echo Failed to write TargetDeviceId. Run apo\install.ps1 as admin once to grant Users write access.
  exit /b 1
)

"%sound_cli%" /Enable "%defaultRender%"
"%sound_cli%" /SetDefault "%defaultRender%" 0
"%sound_cli%" /SetDefault "%defaultRender%" 1
"%sound_cli%" /SetDefault "%defaultRender%" 2

@REM On Bluetooth the cable clock hides the ~250ms headset delay, so video runs ahead of the sound.
@REM MPC-BE has its own audio offset for that. It reads TimeShift at start and rewrites it on exit.
reg query "%mpcKey%" >nul 2>&1 && (
  tasklist /fi "imagename eq mpc-be64.exe" | find /i "mpc-be64.exe" >nul || (
    reg add "%mpcKey%" /v EnableTimeShift /t REG_DWORD /d 1 /f >nul
    reg add "%mpcKey%" /v TimeShift /t REG_DWORD /d %mpcShift% /f >nul
  )
)

@REM Store audio device in registry for AHK
if "%eventState%"=="1" if /I "%deviceid%"=="%eventId%" (
  for /f "tokens=2,*" %%a in ('reg query "%ahkKey%" /v AudioDevice 2^>nul ^| find "AudioDevice"') do set "previousDevice=%%b"
  for /f "tokens=2,*" %%a in ('reg query "%ahkKey%" /v AudioDeviceId 2^>nul ^| find "AudioDeviceId"') do set "previousDeviceId=%%b"
  if defined previousDeviceId if /I not "!previousDeviceId!"=="%deviceid%" (
    reg add "%ahkKey%" /v PreviousAudioDevice /t REG_SZ /d "!previousDevice!" /f >nul
    reg add "%ahkKey%" /v PreviousAudioDeviceId /t REG_SZ /d "!previousDeviceId!" /f >nul
  )
)
@REM vss-volume-osd.ahk watches these values with a registry event (WatchDevice), no relaunch needed
@REM RouteScript lets the tray menu route through this file
reg add "%ahkKey%" /v RouteScript /t REG_SZ /d "%~f0" /f >nul
reg add "%ahkKey%" /v AudioDevice /t REG_SZ /d "%name% (%deviceName%)" /f >nul
reg add "%ahkKey%" /v AudioDeviceId /t REG_SZ /d "%deviceid%" /f >nul
