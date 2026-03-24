@echo off
setlocal EnableDelayedExpansion

set "soundvolumeview=soundvolumeview.exe"

:enumerate_devices
cls
rem Enumerate and select audio devices
set "i=0"
echo Devices:
for /f "tokens=1,2,3,4,5 delims=, skip=1" %%a in ('%soundvolumeview% /scomma "" /Columns "Name,Type,Direction,DeviceName,ItemID"') do (
  if "%%b" equ "Device" (
    if "%%c" equ "Render" (
      set /A i+=1
      echo !i!. %%a: %%d
      set "names[!i!]=%%a"
      set "deviceNames[!i!]=%%d"
      set "option[!i!]=%%e"
    )
  )
)
set "choice="
set /P "choice=Enter desired option (or press Enter to refresh):"
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
powershell -NoProfile -Command "$hex='%StreamRedirectionDeviceId%'; [byte[]]$bytes=for($i=0;$i -lt $hex.Length;$i+=2){[convert]::ToByte($hex.Substring($i,2),16)}; $base='%apoBase%'; $hklm=[Microsoft.Win32.Registry]::LocalMachine; $root=$hklm.OpenSubKey(\"$base\Streams\"); if(-not $root){exit}; foreach($s in $root.GetSubKeyNames()){$k=$hklm.OpenSubKey(\"$base\Streams\$s\",$true); if(-not $k){continue}; [byte[]]$ff=New-Object byte[] 28; for($j=0;$j -lt 28;$j++){$ff[$j]=0xFF}; $k.SetValue('kSet_StreamRedirectionState',1,'DWord'); $k.SetValue('ModifiedRender',$ff,'Binary'); $k.SetValue('kSet_StreamRedirectionDeviceIdCount',56,'DWord'); $k.SetValue('kSet_StreamRedirectionDeviceId',$bytes,'Binary'); $k.SetValue('kSet_RenderState',1,'DWord'); $k.SetValue('kSet_StreamRedirectionGainLin',1065353216,'DWord'); $k.SetValue('kSet_StreamRedirectionMute',0,'DWord'); $k.Close()}; $root.Close()"
%soundvolumeview% /Enable "SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render"
%soundvolumeview% /SetDefault "SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render" 0
%soundvolumeview% /SetDefault "SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render" 2

rem Store audio device in registry for AHK
reg add "HKCU\SOFTWARE\SteelSeries ApS\Sonar.APO\AHK" /v AudioDevice /t REG_SZ /d "%name% (%deviceName%)" /f >nul

start "" "%~dp0volume_set.ahk"
