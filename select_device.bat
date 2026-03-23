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

rem Route audio to desired device
reg add "HKLM\SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings\GlobalControl\Store" /v kSet_StreamRedirectionDeviceIdCount /t REG_DWORD /d 56 /f >nul
reg add "HKLM\SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings\GlobalControl\Store" /v kSet_StreamRedirectionState /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings\GlobalControl\Store" /v kSet_StreamRedirectionDeviceId /t REG_BINARY /d %StreamRedirectionDeviceId% /f >nul

rem Notify APO to reload settings
rem   APO watches `GlobalSettingChanged` via RegNotifyChangeKeyValue
rem   Write volatile subkey under NotificationClients\{clientId}\GlobalSettingChanged\{tmpId}
rem   Setting = REG_DWORD 175 (stream redirection category), then delete subkey
set "notifBase=SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings\NotificationClients"
for /f "delims=" %%c in ('reg query "HKLM\%notifBase%" 2^>nul ^| findstr /r "[0-9]"') do set "clientKey=%%~nxc"
set "gscPath=!notifBase!\!clientKey!\GlobalSettingChanged"
set "tmpName=%random%%random%"
powershell -Command "$k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('%gscPath%',$true); $s=$k.CreateSubKey('%tmpName%','Default','Volatile'); $s.SetValue('Setting',175,'DWord'); $s.Close(); try{$k.DeleteSubKeyTree('%tmpName%')}catch{}; $k.Close()"
%soundvolumeview% /SetDefault "SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render" 0
%soundvolumeview% /SetDefault "SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render" 2

rem Store audio device in registry for AHK
reg add "HKCU\SOFTWARE\SteelSeries ApS\Sonar.APO\AHK" /v AudioDevice /t REG_SZ /d "%name% (%deviceName%)" /f >nul

start "" "%~dp0volume_set.ahk"
