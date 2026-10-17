@echo off
rem Builds everything, writes dist\ (exes + manifest.ini) and, with "publish", uploads a GitHub release.
rem   release.bat            build + stage only
rem   release.bat publish    also run: gh release create v<VERSION>
setlocal
cd /d "%~dp0"
set REPO=StudioSyndiCatCaius/SaberLauncher
set /p VERSION=<VERSION
if "%VERSION%"=="" echo VERSION file missing & exit /b 1

call build.bat || exit /b 1
call Flasher\build.bat || exit /b 1
call Updater\build.bat || exit /b 1
> APP\version.ini echo version=%VERSION%

if exist dist rmdir /s /q dist
mkdir dist
> dist\manifest.ini echo version=%VERSION%
for %%F in (Saber.exe SaberFlasher.exe SaberUpdater.exe) do (
	copy /Y APP\%%F dist\%%F >nul
	for /f %%H in ('powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 'dist\%%F').Hash"') do >> dist\manifest.ini echo %%F=%%H
)
type dist\manifest.ini

if /i not "%1"=="publish" (
	echo Staged dist\ for v%VERSION%. Run "release.bat publish" to upload.
	exit /b 0
)
gh release create v%VERSION% dist\Saber.exe dist\SaberFlasher.exe dist\SaberUpdater.exe dist\manifest.ini --repo %REPO% --title "Saber %VERSION%" --generate-notes || exit /b 1
echo Published v%VERSION%
