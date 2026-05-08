@echo off
setlocal
cd /d "%~dp0.."

echo Product Image Fetch
echo.

if "%BRAVE_SEARCH_API_KEY%"=="" (
    set /p BRAVE_SEARCH_API_KEY=Brave Search API key: 
)

set /p SOURCE_FILE=Source CSV file path: 
if "%SOURCE_FILE%"=="" goto :usage

set /p IMAGE_ROOT=Image folder path (default product-images): 
if "%IMAGE_ROOT%"=="" set IMAGE_ROOT=product-images

set /p OUTPUT_FILE=Output CSV file path (optional): 

set /p MAX_PRODUCTS=Max products to process (optional, example 3): 
if "%MAX_PRODUCTS%"=="" set MAX_PRODUCTS=0

set /p CANDIDATES_ONLY=Only make candidate report? (Y/N, default N): 

if /I "%CANDIDATES_ONLY%"=="Y" (
    powershell -ExecutionPolicy Bypass -File "%~dp0fetch-product-images.ps1" -SourceFile "%SOURCE_FILE%" -ImageRoot "%IMAGE_ROOT%" -OutputFile "%OUTPUT_FILE%" -MaxProducts "%MAX_PRODUCTS%" -CandidatesOnly
) else (
    powershell -ExecutionPolicy Bypass -File "%~dp0fetch-product-images.ps1" -SourceFile "%SOURCE_FILE%" -ImageRoot "%IMAGE_ROOT%" -OutputFile "%OUTPUT_FILE%" -MaxProducts "%MAX_PRODUCTS%"
)

echo.
pause
goto :eof

:usage
echo.
echo Source CSV file path is required.
echo.
pause
