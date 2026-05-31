@echo off
setlocal EnableDelayedExpansion

@REM Dry-run: vss-device-select.bat auto "" "" "" dry-run
set "sound_cli=%~dp0..\tools\soundvolumeview.exe"
set "defaultTarget=Speakers: High Definition Audio Device"
set "ahkKey=HKCU\SOFTWARE\SteelSeries ApS\Sonar.APO\AHK"
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
@REM Scan selectable render endpoints from SoundVolumeView.
set "deviceid="
set "scanAction=%~1"
set "scanTarget=%~2"
@REM SoundVolumeView exports CSV to stdout only when piped.
for /f "tokens=1,2,3,4,5 delims=, skip=1" %%a in ('^""%sound_cli%" /scomma "" /Columns "Name,Type,Direction,DeviceName,ItemID" ^| more^"') do (
  if "%%b:%%c"=="Device:Render" if not "%%d"=="SteelSeries Sonar Virtual Audio Device" (
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

@REM Sonar stores endpoint ID as UTF-16LE hex plus null terminator count.
for /f "tokens=1,2" %%h in ('powershell -NoProfile -Command "$id='%deviceid%'; $b=[System.Text.Encoding]::Unicode.GetBytes($id+[char]0); $hex=-join($b|ForEach-Object{'{0:X2}'-f$_}); Write-Output ($hex+' '+($id.Length+1))"') do (
  set "StreamRedirectionDeviceId=%%h"
  set "StreamRedirectionDeviceIdCount=%%i"
)
echo Final Hex Output: %StreamRedirectionDeviceId%
if /I "%dryRun%"=="dry-run" exit /b 0

@REM Route audio to desired device (GlobalControl for persistence, Streams for live APO)
set "apoBase=SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings"
@REM GlobalControl persists route across restarts; admin required, live route below is main path.
set "persistStore=HKLM\%apoBase%\GlobalControl\Store"
set "saveFailed="
reg add "%persistStore%" /v kSet_StreamRedirectionState /t REG_DWORD /d 1 /f >nul 2>nul || set "saveFailed=1"
if not defined saveFailed (
  reg add "%persistStore%" /v kSet_StreamRedirectionDeviceIdCount /t REG_DWORD /d %StreamRedirectionDeviceIdCount% /f >nul
  reg add "%persistStore%" /v kSet_StreamRedirectionDeviceId /t REG_BINARY /d %StreamRedirectionDeviceId% /f >nul
  reg add "%persistStore%" /v kSet_RenderState /t REG_DWORD /d 1 /f >nul
  reg add "%persistStore%" /v kSet_StreamRedirectionGainLin /t REG_DWORD /d 1065353216 /f >nul
  reg add "%persistStore%" /v kSet_StreamRedirectionMute /t REG_DWORD /d 0 /f >nul
)
if defined saveFailed echo Note: To save this choice permanently, re-run script as admin.

@REM Live Sonar streams are volatile registry keys; .NET API can update binary values in-place.
powershell -NoProfile -Command ^
  "$hklm=[Microsoft.Win32.Registry]::LocalMachine;" ^
  "$hex='%StreamRedirectionDeviceId%';" ^
  "[byte[]]$bytes=for($i=0;$i -lt $hex.Length;$i+=2){[convert]::ToByte($hex.Substring($i,2),16)};" ^
  "if($root=$hklm.OpenSubKey('%apoBase%\Streams')){" ^
  "  $root.GetSubKeyNames()|ForEach-Object{" ^
  "    if($key=$hklm.OpenSubKey('%apoBase%\Streams\'+$_,$true)){" ^
  "      $key.SetValue('ModifiedRender',[byte[]](@(0xFF)*28),'Binary');" ^
  "      $key.SetValue('kSet_StreamRedirectionDeviceId',$bytes,'Binary');" ^
  "      @{kSet_StreamRedirectionState=1;kSet_StreamRedirectionDeviceIdCount=%StreamRedirectionDeviceIdCount%;kSet_RenderState=1;kSet_StreamRedirectionGainLin=1065353216;kSet_StreamRedirectionMute=0}.GetEnumerator()|ForEach-Object{$key.SetValue($_.Key,$_.Value,'DWord')};" ^
  "      $key.Close()}};$root.Close()}"
set "sonarRender=SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render"
"%sound_cli%" /Enable "%sonarRender%"
"%sound_cli%" /SetDefault "%sonarRender%" 0
"%sound_cli%" /SetDefault "%sonarRender%" 2

@REM Store audio device in registry for AHK
if "%eventState%"=="1" if /I "%deviceid%"=="%eventId%" (
  for /f "tokens=2,*" %%a in ('reg query "%ahkKey%" /v AudioDevice 2^>nul ^| find "AudioDevice"') do set "previousDevice=%%b"
  for /f "tokens=2,*" %%a in ('reg query "%ahkKey%" /v AudioDeviceId 2^>nul ^| find "AudioDeviceId"') do set "previousDeviceId=%%b"
  if defined previousDeviceId if /I not "!previousDeviceId!"=="%deviceid%" (
    reg add "%ahkKey%" /v PreviousAudioDevice /t REG_SZ /d "!previousDevice!" /f >nul
    reg add "%ahkKey%" /v PreviousAudioDeviceId /t REG_SZ /d "!previousDeviceId!" /f >nul
  )
)
reg add "%ahkKey%" /v AudioDevice /t REG_SZ /d "%name% (%deviceName%)" /f >nul
reg add "%ahkKey%" /v AudioDeviceId /t REG_SZ /d "%deviceid%" /f >nul

start "" "%~dp0vss-volume-osd.ahk"
