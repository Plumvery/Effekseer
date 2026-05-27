@echo off
setlocal EnableExtensions

cd /d "%~dp0" || exit /b 1

set "PROJECT_FILE=Dev\StudioPlugin\default.project.json"
set "OUTPUT_DIR=Dist"
set "OUTPUT_FILE=%OUTPUT_DIR%\EffekseerForRobloxImporter.rbxm"

if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"

echo Building EffekseerForRoblox Studio plugin...
call argon.exe build "%PROJECT_FILE%" --output "%OUTPUT_FILE%"
if errorlevel 1 exit /b 1

echo Done.
echo Plugin package: %CD%\%OUTPUT_FILE%
