@echo off
setlocal
cd /d "%~dp0"
if not exist ..\APP mkdir ..\APP
odin build . -out:..\APP\SaberUpdater.exe -o:speed -vet-unused-imports
if errorlevel 1 exit /b 1
echo Built APP\SaberUpdater.exe
