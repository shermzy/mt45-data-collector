//+------------------------------------------------------------------+
//|  MT45_PriceBridge.mq4                                            |
//|  File-based IPC bridge — exposes MT4 price data to an external   |
//|  HTTP server (price_server.py) via the MQL4/Files sandbox.       |
//|                                                                  |
//|  Writes:                                                         |
//|    prices.json    — live bid/ask/spread for all MarketWatch syms |
//|    symbols.json   — symbol metadata (refreshed every 60s)        |
//|    bars_res\*.res — bar history responses (on demand)            |
//|                                                                  |
//|  Reads:                                                          |
//|    bars_req\*.req — bar history requests from price_server.py    |
//+------------------------------------------------------------------+
#property copyright "MT45 Data Collector"
#property version   "1.00"
#property strict

//--- Inputs
input int  PriceWrite_Interval_ms = 500;   // how often to refresh prices.json (ms)
input int  Symbol_Meta_Interval_s = 60;    // how often to refresh symbols.json (s)
input int  Max_Bars               = 5000;  // cap on bars per request
input int  Request_Timeout_s      = 30;    // ignore .req files older than this

//--- Globals
datetime lastSymbolWrite = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   // Create subdirectories (FileOpen with path creates dirs automatically)
   EnsureDir("bars_req\\dummy.tmp");
   EnsureDir("bars_res\\dummy.tmp");

   EventSetMillisecondTimer(PriceWrite_Interval_ms);

   WritePrices();
   WriteSymbols();
   Print("MT45_PriceBridge: Initialized. Timer=", PriceWrite_Interval_ms, "ms");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("MT45_PriceBridge: Deinitialized.");
}

//+------------------------------------------------------------------+
void OnTick()
{
   WritePrices();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   WritePrices();

   if (TimeCurrent() - lastSymbolWrite >= Symbol_Meta_Interval_s)
      WriteSymbols();

   ProcessBarRequests();
}

//==========================================================================
//  Write prices.json — all MarketWatch symbols
//==========================================================================
void WritePrices()
{
   int total = SymbolsTotal(true);
   if (total == 0) return;

   string json = "{\"ts\":" + IntegerToString((int)TimeCurrent()) + ",\"symbols\":{";

   bool first = true;
   for (int i = 0; i < total; i++)
   {
      string sym = SymbolName(i, true);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
      int    spread = (point > 0) ? (int)MathRound((ask - bid) / point) : 0;

      if (!first) json += ",";
      json += "\"" + sym + "\":{";
      json += "\"bid\":"    + DoubleToStr(bid, digits) + ",";
      json += "\"ask\":"    + DoubleToStr(ask, digits) + ",";
      json += "\"spread\":" + IntegerToString(spread)  + ",";
      json += "\"digits\":" + IntegerToString(digits);
      json += "}";
      first = false;
   }

   json += "}}";

   WriteFileAtomic("prices.json", json);
}

//==========================================================================
//  Write symbols.json — symbol metadata
//==========================================================================
void WriteSymbols()
{
   lastSymbolWrite = TimeCurrent();
   int total = SymbolsTotal(true);

   string json = "{\"ts\":" + IntegerToString((int)TimeCurrent()) + ",\"symbols\":[";

   for (int i = 0; i < total; i++)
   {
      string sym = SymbolName(i, true);
      int    digits      = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double point       = SymbolInfoDouble(sym, SYMBOL_POINT);
      double contractSz  = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
      string baseCurr    = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
      string profitCurr  = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
      double minLot      = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double maxLot      = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      double lotStep     = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      double tickSize    = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);

      if (i > 0) json += ",";
      json += "{";
      json += "\"name\":\""            + sym               + "\",";
      json += "\"digits\":"            + IntegerToString(digits)         + ",";
      json += "\"point\":"             + DoubleToStr(point, 10)          + ",";
      json += "\"contract_size\":"     + DoubleToStr(contractSz, 2)      + ",";
      json += "\"currency_base\":\""   + EscapeJSON(baseCurr)            + "\",";
      json += "\"currency_profit\":\"" + EscapeJSON(profitCurr)          + "\",";
      json += "\"tick_size\":"         + DoubleToStr(tickSize, 10)       + ",";
      json += "\"min_lot\":"           + DoubleToStr(minLot, 2)          + ",";
      json += "\"max_lot\":"           + DoubleToStr(maxLot, 2)          + ",";
      json += "\"lot_step\":"          + DoubleToStr(lotStep, 2);
      json += "}";
   }

   json += "]}";
   WriteFileAtomic("symbols.json", json);
}

//==========================================================================
//  Process bar requests from bars_req\*.req
//==========================================================================
void ProcessBarRequests()
{
   string fileName;
   long   searchHandle = FileFindFirst("bars_req\\*.req", fileName);
   if (searchHandle == INVALID_HANDLE) return;

   do
   {
      ProcessSingleRequest("bars_req\\" + fileName);
   }
   while (FileFindNext(searchHandle, fileName));

   FileFindClose(searchHandle);
}

void ProcessSingleRequest(string reqPath)
{
   // Read request file
   int fh = FileOpen(reqPath, FILE_READ | FILE_TXT | FILE_ANSI);
   if (fh == INVALID_HANDLE) return;

   string body = "";
   while (!FileIsEnding(fh))
      body += FileReadString(fh);
   FileClose(fh);

   // Ignore stale requests
   datetime modTime = (datetime)FileGetInteger(reqPath, FILE_MODIFY_DATE, false);
   if (TimeCurrent() - modTime > Request_Timeout_s)
   {
      FileDelete(reqPath);
      return;
   }

   // Parse fields
   string reqId    = ExtractStr(body, "\"id\":");
   string symbol   = ExtractStr(body, "\"symbol\":");
   string tfStr    = ExtractStr(body, "\"timeframe\":");
   int    count    = (int)ExtractNum(body, "\"count\":");
   int    fromTs   = (int)ExtractNum(body, "\"from_ts\":");

   if (reqId == "" || symbol == "" || tfStr == "")
   {
      FileDelete(reqPath);
      return;
   }

   if (count <= 0 || count > Max_Bars) count = 200;

   int period = TFStringToPeriod(tfStr);

   // Build bars JSON
   string bars = BuildBarsJSON(reqId, symbol, period, tfStr, count, fromTs);

   // Write response
   string resPath = "bars_res\\" + reqId + ".res";
   WriteFileAtomic(resPath, bars);

   // Delete request
   FileDelete(reqPath);

   Print("MT45_PriceBridge: Served bars reqId=", reqId,
         " sym=", symbol, " tf=", tfStr, " count=", count);
}

string BuildBarsJSON(string reqId, string symbol, int period,
                     string tfStr, int count, int fromTs)
{
   // Determine starting shift
   int startShift = 0;
   if (fromTs > 0)
   {
      startShift = iBarShift(symbol, period, (datetime)fromTs, false);
      if (startShift < 0) startShift = 0;
      // fromTs means "bars from that time onwards" → go back startShift bars
   }

   int available = iBars(symbol, period);
   if (available <= 0)
   {
      return "{\"id\":\"" + reqId + "\",\"error\":\"no_data\","
             + "\"symbol\":\"" + symbol + "\",\"timeframe\":\"" + tfStr + "\","
             + "\"bars\":[],\"count\":0,\"ts\":" + IntegerToString((int)TimeCurrent()) + "}";
   }

   // Clamp
   int endShift = startShift + count - 1;
   if (endShift >= available) endShift = available - 1;
   int actualCount = endShift - startShift + 1;
   if (actualCount <= 0) actualCount = 0;

   // Build bars array — oldest first (high shift → low shift)
   string barsArr = "";
   for (int s = endShift; s >= startShift; s--)
   {
      datetime t = iTime(symbol, period, s);
      double   o = iOpen(symbol, period, s);
      double   h = iHigh(symbol, period, s);
      double   l = iLow(symbol, period, s);
      double   c = iClose(symbol, period, s);
      long     v = iVolume(symbol, period, s);

      int digits = (int)MarketInfo(symbol, MODE_DIGITS);

      string bar = "[" + IntegerToString((int)t)  + ","
                       + DoubleToStr(o, digits)    + ","
                       + DoubleToStr(h, digits)    + ","
                       + DoubleToStr(l, digits)    + ","
                       + DoubleToStr(c, digits)    + ","
                       + IntegerToString((int)v)   + "]";

      if (barsArr != "") barsArr += ",";
      barsArr += bar;
   }

   string json = "{";
   json += "\"id\":\""         + reqId                              + "\",";
   json += "\"symbol\":\""     + symbol                             + "\",";
   json += "\"timeframe\":\""  + tfStr                              + "\",";
   json += "\"bars\":["        + barsArr                            + "],";
   json += "\"count\":"        + IntegerToString(actualCount)       + ",";
   json += "\"ts\":"           + IntegerToString((int)TimeCurrent());
   json += "}";
   return json;
}

//==========================================================================
//  Helpers
//==========================================================================
int TFStringToPeriod(string tf)
{
   if (tf == "M1")  return PERIOD_M1;
   if (tf == "M5")  return PERIOD_M5;
   if (tf == "M15") return PERIOD_M15;
   if (tf == "M30") return PERIOD_M30;
   if (tf == "H1")  return PERIOD_H1;
   if (tf == "H4")  return PERIOD_H4;
   if (tf == "D1")  return PERIOD_D1;
   if (tf == "W1")  return PERIOD_W1;
   if (tf == "MN1") return PERIOD_MN1;
   return PERIOD_H1; // default
}

// Write to a tmp file then rename (atomic on Windows same-volume)
void WriteFileAtomic(string target, string content)
{
   string tmp = target + ".tmp";
   int fh = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh == INVALID_HANDLE)
   {
      Print("MT45_PriceBridge: Cannot open ", tmp, " err=", GetLastError());
      return;
   }
   FileWriteString(fh, content);
   FileClose(fh);
   FileDelete(target);
   FileMove(tmp, 0, target, 0);
}

// Create a file to force directory creation, then delete it
void EnsureDir(string dummyPath)
{
   int fh = FileOpen(dummyPath, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh != INVALID_HANDLE) FileClose(fh);
   FileDelete(dummyPath);
}

// Extract quoted string value after key
string ExtractStr(string body, string key)
{
   int kp = StringFind(body, key);
   if (kp < 0) return "";
   int q1 = StringFind(body, "\"", kp + StringLen(key));
   if (q1 < 0) return "";
   int q2 = StringFind(body, "\"", q1 + 1);
   if (q2 < 0) return "";
   return StringSubstr(body, q1 + 1, q2 - q1 - 1);
}

// Extract numeric value after key
double ExtractNum(string body, string key)
{
   int kp = StringFind(body, key);
   if (kp < 0) return 0;
   int vs = kp + StringLen(key);
   while (vs < StringLen(body))
   {
      ushort c = StringGetCharacter(body, vs);
      if (c == ' ' || c == ':' || c == '\t') { vs++; continue; }
      break;
   }
   string num = "";
   for (int i = vs; i < StringLen(body); i++)
   {
      ushort c = StringGetCharacter(body, i);
      if ((c >= '0' && c <= '9') || c == '.' || c == '-') num += CharToStr((uchar)c);
      else break;
   }
   return StringToDouble(num);
}

string EscapeJSON(string s)
{
   string out = "";
   for (int i = 0; i < StringLen(s); i++)
   {
      ushort c = StringGetCharacter(s, i);
      if      (c == '"')  out += "\\\"";
      else if (c == '\\') out += "\\\\";
      else if (c == '\n') out += "\\n";
      else if (c == '\r') out += "\\r";
      else if (c == '\t') out += "\\t";
      else                out += CharToStr((uchar)c);
   }
   return out;
}
//+------------------------------------------------------------------+
