@echo off
setlocal EnableDelayedExpansion

set "soundvolumeview=soundvolumeview.exe"

:enumerate_devices
cls
rem Enumerate and select audio devices
set "i=0"
echo Devices:
for /f "tokens=1,2,3,4,5 delims=, skip=1" %%a in ('%soundvolumeview% /scomma "" /Columns "Name,Type,Direction,DeviceName,ItemID"') do (
  if "%%b" equ "Device" if "%%c" equ "Render" if "%%d" neq "SteelSeries Sonar Virtual Audio Device" (
    set /A i+=1
    echo !i!. %%a: %%d
    set "names[!i!]=%%a"
    set "deviceNames[!i!]=%%d"
    set "option[!i!]=%%e"
  )
)
set "choice="
set /P "choice=Enter desired option (or press Enter to refresh): "
if "%choice%"=="" goto enumerate_devices
if "!option[%choice%]!" equ "" goto enumerate_devices
set "deviceid=!option[%choice%]!"
set "name=!names[%choice%]!"
set "deviceName=!deviceNames[%choice%]!"
echo.
echo Device ID       : %deviceid%

rem Convert device ID to StreamRedirectionDeviceId hex (UTF-16LE + null terminator)
for /f "delims=" %%h in ('powershell -NoProfile -Command "$b=[System.Text.Encoding]::Unicode.GetBytes('%deviceid%'+[char]0); -join($b|ForEach-Object{'{0:X2}'-f$_})"') do set "StreamRedirectionDeviceId=%%h"
echo Final Hex Output: %StreamRedirectionDeviceId%

rem Route audio to desired device (GlobalControl for persistence, Streams for live APO)
set "apoBase=SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings"
reg add "HKLM\%apoBase%\GlobalControl\Store" /v kSet_StreamRedirectionState /t REG_DWORD /d 1 /f >nul
reg add "HKLM\%apoBase%\GlobalControl\Store" /v kSet_StreamRedirectionDeviceIdCount /t REG_DWORD /d 56 /f >nul
reg add "HKLM\%apoBase%\GlobalControl\Store" /v kSet_StreamRedirectionDeviceId /t REG_BINARY /d %StreamRedirectionDeviceId% /f >nul
reg add "HKLM\%apoBase%\GlobalControl\Store" /v kSet_RenderState /t REG_DWORD /d 1 /f >nul
reg add "HKLM\%apoBase%\GlobalControl\Store" /v kSet_StreamRedirectionGainLin /t REG_DWORD /d 1065353216 /f >nul
reg add "HKLM\%apoBase%\GlobalControl\Store" /v kSet_StreamRedirectionMute /t REG_DWORD /d 0 /f >nul

rem Write to active stream (volatile key, must use .NET) and touch ModifiedRender
powershell -NoProfile -Command ^
  "$hklm=[Microsoft.Win32.Registry]::LocalMachine;" ^
  "$hex='%StreamRedirectionDeviceId%';" ^
  "[byte[]]$bytes=for($i=0;$i -lt $hex.Length;$i+=2){[convert]::ToByte($hex.Substring($i,2),16)};" ^
  "if($root=$hklm.OpenSubKey('%apoBase%\Streams')){" ^
  "  $root.GetSubKeyNames()|ForEach-Object{" ^
  "    if($key=$hklm.OpenSubKey('%apoBase%\Streams\'+$_,$true)){" ^
  "      $key.SetValue('ModifiedRender',[byte[]](@(0xFF)*28),'Binary');" ^
  "      $key.SetValue('kSet_StreamRedirectionDeviceId',$bytes,'Binary');" ^
  "      @{kSet_StreamRedirectionState=1;kSet_StreamRedirectionDeviceIdCount=56;kSet_RenderState=1;kSet_StreamRedirectionGainLin=1065353216;kSet_StreamRedirectionMute=0}.GetEnumerator()|ForEach-Object{$key.SetValue($_.Key,$_.Value,'DWord')};" ^
  "      $key.Close()}};$root.Close()}"
set "sonarRender=SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render"
%soundvolumeview% /Enable "%sonarRender%"
%soundvolumeview% /SetDefault "%sonarRender%" 0
%soundvolumeview% /SetDefault "%sonarRender%" 2

rem Store audio device in registry for AHK
reg add "HKCU\SOFTWARE\SteelSeries ApS\Sonar.APO\AHK" /v AudioDevice /t REG_SZ /d "%name% (%deviceName%)" /f >nul

start "" "%~dp0volume_set.ahk"
