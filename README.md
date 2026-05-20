# XAUUSD EA — Deriv / MetaTrader 5

An MQL5 Expert Advisor for **XAUUSD (Gold)** on the **Deriv / MetaTrader 5** platform.  
Uses an EMA/trend breakout strategy with ATR-based stop loss / take profit, with **fixed-dollar risk sizing** and automatic lot sizing.

---

## Strategy

| Component | Description |
|-----------|-------------|
| Entry | Trade with trend alignment plus either a fresh EMA crossover or a breakout candle that closes beyond recent structure |
| Trend filter | Price must be on the correct side of the 200 EMA |
| Stop Loss | 1.2 × ATR(14) from entry |
| Take Profit | 2.4 × ATR(14) from entry (≈ 1:2 RR) |
| Risk per trade | Fixed **$3** risk by default |
| Session | Disabled by default; optional if you want to restrict trading hours |
| Timeframe | **M5** by default for faster execution (configurable) |

---

## Setup

### 1. Install
1. Copy `XAUUSD_EA.mq5` to your MT5 `Experts` folder:  
   `C:\Users\<YourUser>\AppData\Roaming\MetaQuotes\Terminal\<ID>\MQL5\Experts\`
2. Open **MetaEditor** → compile the file (F7).
3. In MT5, open an **XAUUSD** chart on your preferred timeframe (**M5 default**).
4. Drag the EA onto the chart and enable **Algo Trading**.

### 2. Broker / Account
- Broker: **Deriv** (MT5 account)
- Symbol: `XAUUSD` (verify the exact symbol name — may be `XAUUSD.` or `Gold`)
- Account type: Real or Demo

### 3. Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpRiskUSD` | `3.0` | Max risk cap per trade in USD |
| `InpRiskPercent` | `0.0` | Optional % risk, only used when `InpRiskUSD` is set to `0` |
| `InpMaxLotSize` | `5.0` | Hard cap on lot size |
| `InpMinLotSize` | `0.01` | Minimum lot size |
| `InpAllowMinLotFallback` | `true` | Allow broker minimum lot if the risk remains reasonable |
| `InpMaxMinLotRiskUSD` | `3.0` | Maximum USD risk allowed when falling back to the minimum lot |
| `InpMinFreeMarginUSD` | `0.0` | Free margin buffer to keep after entry |
| `InpFastEMA` | `21` | Fast EMA period |
| `InpSlowEMA` | `50` | Slow EMA period |
| `InpTrendEMA` | `200` | Trend filter EMA period |
| `InpATRPeriod` | `14` | ATR period |
| `InpSLMultiplier` | `1.2` | SL distance = ATR × multiplier |
| `InpTPMultiplier` | `2.4` | TP distance = ATR × multiplier |
| `InpMagicNumber` | `202600` | Unique EA identifier |
| `InpMaxSpreadPts` | `0` | Skip trade if spread exceeds this; `0` disables the spread filter |
| `InpTradeSession` | `false` | Enable session filter |
| `InpSessionStart` | `12` | Session start (UTC hour) |
| `InpSessionEnd` | `17` | Session end (UTC hour) |
| `InpTimeframe` | `M5` | Signal timeframe |
| `InpSignalBars` | `3` | Bars to scan for a fresh EMA crossover |
| `InpBreakoutLookback` | `3` | Bars used to define the recent breakout range |
| `InpMinBodyATR` | `0.20` | Minimum signal candle body as a fraction of ATR |

---

## How Lot Sizing Works

```
Risk USD = $3 fixed by default
Lot Size = Risk USD ÷ (SL in points × tick value per point per lot)
```

If the calculated lot is below the broker minimum, the EA can still use the minimum lot only when the projected loss stays within the configured USD fallback risk limit.

---

## Risk Warning

Trading gold (XAUUSD) involves significant risk. Past performance is not indicative of future results. Always test on a **demo account** before going live.

The new defaults are intended to be more active on a **small account such as $30** by using a fixed-dollar risk model, faster signal timing, and momentum-based opportunity detection instead of a mandatory session filter.

These settings still do not guarantee growth and do not protect against slippage, gap risk, or consecutive losses.

---

## Files

| File | Description |
|------|-------------|
| `XAUUSD_EA.mq5` | Main Expert Advisor source code |
