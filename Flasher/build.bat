@echo off
setlocal
cd /d "%~dp0"
if not exist ..\APP mkdir ..\APP
if not exist lua\lua54_static.lib call lua\build_lua.bat || exit /b 1
odin build . -out:..\APP\SaberFlasher.exe -subsystem:windows -o:speed -vet-unused-imports -resource:../res/flasher.rc
if errorlevel 1 exit /b 1
echo Built APP\SaberFlasher.exe
