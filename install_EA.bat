@echo off
setlocal EnableDelayedExpansion

echo ============================================================
echo  MT45 N8N Reporter EA Installer
echo ============================================================
echo.

:: ----------------------------------------------------------------
:: 1. Locate MT4 terminal(s)
:: ----------------------------------------------------------------
set "FOUND=0"
set "INSTALL_COUNT=0"

:: Common MT4 install locations
set "SEARCH_ROOTS=%ProgramFiles%\MetaTrader 4 %ProgramFiles(x86)%\MetaTrader 4 %ProgramFiles%\MetaTrader4 %ProgramFiles(x86)%\MetaTrader4 %APPDATA%\MetaQuotes\Terminal %LOCALAPPDATA%\MetaQuotes\Terminal"

:: Also scan Program Files for any folder containing "MetaTrader 4" or "MT4"
set "EA_FILE=%~dp0MT45_N8N_Reporter.mq4"

if not exist "!EA_FILE!" (
    echo ERROR: MT45_N8N_Reporter.mq4 not found next to this installer.
    echo        Make sure both files are in the same folder.
    goto :end
)

echo Looking for MetaTrader 4 installations...
echo.

:: Try common direct paths first
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

:: Scan AppData/Roaming for MetaQuotes terminal instances
for /D %%G in ("%APPDATA%\MetaQuotes\Terminal\*") do (
    if exist "%%G\MQL4\Experts" (
        call :InstallToDataFolder "%%G"
    )
)

:: Also check if user ran MT4 portable — scan current drive root
for /D %%D in ("C:\*") do (
    if exist "%%D\terminal.exe" (
        findstr /I /M "MetaTrader" "%%D\terminal.exe" >nul 2>&1
        if !errorlevel! == 0 (
            call :InstallToTerminal "%%D"
        )
    )
)

echo.
if !INSTALL_COUNT! == 0 (
    echo No MetaTrader 4 installations were found automatically.
    echo.
    set /p MANUAL_PATH="Enter your MT4 data folder path (e.g. C:\Users\You\AppData\Roaming\MetaQuotes\Terminal\XXXXX): "
    if exist "!MANUAL_PATH!\MQL4\Experts" (
        call :InstallToDataFolder "!MANUAL_PATH!"
    ) else if exist "!MANUAL_PATH!\experts" (
        copy /Y "!EA_FILE!" "!MANUAL_PATH!\experts\" >nul
        echo [OK] Copied to !MANUAL_PATH!\experts\
        set /A INSTALL_COUNT+=1
    ) else (
        echo ERROR: Path not found or does not contain an Experts folder.
    )
)

echo.
echo ============================================================
if !INSTALL_COUNT! GTR 0 (
    echo  Installation complete: !INSTALL_COUNT! location(s) updated.
    echo.
    echo  NEXT STEPS:
    echo  1. Open MetaTrader 4.
    echo  2. Go to Tools ^> Options ^> Expert Advisors tab.
    echo  3. Tick "Allow WebRequest for listed URL" and add your
    echo     N8N webhook URL (e.g. http://localhost:5678/...).
    echo  4. In the Navigator panel, find MT45_N8N_Reporter under
    echo     Expert Advisors and drag it onto any chart.
    echo  5. Set your N8N_Webhook_URL in the EA input parameters.
    echo  6. Make sure "Allow live trading" is enabled on the EA.
) else (
    echo  Installation FAILED. Please copy MT45_N8N_Reporter.mq4
    echo  manually to your MT4 Experts folder.
)
echo ============================================================
echo.
goto :end

:: ----------------------------------------------------------------
:: :InstallToTerminal  — given the terminal.exe folder, find data dir
:: ----------------------------------------------------------------
:InstallToTerminal
set "TERM_DIR=%~1"
:: MQL4/Experts may be inside the terminal folder (portable) or in AppData
if exist "!TERM_DIR!\MQL4\Experts\" (
    call :CopyEA "!TERM_DIR!\MQL4\Experts"
    goto :eof
)
:: Try matching AppData terminal instance by terminal.exe path hash — skip,
:: just report it and fall through to AppData scan above
goto :eof

:: ----------------------------------------------------------------
:: :InstallToDataFolder  — given an AppData terminal data folder
:: ----------------------------------------------------------------
:InstallToDataFolder
set "DATA_DIR=%~1"
if exist "!DATA_DIR!\MQL4\Experts\" (
    call :CopyEA "!DATA_DIR!\MQL4\Experts"
) else (
    :: Older MT4 uses lowercase 'experts'
    if exist "!DATA_DIR!\experts\" (
        call :CopyEA "!DATA_DIR!\experts"
    )
)
goto :eof

:: ----------------------------------------------------------------
:: :CopyEA  — copy the .mq4 file to target Experts folder
:: ----------------------------------------------------------------
:CopyEA
set "TARGET=%~1"
copy /Y "!EA_FILE!" "!TARGET!\" >nul 2>&1
if !errorlevel! == 0 (
    echo [OK] Installed to: !TARGET!\MT45_N8N_Reporter.mq4
    set /A INSTALL_COUNT+=1
    set FOUND=1
) else (
    echo [!!] Failed to copy to: !TARGET!  ^(try running as Administrator^)
)
goto :eof

:end
pause
endlocal
