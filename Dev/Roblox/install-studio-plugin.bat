@echo off
setlocal EnableExtensions

cd /d "%~dp0" || exit /b 1

set "PLUGIN_FILE=Dist\EffekseerForRobloxImporter.rbxm"
set "PLUGIN_DIR=%LOCALAPPDATA%\Roblox\Plugins"

if not exist "%PLUGIN_FILE%" (
	call build-studio-plugin.bat
	if errorlevel 1 exit /b 1
)

if not exist "%PLUGIN_DIR%" mkdir "%PLUGIN_DIR%"
copy /Y "%PLUGIN_FILE%" "%PLUGIN_DIR%\EffekseerForRobloxImporter.rbxm" > nul
if errorlevel 1 exit /b 1

echo Installed local Studio plugin:
echo %PLUGIN_DIR%\EffekseerForRobloxImporter.rbxm
echo Restart Roblox Studio if the plugin was already loaded.
