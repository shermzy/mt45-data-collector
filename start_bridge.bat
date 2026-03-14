@echo off
setlocal EnableDelayedExpansion

echo ============================================================
echo  MT45 Price Bridge Server
echo ============================================================
echo.

set "SCRIPT_DIR=%~dp0"
set "PY_SERVER=%SCRIPT_DIR%price_server.py"

:: Check Python
where python >nul 2>&1
if !errorlevel! NEQ 0 (
    echo [!!] Python not found in PATH.
    echo      Download from https://www.python.org/downloads/
    goto :end
)

:: Check server script exists
if not exist "!PY_SERVER!" (
    echo [!!] price_server.py not found in: !SCRIPT_DIR!
    goto :end
)

:: Optional: check dependencies are installed
python -c "import fastapi, uvicorn" >nul 2>&1
if !errorlevel! NEQ 0 (
    echo [..] Installing missing dependencies...
    python -m pip install -r "%SCRIPT_DIR%requirements.txt" --quiet
    if !errorlevel! NEQ 0 (
        echo [!!] Dependency install failed. Run: pip install fastapi uvicorn
        goto :end
    )
    echo [OK] Dependencies ready.
    echo.
)

echo  Server starting on http://localhost:8765
echo  API docs:         http://localhost:8765/docs
echo  Health check:     http://localhost:8765/health
echo.
echo  Press Ctrl+C to stop.
echo ============================================================
echo.

python "!PY_SERVER!"

:end
pause
endlocal
