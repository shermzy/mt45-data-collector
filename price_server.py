"""
MT45 Price Bridge Server
========================
FastAPI REST server that reads MT4 price data files written by MT45_PriceBridge.mq4
and exposes them as HTTP endpoints for N8N or any HTTP client.

Endpoints:
  GET /health                         — server + file health check
  GET /prices                         — all MarketWatch symbols (bid/ask/spread)
  GET /prices/{symbol}                — single symbol
  GET /symbols                        — full symbol metadata list
  GET /bars/{symbol}/{timeframe}      — historical OHLCV bars
                                        ?count=200  (max 5000)
                                        &from_ts=0  (unix timestamp, 0 = latest N bars)

Usage:
  python price_server.py [--mt4-files-path "C:\\path\\to\\MQL4\\Files"] [--port 8765]

If --mt4-files-path is omitted, the server auto-detects all MetaQuotes terminal
instances and uses the one that has a prices.json file.
"""

import argparse
import asyncio
import glob
import json
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Optional

try:
    from fastapi import FastAPI, HTTPException, Query
    from fastapi.responses import JSONResponse
    import uvicorn
except ImportError:
    print("Missing dependencies. Run:  pip install fastapi uvicorn aiofiles")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DEFAULT_PORT = 8765
BAR_REQUEST_TIMEOUT = 10.0   # seconds to wait for EA to respond
BAR_POLL_INTERVAL   = 0.1    # seconds between polls for bar response

app = FastAPI(
    title="MT45 Price Bridge",
    description="Exposes MT4 live price and bar history data via REST.",
    version="1.0.0",
)

MT4_FILES_PATH: Optional[Path] = None  # set at startup


# ---------------------------------------------------------------------------
# Auto-detect MT4 Files folder
# ---------------------------------------------------------------------------
def find_mt4_files_paths() -> list[Path]:
    """Return all MetaQuotes terminal MQL4/Files directories that exist."""
    candidates = []
    roaming = Path(os.environ.get("APPDATA", ""))
    mq_root = roaming / "MetaQuotes" / "Terminal"
    if mq_root.exists():
        for terminal_dir in mq_root.iterdir():
            if terminal_dir.is_dir():
                p = terminal_dir / "MQL4" / "Files"
                if p.exists():
                    candidates.append(p)
    return candidates


def resolve_mt4_path(user_path: Optional[str]) -> Path:
    if user_path:
        p = Path(user_path)
        if not p.exists():
            print(f"[ERROR] Provided MT4 files path does not exist: {p}")
            sys.exit(1)
        return p

    candidates = find_mt4_files_paths()
    if not candidates:
        print("[ERROR] No MetaQuotes terminal MQL4/Files directories found.")
        print("        Run with --mt4-files-path to specify manually.")
        sys.exit(1)

    # Prefer the one that already has prices.json
    for c in candidates:
        if (c / "prices.json").exists():
            print(f"[INFO] Using MT4 Files path: {c}")
            return c

    # Fall back to first found
    print(f"[INFO] Using MT4 Files path (prices.json not yet present): {candidates[0]}")
    return candidates[0]


# ---------------------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------------------
def read_json(path: Path) -> Optional[dict]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def file_age(path: Path) -> Optional[float]:
    try:
        return time.time() - path.stat().st_mtime
    except FileNotFoundError:
        return None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    prices_path  = MT4_FILES_PATH / "prices.json"
    symbols_path = MT4_FILES_PATH / "symbols.json"
    prices_age   = file_age(prices_path)
    symbols_age  = file_age(symbols_path)

    prices_data  = read_json(prices_path)
    symbol_count = len(prices_data.get("symbols", {})) if prices_data else 0

    stale = prices_age is None or prices_age > 10
    return {
        "status":                "stale" if stale else "ok",
        "mt4_files_path":        str(MT4_FILES_PATH),
        "prices_age_seconds":    round(prices_age, 2) if prices_age is not None else None,
        "symbols_age_seconds":   round(symbols_age, 2) if symbols_age is not None else None,
        "prices_symbol_count":   symbol_count,
    }


@app.get("/prices")
def get_all_prices():
    data = read_json(MT4_FILES_PATH / "prices.json")
    if data is None:
        raise HTTPException(503, "prices.json not available — is MT45_PriceBridge.mq4 running?")
    age = file_age(MT4_FILES_PATH / "prices.json")
    return {
        "ts":         data.get("ts"),
        "age_seconds": round(age, 2) if age is not None else None,
        "symbols":    data.get("symbols", {}),
    }


@app.get("/prices/{symbol}")
def get_price(symbol: str):
    symbol = symbol.upper()
    data = read_json(MT4_FILES_PATH / "prices.json")
    if data is None:
        raise HTTPException(503, "prices.json not available")
    syms = data.get("symbols", {})
    if symbol not in syms:
        raise HTTPException(404, f"Symbol '{symbol}' not in MarketWatch")
    age = file_age(MT4_FILES_PATH / "prices.json")
    entry = syms[symbol]
    return {
        "symbol":       symbol,
        "bid":          entry.get("bid"),
        "ask":          entry.get("ask"),
        "spread":       entry.get("spread"),
        "digits":       entry.get("digits"),
        "ts":           data.get("ts"),
        "age_seconds":  round(age, 2) if age is not None else None,
    }


@app.get("/symbols")
def get_symbols():
    data = read_json(MT4_FILES_PATH / "symbols.json")
    if data is None:
        raise HTTPException(503, "symbols.json not available")
    return {
        "ts":      data.get("ts"),
        "symbols": data.get("symbols", []),
    }


VALID_TIMEFRAMES = {"M1", "M5", "M15", "M30", "H1", "H4", "D1", "W1", "MN1"}

@app.get("/bars/{symbol}/{timeframe}")
async def get_bars(
    symbol: str,
    timeframe: str,
    count: int = Query(default=200, ge=1, le=5000),
    from_ts: int = Query(default=0, ge=0),
):
    symbol    = symbol.upper()
    timeframe = timeframe.upper()

    if timeframe not in VALID_TIMEFRAMES:
        raise HTTPException(400, f"Invalid timeframe '{timeframe}'. Valid: {sorted(VALID_TIMEFRAMES)}")

    req_id   = f"r_{int(time.time() * 1000)}_{uuid.uuid4().hex[:8]}"
    req_body = json.dumps({
        "id":        req_id,
        "symbol":    symbol,
        "timeframe": timeframe,
        "count":     count,
        "from_ts":   from_ts,
    })

    req_dir = MT4_FILES_PATH / "bars_req"
    res_dir = MT4_FILES_PATH / "bars_res"
    req_dir.mkdir(exist_ok=True)
    res_dir.mkdir(exist_ok=True)

    req_path = req_dir / f"{req_id}.req"
    res_path = res_dir / f"{req_id}.res"

    # Write request file
    req_path.write_text(req_body, encoding="utf-8")

    # Poll for response
    deadline = time.time() + BAR_REQUEST_TIMEOUT
    try:
        while time.time() < deadline:
            await asyncio.sleep(BAR_POLL_INTERVAL)
            if res_path.exists():
                try:
                    result = json.loads(res_path.read_text(encoding="utf-8"))
                    res_path.unlink(missing_ok=True)
                    if "error" in result:
                        raise HTTPException(404, f"MT4 error: {result['error']}")
                    return result
                except (json.JSONDecodeError, PermissionError):
                    # File still being written — try again
                    continue
    finally:
        # Clean up request file if EA never processed it
        req_path.unlink(missing_ok=True)

    raise HTTPException(504, f"Timeout waiting for MT4 bar data (reqId={req_id}). "
                             "Is MT45_PriceBridge.mq4 running on a chart?")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main():
    global MT4_FILES_PATH

    parser = argparse.ArgumentParser(description="MT45 Price Bridge Server")
    parser.add_argument("--mt4-files-path", default=None,
                        help="Path to MT4 MQL4/Files directory")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"HTTP port (default: {DEFAULT_PORT})")
    parser.add_argument("--host", default="127.0.0.1",
                        help="Bind host (default: 127.0.0.1)")
    parser.add_argument("--install-task", action="store_true",
                        help="Register as a Windows Scheduled Task at logon and exit")
    args = parser.parse_args()

    MT4_FILES_PATH = resolve_mt4_path(args.mt4_files_path)

    if args.install_task:
        install_scheduled_task(args.port, args.mt4_files_path)
        return

    print(f"MT45 Price Bridge starting on http://{args.host}:{args.port}")
    print(f"MT4 Files path: {MT4_FILES_PATH}")
    print(f"API docs: http://{args.host}:{args.port}/docs")

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


def install_scheduled_task(port: int, mt4_path: Optional[str]):
    """Register a Windows Scheduled Task to auto-start at logon."""
    python_exe = sys.executable
    script     = Path(__file__).resolve()
    cmd_args   = f'"{python_exe}" "{script}" --port {port}'
    if mt4_path:
        cmd_args += f' --mt4-files-path "{mt4_path}"'

    task_name = "MT45PriceBridge"
    cmd = (
        f'schtasks /create /tn "{task_name}" /tr {cmd_args} '
        f'/sc ONLOGON /rl HIGHEST /f'
    )
    print(f"Registering scheduled task: {task_name}")
    ret = os.system(cmd)
    if ret == 0:
        print(f"[OK] Task '{task_name}' registered. Will auto-start on next logon.")
        print(f"     To start now: schtasks /run /tn \"{task_name}\"")
    else:
        print(f"[ERROR] schtasks returned {ret}. Try running as Administrator.")


if __name__ == "__main__":
    main()
