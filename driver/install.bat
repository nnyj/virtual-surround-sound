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

"%~dp0apoDriverPackage\Sonar.AgsSetup.exe" "Game" "ChatRender" "ChatCapture"

"%~dp0Sonar.DevInst.exe" add --device-hwid "ROOT\VEN_SSGG&DEV_0001" --inf "%~dp0vad\SteelSeries-Sonar-VAD.inf" --inf "%~dp0apoDriverPackage\Sonar.Apo.inf" --inf "%~dp0vad\SteelSeries-Sonar-VAD-Extension.inf"

rem Initialize NotificationClients key and grant Users write access for APO reload notifications
set "notifKey=SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings\NotificationClients"
reg query "HKLM\%notifKey%\2720411704\GlobalSettingChanged" >nul 2>nul && goto :skip_notif
powershell -NoProfile -Command ^
  "$k='%notifKey%';" ^
  "$r=[Microsoft.Win32.Registry]::LocalMachine;" ^
  "$o=$r.OpenSubKey($k,[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Security.AccessControl.RegistryRights]::TakeOwnership);" ^
  "$a=$o.GetAccessControl();$a.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User);$o.SetAccessControl($a);$o.Close();" ^
  "$o=$r.OpenSubKey($k,[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Security.AccessControl.RegistryRights]::ChangePermissions);" ^
  "$a=$o.GetAccessControl();$a.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule 'BUILTIN\Users','FullControl','ContainerInherit,ObjectInherit','None','Allow'));" ^
  "$o.SetAccessControl($a);$o.Close();" ^
  "New-Item 'HKLM:\%notifKey%\2720411704\GlobalSettingChanged' -Force >$null"
:skip_notif
