@echo off
setlocal EnableExtensions

cd /d "%~dp0" || exit /b 1

set "SAMPLE_DIR=%~1"
if "%SAMPLE_DIR%"=="" set "SAMPLE_DIR=C:\Users\princ\Downloads\Effekseer01\Effekseer01"

set "ROCAS_CONFIG=rocas.toml"
set "PROJECT_FILE=Dev\Plugin\default.project.json"
set "PREVIEW_FILE=Dev\Plugin\EffekseerForRobloxPreview.rbxlx"

echo Effekseer01 Roblox preview update
echo Working directory: %CD%
echo Sample directory: %SAMPLE_DIR%
echo.

if not defined ROCAS_API_KEY (
	echo ERROR: ROCAS_API_KEY is not set.
	echo Set it as a user environment variable, then open a new terminal.
	echo.
	echo   setx ROCAS_API_KEY "your-roblox-open-cloud-api-key"
	exit /b 1
)

if not exist "%ROCAS_CONFIG%" (
	echo ERROR: %ROCAS_CONFIG% was not found.
	echo Copy rocas.toml.example to rocas.toml and set the creator id and asset paths.
	exit /b 1
)

if not exist "%SAMPLE_DIR%" (
	echo ERROR: sample directory was not found: %SAMPLE_DIR%
	exit /b 1
)

if not exist "node_modules\rocas" (
	echo [1/4] Installing npm dependencies...
	call npm.cmd install
	if errorlevel 1 exit /b 1
) else (
	echo [1/4] npm dependencies already installed.
)

echo.
echo [2/4] Syncing rocas assets and generating Effekseer01 modules...
call node.exe bin\generate-sample-pack.js "%SAMPLE_DIR%" --rocas-config "%ROCAS_CONFIG%" --rocas-sync
if errorlevel 1 exit /b 1

echo.
echo [3/4] Running converter tests...
call npm.cmd test
if errorlevel 1 exit /b 1

echo.
echo [4/4] Building Roblox preview place...
call argon.exe build "%PROJECT_FILE%" --output "%PREVIEW_FILE%"
if errorlevel 1 exit /b 1

echo.
echo Done.
echo Preview place: %CD%\%PREVIEW_FILE%
