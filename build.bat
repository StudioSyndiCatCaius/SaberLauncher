@echo off
setlocal
cd /d "%~dp0"
if not exist APP mkdir APP
odin build src -out:APP\Saber.exe -subsystem:windows -vet-unused-imports -resource:res/saber.rc
if errorlevel 1 exit /b 1
copy /Y "C:\Lang\Odin\vendor\raylib\windows\raylib.dll" APP\raylib.dll >nul
echo Built APP\Saber.exe
