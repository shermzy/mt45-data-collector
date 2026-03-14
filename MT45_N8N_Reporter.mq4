//+------------------------------------------------------------------+
//|  MT45_N8N_Reporter.mq4                                           |
//|  Sends open positions + account balance/equity to N8N webhook    |
//|  every minute via HTTP POST (JSON).                              |
//+------------------------------------------------------------------+
#property copyright "MT45 Data Collector"
#property version   "1.00"
#property strict

//--- Input parameters
input string N8N_Webhook_URL = "http://localhost:5678/webhook/mt4-positions";
input int    Update_Interval = 60;   // seconds between updates

//--- Globals
datetime lastUpdate = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   Print("MT45_N8N_Reporter: Initialized. Webhook: ", N8N_Webhook_URL);
   Print("MT45_N8N_Reporter: Update interval: ", Update_Interval, "s");
   // Send immediately on attach
   SendDataToN8N();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("MT45_N8N_Reporter: Deinitialized.");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if (TimeCurrent() - lastUpdate >= Update_Interval)
   {
      SendDataToN8N();
   }
}

//+------------------------------------------------------------------+
// Also fire on timer-like basis using chart events when ticks are slow
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if (TimeCurrent() - lastUpdate >= Update_Interval)
   {
      SendDataToN8N();
   }
}

//+------------------------------------------------------------------+
void SendDataToN8N()
{
   lastUpdate = TimeCurrent();

   string json = BuildJSON();

   int result = SendHTTPPost(N8N_Webhook_URL, json);

   if (result == 200)
      Print("MT45_N8N_Reporter: Data sent successfully at ", TimeToStr(TimeCurrent()));
   else
      Print("MT45_N8N_Reporter: HTTP POST returned code ", result,
            " at ", TimeToStr(TimeCurrent()));
}

//+------------------------------------------------------------------+
string BuildJSON()
{
   // Account info
   double balance  = AccountBalance();
   double equity   = AccountEquity();
   double margin   = AccountMargin();
   double freeMargin = AccountFreeMargin();
   string currency = AccountCurrency();
   int    leverage = AccountLeverage();
   string account  = IntegerToString(AccountNumber());
   string server   = AccountServer();

   // Build positions array
   string positionsArr = "";
   int total = OrdersTotal();

   for (int i = 0; i < total; i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if (OrderType() > OP_SELL)   // skip pending orders — include if you want
         continue;

      string pos = "{";
      pos += "\"ticket\":"    + IntegerToString(OrderTicket())         + ",";
      pos += "\"symbol\":\""  + OrderSymbol()                          + "\",";
      pos += "\"type\":"      + IntegerToString(OrderType())           + ",";
      pos += "\"type_str\":\"" + OrderTypeStr(OrderType())             + "\",";
      pos += "\"lots\":"      + DoubleToStr(OrderLots(), 2)            + ",";
      pos += "\"open_price\":" + DoubleToStr(OrderOpenPrice(), 5)      + ",";
      pos += "\"current_price\":" + DoubleToStr(
                  OrderType() == OP_BUY
                     ? MarketInfo(OrderSymbol(), MODE_BID)
                     : MarketInfo(OrderSymbol(), MODE_ASK), 5)         + ",";
      pos += "\"sl\":"        + DoubleToStr(OrderStopLoss(), 5)        + ",";
      pos += "\"tp\":"        + DoubleToStr(OrderTakeProfit(), 5)      + ",";
      pos += "\"profit\":"    + DoubleToStr(OrderProfit(), 2)          + ",";
      pos += "\"swap\":"      + DoubleToStr(OrderSwap(), 2)            + ",";
      pos += "\"commission\":" + DoubleToStr(OrderCommission(), 2)     + ",";
      pos += "\"magic\":"     + IntegerToString(OrderMagicNumber())    + ",";
      pos += "\"comment\":\"" + EscapeJSON(OrderComment())             + "\",";
      pos += "\"open_time\":" + IntegerToString((int)OrderOpenTime())  + ",";
      pos += "\"open_time_str\":\"" + TimeToStr(OrderOpenTime(), TIME_DATE|TIME_MINUTES) + "\"";
      pos += "}";

      if (positionsArr != "") positionsArr += ",";
      positionsArr += pos;
   }

   // Build full JSON payload
   string json = "{";
   json += "\"account\":{";
   json += "\"number\":\""    + account    + "\",";
   json += "\"server\":\""    + EscapeJSON(server) + "\",";
   json += "\"currency\":\""  + currency   + "\",";
   json += "\"leverage\":"    + IntegerToString(leverage) + ",";
   json += "\"balance\":"     + DoubleToStr(balance, 2)   + ",";
   json += "\"equity\":"      + DoubleToStr(equity, 2)    + ",";
   json += "\"margin\":"      + DoubleToStr(margin, 2)    + ",";
   json += "\"free_margin\":" + DoubleToStr(freeMargin, 2);
   json += "},";
   json += "\"open_positions_count\":" + IntegerToString(total) + ",";
   json += "\"positions\":["  + positionsArr + "],";
   json += "\"timestamp\":"   + IntegerToString((int)TimeCurrent()) + ",";
   json += "\"timestamp_str\":\"" + TimeToStr(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS) + "\"";
   json += "}";

   return json;
}

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
// Escape special JSON characters in a string
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
// HTTP POST via WinInet (MT4 built-in WebRequest)
// Returns HTTP status code, or -1 on error.
int SendHTTPPost(string url, string body)
{
   char   postData[];
   char   result[];
   string resultHeaders;

   StringToCharArray(body, postData, 0, StringLen(body));

   // Remove null terminator that StringToCharArray adds
   ArrayResize(postData, ArraySize(postData) - 1);

   int timeout = 5000; // ms

   int res = WebRequest(
      "POST",
      url,
      "Content-Type: application/json\r\n",
      timeout,
      postData,
      result,
      resultHeaders
   );

   if (res == -1)
   {
      int err = GetLastError();
      Print("MT45_N8N_Reporter: WebRequest error ", err,
            ". Make sure '", url, "' is in Tools > Options > Expert Advisors > Allow WebRequest URLs.");
   }

   return res;
}
//+------------------------------------------------------------------+
