//+------------------------------------------------------------------+
//|                                             XAUUSD_Indicator.mq5 |
//|                                          Ovidhub/Trading (2026)  |
//|  Indicator: EMA trend breakout + ATR-based momentum filter       |
//|  Platform : MetaTrader 5                                         |
//|  Symbol   : XAUUSD                                               |
//+------------------------------------------------------------------+
#property copyright "Ovidhub/Trading"
#property version   "1.0"
#property strict
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_label1  "Buy Signal"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  2

#property indicator_label2  "Sell Signal"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2

input group "=== Signal Timeframe ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M5; // Signal timeframe

input group "=== EMA Settings ==="
input int      InpFastEMA       = 21;       // Fast EMA period
input int      InpSlowEMA       = 50;       // Slow EMA period
input int      InpTrendEMA      = 200;      // Trend EMA period

input group "=== ATR Settings ==="
input int      InpATRPeriod     = 14;       // ATR period
input double   InpMinBodyATR    = 0.20;     // Minimum candle body as ATR fraction
input double   InpArrowOffsetATR = 0.20;    // Arrow offset as ATR fraction

input group "=== Trigger Settings ==="
input int      InpSignalBars    = 3;        // Bars to scan for a fresh EMA crossover
input int      InpBreakoutLookback = 3;     // Bars used to detect breakout opportunity

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
input bool     InpDebugLog      = false;    // Enable diagnostic logging for blocked signals

//--- Indicator buffers
double         buyBuffer[];
double         sellBuffer[];

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

const int      MIN_BUFFER_BARS = 3;

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
//| Indicator initialization                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   SetIndexBuffer(0, buyBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, sellBuffer, INDICATOR_DATA);

   ArraySetAsSeries(buyBuffer,  true);
   ArraySetAsSeries(sellBuffer, true);
   ArraySetAsSeries(fastEMABuf,  true);
   ArraySetAsSeries(slowEMABuf,  true);
   ArraySetAsSeries(trendEMABuf, true);
   ArraySetAsSeries(atrBuf,      true);
   ArraySetAsSeries(htfFastEMABuf,  true);
   ArraySetAsSeries(htfSlowEMABuf,  true);
   ArraySetAsSeries(htfTrendEMABuf, true);

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

   if(InpMinBodyATR <= 0 || InpArrowOffsetATR < 0)
     {
      Print("ERROR: InpMinBodyATR must be greater than zero and InpArrowOffsetATR cannot be negative.");
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
      Print("ERROR: Structure and liquidity lookbacks must be at least InpSwingStrength + 2.");
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

   IndicatorSetString(INDICATOR_SHORTNAME, "XAUUSD Signal Indicator");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Indicator deinitialization                                        |
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
//| Indicator calculation                                             |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 2)
      return 0;

   ENUM_TIMEFRAMES signalTimeframe = GetSignalTimeframe();
   ENUM_TIMEFRAMES higherTimeframe = GetHigherTimeframe();
   ENUM_TIMEFRAMES chartTimeframe = (ENUM_TIMEFRAMES)_Period;

   int signalBars = iBars(_Symbol, signalTimeframe);
   int htfBars = iBars(_Symbol, higherTimeframe);
   if(signalBars < MIN_BUFFER_BARS || htfBars < MIN_BUFFER_BARS)
      return 0;

   if(!RefreshBuffers(signalBars, htfBars))
      return 0;

   ArrayInitialize(buyBuffer, EMPTY_VALUE);
   ArrayInitialize(sellBuffer, EMPTY_VALUE);

   for(int shift = signalBars - 1; shift >= 1; shift--)
     {
      datetime signalTime = iTime(_Symbol, signalTimeframe, shift);
      if(signalTime == 0)
         continue;

      int chartShift = iBarShift(_Symbol, chartTimeframe, signalTime, true);
      if(chartShift < 0 || chartShift >= rates_total)
         continue;

      int signal = GetSignalAt(shift, signalTimeframe, higherTimeframe);
      if(signal == 0)
         continue;

      double atr = atrBuf[shift];
      double offset = GetArrowOffset(atr);
      if(signal > 0)
        {
         buyBuffer[chartShift] = iLow(_Symbol, chartTimeframe, chartShift) - offset;
        }
      else if(signal < 0)
        {
         sellBuffer[chartShift] = iHigh(_Symbol, chartTimeframe, chartShift) + offset;
        }
     }

   return rates_total;
  }

//+------------------------------------------------------------------+
//| Refresh all indicator buffers                                     |
//+------------------------------------------------------------------+
bool RefreshBuffers(int signalBars, int htfBars)
  {
   if(CopyBuffer(handleFastEMA,  0, 0, signalBars, fastEMABuf)  < signalBars) return false;
   if(CopyBuffer(handleSlowEMA,  0, 0, signalBars, slowEMABuf)  < signalBars) return false;
   if(CopyBuffer(handleTrendEMA, 0, 0, signalBars, trendEMABuf) < signalBars) return false;
   if(CopyBuffer(handleATR,      0, 0, signalBars, atrBuf)      < signalBars) return false;
   if(CopyBuffer(handleHTFFastEMA,  0, 0, htfBars, htfFastEMABuf)  < htfBars) return false;
   if(CopyBuffer(handleHTFSlowEMA,  0, 0, htfBars, htfSlowEMABuf)  < htfBars) return false;
   if(CopyBuffer(handleHTFTrendEMA, 0, 0, htfBars, htfTrendEMABuf) < htfBars) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Compute arrow offset                                               |
//+------------------------------------------------------------------+
double GetArrowOffset(double atr)
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minOffset = point * 10.0;
   if(atr <= 0 || InpArrowOffsetATR <= 0)
      return minOffset;
   return MathMax(minOffset, atr * InpArrowOffsetATR);
  }

//+------------------------------------------------------------------+
//| Determine trade signal                                            |
//+------------------------------------------------------------------+
int GetSignalAt(int shift, ENUM_TIMEFRAMES signalTimeframe, ENUM_TIMEFRAMES higherTimeframe)
  {
   int bufferSize = ArraySize(fastEMABuf);
   if(bufferSize == 0 || shift + InpSignalBars >= bufferSize || shift + InpBreakoutLookback >= bufferSize)
      return 0;

   double closePrice = iClose(_Symbol, signalTimeframe, shift);
   double openPrice  = iOpen(_Symbol, signalTimeframe, shift);
   double bodySize   = MathAbs(closePrice - openPrice);
   double atr        = atrBuf[shift];

   if(atr <= 0)
      return 0;

   bool bullTrend = (closePrice > trendEMABuf[shift] &&
                     fastEMABuf[shift] > slowEMABuf[shift] &&
                     closePrice > fastEMABuf[shift]);
   bool bearTrend = (closePrice < trendEMABuf[shift] &&
                     fastEMABuf[shift] < slowEMABuf[shift] &&
                     closePrice < fastEMABuf[shift]);

   bool bullCross = false;
   bool bearCross = false;
   for(int i = 1; i <= InpSignalBars; i++)
     {
      int idx = shift + i;
      if(fastEMABuf[idx] <= slowEMABuf[idx] && fastEMABuf[idx - 1] > slowEMABuf[idx - 1])
        {
         bullCross = true;
         break;
        }
      if(fastEMABuf[idx] >= slowEMABuf[idx] && fastEMABuf[idx - 1] < slowEMABuf[idx - 1])
        {
         bearCross = true;
         break;
        }
     }

   double recentHigh = iHigh(_Symbol, signalTimeframe, shift + 1);
   double recentLow  = iLow(_Symbol, signalTimeframe, shift + 1);
   for(int i = shift + 2; i <= shift + InpBreakoutLookback; i++)
     {
      recentHigh = MathMax(recentHigh, iHigh(_Symbol, signalTimeframe, i));
      recentLow  = MathMin(recentLow, iLow(_Symbol, signalTimeframe, i));
     }

   bool strongMove   = (bodySize >= atr * InpMinBodyATR);
   bool bullBreakout = (closePrice > recentHigh);
   bool bearBreakout = (closePrice < recentLow);

   bool bullSignal = (bullTrend && strongMove && (bullCross || bullBreakout));
   bool bearSignal = (bearTrend && strongMove && (bearCross || bearBreakout));

   if(bullSignal && PassDirectionalFilters(1, shift, closePrice, atr, signalTimeframe, higherTimeframe))
      return 1;

   if(bearSignal && PassDirectionalFilters(-1, shift, closePrice, atr, signalTimeframe, higherTimeframe))
      return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//| Determine EMA trend bias from the requested bar                   |
//+------------------------------------------------------------------+
int GetTrendBias(ENUM_TIMEFRAMES timeframe, int shift, const double &fastBuf[], const double &slowBuf[], const double &trendBuf[])
  {
   if(shift < 1 || shift >= ArraySize(trendBuf) || shift >= ArraySize(fastBuf) || shift >= ArraySize(slowBuf))
      return 0;

   double closePrice = iClose(_Symbol, timeframe, shift);
   if(closePrice == 0)
      return 0;

   if(closePrice > trendBuf[shift] && fastBuf[shift] > slowBuf[shift] && closePrice > fastBuf[shift])
      return 1;

   if(closePrice < trendBuf[shift] && fastBuf[shift] < slowBuf[shift] && closePrice < fastBuf[shift])
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
bool FindRecentSwing(ENUM_TIMEFRAMES timeframe, int baseShift, int lookbackBars, int strength,
                     bool findHigh, double &price, int &shiftFound)
  {
   int barsAvailable = iBars(_Symbol, timeframe);
   int startShift = baseShift + strength + 1;
   int maxSearchShift = baseShift + lookbackBars + strength;
   if(barsAvailable < maxSearchShift + strength + 1)
      return false;

   for(int shift = startShift; shift <= maxSearchShift; shift++)
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
bool FindRecentSwingPair(ENUM_TIMEFRAMES timeframe, int baseShift, int lookbackBars, int strength, bool findHigh,
                         double &latestPrice, double &previousPrice)
  {
   int barsAvailable = iBars(_Symbol, timeframe);
   int startShift = baseShift + strength + 1;
   int maxSearchShift = baseShift + lookbackBars + strength;
   int found = 0;

   if(barsAvailable < maxSearchShift + strength + 1)
      return false;

   for(int shift = startShift; shift <= maxSearchShift; shift++)
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
int GetStructureBias(ENUM_TIMEFRAMES timeframe, int baseShift, int lookbackBars, int strength)
  {
   double latestHigh = 0.0, previousHigh = 0.0;
   double latestLow  = 0.0, previousLow  = 0.0;
   bool hasHighs = FindRecentSwingPair(timeframe, baseShift, lookbackBars, strength, true, latestHigh, previousHigh);
   bool hasLows  = FindRecentSwingPair(timeframe, baseShift, lookbackBars, strength, false, latestLow, previousLow);
   double closePrice = iClose(_Symbol, timeframe, baseShift);

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
bool PassHigherTimeframeBias(int direction, datetime signalTime, ENUM_TIMEFRAMES higherTimeframe)
  {
   if(!InpUseHTFBias)
      return true;

   int htfShift = iBarShift(_Symbol, higherTimeframe, signalTime, true);
   if(htfShift < 1)
      return false;

   int trendBias = GetTrendBias(higherTimeframe, htfShift, htfFastEMABuf, htfSlowEMABuf, htfTrendEMABuf);
   if(trendBias != direction)
      return false;

   int structureBias = GetStructureBias(higherTimeframe, htfShift, InpHTFStructureLookback, InpSwingStrength);
   return (structureBias == direction);
  }

//+------------------------------------------------------------------+
//| Check higher-timeframe support / resistance distance               |
//+------------------------------------------------------------------+
bool PassHigherTimeframeDistanceFilter(int direction, datetime signalTime, double closePrice, double atr,
                                       ENUM_TIMEFRAMES higherTimeframe)
  {
   if(!InpUseHTFSRFilter)
      return true;

   double minDistance = atr * InpHTFMinDistanceATR;
   if(minDistance <= 0)
      return true;

   int htfShift = iBarShift(_Symbol, higherTimeframe, signalTime, true);
   if(htfShift < 1)
      return false;

   double level = 0.0;
   int levelShift = 0;

   if(direction > 0)
     {
      if(!FindRecentSwing(higherTimeframe, htfShift, InpHTFSRLookback, InpSwingStrength, true, level, levelShift))
         return true;
      if(level <= closePrice)
         return true;
      return ((level - closePrice) >= minDistance);
     }

   if(!FindRecentSwing(higherTimeframe, htfShift, InpHTFSRLookback, InpSwingStrength, false, level, levelShift))
      return true;
   if(level >= closePrice)
      return true;
   return ((closePrice - level) >= minDistance);
  }

//+------------------------------------------------------------------+
//| Check signal-timeframe market structure                            |
//+------------------------------------------------------------------+
bool PassMarketStructureFilter(int direction, int signalShift, ENUM_TIMEFRAMES signalTimeframe)
  {
   if(!InpUseMarketStructure)
      return true;

   int structureBias = GetStructureBias(signalTimeframe, signalShift, InpStructureLookback, InpSwingStrength);
   return (structureBias == direction);
  }

//+------------------------------------------------------------------+
//| Check optional liquidity sweep confirmation                        |
//+------------------------------------------------------------------+
bool PassLiquiditySweepFilter(int direction, int signalShift, double closePrice, double atr,
                              ENUM_TIMEFRAMES signalTimeframe)
  {
   if(!InpUseLiquiditySweep)
      return true;

   double reclaimDistance = atr * InpLiquiditySweepRejectATR;
   double level = 0.0;
   int levelShift = 0;

   if(direction > 0)
     {
      if(!FindRecentSwing(signalTimeframe, signalShift, InpLiquiditySweepLookback, InpSwingStrength, false, level, levelShift))
         return false;

      double candleLow = iLow(_Symbol, signalTimeframe, signalShift);
      return (candleLow < level && closePrice > (level + reclaimDistance));
     }

   if(!FindRecentSwing(signalTimeframe, signalShift, InpLiquiditySweepLookback, InpSwingStrength, true, level, levelShift))
      return false;

   double candleHigh = iHigh(_Symbol, signalTimeframe, signalShift);
   return (candleHigh > level && closePrice < (level - reclaimDistance));
  }

//+------------------------------------------------------------------+
//| Run the directional filter chain                                   |
//+------------------------------------------------------------------+
bool PassDirectionalFilters(int direction, int signalShift, double closePrice, double atr,
                            ENUM_TIMEFRAMES signalTimeframe, ENUM_TIMEFRAMES higherTimeframe)
  {
   datetime signalTime = iTime(_Symbol, signalTimeframe, signalShift);

   if(!PassHigherTimeframeBias(direction, signalTime, higherTimeframe))
     {
      if(InpDebugLog)
         Print(direction > 0 ? "BLOCKED: HTF bias is not bullish." : "BLOCKED: HTF bias is not bearish.");
      return false;
     }

   if(!PassHigherTimeframeDistanceFilter(direction, signalTime, closePrice, atr, higherTimeframe))
     {
      if(InpDebugLog)
         Print(direction > 0 ? "BLOCKED: buy signal too close to HTF resistance." : "BLOCKED: sell signal too close to HTF support.");
      return false;
     }

   if(!PassMarketStructureFilter(direction, signalShift, signalTimeframe))
     {
      if(InpDebugLog)
         Print(direction > 0 ? "BLOCKED: bullish market structure confirmation missing." : "BLOCKED: bearish market structure confirmation missing.");
      return false;
     }

   if(!PassLiquiditySweepFilter(direction, signalShift, closePrice, atr, signalTimeframe))
     {
      if(InpDebugLog)
         Print(direction > 0 ? "BLOCKED: no bullish liquidity sweep rejection detected." : "BLOCKED: no bearish liquidity sweep rejection detected.");
      return false;
     }

   return true;
  }
