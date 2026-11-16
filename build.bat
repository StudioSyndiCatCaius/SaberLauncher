@echo off
setlocal
cd /d "%~dp0"
if not exist APP mkdir APP
odin build src -out:APP\Saber.exe -subsystem:windows -o:speed -vet-unused-imports -resource:res/saber.rc
if errorlevel 1 exit /b 1
echo Built APP\Saber.exe
