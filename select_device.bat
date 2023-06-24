@echo off
setlocal EnableDelayedExpansion

rem Enumerate and select audio devices
set soundvolumeview="soundvolumeview.exe"
%soundvolumeview% /scomma device.csv /Columns "Name,Type,Direction,DeviceName,ItemID"

set i=0
echo Devices:
for /f "tokens=1,2,3,4,5 delims=, skip=1" %%a in (device.csv) do (
  if "%%b" equ "Device" (
    if "%%c" equ "Render" (
      set /A i+=1
	  echo !i!. %%a: %%d
	  set "option[!i!]=%%e"
	)
  )
)

:getChoice
set /P "choice=Enter desired option: "
if "!option[%choice%]!" equ "" echo ERROR: no such option & goto getChoice
set "deviceid=!option[%choice%]!"
echo/
echo Device ID       : %deviceid%

rem Store the string in chr.tmp file without newline & space
echo | set /p deviceid="%deviceid%" > chr.txt

rem Convert string to hex
certutil -encodehex -f chr.txt chr.tmp 12 > NUL
set /P hex= < chr.tmp
echo Device ID (Hex) : %hex%

rem Generate StreamRedirectionDeviceId hex
set pos=0
set StreamRedirectionDeviceId=
:nextChar
  rem echo Char %pos% is '!hex:~%pos%,2!'
  set "StreamRedirectionDeviceId=!StreamRedirectionDeviceId!!hex:~%pos%,2!00"
  set /a pos=pos+2
  if "!hex:~%pos%,2!" NEQ "" goto NextChar
set "StreamRedirectionDeviceId=!StreamRedirectionDeviceId!0000"
del device.csv chr.txt chr.tmp
echo Final Hex Output: %StreamRedirectionDeviceId%

rem Route audio to desired device
reg add "HKLM\SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings\GlobalControl\Store" /v kSet_StreamRedirectionDeviceIdCount /t REG_DWORD /d 56 /f
reg add "HKLM\SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings\GlobalControl\Store" /v kSet_StreamRedirectionState /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings\GlobalControl\Store" /v kSet_StreamRedirectionDeviceId /t REG_BINARY /d %StreamRedirectionDeviceId% /f
%soundvolumeview% /Disable "SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render"
%soundvolumeview% /Enable "SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render"
%soundvolumeview% /SetDefault "SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render" 0

rem pause