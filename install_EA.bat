@echo off
setlocal EnableDelayedExpansion

echo ============================================================
echo  MT45 Full Suite Installer
echo  - MT45_N8N_Reporter.mq4   (positions + account reporter)
echo  - MT45_PriceBridge.mq4    (price data bridge)
echo  - price_server.py          (REST API server)
echo ============================================================
echo.

set "SCRIPT_DIR=%~dp0"
set "EA_REPORTER=%SCRIPT_DIR%MT45_N8N_Reporter.mq4"
set "EA_BRIDGE=%SCRIPT_DIR%MT45_PriceBridge.mq4"
set "PY_SERVER=%SCRIPT_DIR%price_server.py"
set "REQUIREMENTS=%SCRIPT_DIR%requirements.txt"

:: ----------------------------------------------------------------
:: Verify source files exist
:: ----------------------------------------------------------------
set "MISSING=0"
for %%F in ("!EA_REPORTER!" "!EA_BRIDGE!" "!PY_SERVER!" "!REQUIREMENTS!") do (
    if not exist "%%~F" (
        echo [!!] Missing file: %%~F
        set MISSING=1
    )
)
if !MISSING! == 1 (
    echo.
    echo ERROR: Some files are missing. Make sure all MT45 files are
    echo        in the same folder as this installer.
    goto :end
)

:: ----------------------------------------------------------------
:: Step 1: Install Python dependencies
:: ----------------------------------------------------------------
echo [1/3] Installing Python dependencies...
echo.
where python >nul 2>&1
if !errorlevel! NEQ 0 (
    echo [!!] Python not found in PATH.
    echo      Download from https://www.python.org/downloads/
    echo      Make sure to tick "Add Python to PATH" during install.
    echo      Skipping Python setup.
    set "PYTHON_OK=0"
) else (
    for /f "tokens=*" %%V in ('python --version 2^>^&1') do echo      %%V found.
    python -m pip install -r "!REQUIREMENTS!" --quiet
    if !errorlevel! == 0 (
        echo [OK] Python dependencies installed.
        set "PYTHON_OK=1"
    ) else (
        echo [!!] pip install failed. Run manually:
        echo      pip install -r "!REQUIREMENTS!"
        set "PYTHON_OK=0"
    )
)
echo.

:: ----------------------------------------------------------------
:: Step 2: Install EAs to all MT4 instances
:: ----------------------------------------------------------------
echo [2/3] Installing Expert Advisors to MetaTrader 4...
echo.
set "INSTALL_COUNT=0"

:: Common installation paths
for %%D in (
    "%ProgramFiles%\MetaTrader 4"
    "%ProgramFiles(x86)%\MetaTrader 4"
    "%ProgramFiles%\MetaTrader4"
    "%ProgramFiles(x86)%\MetaTrader4"
    "C:\MetaTrader 4"
    "C:\MT4"
) do (
    if exist "%%~D\terminal.exe" (
        call :InstallToTerminal "%%~D"
    )
)

:: Scan AppData MetaQuotes terminal instances
for /D %%G in ("%APPDATA%\MetaQuotes\Terminal\*") do (
    if exist "%%G\MQL4\Experts" (
        call :InstallToDataFolder "%%G"
    )
)

if !INSTALL_COUNT! == 0 (
    echo No MetaTrader 4 installations found automatically.
    echo.
    set /p MANUAL_PATH="Enter your MT4 data folder path: "
    if exist "!MANUAL_PATH!\MQL4\Experts" (
        call :InstallToDataFolder "!MANUAL_PATH!"
    ) else (
        echo [!!] Path not found or has no Experts folder.
    )
)
echo.

:: ----------------------------------------------------------------
:: Step 3: Register price_server.py as a Windows Scheduled Task
:: ----------------------------------------------------------------
echo [3/3] Registering price_server.py as a Scheduled Task...
echo.
if "!PYTHON_OK!" == "1" (
    set "TASK_NAME=MT45PriceBridge"
    set "PYTHON_EXE="
    for /f "tokens=*" %%P in ('where python 2^>nul') do (
        if "!PYTHON_EXE!" == "" set "PYTHON_EXE=%%P"
    )

    schtasks /query /tn "!TASK_NAME!" >nul 2>&1
    if !errorlevel! == 0 (
        echo [OK] Scheduled task '!TASK_NAME!' already exists. Updating...
        schtasks /delete /tn "!TASK_NAME!" /f >nul 2>&1
    )

    schtasks /create ^
        /tn "!TASK_NAME!" ^
        /tr "\"!PYTHON_EXE!\" \"!PY_SERVER!\"" ^
        /sc ONLOGON ^
        /rl HIGHEST ^
        /f >nul 2>&1

    if !errorlevel! == 0 (
        echo [OK] Task '!TASK_NAME!' registered — runs at logon.
        echo      To start now without logging off:
        echo      schtasks /run /tn "!TASK_NAME!"
        set "TASK_OK=1"
    ) else (
        echo [!!] Failed to register task ^(try running as Administrator^).
        echo      You can start the server manually with:
        echo      python "!PY_SERVER!"
        set "TASK_OK=0"
    )
) else (
    echo [!!] Skipped — Python not available.
    set "TASK_OK=0"
)
echo.

:: ----------------------------------------------------------------
:: Summary
:: ----------------------------------------------------------------
echo ============================================================
echo  INSTALLATION SUMMARY
echo ============================================================
echo.
echo  EAs installed : !INSTALL_COUNT! location(s)
echo  Python deps   : !PYTHON_OK! (1=ok)
if defined TASK_OK echo  Auto-start    : !TASK_OK! (1=ok)
echo.
echo  NEXT STEPS
echo  ----------
echo  1. Open MetaTrader 4
echo  2. Tools ^> Options ^> Expert Advisors:
echo       - Tick "Allow WebRequest for listed URL"
echo       - Add your N8N webhook URL
echo       - Add http://localhost:8765 (for price bridge comms if needed)
echo  3. In Navigator, drag onto charts:
echo       - MT45_N8N_Reporter  (any chart — reports positions to N8N)
echo       - MT45_PriceBridge   (any chart — enables price query API)
echo  4. Start the price server:
echo       schtasks /run /tn "MT45PriceBridge"
echo     OR manually: python "!PY_SERVER!"
echo  5. Test: http://localhost:8765/health
echo             http://localhost:8765/prices
echo             http://localhost:8765/docs  (full API reference)
echo.
echo ============================================================
goto :end

:: ----------------------------------------------------------------
:InstallToTerminal
set "TERM_DIR=%~1"
if exist "!TERM_DIR!\MQL4\Experts\" (
    call :CopyEAs "!TERM_DIR!\MQL4\Experts"
)
goto :eof

:: ----------------------------------------------------------------
:InstallToDataFolder
set "DATA_DIR=%~1"
if exist "!DATA_DIR!\MQL4\Experts\" (
    call :CopyEAs "!DATA_DIR!\MQL4\Experts"
) else if exist "!DATA_DIR!\experts\" (
    call :CopyEAs "!DATA_DIR!\experts"
)
goto :eof

:: ----------------------------------------------------------------
:CopyEAs
set "TARGET=%~1"
set "ANY_FAIL=0"

copy /Y "!EA_REPORTER!" "!TARGET!\" >nul 2>&1
if !errorlevel! NEQ 0 set ANY_FAIL=1

copy /Y "!EA_BRIDGE!" "!TARGET!\" >nul 2>&1
if !errorlevel! NEQ 0 set ANY_FAIL=1

if !ANY_FAIL! == 0 (
    echo [OK] EAs installed to: !TARGET!\
    set /A INSTALL_COUNT+=1
) else (
    echo [!!] Partial failure copying to: !TARGET!  ^(try running as Administrator^)
)
goto :eof

:end
pause
endlocal
