//+------------------------------------------------------------------+
//|  MT45_N8N_Reporter.mq4                                           |
//|  Bidirectional N8N integration for MT4                           |
//|                                                                  |
//|  OUTBOUND (push):                                                |
//|    - Periodic heartbeat every Update_Interval seconds            |
//|    - Event-driven alerts on position open / close / modify       |
//|                                                                  |
//|  INBOUND (poll):                                                 |
//|    - Polls N8N commands endpoint every Poll_Interval seconds     |
//|    - Executes: open_trade, close_trade, modify_trade, close_all  |
//+------------------------------------------------------------------+
#property copyright "MT45 Data Collector"
#property version   "2.00"
#property strict

//--- Input parameters
input string N8N_Webhook_URL  = "http://localhost:5678/webhook/mt4-positions";
// Separate endpoint N8N listens on for commands (GET request)
// Response: {"commands":[{"id":"...","command":"open_trade","params":{...}}]}
// Return empty array or omit "commands" key when no pending commands.
input string N8N_Commands_URL = "http://localhost:5678/webhook/mt4-commands";
input int    Update_Interval  = 60;   // seconds between heartbeat updates
input int    Poll_Interval    = 5;    // seconds between command polls
input bool   EnablePolling    = true; // set false to disable inbound commands
input bool   EnableEvents     = true; // set false to disable event-driven pushes

//--- Snapshot struct for change detection
struct PositionSnap
{
   int    ticket;
   string symbol;
   int    type;
   double lots;
   double sl;
   double tp;
   double profit;
};

//--- Globals
datetime         lastUpdate    = 0;
datetime         lastPoll      = 0;
PositionSnap     snap[];          // snapshot of last known open positions
int              snapCount     = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   Print("MT45_N8N_Reporter v2: Initialized.");
   Print("  Heartbeat URL : ", N8N_Webhook_URL);
   Print("  Commands URL  : ", N8N_Commands_URL);
   Print("  Update interval: ", Update_Interval, "s  Poll interval: ", Poll_Interval, "s");

   TakeSnapshot();
   SendHeartbeat();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("MT45_N8N_Reporter v2: Deinitialized (reason=", reason, ").");
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();

   // --- Heartbeat ---
   if (now - lastUpdate >= Update_Interval)
      SendHeartbeat();

   // --- Event detection ---
   if (EnableEvents)
      DetectPositionChanges();

   // --- Command polling ---
   if (EnablePolling && now - lastPoll >= Poll_Interval)
      PollCommands();
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   datetime now = TimeCurrent();
   if (now - lastUpdate >= Update_Interval) SendHeartbeat();
   if (EnablePolling && now - lastPoll >= Poll_Interval) PollCommands();
}

//==========================================================================
//  OUTBOUND — Heartbeat
//==========================================================================
void SendHeartbeat()
{
   lastUpdate = TimeCurrent();
   string json = BuildAccountJSON("heartbeat");
   int rc = HTTPPost(N8N_Webhook_URL, json);
   if (rc == 200)
      Print("MT45: Heartbeat sent OK");
   else
      Print("MT45: Heartbeat HTTP ", rc);
}

//==========================================================================
//  OUTBOUND — Event detection (compare against snapshot)
//==========================================================================
void DetectPositionChanges()
{
   int total = OrdersTotal();

   // Build current market order list
   int     curTickets[];
   ArrayResize(curTickets, total);
   int     curCount = 0;

   for (int i = 0; i < total; i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderType() > OP_SELL) continue;  // skip pending orders
      curTickets[curCount++] = OrderTicket();
   }

   // Check for newly opened positions (in current but not in snapshot)
   for (int c = 0; c < curCount; c++)
   {
      bool found = false;
      for (int s = 0; s < snapCount; s++)
         if (snap[s].ticket == curTickets[c]) { found = true; break; }

      if (!found)
      {
         if (OrderSelect(curTickets[c], SELECT_BY_TICKET))
            SendTradeEvent("position_opened", curTickets[c]);
      }
   }

   // Check for closed positions (in snapshot but not in current)
   for (int s = 0; s < snapCount; s++)
   {
      bool found = false;
      for (int c = 0; c < curCount; c++)
         if (curTickets[c] == snap[s].ticket) { found = true; break; }

      if (!found)
         SendClosedEvent(snap[s]);
   }

   // Check for SL/TP modifications on existing positions
   for (int s = 0; s < snapCount; s++)
   {
      for (int c = 0; c < curCount; c++)
      {
         if (curTickets[c] != snap[s].ticket) continue;
         if (!OrderSelect(curTickets[c], SELECT_BY_TICKET)) continue;

         bool slChanged = MathAbs(OrderStopLoss()   - snap[s].sl) > 0.000001;
         bool tpChanged = MathAbs(OrderTakeProfit() - snap[s].tp) > 0.000001;

         if (slChanged || tpChanged)
            SendTradeEvent("position_modified", curTickets[c]);
         break;
      }
   }

   TakeSnapshot();
}

//--- Fire event for an open/modified position
void SendTradeEvent(string eventType, int ticket)
{
   if (!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   string json = "{";
   json += "\"event\":\""       + eventType                                  + "\",";
   json += "\"ticket\":"        + IntegerToString(ticket)                    + ",";
   json += "\"symbol\":\""      + OrderSymbol()                              + "\",";
   json += "\"type_str\":\""    + OrderTypeStr(OrderType())                  + "\",";
   json += "\"lots\":"          + DoubleToStr(OrderLots(), 2)                + ",";
   json += "\"open_price\":"    + DoubleToStr(OrderOpenPrice(), 5)           + ",";
   json += "\"sl\":"            + DoubleToStr(OrderStopLoss(), 5)            + ",";
   json += "\"tp\":"            + DoubleToStr(OrderTakeProfit(), 5)          + ",";
   json += "\"profit\":"        + DoubleToStr(OrderProfit(), 2)              + ",";
   json += "\"magic\":"         + IntegerToString(OrderMagicNumber())        + ",";
   json += "\"comment\":\""     + EscapeJSON(OrderComment())                 + "\",";
   json += "\"timestamp\":"     + IntegerToString((int)TimeCurrent())        + ",";
   json += "\"timestamp_str\":\"" + TimeToStr(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS) + "\"";
   json += "}";

   int rc = HTTPPost(N8N_Webhook_URL, json);
   Print("MT45: Event '", eventType, "' ticket=", ticket, " HTTP ", rc);
}

//--- Fire event for a position that just closed (data from snapshot)
void SendClosedEvent(PositionSnap &s)
{
   // Try to get final profit from order history
   double closeProfit = 0;
   double closePrice  = 0;
   if (OrderSelect(s.ticket, SELECT_BY_TICKET, MODE_HISTORY))
   {
      closeProfit = OrderProfit() + OrderSwap() + OrderCommission();
      closePrice  = OrderClosePrice();
   }

   string json = "{";
   json += "\"event\":\"position_closed\",";
   json += "\"ticket\":"       + IntegerToString(s.ticket)        + ",";
   json += "\"symbol\":\""     + s.symbol                         + "\",";
   json += "\"type_str\":\""   + OrderTypeStr(s.type)             + "\",";
   json += "\"lots\":"         + DoubleToStr(s.lots, 2)           + ",";
   json += "\"close_price\":"  + DoubleToStr(closePrice, 5)       + ",";
   json += "\"net_profit\":"   + DoubleToStr(closeProfit, 2)      + ",";
   json += "\"timestamp\":"    + IntegerToString((int)TimeCurrent()) + ",";
   json += "\"timestamp_str\":\"" + TimeToStr(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS) + "\"";
   json += "}";

   int rc = HTTPPost(N8N_Webhook_URL, json);
   Print("MT45: Event 'position_closed' ticket=", s.ticket, " HTTP ", rc);
}

//--- Update snapshot
void TakeSnapshot()
{
   snapCount = 0;
   int total = OrdersTotal();
   ArrayResize(snap, total);

   for (int i = 0; i < total; i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderType() > OP_SELL) continue;

      snap[snapCount].ticket = OrderTicket();
      snap[snapCount].symbol = OrderSymbol();
      snap[snapCount].type   = OrderType();
      snap[snapCount].lots   = OrderLots();
      snap[snapCount].sl     = OrderStopLoss();
      snap[snapCount].tp     = OrderTakeProfit();
      snap[snapCount].profit = OrderProfit();
      snapCount++;
   }
}

//==========================================================================
//  INBOUND — Poll N8N for commands
//==========================================================================
//
//  N8N should return JSON like:
//  {
//    "commands": [
//      { "id": "cmd_001", "command": "open_trade",
//        "params": { "symbol":"EURUSD","type":"BUY","lots":0.1,
//                    "sl":1.08000,"tp":1.09000,"magic":0,"comment":"n8n" } },
//      { "id": "cmd_002", "command": "close_trade",
//        "params": { "ticket": 123456 } },
//      { "id": "cmd_003", "command": "modify_trade",
//        "params": { "ticket":123456,"sl":1.07500,"tp":1.09500 } },
//      { "id": "cmd_004", "command": "close_all", "params": {} }
//    ]
//  }
//  Return [] or omit "commands" key when no pending commands.
//
void PollCommands()
{
   lastPoll = TimeCurrent();

   char   dummy[];
   char   response[];
   string respHeaders;
   ArrayResize(dummy, 0);

   int rc = WebRequest(
      "GET",
      N8N_Commands_URL,
      "Accept: application/json\r\n",
      3000,
      dummy,
      response,
      respHeaders
   );

   if (rc != 200)
   {
      if (rc != -1)  // -1 = network error, expected if N8N not running
         Print("MT45: Command poll HTTP ", rc);
      return;
   }

   string body = CharArrayToString(response);
   if (StringLen(body) < 10) return;  // empty / no commands

   ParseAndExecuteCommands(body);
}

//--- Minimal JSON command parser
//    Finds each "command":"..." block and dispatches it.
void ParseAndExecuteCommands(string body)
{
   // We iterate over occurrences of "command":"
   int searchFrom = 0;
   while (true)
   {
      int cmdPos = StringFind(body, "\"command\":", searchFrom);
      if (cmdPos < 0) break;

      // Extract command name value
      int q1 = StringFind(body, "\"", cmdPos + 10);
      if (q1 < 0) break;
      int q2 = StringFind(body, "\"", q1 + 1);
      if (q2 < 0) break;
      string cmd = StringSubstr(body, q1 + 1, q2 - q1 - 1);

      // Extract "id" near this command (search backwards a bit)
      string cmdId = ExtractStringField(body, "\"id\":", cmdPos - 60, cmdPos + 5);

      // Extract params block {}
      int pOpen  = StringFind(body, "{", q2);
      // find matching closing brace
      int pClose = FindMatchingBrace(body, pOpen);
      string params = "";
      if (pOpen >= 0 && pClose > pOpen)
         params = StringSubstr(body, pOpen, pClose - pOpen + 1);

      Print("MT45: Command received id=", cmdId, " cmd=", cmd);
      ExecuteCommand(cmd, params, cmdId);

      searchFrom = (pClose > 0) ? pClose : q2 + 1;
   }
}

void ExecuteCommand(string cmd, string params, string cmdId)
{
   bool ok = false;

   if (cmd == "open_trade")
      ok = CmdOpenTrade(params);
   else if (cmd == "close_trade")
      ok = CmdCloseTrade(params);
   else if (cmd == "modify_trade")
      ok = CmdModifyTrade(params);
   else if (cmd == "close_all")
      ok = CmdCloseAll();
   else
      Print("MT45: Unknown command '", cmd, "'");

   // Acknowledge back to N8N
   string ack = "{";
   ack += "\"event\":\"command_ack\",";
   ack += "\"id\":\""      + EscapeJSON(cmdId) + "\",";
   ack += "\"command\":\"" + EscapeJSON(cmd)   + "\",";
   ack += "\"success\":"   + (ok ? "true" : "false") + ",";
   ack += "\"timestamp\":" + IntegerToString((int)TimeCurrent());
   ack += "}";
   HTTPPost(N8N_Webhook_URL, ack);
}

//--- open_trade
bool CmdOpenTrade(string params)
{
   string symbol  = ExtractStringField(params, "\"symbol\":", 0, StringLen(params));
   string typeStr = ExtractStringField(params, "\"type\":",   0, StringLen(params));
   double lots    = ExtractDoubleField(params, "\"lots\":");
   double sl      = ExtractDoubleField(params, "\"sl\":");
   double tp      = ExtractDoubleField(params, "\"tp\":");
   int    magic   = (int)ExtractDoubleField(params, "\"magic\":");
   string comment = ExtractStringField(params, "\"comment\":", 0, StringLen(params));

   if (symbol == "" || lots <= 0)
   {
      Print("MT45 open_trade: missing symbol or lots");
      return false;
   }

   int orderType = (typeStr == "BUY" || typeStr == "0") ? OP_BUY : OP_SELL;
   double price  = (orderType == OP_BUY)
                     ? MarketInfo(symbol, MODE_ASK)
                     : MarketInfo(symbol, MODE_BID);
   int digits    = (int)MarketInfo(symbol, MODE_DIGITS);
   double point  = MarketInfo(symbol, MODE_POINT);

   int ticket = OrderSend(symbol, orderType, lots,
                          NormalizeDouble(price, digits),
                          30,  // slippage in points
                          NormalizeDouble(sl, digits),
                          NormalizeDouble(tp, digits),
                          comment, magic, 0, clrBlue);
   if (ticket > 0)
   {
      Print("MT45 open_trade: opened ticket=", ticket);
      return true;
   }
   Print("MT45 open_trade: OrderSend failed error=", GetLastError());
   return false;
}

//--- close_trade
bool CmdCloseTrade(string params)
{
   int ticket = (int)ExtractDoubleField(params, "\"ticket\":");
   if (ticket <= 0) { Print("MT45 close_trade: invalid ticket"); return false; }

   if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
   {
      Print("MT45 close_trade: ticket not found ", ticket);
      return false;
   }

   string symbol = OrderSymbol();
   double lots   = OrderLots();
   int    type   = OrderType();
   double price  = (type == OP_BUY)
                     ? MarketInfo(symbol, MODE_BID)
                     : MarketInfo(symbol, MODE_ASK);
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);

   bool ok = OrderClose(ticket, lots, NormalizeDouble(price, digits), 30, clrRed);
   if (ok)
      Print("MT45 close_trade: closed ticket=", ticket);
   else
      Print("MT45 close_trade: failed ticket=", ticket, " error=", GetLastError());
   return ok;
}

//--- modify_trade
bool CmdModifyTrade(string params)
{
   int    ticket = (int)ExtractDoubleField(params, "\"ticket\":");
   double sl     = ExtractDoubleField(params, "\"sl\":");
   double tp     = ExtractDoubleField(params, "\"tp\":");

   if (ticket <= 0) { Print("MT45 modify_trade: invalid ticket"); return false; }
   if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
   {
      Print("MT45 modify_trade: ticket not found ", ticket);
      return false;
   }

   int digits = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);
   bool ok = OrderModify(ticket,
                         OrderOpenPrice(),
                         NormalizeDouble(sl, digits),
                         NormalizeDouble(tp, digits),
                         0, clrYellow);
   if (ok)
      Print("MT45 modify_trade: modified ticket=", ticket);
   else
      Print("MT45 modify_trade: failed ticket=", ticket, " error=", GetLastError());
   return ok;
}

//--- close_all
bool CmdCloseAll()
{
   bool allOk = true;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderType() > OP_SELL) continue;

      string symbol = OrderSymbol();
      int    type   = OrderType();
      double lots   = OrderLots();
      int    ticket = OrderTicket();
      int    digits = (int)MarketInfo(symbol, MODE_DIGITS);
      double price  = (type == OP_BUY)
                        ? MarketInfo(symbol, MODE_BID)
                        : MarketInfo(symbol, MODE_ASK);

      bool ok = OrderClose(ticket, lots, NormalizeDouble(price, digits), 30, clrRed);
      if (!ok)
      {
         Print("MT45 close_all: failed ticket=", ticket, " error=", GetLastError());
         allOk = false;
      }
   }
   Print("MT45 close_all: done allOk=", allOk);
   return allOk;
}

//==========================================================================
//  HEARTBEAT JSON builder
//==========================================================================
string BuildAccountJSON(string eventType)
{
   string json = "{";
   json += "\"event\":\""       + eventType                                               + "\",";
   json += "\"account\":{";
   json += "\"number\":\""      + IntegerToString(AccountNumber())                        + "\",";
   json += "\"server\":\""      + EscapeJSON(AccountServer())                             + "\",";
   json += "\"currency\":\""    + AccountCurrency()                                       + "\",";
   json += "\"leverage\":"      + IntegerToString(AccountLeverage())                      + ",";
   json += "\"balance\":"       + DoubleToStr(AccountBalance(), 2)                        + ",";
   json += "\"equity\":"        + DoubleToStr(AccountEquity(), 2)                         + ",";
   json += "\"margin\":"        + DoubleToStr(AccountMargin(), 2)                         + ",";
   json += "\"free_margin\":"   + DoubleToStr(AccountFreeMargin(), 2);
   json += "},";

   // Positions array
   string posArr = "";
   int total = OrdersTotal();
   for (int i = 0; i < total; i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderType() > OP_SELL) continue;

      string pos = "{";
      pos += "\"ticket\":"         + IntegerToString(OrderTicket())                   + ",";
      pos += "\"symbol\":\""       + OrderSymbol()                                    + "\",";
      pos += "\"type_str\":\""     + OrderTypeStr(OrderType())                        + "\",";
      pos += "\"lots\":"           + DoubleToStr(OrderLots(), 2)                      + ",";
      pos += "\"open_price\":"     + DoubleToStr(OrderOpenPrice(), 5)                 + ",";
      pos += "\"current_price\":"  + DoubleToStr(
                  OrderType() == OP_BUY
                     ? MarketInfo(OrderSymbol(), MODE_BID)
                     : MarketInfo(OrderSymbol(), MODE_ASK), 5)                        + ",";
      pos += "\"sl\":"             + DoubleToStr(OrderStopLoss(), 5)                  + ",";
      pos += "\"tp\":"             + DoubleToStr(OrderTakeProfit(), 5)                + ",";
      pos += "\"profit\":"         + DoubleToStr(OrderProfit(), 2)                    + ",";
      pos += "\"swap\":"           + DoubleToStr(OrderSwap(), 2)                      + ",";
      pos += "\"commission\":"     + DoubleToStr(OrderCommission(), 2)                + ",";
      pos += "\"magic\":"          + IntegerToString(OrderMagicNumber())              + ",";
      pos += "\"comment\":\""      + EscapeJSON(OrderComment())                       + "\",";
      pos += "\"open_time_str\":\"" + TimeToStr(OrderOpenTime(), TIME_DATE|TIME_MINUTES) + "\"";
      pos += "}";

      if (posArr != "") posArr += ",";
      posArr += pos;
   }

   json += "\"open_positions_count\":" + IntegerToString(total) + ",";
   json += "\"positions\":["           + posArr                  + "],";
   json += "\"timestamp\":"            + IntegerToString((int)TimeCurrent()) + ",";
   json += "\"timestamp_str\":\""      + TimeToStr(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS) + "\"";
   json += "}";
   return json;
}

//==========================================================================
//  Utilities
//==========================================================================
string OrderTypeStr(int type)
{
   switch (type)
   {
      case OP_BUY:       return "BUY";
      case OP_SELL:      return "SELL";
      case OP_BUYLIMIT:  return "BUY_LIMIT";
      case OP_SELLLIMIT: return "SELL_LIMIT";
      case OP_BUYSTOP:   return "BUY_STOP";
      case OP_SELLSTOP:  return "SELL_STOP";
      default:           return "UNKNOWN";
   }
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

//--- Extract a quoted string value after a key
string ExtractStringField(string body, string key, int fromPos, int toPos)
{
   int kp = StringFind(body, key, fromPos);
   if (kp < 0 || kp > toPos) return "";
   int q1 = StringFind(body, "\"", kp + StringLen(key));
   if (q1 < 0) return "";
   int q2 = StringFind(body, "\"", q1 + 1);
   if (q2 < 0) return "";
   return StringSubstr(body, q1 + 1, q2 - q1 - 1);
}

//--- Extract a numeric value after a key (handles int and float)
double ExtractDoubleField(string body, string key, int fromPos = 0)
{
   int kp = StringFind(body, key, fromPos);
   if (kp < 0) return 0;
   int vStart = kp + StringLen(key);
   // Skip whitespace/colon
   while (vStart < StringLen(body))
   {
      ushort c = StringGetCharacter(body, vStart);
      if (c == ' ' || c == '\t' || c == ':') { vStart++; continue; }
      break;
   }
   // Read until non-numeric
   string numStr = "";
   for (int i = vStart; i < StringLen(body); i++)
   {
      ushort c = StringGetCharacter(body, i);
      if ((c >= '0' && c <= '9') || c == '.' || c == '-') numStr += CharToStr((uchar)c);
      else break;
   }
   return StringToDouble(numStr);
}

//--- Find matching closing brace
int FindMatchingBrace(string body, int openPos)
{
   if (openPos < 0) return -1;
   int depth = 0;
   for (int i = openPos; i < StringLen(body); i++)
   {
      ushort c = StringGetCharacter(body, i);
      if (c == '{') depth++;
      else if (c == '}') { depth--; if (depth == 0) return i; }
   }
   return -1;
}

//--- HTTP POST, returns status code
int HTTPPost(string url, string body)
{
   char   postData[];
   char   result[];
   string resultHeaders;

   StringToCharArray(body, postData, 0, StringLen(body));
   ArrayResize(postData, ArraySize(postData) - 1);

   int rc = WebRequest("POST", url,
                       "Content-Type: application/json\r\n",
                       5000, postData, result, resultHeaders);
   if (rc == -1)
      Print("MT45: WebRequest error ", GetLastError(),
            " — add URL to Tools > Options > Expert Advisors");
   return rc;
}
//+------------------------------------------------------------------+
