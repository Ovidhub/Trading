//+------------------------------------------------------------------+
//|                                                    XAUUSD_EA.mq5 |
//|                                          Ovidhub/Trading (2026)  |
//|  Strategy : EMA trend breakout + ATR-based SL/TP                 |
//|  Risk      : Fixed-dollar risk with auto lot sizing               |
//|  Platform  : Deriv / MetaTrader 5                                 |
//|  Symbol    : XAUUSD                                               |
//+------------------------------------------------------------------+
#property copyright "Ovidhub/Trading"
#property version   "1.13"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input parameters
input group "=== Risk Management ==="
input double   InpRiskUSD       = 3.0;      // Max risk cap per trade (USD)
input double   InpRiskPercent   = 0.0;      // Optional % risk, only used when USD risk is zero
input double   InpMaxLotSize    = 5.0;      // Maximum lot size cap
input double   InpMinLotSize    = 0.01;     // Minimum lot size
input bool     InpAllowMinLotFallback = true; // Allow broker min lot when risk stays reasonable
input double   InpMinLotFallbackRiskUSD = 3.0; // Max USD risk allowed for min-lot fallback
input double   InpMinFreeMarginUSD = 0.0;  // Keep this free margin after entry

input group "=== EMA Settings ==="
input int      InpFastEMA       = 21;       // Fast EMA period
input int      InpSlowEMA       = 50;       // Slow EMA period
input int      InpTrendEMA      = 200;      // Trend EMA period

input group "=== ATR Settings ==="
input int      InpATRPeriod     = 14;       // ATR period
input double   InpSLMultiplier  = 1.2;      // SL = ATR × multiplier
input double   InpTPMultiplier  = 2.4;      // TP = ATR × multiplier (RR ≈ 1:2)

input group "=== Trade Filters ==="
input int      InpMagicNumber   = 202600;   // Magic number
input int      InpMaxSpreadPts  = 0;        // Max allowed spread (points), 0 disables the filter
input bool     InpTradeSession  = false;    // Filter by London/NY overlap session
input int      InpSessionStart  = 12;       // Session start hour (UTC)
input int      InpSessionEnd    = 17;       // Session end hour (UTC)

input group "=== Signal Settings ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M5; // Signal timeframe
input int      InpSignalBars    = 3;        // Bars to scan for a fresh EMA crossover
input int      InpBreakoutLookback = 3;     // Bars used to detect breakout opportunity
input double   InpMinBodyATR    = 0.20;     // Minimum signal candle body as ATR fraction

input group "=== Debug ==="
input bool     InpDebugLog      = false;    // Enable diagnostic logging for blocked trades and signals

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
//| Resolve the configured signal timeframe                          |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetSignalTimeframe()
  {
   return (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;
  }

//+------------------------------------------------------------------+
//| Expert initialisation                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(30);
   Trade.SetTypeFilling(ORDER_FILLING_IOC);

   ENUM_TIMEFRAMES signalTimeframe = GetSignalTimeframe();

   handleFastEMA  = iMA(_Symbol, signalTimeframe, InpFastEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA  = iMA(_Symbol, signalTimeframe, InpSlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleTrendEMA = iMA(_Symbol, signalTimeframe, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleATR      = iATR(_Symbol, signalTimeframe, InpATRPeriod);

   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE ||
       handleTrendEMA == INVALID_HANDLE || handleATR == INVALID_HANDLE)
      {
       Print("ERROR: Failed to create indicator handles.");
       return INIT_FAILED;
      }

   if(InpRiskUSD <= 0 && InpRiskPercent <= 0)
      {
      Print("ERROR: At least one of InpRiskUSD or InpRiskPercent must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
      }

   if(InpSignalBars < 1)
      {
      Print("ERROR: InpSignalBars must be at least 1.");
      return INIT_PARAMETERS_INCORRECT;
      }

   if(InpBreakoutLookback < 1)
      {
      Print("ERROR: InpBreakoutLookback must be at least 1.");
      return INIT_PARAMETERS_INCORRECT;
      }

   if(InpMinBodyATR <= 0)
      {
      Print("ERROR: InpMinBodyATR must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
      }

   ArraySetAsSeries(fastEMABuf,  true);
   ArraySetAsSeries(slowEMABuf,  true);
   ArraySetAsSeries(trendEMABuf, true);
   ArraySetAsSeries(atrBuf,      true);

   Print("XAUUSD EA initialised. Risk cap: $", DoubleToString(InpRiskUSD, 2),
         " | Risk %: ", DoubleToString(InpRiskPercent, 2),
         " | Signal TF: ", EnumToString(signalTimeframe),
         " | Chart TF: ", EnumToString((ENUM_TIMEFRAMES)_Period),
         " | Session: ", IntegerToString(InpSessionStart), ":00-", IntegerToString(InpSessionEnd), ":00 UTC");
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
   ENUM_TIMEFRAMES signalTimeframe = GetSignalTimeframe();
   datetime currentBarTime = iTime(_Symbol, signalTimeframe, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // Check spread
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(InpMaxSpreadPts > 0 && spreadPoints > InpMaxSpreadPts)
     {
      if(InpDebugLog)
         Print("BLOCKED: spread=", spreadPoints, " pts (max ", InpMaxSpreadPts, ")");
      return;
     }

   // Session filter
   if(InpTradeSession && !IsInSession())
     {
      if(InpDebugLog)
        {
         MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
         Print("BLOCKED: outside session UTC hour=", dt.hour,
               " (allowed ", InpSessionStart, "-", InpSessionEnd, ")");
        }
      return;
     }

   // Refresh indicator data
   if(!RefreshBuffers())
     {
      if(InpDebugLog)
         Print("BLOCKED: RefreshBuffers failed — not enough history yet.");
      return;
     }

   // Skip if already holding a position on this symbol/magic
   if(HasOpenPosition())
     {
      if(InpDebugLog)
         Print("BLOCKED: already in position.");
      return;
     }

   // Evaluate signal
   int signal = GetSignal();
   if(signal == 0)
     {
      if(InpDebugLog)
         // Signal requires an EMA crossover aligned with the trend EMA filter.
         PrintFormat("NO SIGNAL: fast[1]=%.2f slow[1]=%.2f fast[2]=%.2f slow[2]=%.2f trend=%.2f close=%.2f",
                     fastEMABuf[1], slowEMABuf[1], fastEMABuf[2], slowEMABuf[2],
                     trendEMABuf[1], iClose(_Symbol, signalTimeframe, 1));
      return;
     }

   double atr = atrBuf[1];
   if(atr <= 0) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return;

   if(signal == 1) // BUY
     {
      double sl     = NormalizeDouble(ask - InpSLMultiplier * atr, _Digits);
      double tp     = NormalizeDouble(ask + InpTPMultiplier * atr, _Digits);
      double slInPoints = (ask - sl) / point;
      double lots       = CalculateLotSize(slInPoints);
      if(lots <= 0) return;
      if(!CanAffordTrade(ORDER_TYPE_BUY, lots, ask)) return;
      if(Trade.Buy(lots, _Symbol, ask, sl, tp, "XAUUSD EA BUY"))
         PrintTradeInfo("BUY", lots, ask, sl, tp, atr);
      else
         PrintTradeError("BUY");
      }
   else if(signal == -1) // SELL
     {
      double sl       = NormalizeDouble(bid + InpSLMultiplier * atr, _Digits);
      double tp       = NormalizeDouble(bid - InpTPMultiplier * atr, _Digits);
      double slInPoints = (sl - bid) / point;
      double lots       = CalculateLotSize(slInPoints);
      if(lots <= 0) return;
      if(!CanAffordTrade(ORDER_TYPE_SELL, lots, bid)) return;
      if(Trade.Sell(lots, _Symbol, bid, sl, tp, "XAUUSD EA SELL"))
         PrintTradeInfo("SELL", lots, bid, sl, tp, atr);
      else
         PrintTradeError("SELL");
     }
  }

//+------------------------------------------------------------------+
//| Determine trade signal                                            |
//|  Returns: 1 = BUY, -1 = SELL, 0 = no signal                     |
//+------------------------------------------------------------------+
int GetSignal()
  {
   ENUM_TIMEFRAMES signalTimeframe = GetSignalTimeframe();
   double closePrice = iClose(_Symbol, signalTimeframe, 1);
   double openPrice  = iOpen(_Symbol, signalTimeframe, 1);
   double bodySize   = MathAbs(closePrice - openPrice);
   double atr        = atrBuf[1];

   if(atr <= 0)
      return 0;

   bool bullTrend = (closePrice > trendEMABuf[1] &&
                     fastEMABuf[1] > slowEMABuf[1] &&
                     closePrice > fastEMABuf[1]);
   bool bearTrend = (closePrice < trendEMABuf[1] &&
                     fastEMABuf[1] < slowEMABuf[1] &&
                     closePrice < fastEMABuf[1]);

   bool bullCross = false;
   bool bearCross = false;
   for(int i = 1; i <= InpSignalBars; i++)
      {
      if(fastEMABuf[i + 1] <= slowEMABuf[i + 1] && fastEMABuf[i] > slowEMABuf[i])
        {
         bullCross = true;
         break;
        }
      if(fastEMABuf[i + 1] >= slowEMABuf[i + 1] && fastEMABuf[i] < slowEMABuf[i])
        {
         bearCross = true;
         break;
        }
      }

   double recentHigh = iHigh(_Symbol, signalTimeframe, 2);
   double recentLow  = iLow(_Symbol, signalTimeframe, 2);
   for(int i = 3; i < InpBreakoutLookback + 2; i++)
      {
      recentHigh = MathMax(recentHigh, iHigh(_Symbol, signalTimeframe, i));
      recentLow  = MathMin(recentLow, iLow(_Symbol, signalTimeframe, i));
      }

   bool strongMove   = (bodySize >= atr * InpMinBodyATR);
   bool bullBreakout = (closePrice > recentHigh);
   bool bearBreakout = (closePrice < recentLow);

   if(bullTrend && strongMove && (bullCross || bullBreakout)) return 1;
   if(bearTrend && strongMove && (bearCross || bearBreakout)) return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//| Helper: calculate percentage amount                              |
//+------------------------------------------------------------------+
double PercentOf(double value, double percent)
  {
   return value * (percent / 100.0);
  }

//+------------------------------------------------------------------+
//| Auto lot size based on adaptive risk and SL distance             |
//+------------------------------------------------------------------+
double GetRiskAmountUSD()
  {
   if(InpRiskUSD > 0)
      return InpRiskUSD;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return PercentOf(equity, InpRiskPercent);
  }

//+------------------------------------------------------------------+
//| Estimate trade risk in USD                                        |
//+------------------------------------------------------------------+
double EstimateRiskUSD(double lots, double slInPoints)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickValue <= 0 || tickSize <= 0 || point <= 0)
      return 0;

   // Repeat the same point-value calculation used in lot sizing so the
   // logged/validated USD risk matches the sizing formula.
   double valuePerPointPerLot = tickValue * (point / tickSize);
   return lots * slInPoints * valuePerPointPerLot;
  }

//+------------------------------------------------------------------+
//| Auto lot size based on adaptive risk and SL distance             |
//+------------------------------------------------------------------+
double CalculateLotSize(double slInPoints)
  {
   if(slInPoints <= 0) return 0;

   double riskUSD   = GetRiskAmountUSD();
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(riskUSD <= 0 || tickValue <= 0 || tickSize <= 0 || point <= 0) return 0;

   // Value per point per lot
   double valuePerPointPerLot = tickValue * (point / tickSize);

   // Risk amount ÷ (SL in points × value per point per lot)
   double lots = riskUSD / (slInPoints * valuePerPointPerLot);

   // Round to lot step
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) return 0;
   lots = MathFloor(lots / lotStep) * lotStep;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   minLot = MathMax(minLot, InpMinLotSize);
   maxLot = MathMin(maxLot, InpMaxLotSize);

   if(lots < minLot)
     {
      if(!InpAllowMinLotFallback)
        {
         Print("Skipped: calculated lot size below broker minimum.");
         return 0;
        }

      double minLotRiskUSD = EstimateRiskUSD(minLot, slInPoints);
      double allowedMinLotRiskUSD = (InpMinLotFallbackRiskUSD > 0) ? InpMinLotFallbackRiskUSD : riskUSD;

      if(minLotRiskUSD > allowedMinLotRiskUSD)
        {
         Print("Skipped: min lot fallback risk too high. Risk=", DoubleToString(minLotRiskUSD, 2),
               " USD | Cap=", DoubleToString(allowedMinLotRiskUSD, 2), " USD");
         return 0;
        }

      lots = minLot;
     }

   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Check margin before sending order                                 |
//+------------------------------------------------------------------+
bool CanAffordTrade(ENUM_ORDER_TYPE orderType, double lots, double price)
  {
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   if(freeMargin <= InpMinFreeMarginUSD)
     {
      Print("Skipped: free margin too low. Free margin=", DoubleToString(freeMargin, 2), " USD");
      return false;
     }

   double marginRequired = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, lots, price, marginRequired))
     {
      Print("Skipped: failed to calculate margin for trade.");
      return false;
     }

   if((freeMargin - marginRequired) < InpMinFreeMarginUSD)
     {
      Print("Skipped: insufficient free margin buffer. Required=", DoubleToString(marginRequired, 2),
            " USD | Free margin=", DoubleToString(freeMargin, 2), " USD");
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Refresh all indicator buffers                                     |
//+------------------------------------------------------------------+
bool RefreshBuffers()
  {
   int bars = MathMax(InpSignalBars + 3, InpBreakoutLookback + 4);
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
//| Session filter: trade during strongest XAUUSD liquidity window   |
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
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double riskUSD = 0.0;
   if(point > 0)
      riskUSD = EstimateRiskUSD(lots, MathAbs(price - sl) / point);

   Print(StringFormat(
        "[TRADE] %s | Lots: %.2f | Entry: %.2f | SL: %.2f | TP: %.2f | ATR: %.2f | Risk: $%.2f",
        dir, lots, price, sl, tp, atr, riskUSD));
  }

//+------------------------------------------------------------------+
//| Log trade send failures                                           |
//+------------------------------------------------------------------+
void PrintTradeError(string dir)
  {
   Print(dir, " failed: ", Trade.ResultRetcode(), " - ", Trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
