@echo off
setlocal

set "installer=%~1"
for %%i in ("%~dp0..") do set "repo_dir=%%~fi"
set "driver_dir=%repo_dir%\driver"
set "temp_dir=%TEMP%\vss-driver-%RANDOM%"
set "seven_zip="
set "source_dir="
set "device_installer="

if not defined installer (
  set "error_msg=Drag SteelSeries GG installer onto this script."
  goto abort
)
if not exist "%installer%" (
  set "error_msg=Installer not found."
  goto abort
)

where 7z.exe >nul 2>nul && set "seven_zip=7z.exe"
if not defined seven_zip if exist "%ProgramFiles%\7-Zip\7z.exe" set "seven_zip=%ProgramFiles%\7-Zip\7z.exe"
if not defined seven_zip if exist "%ProgramFiles(x86)%\7-Zip\7z.exe" set "seven_zip=%ProgramFiles(x86)%\7-Zip\7z.exe"
if not defined seven_zip (
  set "error_msg=7-Zip not found. Install 7-Zip or add 7z.exe to PATH."
  goto abort
)

mkdir "%temp_dir%" >nul 2>nul
"%seven_zip%" x "%installer%" -o"%temp_dir%" "sonar\driver\*" "apps\sonar\driver\*" "shared\Steelseries.AudioDeviceInstaller.exe" -y -bso0 -bsp0
if errorlevel 1 goto fail

@REM GG v14-v27 uses sonar\driver, v28-v111 uses apps\sonar\driver, v112+ moves device installer to shared.
if exist "%temp_dir%\sonar\driver\apoDriverPackage\Sonar.Apo.inf" set "source_dir=%temp_dir%\sonar\driver"
if exist "%temp_dir%\apps\sonar\driver\apoDriverPackage\Sonar.Apo.inf" set "source_dir=%temp_dir%\apps\sonar\driver"
if not defined source_dir goto fail
if not exist "%source_dir%\vad\SteelSeries-Sonar-VAD.inf" goto fail

if exist "%source_dir%\Sonar.DevInst.exe" set "device_installer=%source_dir%\Sonar.DevInst.exe"
if not defined device_installer if exist "%temp_dir%\shared\Steelseries.AudioDeviceInstaller.exe" set "device_installer=%temp_dir%\shared\Steelseries.AudioDeviceInstaller.exe"
if not defined device_installer goto fail

mkdir "%driver_dir%" >nul 2>nul
attrib -R "%driver_dir%\*" /S /D >nul 2>nul
del /Q "%driver_dir%\Sonar.DevInst.exe" "%driver_dir%\Steelseries.AudioDeviceInstaller.exe" >nul 2>nul
copy /Y "%device_installer%" "%driver_dir%\" >nul || goto fail
robocopy "%source_dir%\apoDriverPackage" "%driver_dir%\apoDriverPackage" /MIR >nul
if errorlevel 8 goto fail
robocopy "%source_dir%\vad" "%driver_dir%\vad" /MIR >nul
if errorlevel 8 goto fail
rmdir /s /q "%temp_dir%" >nul 2>nul

echo.
echo Extracted driver files to "%driver_dir%".
echo.
pause
exit /b 0

:abort
echo.
echo %error_msg%
echo.
pause
exit /b 1

:fail
echo.
echo Driver extraction failed.
echo.
rmdir /s /q "%temp_dir%" >nul 2>nul
pause
exit /b 1
