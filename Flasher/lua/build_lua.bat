@echo off
rem Builds Lua 5.4.7 as a static lib (/MT, matches static raylib) so SaberFlasher stays a single exe.
setlocal
cd /d "%~dp0"
where cl >nul 2>nul || call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if not exist obj mkdir obj
cl /nologo /c /O2 /MT /W0 /DLUA_COMPAT_5_3 /Foobj\ src\*.c || exit /b 1
lib /nologo /OUT:lua54_static.lib obj\*.obj || exit /b 1
rmdir /s /q obj
echo Built lua54_static.lib
