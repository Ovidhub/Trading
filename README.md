# XAUUSD EA — Deriv / MetaTrader 5

An MQL5 Expert Advisor for **XAUUSD (Gold)** on the **Deriv / MetaTrader 5** platform.  
Uses an EMA crossover strategy with a trend filter and ATR-based stop loss / take profit, with **balance-aware risk sizing** and automatic lot sizing.

---

## Strategy

| Component | Description |
|-----------|-------------|
| Entry | Fast EMA (21) crosses Slow EMA (50) |
| Trend filter | Price must be on the correct side of the 200 EMA |
| Stop Loss | 1.2 × ATR(14) from entry |
| Take Profit | 2.4 × ATR(14) from entry (≈ 1:2 RR) |
| Risk per trade | Equity-based risk with a **$3 hard cap** |
| Session | London / New York overlap focus (**12:00–17:00 UTC**, configurable) |
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
| `InpRiskUSD` | `3.0` | Max risk cap per trade in USD |
| `InpRiskPercent` | `5.0` | Risk as % of equity, capped by `InpRiskUSD` |
| `InpMaxLotSize` | `5.0` | Hard cap on lot size |
| `InpMinLotSize` | `0.01` | Minimum lot size |
| `InpAllowMinLotFallback` | `true` | Allow broker minimum lot if the risk remains reasonable |
| `InpMaxMinLotRiskPct` | `6.0` | Maximum equity risk allowed when falling back to the minimum lot |
| `InpMinFreeMarginUSD` | `10.0` | Free margin buffer to keep after entry |
| `InpFastEMA` | `21` | Fast EMA period |
| `InpSlowEMA` | `50` | Slow EMA period |
| `InpTrendEMA` | `200` | Trend filter EMA period |
| `InpATRPeriod` | `14` | ATR period |
| `InpSLMultiplier` | `1.2` | SL distance = ATR × multiplier |
| `InpTPMultiplier` | `2.4` | TP distance = ATR × multiplier |
| `InpMagicNumber` | `202600` | Unique EA identifier |
| `InpMaxSpreadPts` | `35` | Skip trade if spread exceeds this |
| `InpTradeSession` | `true` | Enable session filter |
| `InpSessionStart` | `12` | Session start (UTC hour) |
| `InpSessionEnd` | `17` | Session end (UTC hour) |
| `InpTimeframe` | `M15` | Signal timeframe |

---

## How Lot Sizing Works

```
Risk USD = min($3 cap, equity × 5%)
Lot Size = Risk USD ÷ (SL in points × tick value per point per lot)
```

If the calculated lot is below the broker minimum, the EA can still use the minimum lot only when the projected loss stays within the configured fallback risk limit.

---

## Risk Warning

Trading gold (XAUUSD) involves significant risk. Past performance is not indicative of future results. Always test on a **demo account** before going live. The new defaults are intended to be safer for a **small account such as $30** because they scale risk from equity, keep a free-margin buffer, and focus trading on the highest-liquidity XAUUSD session. They still do not guarantee growth and do not protect against slippage, gap risk, or consecutive losses.

---

## Files

| File | Description |
|------|-------------|
| `XAUUSD_EA.mq5` | Main Expert Advisor source code |
