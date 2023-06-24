@echo off

"%~dp0Sonar.DevInst.exe" remove --device-hwid "ROOT\VEN_SSGG&DEV_0001" --inf "%~dp0vad\SteelSeries-Sonar-VAD-Extension.inf" --inf "%~dp0vad\SteelSeries-Sonar-VAD.inf" --inf "%~dp0apoDriverPackage\Sonar.Apo.inf" --catalog "SteelSeries.Sonar.VAD.cat" --catalog "SteelSeries.Sonar.VAD.Extension.cat" 
