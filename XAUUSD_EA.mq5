//+------------------------------------------------------------------+
//|                                                    XAUUSD_EA.mq5 |
//|                                          Ovidhub/Trading (2026)  |
//|  Strategy : EMA trend breakout + ATR-based SL/TP                 |
//|  Risk      : Fixed-dollar risk with auto lot sizing               |
//|  Platform  : Deriv / MetaTrader 5                                 |
//|  Symbol    : XAUUSD                                               |
//+------------------------------------------------------------------+
#property copyright "Ovidhub/Trading"
#property version   "1.14"
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

input group "=== Higher Timeframe Filters ==="
input bool     InpUseHTFBias    = true;     // Require higher-timeframe trend + structure alignment
input ENUM_TIMEFRAMES InpHTFTimeframe = PERIOD_H1; // Higher timeframe for directional bias
input int      InpHTFStructureLookback = 30; // Bars used to read higher-timeframe structure
input bool     InpUseHTFSRFilter = true;    // Block entries too close to higher-timeframe S/R
input int      InpHTFSRLookback = 30;       // Bars used to find higher-timeframe swing S/R
input double   InpHTFMinDistanceATR = 0.50; // Minimum distance to HTF S/R as ATR multiple

input group "=== Market Structure Filters ==="
input bool     InpUseMarketStructure = true; // Require signal-timeframe structure alignment
input int      InpStructureLookback = 20;   // Bars used to evaluate recent structure
input int      InpSwingStrength = 2;        // Pivot strength for swing detection

input group "=== Liquidity Sweep Filter ==="
input bool     InpUseLiquiditySweep = false; // Require a sweep + rejection of recent liquidity
input int      InpLiquiditySweepLookback = 12; // Bars used to find recent swing liquidity
input double   InpLiquiditySweepRejectATR = 0.10; // Rejection reclaim distance as ATR multiple

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
int            handleHTFFastEMA;
int            handleHTFSlowEMA;
int            handleHTFTrendEMA;

//--- Cached buffers
double         fastEMABuf[];
double         slowEMABuf[];
double         trendEMABuf[];
double         atrBuf[];
double         htfFastEMABuf[];
double         htfSlowEMABuf[];
double         htfTrendEMABuf[];

const int      MIN_INDICATOR_BUFFER_BARS = 3;

//+------------------------------------------------------------------+
//| Resolve the configured signal timeframe                          |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetSignalTimeframe()
  {
   return (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;
  }

//+------------------------------------------------------------------+
//| Resolve the configured higher timeframe                           |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetHigherTimeframe()
  {
   return (InpHTFTimeframe == PERIOD_CURRENT) ? GetSignalTimeframe() : InpHTFTimeframe;
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
   ENUM_TIMEFRAMES higherTimeframe = GetHigherTimeframe();

   handleFastEMA  = iMA(_Symbol, signalTimeframe, InpFastEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA  = iMA(_Symbol, signalTimeframe, InpSlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleTrendEMA = iMA(_Symbol, signalTimeframe, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleATR      = iATR(_Symbol, signalTimeframe, InpATRPeriod);
   handleHTFFastEMA  = iMA(_Symbol, higherTimeframe, InpFastEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleHTFSlowEMA  = iMA(_Symbol, higherTimeframe, InpSlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleHTFTrendEMA = iMA(_Symbol, higherTimeframe, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE ||
      handleTrendEMA == INVALID_HANDLE || handleATR == INVALID_HANDLE ||
      handleHTFFastEMA == INVALID_HANDLE || handleHTFSlowEMA == INVALID_HANDLE ||
      handleHTFTrendEMA == INVALID_HANDLE)
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

   if(InpSwingStrength < 1)
      {
      Print("ERROR: InpSwingStrength must be at least 1.");
      return INIT_PARAMETERS_INCORRECT;
      }

   if(InpHTFStructureLookback < (InpSwingStrength + 2) ||
      InpHTFSRLookback < (InpSwingStrength + 2) ||
      InpStructureLookback < (InpSwingStrength + 2) ||
      InpLiquiditySweepLookback < (InpSwingStrength + 2))
      {
      Print("ERROR: Structure and liquidity lookbacks must be larger than the swing strength.");
      return INIT_PARAMETERS_INCORRECT;
      }

   if(InpHTFMinDistanceATR < 0 || InpLiquiditySweepRejectATR < 0)
      {
      Print("ERROR: ATR-based distance filters cannot be negative.");
      return INIT_PARAMETERS_INCORRECT;
      }

   if((InpUseHTFBias || InpUseHTFSRFilter) && PeriodSeconds(higherTimeframe) <= PeriodSeconds(signalTimeframe))
      {
      Print("ERROR: InpHTFTimeframe must be higher than the signal timeframe when HTF filters are enabled.");
      return INIT_PARAMETERS_INCORRECT;
      }

   ArraySetAsSeries(fastEMABuf,  true);
   ArraySetAsSeries(slowEMABuf,  true);
   ArraySetAsSeries(trendEMABuf, true);
   ArraySetAsSeries(atrBuf,      true);
   ArraySetAsSeries(htfFastEMABuf,  true);
   ArraySetAsSeries(htfSlowEMABuf,  true);
   ArraySetAsSeries(htfTrendEMABuf, true);

   Print("XAUUSD EA initialised. Risk cap: $", DoubleToString(InpRiskUSD, 2),
         " | Risk %: ", DoubleToString(InpRiskPercent, 2),
         " | Signal TF: ", EnumToString(signalTimeframe),
         " | HTF: ", EnumToString(higherTimeframe),
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
   IndicatorRelease(handleHTFFastEMA);
   IndicatorRelease(handleHTFSlowEMA);
   IndicatorRelease(handleHTFTrendEMA);
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

   bool bullSignal = (bullTrend && strongMove && (bullCross || bullBreakout));
   bool bearSignal = (bearTrend && strongMove && (bearCross || bearBreakout));

   if(bullSignal && PassDirectionalFilters(1, closePrice, atr))
      return 1;

   if(bearSignal && PassDirectionalFilters(-1, closePrice, atr))
      return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//| Determine EMA trend bias from the latest closed candle            |
//+------------------------------------------------------------------+
int GetTrendBias(ENUM_TIMEFRAMES timeframe, const double &fastBuf[], const double &slowBuf[], const double &trendBuf[])
  {
   double closePrice = iClose(_Symbol, timeframe, 1);

   if(closePrice > trendBuf[1] && fastBuf[1] > slowBuf[1] && closePrice > fastBuf[1])
      return 1;

   if(closePrice < trendBuf[1] && fastBuf[1] < slowBuf[1] && closePrice < fastBuf[1])
      return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//| Detect swing high                                                  |
//+------------------------------------------------------------------+
bool IsSwingHigh(ENUM_TIMEFRAMES timeframe, int shift, int strength)
  {
   if(shift <= strength)
      return false;

   double candidate = iHigh(_Symbol, timeframe, shift);
   if(candidate == 0)
      return false;

   for(int offset = 1; offset <= strength; offset++)
      {
       if(candidate <= iHigh(_Symbol, timeframe, shift - offset) ||
          candidate <= iHigh(_Symbol, timeframe, shift + offset))
          return false;
      }

   return true;
  }

//+------------------------------------------------------------------+
//| Detect swing low                                                   |
//+------------------------------------------------------------------+
bool IsSwingLow(ENUM_TIMEFRAMES timeframe, int shift, int strength)
  {
   if(shift <= strength)
      return false;

   double candidate = iLow(_Symbol, timeframe, shift);
   if(candidate == 0)
      return false;

   for(int offset = 1; offset <= strength; offset++)
      {
       if(candidate >= iLow(_Symbol, timeframe, shift - offset) ||
          candidate >= iLow(_Symbol, timeframe, shift + offset))
          return false;
      }

   return true;
  }

//+------------------------------------------------------------------+
//| Find the most recent swing point                                   |
//+------------------------------------------------------------------+
bool FindRecentSwing(ENUM_TIMEFRAMES timeframe, int lookbackBars, int strength, bool findHigh, double &price, int &shiftFound)
  {
   int barsAvailable = iBars(_Symbol, timeframe);
   int maxShift = lookbackBars + strength;
   if(barsAvailable <= maxShift + strength)
      return false;

   for(int shift = strength + 1; shift <= maxShift; shift++)
      {
       bool isMatch = findHigh ? IsSwingHigh(timeframe, shift, strength) : IsSwingLow(timeframe, shift, strength);
       if(isMatch)
         {
          price = findHigh ? iHigh(_Symbol, timeframe, shift) : iLow(_Symbol, timeframe, shift);
          shiftFound = shift;
          return true;
         }
      }

   return false;
  }

//+------------------------------------------------------------------+
//| Find the two most recent swings of the same type                   |
//+------------------------------------------------------------------+
bool FindRecentSwingPair(ENUM_TIMEFRAMES timeframe, int lookbackBars, int strength, bool findHigh,
                         double &latestPrice, double &previousPrice)
  {
   int barsAvailable = iBars(_Symbol, timeframe);
   int maxShift = lookbackBars + strength;
   int found = 0;

   if(barsAvailable <= maxShift + strength)
      return false;

   for(int shift = strength + 1; shift <= maxShift; shift++)
      {
       bool isMatch = findHigh ? IsSwingHigh(timeframe, shift, strength) : IsSwingLow(timeframe, shift, strength);
       if(!isMatch)
          continue;

       double price = findHigh ? iHigh(_Symbol, timeframe, shift) : iLow(_Symbol, timeframe, shift);
       if(found == 0)
          latestPrice = price;
       else
         {
          previousPrice = price;
          return true;
         }

       found++;
      }

   return false;
  }

//+------------------------------------------------------------------+
//| Derive directional structure bias from recent swings               |
//+------------------------------------------------------------------+
int GetStructureBias(ENUM_TIMEFRAMES timeframe, int lookbackBars, int strength)
  {
   double latestHigh = 0.0, previousHigh = 0.0;
   double latestLow  = 0.0, previousLow  = 0.0;
   bool hasHighs = FindRecentSwingPair(timeframe, lookbackBars, strength, true, latestHigh, previousHigh);
   bool hasLows  = FindRecentSwingPair(timeframe, lookbackBars, strength, false, latestLow, previousLow);
   double closePrice = iClose(_Symbol, timeframe, 1);

   bool bullishStructure = hasHighs && hasLows && latestHigh > previousHigh && latestLow > previousLow;
   bool bearishStructure = hasHighs && hasLows && latestHigh < previousHigh && latestLow < previousLow;
   bool bullishBreak = hasHighs && closePrice > latestHigh;
   bool bearishBreak = hasLows && closePrice < latestLow;

   if((bullishStructure || bullishBreak) && !(bearishStructure || bearishBreak))
      return 1;

   if((bearishStructure || bearishBreak) && !(bullishStructure || bullishBreak))
      return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//| Check higher-timeframe bias                                        |
//+------------------------------------------------------------------+
bool PassHigherTimeframeBias(int direction)
  {
   if(!InpUseHTFBias)
      return true;

   ENUM_TIMEFRAMES higherTimeframe = GetHigherTimeframe();
   int trendBias = GetTrendBias(higherTimeframe, htfFastEMABuf, htfSlowEMABuf, htfTrendEMABuf);
   if(trendBias != direction)
      return false;

   int structureBias = GetStructureBias(higherTimeframe, InpHTFStructureLookback, InpSwingStrength);
   return (structureBias == direction);
  }

//+------------------------------------------------------------------+
//| Check higher-timeframe support / resistance distance               |
//+------------------------------------------------------------------+
bool PassHigherTimeframeDistanceFilter(int direction, double closePrice, double atr)
  {
   if(!InpUseHTFSRFilter)
      return true;

   double minDistance = atr * InpHTFMinDistanceATR;
   if(minDistance <= 0)
      return true;

   ENUM_TIMEFRAMES higherTimeframe = GetHigherTimeframe();
   double level = 0.0;
   int levelShift = 0;

   if(direction > 0)
     {
      if(!FindRecentSwing(higherTimeframe, InpHTFSRLookback, InpSwingStrength, true, level, levelShift))
         return true;
      if(level <= closePrice)
         return true;
      return ((level - closePrice) >= minDistance);
     }

   if(!FindRecentSwing(higherTimeframe, InpHTFSRLookback, InpSwingStrength, false, level, levelShift))
      return true;
   if(level >= closePrice)
      return true;
   return ((closePrice - level) >= minDistance);
  }

//+------------------------------------------------------------------+
//| Run the directional filter chain                                   |
//+------------------------------------------------------------------+
bool PassDirectionalFilters(int direction, double closePrice, double atr)
  {
   if(!PassHigherTimeframeBias(direction))
     {
      if(InpDebugLog)
         Print(direction > 0 ? "BLOCKED: HTF bias is not bullish." : "BLOCKED: HTF bias is not bearish.");
      return false;
     }

   if(!PassHigherTimeframeDistanceFilter(direction, closePrice, atr))
     {
      if(InpDebugLog)
         Print(direction > 0 ? "BLOCKED: buy signal too close to HTF resistance." : "BLOCKED: sell signal too close to HTF support.");
      return false;
     }

   if(!PassMarketStructureFilter(direction))
     {
      if(InpDebugLog)
         Print(direction > 0 ? "BLOCKED: bullish market structure confirmation missing." : "BLOCKED: bearish market structure confirmation missing.");
      return false;
     }

   if(!PassLiquiditySweepFilter(direction, closePrice, atr))
     {
      if(InpDebugLog)
         Print(direction > 0 ? "BLOCKED: no bullish liquidity sweep rejection detected." : "BLOCKED: no bearish liquidity sweep rejection detected.");
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Check signal-timeframe market structure                            |
//+------------------------------------------------------------------+
bool PassMarketStructureFilter(int direction)
  {
   if(!InpUseMarketStructure)
      return true;

   int structureBias = GetStructureBias(GetSignalTimeframe(), InpStructureLookback, InpSwingStrength);
   return (structureBias == direction);
  }

//+------------------------------------------------------------------+
//| Check optional liquidity sweep confirmation                        |
//+------------------------------------------------------------------+
bool PassLiquiditySweepFilter(int direction, double closePrice, double atr)
  {
   if(!InpUseLiquiditySweep)
      return true;

   double reclaimDistance = atr * InpLiquiditySweepRejectATR;
   ENUM_TIMEFRAMES signalTimeframe = GetSignalTimeframe();
   double level = 0.0;
   int levelShift = 0;

   if(direction > 0)
     {
      if(!FindRecentSwing(signalTimeframe, InpLiquiditySweepLookback, InpSwingStrength, false, level, levelShift))
         return false;

      double candleLow = iLow(_Symbol, signalTimeframe, 1);
      return (candleLow < level && closePrice > (level + reclaimDistance));
     }

   if(!FindRecentSwing(signalTimeframe, InpLiquiditySweepLookback, InpSwingStrength, true, level, levelShift))
      return false;

   double candleHigh = iHigh(_Symbol, signalTimeframe, 1);
   return (candleHigh > level && closePrice < (level - reclaimDistance));
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
   bars = MathMax(bars, MIN_INDICATOR_BUFFER_BARS);
   if(CopyBuffer(handleFastEMA,  0, 0, bars, fastEMABuf)  < bars) return false;
   if(CopyBuffer(handleSlowEMA,  0, 0, bars, slowEMABuf)  < bars) return false;
   if(CopyBuffer(handleTrendEMA, 0, 0, bars, trendEMABuf) < bars) return false;
   if(CopyBuffer(handleATR,      0, 0, bars, atrBuf)      < bars) return false;
   if(CopyBuffer(handleHTFFastEMA,  0, 0, MIN_INDICATOR_BUFFER_BARS, htfFastEMABuf)  < MIN_INDICATOR_BUFFER_BARS) return false;
   if(CopyBuffer(handleHTFSlowEMA,  0, 0, MIN_INDICATOR_BUFFER_BARS, htfSlowEMABuf)  < MIN_INDICATOR_BUFFER_BARS) return false;
   if(CopyBuffer(handleHTFTrendEMA, 0, 0, MIN_INDICATOR_BUFFER_BARS, htfTrendEMABuf) < MIN_INDICATOR_BUFFER_BARS) return false;
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
