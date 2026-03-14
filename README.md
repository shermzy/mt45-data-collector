# MT45 Data Collector

Bidirectional MT4 ↔ N8N integration via HTTP.

## Files

| File | Description |
|------|-------------|
| `MT45_N8N_Reporter.mq4` | Expert Advisor source code |
| `install_EA.bat` | Installer — auto-detects MT4 and copies EA to Experts folder |

---

## Installation

1. Run `install_EA.bat` (as Administrator if needed)
2. In MT4: **Tools > Options > Expert Advisors**
   - Tick *Allow WebRequest for listed URL*
   - Add both your webhook URL and commands URL
3. Drag `MT45_N8N_Reporter` from the Navigator onto any chart
4. Set input parameters (see below)
5. Ensure *Allow live trading* is checked

---

## Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N8N_Webhook_URL` | `http://localhost:5678/webhook/mt4-positions` | N8N endpoint that receives all outbound events |
| `N8N_Commands_URL` | `http://localhost:5678/webhook/mt4-commands` | N8N endpoint the EA polls for incoming commands |
| `Update_Interval` | `60` | Seconds between heartbeat updates |
| `Poll_Interval` | `5` | Seconds between command polls |
| `EnablePolling` | `true` | Toggle inbound command polling on/off |
| `EnableEvents` | `true` | Toggle event-driven outbound push on/off |

---

## Outbound Events (MT4 → N8N)

All events are POSTed as JSON to `N8N_Webhook_URL`. Each payload includes an `"event"` field identifying its type.

### `heartbeat`
Sent every `Update_Interval` seconds. Full account + all open positions snapshot.

```json
{
  "event": "heartbeat",
  "account": {
    "number": "12345678",
    "server": "Broker-Live",
    "currency": "USD",
    "leverage": 100,
    "balance": 10000.00,
    "equity": 10250.00,
    "margin": 500.00,
    "free_margin": 9750.00
  },
  "open_positions_count": 1,
  "positions": [ { "ticket": 123456, "symbol": "EURUSD", "type_str": "BUY", "lots": 0.10, "open_price": 1.08500, "current_price": 1.08750, "sl": 1.08000, "tp": 1.09000, "profit": 25.00, "swap": -0.50, "commission": -1.00, "magic": 0, "comment": "", "open_time_str": "2024.03.10 08:00" } ],
  "timestamp": 1710000060,
  "timestamp_str": "2024.03.10 08:01:00"
}
```

### `position_opened`
Fired immediately when a new market position is detected.

```json
{
  "event": "position_opened",
  "ticket": 123456,
  "symbol": "EURUSD",
  "type_str": "BUY",
  "lots": 0.10,
  "open_price": 1.08500,
  "sl": 1.08000,
  "tp": 1.09000,
  "profit": 0.00,
  "magic": 0,
  "comment": "",
  "timestamp": 1710000060,
  "timestamp_str": "2024.03.10 08:01:00"
}
```

### `position_closed`
Fired immediately when an open position disappears from the order pool.

```json
{
  "event": "position_closed",
  "ticket": 123456,
  "symbol": "EURUSD",
  "type_str": "BUY",
  "lots": 0.10,
  "close_price": 1.09000,
  "net_profit": 50.00,
  "timestamp": 1710003600,
  "timestamp_str": "2024.03.10 09:00:00"
}
```

### `position_modified`
Fired when SL or TP changes on an existing position.

```json
{
  "event": "position_modified",
  "ticket": 123456,
  "symbol": "EURUSD",
  "type_str": "BUY",
  "lots": 0.10,
  "open_price": 1.08500,
  "sl": 1.08200,
  "tp": 1.09500,
  "profit": 25.00,
  "magic": 0,
  "comment": "",
  "timestamp": 1710001800,
  "timestamp_str": "2024.03.10 08:30:00"
}
```

### `command_ack`
Sent after every command is executed — confirms success or failure.

```json
{
  "event": "command_ack",
  "id": "cmd_001",
  "command": "open_trade",
  "success": true,
  "timestamp": 1710000065
}
```

---

## Inbound Commands (N8N → MT4)

The EA polls `N8N_Commands_URL` (GET) every `Poll_Interval` seconds.

**Your N8N webhook must respond with:**

```json
{
  "commands": [
    {
      "id": "cmd_001",
      "command": "open_trade",
      "params": {
        "symbol": "EURUSD",
        "type": "BUY",
        "lots": 0.10,
        "sl": 1.08000,
        "tp": 1.09000,
        "magic": 0,
        "comment": "n8n order"
      }
    }
  ]
}
```

Return `{"commands":[]}` (or omit the key) when there are no pending commands.

### Supported Commands

| Command | Required params | Description |
|---------|----------------|-------------|
| `open_trade` | `symbol`, `type` (`BUY`/`SELL`), `lots` | Opens a market order. `sl`, `tp`, `magic`, `comment` optional |
| `close_trade` | `ticket` | Closes a single position by ticket number |
| `modify_trade` | `ticket`, `sl`, `tp` | Modifies SL and/or TP on an existing position |
| `close_all` | *(none)* | Closes all open market positions |

After each command the EA sends a `command_ack` event back to `N8N_Webhook_URL`.

---

## N8N Setup Tips

- Create a **Webhook** node at `/webhook/mt4-positions` to receive all outbound events — route by the `event` field
- Create a **Webhook** node at `/webhook/mt4-commands` that returns a JSON response with a `commands` array (use a Function node to build it from a queue/database)
- Use an **IF** node on `event` to branch logic for `heartbeat`, `position_opened`, `position_closed`, `position_modified`, and `command_ack`
