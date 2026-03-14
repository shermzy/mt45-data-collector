# MT45 Data Collector

MT4 Expert Advisor that sends open positions and account balance/equity to an [N8N](https://n8n.io) webhook every minute via HTTP POST (JSON).

## Files

| File | Description |
|------|-------------|
| `MT45_N8N_Reporter.mq4` | The Expert Advisor source code |
| `install_EA.bat` | Installer — auto-detects MT4 and copies the EA to the Experts folder |

## Installation

1. Run `install_EA.bat` (as Administrator if needed)
2. In MT4: **Tools > Options > Expert Advisors** — tick *Allow WebRequest for listed URL* and add your N8N webhook URL
3. Drag `MT45_N8N_Reporter` from the Navigator onto any chart
4. Set `N8N_Webhook_URL` in the EA input parameters
5. Ensure *Allow live trading* is checked

## JSON Payload

```json
{
  "account": {
    "number": "12345678",
    "server": "BrokerName-Live",
    "currency": "USD",
    "leverage": 100,
    "balance": 10000.00,
    "equity": 10250.00,
    "margin": 500.00,
    "free_margin": 9750.00
  },
  "open_positions_count": 1,
  "positions": [
    {
      "ticket": 123456,
      "symbol": "EURUSD",
      "type": 0,
      "type_str": "BUY",
      "lots": 0.10,
      "open_price": 1.08500,
      "current_price": 1.08750,
      "sl": 1.08000,
      "tp": 1.09000,
      "profit": 25.00,
      "swap": -0.50,
      "commission": -1.00,
      "magic": 0,
      "comment": "",
      "open_time": 1710000000,
      "open_time_str": "2024.03.10 08:00"
    }
  ],
  "timestamp": 1710000060,
  "timestamp_str": "2024.03.10 08:01:00"
}
```

## Configuration

| Input | Default | Description |
|-------|---------|-------------|
| `N8N_Webhook_URL` | `http://localhost:5678/webhook/mt4-positions` | Your N8N webhook endpoint |
| `Update_Interval` | `60` | Seconds between updates |
