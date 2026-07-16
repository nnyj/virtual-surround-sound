@echo off
rem Build vss_apo.dll with VS Build Tools 2022 (x64)
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0"
if not exist build mkdir build
cl /nologo /O2 /W3 /EHsc /std:c++17 /LD src\vss_apo.cpp /Fobuild\ /Febuild\vss_apo.dll ^
  /link /DEF:src\vss_apo.def ole32.lib advapi32.lib avrt.lib uuid.lib
