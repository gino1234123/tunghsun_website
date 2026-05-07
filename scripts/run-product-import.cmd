@echo off
setlocal
cd /d "%~dp0.."

echo Product Import
set /p SOURCE_FILE=Source CSV or Excel file path: 
if "%SOURCE_FILE%"=="" goto :usage

set /p IMAGE_ROOT=Image folder path (optional): 

set /p DRY_RUN=Dry run first? (Y/N, default Y): 
if /I "%DRY_RUN%"=="N" (
    powershell -ExecutionPolicy Bypass -File "%~dp0import-products.ps1" -SourceFile "%SOURCE_FILE%" -ImageRoot "%IMAGE_ROOT%" -Force
) else (
    powershell -ExecutionPolicy Bypass -File "%~dp0import-products.ps1" -SourceFile "%SOURCE_FILE%" -ImageRoot "%IMAGE_ROOT%" -DryRun
)

echo.
pause
goto :eof

:usage
echo.
echo Source file path is required.
echo.
pause
