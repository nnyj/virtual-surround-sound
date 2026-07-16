@echo off
setlocal EnableDelayedExpansion

@REM Dry-run: vss-device-select.bat auto "" "" "" dry-run
set "sound_cli=soundvolumeview.exe"
set "defaultTarget=Speakers: High Definition Audio Device"
set "ahkKey=HKCU\SOFTWARE\VirtualSurroundSound\AHK"
set "cableFilter=VB-Audio Virtual Cable"
set "cableRender=VB-Audio Virtual Cable\Device\CABLE Input\Render"
set "mode=%~1"
set "eventState=%~3"
set "eventId=%~4"
set "dryRun=%~5"
if /I "%mode%"=="auto" goto auto_select

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
call :scan_render_devices target "%defaultTarget%"
if defined deviceid goto route_device
echo No matching render device found.
exit /b 1

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
if /I "%dryRun%"=="dry-run" exit /b 0

@REM vss_apo.dll watches TargetDeviceId (RegNotifyChangeKeyValue) and re-points its sink live.
@REM Plain reg add requests KEY_WRITE and gets denied for non-admin; .NET open with exact rights works
@REM (install.ps1 grants Users QueryValues+SetValue on the key).
powershell -NoProfile -Command ^
  "$k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\VirtualSurroundSound'," ^
  "[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree," ^
  "[System.Security.AccessControl.RegistryRights]::QueryValues -bor [System.Security.AccessControl.RegistryRights]::SetValue);" ^
  "$k.SetValue('TargetDeviceId','%deviceid%','String');$k.Close()"
if errorlevel 1 (
  echo Failed to write TargetDeviceId. Run apo\install.ps1 as admin once to grant Users write access.
  exit /b 1
)

@REM Keep cable as default so apps feed the virtual surround chain
"%sound_cli%" /Enable "%cableRender%"
"%sound_cli%" /SetDefault "%cableRender%" 0
"%sound_cli%" /SetDefault "%cableRender%" 1
"%sound_cli%" /SetDefault "%cableRender%" 2

@REM Store audio device in registry for AHK
if "%eventState%"=="1" if /I "%deviceid%"=="%eventId%" (
  for /f "tokens=2,*" %%a in ('reg query "%ahkKey%" /v AudioDevice 2^>nul ^| find "AudioDevice"') do set "previousDevice=%%b"
  for /f "tokens=2,*" %%a in ('reg query "%ahkKey%" /v AudioDeviceId 2^>nul ^| find "AudioDeviceId"') do set "previousDeviceId=%%b"
  if defined previousDeviceId if /I not "!previousDeviceId!"=="%deviceid%" (
    reg add "%ahkKey%" /v PreviousAudioDevice /t REG_SZ /d "!previousDevice!" /f >nul
    reg add "%ahkKey%" /v PreviousAudioDeviceId /t REG_SZ /d "!previousDeviceId!" /f >nul
  )
)
@REM vss-volume-osd.ahk polls these values (WatchDevice), no relaunch needed
reg add "%ahkKey%" /v AudioDevice /t REG_SZ /d "%name% (%deviceName%)" /f >nul
reg add "%ahkKey%" /v AudioDeviceId /t REG_SZ /d "%deviceid%" /f >nul
