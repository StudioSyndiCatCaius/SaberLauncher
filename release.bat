@echo off
rem Builds everything and stamps APP\version.ini from VERSION.
rem   release.bat            build only (make_release_zip.bat calls this, then packs dist\*.zip)
rem   release.bat publish    also upload dist\SaberLauncher-v<VERSION>.zip as release <VERSION>
rem SaberUpdater only needs that zip on the release; the tag is the version.
setlocal
cd /d "%~dp0"
set REPO=StudioSyndiCatCaius/SaberLauncher
set /p VERSION=<VERSION
if "%VERSION%"=="" echo VERSION file missing & exit /b 1

call build.bat || exit /b 1
call Flasher\build.bat || exit /b 1
call Updater\build.bat || exit /b 1
> APP\version.ini echo version=%VERSION%

if /i not "%1"=="publish" exit /b 0
set ZIP=dist\SaberLauncher-v%VERSION%.zip
if not exist %ZIP% echo %ZIP% missing, run make_release_zip.bat first & exit /b 1
gh release create %VERSION% %ZIP% --repo %REPO% --title "Saber %VERSION%" --generate-notes || exit /b 1
echo Published %VERSION%
