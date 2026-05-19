# XAUUSD EA — Deriv / MetaTrader 5

An MQL5 Expert Advisor for **XAUUSD (Gold)** on the **Deriv / MetaTrader 5** platform.  
Uses an EMA crossover strategy with a trend filter and ATR-based stop loss / take profit, with **fixed $3 risk per trade** and automatic lot sizing.

---

## Strategy

| Component | Description |
|-----------|-------------|
| Entry | Fast EMA (21) crosses Slow EMA (50) |
| Trend filter | Price must be on the correct side of the 200 EMA |
| Stop Loss | 1.5 × ATR(14) from entry |
| Take Profit | 3.0 × ATR(14) from entry (≈ 1:2 RR) |
| Risk per trade | **$3 fixed** (lot size auto-calculated) |
| Session | London / NY hours (07:00–20:00 UTC, configurable) |
| Timeframe | M15 (configurable) |

---

## Setup

### 1. Install
1. Copy `XAUUSD_EA.mq5` to your MT5 `Experts` folder:  
   `C:\Users\<YourUser>\AppData\Roaming\MetaQuotes\Terminal\<ID>\MQL5\Experts\`
2. Open **MetaEditor** → compile the file (F7).
3. In MT5, open an **XAUUSD M15** chart.
4. Drag the EA onto the chart and enable **Algo Trading**.

### 2. Broker / Account
- Broker: **Deriv** (MT5 account)
- Symbol: `XAUUSD` (verify the exact symbol name — may be `XAUUSD.` or `Gold`)
- Account type: Real or Demo

### 3. Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpRiskUSD` | `3.0` | Risk per trade in USD |
| `InpMaxLotSize` | `5.0` | Hard cap on lot size |
| `InpMinLotSize` | `0.01` | Minimum lot size |
| `InpFastEMA` | `21` | Fast EMA period |
| `InpSlowEMA` | `50` | Slow EMA period |
| `InpTrendEMA` | `200` | Trend filter EMA period |
| `InpATRPeriod` | `14` | ATR period |
| `InpSLMultiplier` | `1.5` | SL distance = ATR × multiplier |
| `InpTPMultiplier` | `3.0` | TP distance = ATR × multiplier |
| `InpMagicNumber` | `202600` | Unique EA identifier |
| `InpMaxSpreadPts` | `50` | Skip trade if spread exceeds this |
| `InpTradeSession` | `true` | Enable session filter |
| `InpSessionStart` | `7` | Session start (UTC hour) |
| `InpSessionEnd` | `20` | Session end (UTC hour) |
| `InpTimeframe` | `M15` | Signal timeframe |

---

## How Lot Sizing Works

```
Lot Size = Risk ($3) ÷ (SL in points × tick value per point per lot)
```

This ensures every trade risks exactly **$3** regardless of where the stop loss is placed.

---

## Risk Warning

Trading gold (XAUUSD) involves significant risk. Past performance is not indicative of future results. Always test on a **demo account** before going live. The $3 risk setting is a hard cap per trade but does not protect against slippage, gap risk, or consecutive losses.

---

## Files

| File | Description |
|------|-------------|
| `XAUUSD_EA.mq5` | Main Expert Advisor source code |
