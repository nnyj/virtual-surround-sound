@echo off

"%~dp0apoDriverPackage\Sonar.AgsSetup.exe" "Game" "ChatRender" "ChatCapture"

"%~dp0Sonar.DevInst.exe" add --device-hwid "ROOT\VEN_SSGG&DEV_0001" --inf "%~dp0vad\SteelSeries-Sonar-VAD.inf" --inf "%~dp0apoDriverPackage\Sonar.Apo.inf" --inf "%~dp0vad\SteelSeries-Sonar-VAD-Extension.inf" 
