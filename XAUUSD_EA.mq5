//+------------------------------------------------------------------+
//|                                                    XAUUSD_EA.mq5 |
//|                                          Ovidhub/Trading (2026)  |
//|  Strategy : EMA trend filter + ATR-based SL/TP                   |
//|  Risk      : Fixed $3 per trade (auto lot sizing)                 |
//|  Platform  : Deriv / MetaTrader 5                                 |
//|  Symbol    : XAUUSD                                               |
//+------------------------------------------------------------------+
#property copyright "Ovidhub/Trading"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input parameters
input group "=== Risk Management ==="
input double   InpRiskUSD       = 3.0;      // Risk per trade (USD)
input double   InpMaxLotSize    = 5.0;      // Maximum lot size cap
input double   InpMinLotSize    = 0.01;     // Minimum lot size

input group "=== EMA Settings ==="
input int      InpFastEMA       = 21;       // Fast EMA period
input int      InpSlowEMA       = 50;       // Slow EMA period
input int      InpTrendEMA      = 200;      // Trend EMA period

input group "=== ATR Settings ==="
input int      InpATRPeriod     = 14;       // ATR period
input double   InpSLMultiplier  = 1.5;      // SL = ATR × multiplier
input double   InpTPMultiplier  = 3.0;      // TP = ATR × multiplier (RR ≈ 1:2)

input group "=== Trade Filters ==="
input int      InpMagicNumber   = 202600;   // Magic number
input int      InpMaxSpreadPts  = 50;       // Max allowed spread (points)
input bool     InpTradeSession  = true;     // Filter by London/NY session
input int      InpSessionStart  = 7;        // Session start hour (UTC)
input int      InpSessionEnd    = 20;       // Session end hour (UTC)

input group "=== Signal Settings ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M15; // Signal timeframe
input int      InpSignalBars    = 2;        // Bars to confirm crossover

//--- Global objects
CTrade         Trade;
CPositionInfo  PosInfo;

//--- Indicator handles
int            handleFastEMA;
int            handleSlowEMA;
int            handleTrendEMA;
int            handleATR;

//--- Cached buffers
double         fastEMABuf[];
double         slowEMABuf[];
double         trendEMABuf[];
double         atrBuf[];

//+------------------------------------------------------------------+
//| Expert initialisation                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(30);
   Trade.SetTypeFilling(ORDER_FILLING_FOK);

   handleFastEMA  = iMA(_Symbol, InpTimeframe, InpFastEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA  = iMA(_Symbol, InpTimeframe, InpSlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleTrendEMA = iMA(_Symbol, InpTimeframe, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleATR      = iATR(_Symbol, InpTimeframe, InpATRPeriod);

   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE ||
      handleTrendEMA == INVALID_HANDLE || handleATR == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create indicator handles.");
      return INIT_FAILED;
     }

   ArraySetAsSeries(fastEMABuf,  true);
   ArraySetAsSeries(slowEMABuf,  true);
   ArraySetAsSeries(trendEMABuf, true);
   ArraySetAsSeries(atrBuf,      true);

   Print("XAUUSD EA initialised. Risk per trade: $", DoubleToString(InpRiskUSD, 2));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handleFastEMA);
   IndicatorRelease(handleSlowEMA);
   IndicatorRelease(handleTrendEMA);
   IndicatorRelease(handleATR);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Only act on new bar
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // Check spread
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPts)
     {
      Print("Spread too wide: ", spreadPoints, " pts — skipping.");
      return;
     }

   // Session filter
   if(InpTradeSession && !IsInSession())
      return;

   // Refresh indicator data
   if(!RefreshBuffers()) return;

   // Skip if already holding a position on this symbol/magic
   if(HasOpenPosition()) return;

   // Evaluate signal
   int signal = GetSignal();
   if(signal == 0) return;

   double atr = atrBuf[1];
   if(atr <= 0) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(signal == 1) // BUY
     {
      double sl     = NormalizeDouble(ask - InpSLMultiplier * atr, _Digits);
      double tp     = NormalizeDouble(ask + InpTPMultiplier * atr, _Digits);
      double slPips = (ask - sl) / point;
      double lots   = CalculateLotSize(slPips);
      if(lots <= 0) return;
      Trade.Buy(lots, _Symbol, ask, sl, tp, "XAUUSD EA BUY");
      PrintTradeInfo("BUY", lots, ask, sl, tp, atr);
     }
   else if(signal == -1) // SELL
     {
      double sl     = NormalizeDouble(bid + InpSLMultiplier * atr, _Digits);
      double tp     = NormalizeDouble(bid - InpTPMultiplier * atr, _Digits);
      double slPips = (sl - bid) / point;
      double lots   = CalculateLotSize(slPips);
      if(lots <= 0) return;
      Trade.Sell(lots, _Symbol, bid, sl, tp, "XAUUSD EA SELL");
      PrintTradeInfo("SELL", lots, bid, sl, tp, atr);
     }
  }

//+------------------------------------------------------------------+
//| Determine trade signal                                            |
//|  Returns: 1 = BUY, -1 = SELL, 0 = no signal                     |
//+------------------------------------------------------------------+
int GetSignal()
  {
   // Need at least InpSignalBars+1 bars of history
   int barsNeeded = InpSignalBars + 2;

   // Current bar (index 1 = last closed bar)
   double fastNow  = fastEMABuf[1];
   double slowNow  = slowEMABuf[1];
   double trendNow = trendEMABuf[1];

   // Previous bar
   double fastPrev = fastEMABuf[2];
   double slowPrev = slowEMABuf[2];

   // Trend filter: price (close) must be above/below 200 EMA
   double closePrice = iClose(_Symbol, InpTimeframe, 1);

   bool bullTrend = (closePrice > trendNow);
   bool bearTrend = (closePrice < trendNow);

   // EMA crossover: fast crosses above slow
   bool bullCross = (fastPrev <= slowPrev) && (fastNow > slowNow);
   // EMA crossover: fast crosses below slow
   bool bearCross = (fastPrev >= slowPrev) && (fastNow < slowNow);

   if(bullCross && bullTrend) return 1;
   if(bearCross && bearTrend) return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//| Auto lot size based on fixed USD risk and SL distance            |
//+------------------------------------------------------------------+
double CalculateLotSize(double slInPoints)
  {
   if(slInPoints <= 0) return 0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickValue <= 0 || tickSize <= 0) return 0;

   // Value per point per lot
   double valuePerPointPerLot = tickValue * (point / tickSize);

   // Risk amount ÷ (SL in points × value per point per lot)
   double lots = InpRiskUSD / (slInPoints * valuePerPointPerLot);

   // Round to lot step
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / lotStep) * lotStep;

   lots = MathMax(lots, InpMinLotSize);
   lots = MathMin(lots, InpMaxLotSize);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Refresh all indicator buffers                                     |
//+------------------------------------------------------------------+
bool RefreshBuffers()
  {
   int bars = InpSignalBars + 5;
   if(CopyBuffer(handleFastEMA,  0, 0, bars, fastEMABuf)  < bars) return false;
   if(CopyBuffer(handleSlowEMA,  0, 0, bars, slowEMABuf)  < bars) return false;
   if(CopyBuffer(handleTrendEMA, 0, 0, bars, trendEMABuf) < bars) return false;
   if(CopyBuffer(handleATR,      0, 0, bars, atrBuf)      < bars) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Check if there is already an open position for this EA           |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PosInfo.SelectByIndex(i))
        {
         if(PosInfo.Symbol() == _Symbol && PosInfo.Magic() == InpMagicNumber)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Session filter: only trade during London/NY overlap              |
//+------------------------------------------------------------------+
bool IsInSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
  }

//+------------------------------------------------------------------+
//| Log trade info to journal                                         |
//+------------------------------------------------------------------+
void PrintTradeInfo(string dir, double lots, double price, double sl, double tp, double atr)
  {
   Print(StringFormat(
      "[TRADE] %s | Lots: %.2f | Entry: %.2f | SL: %.2f | TP: %.2f | ATR: %.2f | Risk: $%.2f",
      dir, lots, price, sl, tp, atr, InpRiskUSD));
  }
//+------------------------------------------------------------------+
