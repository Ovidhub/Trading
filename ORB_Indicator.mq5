//+------------------------------------------------------------------+
//|                                             ORB_Indicator.mq5     |
//|                                          Ovidhub/Trading (2026)   |
//|  Indicator: Opening Range Breakout with value-area levels         |
//|  Platform : MetaTrader 5                                          |
//+------------------------------------------------------------------+
#property copyright "Ovidhub/Trading"
#property version   "1.0"
#property strict
#property indicator_chart_window
#property indicator_buffers 9
#property indicator_plots   9

#property indicator_label1  "ORB High"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGold
#property indicator_width1  1

#property indicator_label2  "ORB Low"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrGold
#property indicator_width2  1

#property indicator_label3  "VAH"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrDodgerBlue
#property indicator_width3  1

#property indicator_label4  "VAL"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrDodgerBlue
#property indicator_width4  1

#property indicator_label5  "POC"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrRed
#property indicator_width5  1

#property indicator_label6  "Breakout Buy"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrLime
#property indicator_width6  2

#property indicator_label7  "Breakout Sell"
#property indicator_type7   DRAW_ARROW
#property indicator_color7  clrRed
#property indicator_width7  2

#property indicator_label8  "Fakeout Buy"
#property indicator_type8   DRAW_ARROW
#property indicator_color8  clrAqua
#property indicator_width8  2

#property indicator_label9  "Fakeout Sell"
#property indicator_type9   DRAW_ARROW
#property indicator_color9  clrOrange
#property indicator_width9  2

input group "=== Session ==="
input int      InpSessionStartHour   = 9;     // Session start hour (server time)
input int      InpSessionStartMinute = 30;    // Session start minute (server time)
input int      InpOpenRangeMinutes   = 15;    // Opening range length in minutes
input bool     InpShowRangeBeforeClose = false; // Plot levels before range completes
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_M5; // Execution timeframe

input group "=== Volume Profile ==="
input double   InpValueAreaPercent   = 0.70;  // Value area percent (0-1)
input int      InpTicksPerRow        = 1;     // Ticks per row for profile bins

input group "=== Signals ==="
input bool     InpShowBreakoutSignals = true; // Show breakout arrows
input bool     InpShowFakeoutSignals  = true; // Show fakeout arrows
input int      InpFakeoutLookbackBars = 1;    // Bars after sweep to accept fakeout
input double   InpArrowOffsetPoints   = 20.0; // Arrow offset in points

//--- Indicator buffers
double orbHighBuf[];
double orbLowBuf[];
double vahBuf[];
double valBuf[];
double pocBuf[];
double breakoutBuyBuf[];
double breakoutSellBuf[];
double fakeoutBuyBuf[];
double fakeoutSellBuf[];

//+------------------------------------------------------------------+
//| Resolve the configured signal timeframe                           |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetSignalTimeframe()
  {
   ENUM_TIMEFRAMES timeframe = InpSignalTimeframe;
   if(timeframe == PERIOD_CURRENT)
      timeframe = (ENUM_TIMEFRAMES)_Period;
   return timeframe;
  }

//+------------------------------------------------------------------+
//| Calculate session start time                                      |
//+------------------------------------------------------------------+
datetime GetSessionStart(datetime barTime)
  {
   MqlDateTime dt;
   TimeToStruct(barTime, dt);
   dt.hour = InpSessionStartHour;
   dt.min = InpSessionStartMinute;
   dt.sec = 0;
   datetime sessionStart = StructToTime(dt);
   if(barTime < sessionStart)
      sessionStart -= 86400;
   return sessionStart;
  }

//+------------------------------------------------------------------+
//| Compute number of bars in opening range                           |
//+------------------------------------------------------------------+
int GetOpenRangeBars(ENUM_TIMEFRAMES timeframe)
  {
   int tfSeconds = PeriodSeconds(timeframe);
   if(tfSeconds <= 0)
     {
      Print("ERROR: Invalid signal timeframe; cannot compute opening range bars.");
      return 0;
     }
   double barsExact = (double)InpOpenRangeMinutes * 60.0 / (double)tfSeconds;
   int bars = (int)MathCeil(barsExact);
   return MathMax(1, bars);
  }

//+------------------------------------------------------------------+
//| Sort helper for descending volumes                                |
//+------------------------------------------------------------------+
void SortDescending(double &vols[], int &idx[], int left, int right)
  {
   int i = left;
   int j = right;
   double pivot = vols[(left + right) / 2];
   while(i <= j)
     {
      while(vols[i] > pivot)
         i++;
      while(vols[j] < pivot)
         j--;
      if(i <= j)
        {
         double tmp = vols[i];
         vols[i] = vols[j];
         vols[j] = tmp;
         int tmpIdx = idx[i];
         idx[i] = idx[j];
         idx[j] = tmpIdx;
         i++;
         j--;
        }
     }
   if(left < j)
      SortDescending(vols, idx, left, j);
   if(i < right)
      SortDescending(vols, idx, i, right);
  }

//+------------------------------------------------------------------+
//| Compute ORB + value area levels for a session                      |
//+------------------------------------------------------------------+
bool ComputeSessionLevels(datetime sessionStart, ENUM_TIMEFRAMES timeframe, int openRangeBars,
                          double &orbHigh, double &orbLow, double &vah, double &val, double &poc)
  {
   int startShift = iBarShift(_Symbol, timeframe, sessionStart, false);
   if(startShift < 0)
      return false;

   int endShift = startShift - (openRangeBars - 1);
   if(endShift < 0)
      return false;

   double highs[];
   double lows[];
   double volumes[];
   ArrayResize(highs, openRangeBars);
   ArrayResize(lows, openRangeBars);
   ArrayResize(volumes, openRangeBars);

   orbHigh = -DBL_MAX;
   orbLow = DBL_MAX;

   int idx = 0;
   for(int shift = startShift; shift >= endShift; shift--)
     {
      double high = iHigh(_Symbol, timeframe, shift);
      double low = iLow(_Symbol, timeframe, shift);
      double volume = (double)iVolume(_Symbol, timeframe, shift);
      highs[idx] = high;
      lows[idx] = low;
      volumes[idx] = volume;
      orbHigh = MathMax(orbHigh, high);
      orbLow = MathMin(orbLow, low);
      idx++;
     }

   if(orbHigh == -DBL_MAX || orbLow == DBL_MAX)
      return false;

   if(orbHigh == orbLow)
     {
      val = orbLow;
      vah = orbHigh;
      poc = orbHigh;
      return true;
     }

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0)
      tickSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double step = tickSize * MathMax(1, InpTicksPerRow);
   if(step <= 0)
     {
      Print("ERROR: Invalid tick size or row size; cannot compute volume profile.");
      return false;
     }

   int binCount = (int)MathCeil((orbHigh - orbLow) / step) + 1;
   if(binCount < 1)
      binCount = 1;

   double bins[];
   ArrayResize(bins, binCount);
   ArrayInitialize(bins, 0.0);

   for(int i = 0; i < openRangeBars; i++)
     {
      double barHigh = highs[i];
      double barLow = lows[i];
      double barVol = volumes[i];
      if(barHigh < barLow)
         continue;
      int startBin = (int)MathFloor((barLow - orbLow) / step);
      int endBin = (int)MathFloor((barHigh - orbLow) / step);
      startBin = MathMax(0, startBin);
      endBin = MathMin(binCount - 1, endBin);
      int span = endBin - startBin + 1;
      if(span <= 0)
         continue;
      double volPerBin = barVol / span;
      for(int b = startBin; b <= endBin; b++)
         bins[b] += volPerBin;
     }

   double totalVolume = 0.0;
   for(int i = 0; i < binCount; i++)
      totalVolume += bins[i];

   int pocIndex = 0;
   for(int i = 1; i < binCount; i++)
     {
      if(bins[i] > bins[pocIndex])
         pocIndex = i;
     }

   if(totalVolume <= 0.0)
     {
      val = orbLow;
      vah = orbHigh;
      poc = orbLow + (pocIndex + 0.5) * step;
      return true;
     }

   double vols[];
   int indices[];
   ArrayResize(vols, binCount);
   ArrayResize(indices, binCount);
   for(int i = 0; i < binCount; i++)
     {
      vols[i] = bins[i];
      indices[i] = i;
     }

   if(binCount > 1)
      SortDescending(vols, indices, 0, binCount - 1);

   double target = totalVolume * InpValueAreaPercent;
   double cumulative = 0.0;
   int minIndex = pocIndex;
   int maxIndex = pocIndex;

   for(int i = 0; i < binCount; i++)
     {
      cumulative += vols[i];
      minIndex = MathMin(minIndex, indices[i]);
      maxIndex = MathMax(maxIndex, indices[i]);
      if(cumulative >= target)
         break;
     }

   val = orbLow + minIndex * step;
   vah = orbLow + (maxIndex + 1) * step;
   poc = orbLow + (pocIndex + 0.5) * step;
   return true;
  }

//+------------------------------------------------------------------+
//| Find cached session index                                         |
//+------------------------------------------------------------------+
int FindSessionIndex(datetime sessionStart, const datetime &sessionStarts[], int count)
  {
   for(int i = 0; i < count; i++)
     {
      if(sessionStarts[i] == sessionStart)
         return i;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| Compute arrow offset                                              |
//+------------------------------------------------------------------+
double GetArrowOffset()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double offset = InpArrowOffsetPoints * point;
   if(offset <= 0)
      offset = point * 10.0;
   return offset;
  }

//+------------------------------------------------------------------+
//| Indicator initialization                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   PlotIndexSetInteger(5, PLOT_ARROW, 233);
   PlotIndexSetInteger(6, PLOT_ARROW, 234);
   PlotIndexSetInteger(7, PLOT_ARROW, 233);
   PlotIndexSetInteger(8, PLOT_ARROW, 234);

   for(int i = 0; i < 9; i++)
      PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   SetIndexBuffer(0, orbHighBuf, INDICATOR_DATA);
   SetIndexBuffer(1, orbLowBuf, INDICATOR_DATA);
   SetIndexBuffer(2, vahBuf, INDICATOR_DATA);
   SetIndexBuffer(3, valBuf, INDICATOR_DATA);
   SetIndexBuffer(4, pocBuf, INDICATOR_DATA);
   SetIndexBuffer(5, breakoutBuyBuf, INDICATOR_DATA);
   SetIndexBuffer(6, breakoutSellBuf, INDICATOR_DATA);
   SetIndexBuffer(7, fakeoutBuyBuf, INDICATOR_DATA);
   SetIndexBuffer(8, fakeoutSellBuf, INDICATOR_DATA);

   ArraySetAsSeries(orbHighBuf, true);
   ArraySetAsSeries(orbLowBuf, true);
   ArraySetAsSeries(vahBuf, true);
   ArraySetAsSeries(valBuf, true);
   ArraySetAsSeries(pocBuf, true);
   ArraySetAsSeries(breakoutBuyBuf, true);
   ArraySetAsSeries(breakoutSellBuf, true);
   ArraySetAsSeries(fakeoutBuyBuf, true);
   ArraySetAsSeries(fakeoutSellBuf, true);

   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionStartMinute < 0 || InpSessionStartMinute > 59)
     {
      Print("ERROR: Session start time is invalid.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpOpenRangeMinutes < 1)
     {
      Print("ERROR: InpOpenRangeMinutes must be at least 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpTicksPerRow < 1)
     {
      Print("ERROR: InpTicksPerRow must be at least 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpValueAreaPercent <= 0.0 || InpValueAreaPercent > 1.0)
     {
      Print("ERROR: InpValueAreaPercent must be between 0 and 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpFakeoutLookbackBars < 1)
     {
      Print("ERROR: InpFakeoutLookbackBars must be at least 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   IndicatorSetString(INDICATOR_SHORTNAME, "ORB Value Area Indicator");
   return INIT_SUCCEEDED;
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
   ENUM_TIMEFRAMES chartTimeframe = (ENUM_TIMEFRAMES)_Period;
   int openRangeBars = GetOpenRangeBars(signalTimeframe);
   if(openRangeBars <= 0)
      return 0;

   ArrayInitialize(orbHighBuf, EMPTY_VALUE);
   ArrayInitialize(orbLowBuf, EMPTY_VALUE);
   ArrayInitialize(vahBuf, EMPTY_VALUE);
   ArrayInitialize(valBuf, EMPTY_VALUE);
   ArrayInitialize(pocBuf, EMPTY_VALUE);
   ArrayInitialize(breakoutBuyBuf, EMPTY_VALUE);
   ArrayInitialize(breakoutSellBuf, EMPTY_VALUE);
   ArrayInitialize(fakeoutBuyBuf, EMPTY_VALUE);
   ArrayInitialize(fakeoutSellBuf, EMPTY_VALUE);

   datetime sessionStarts[];
   bool sessionValid[];
   double sessionOrbHighs[];
   double sessionOrbLows[];
   double sessionVAHs[];
   double sessionVALs[];
   double sessionPOCs[];
   int sessionCount = 0;

   datetime currentSession = 0;
   double currentOrbHigh = 0.0;
   double currentOrbLow = 0.0;
   double currentVAH = 0.0;
   double currentVAL = 0.0;
   double currentPOC = 0.0;
   bool currentValid = false;

   for(int i = rates_total - 1; i >= 0; i--)
     {
      datetime barTime = time[i];
      datetime sessionStart = GetSessionStart(barTime);
      if(sessionStart != currentSession)
        {
         currentSession = sessionStart;
         currentValid = ComputeSessionLevels(sessionStart, signalTimeframe, openRangeBars,
                                             currentOrbHigh, currentOrbLow, currentVAH, currentVAL, currentPOC);

         int newSize = sessionCount + 1;
         ArrayResize(sessionStarts, newSize);
         ArrayResize(sessionValid, newSize);
         ArrayResize(sessionOrbHighs, newSize);
         ArrayResize(sessionOrbLows, newSize);
         ArrayResize(sessionVAHs, newSize);
         ArrayResize(sessionVALs, newSize);
         ArrayResize(sessionPOCs, newSize);
         sessionStarts[sessionCount] = sessionStart;
         sessionValid[sessionCount] = currentValid;
         sessionOrbHighs[sessionCount] = currentOrbHigh;
         sessionOrbLows[sessionCount] = currentOrbLow;
         sessionVAHs[sessionCount] = currentVAH;
         sessionVALs[sessionCount] = currentVAL;
         sessionPOCs[sessionCount] = currentPOC;
         sessionCount++;
        }

      if(!currentValid)
         continue;

      datetime rangeEnd = currentSession + (InpOpenRangeMinutes * 60);
      if(!InpShowRangeBeforeClose && barTime < rangeEnd)
         continue;

      orbHighBuf[i] = currentOrbHigh;
      orbLowBuf[i] = currentOrbLow;
      vahBuf[i] = currentVAH;
      valBuf[i] = currentVAL;
      pocBuf[i] = currentPOC;
     }

   int signalBars = iBars(_Symbol, signalTimeframe);
   if(signalBars < openRangeBars + 2)
      return rates_total;

   double arrowOffset = GetArrowOffset();

   for(int shift = signalBars - 1; shift >= 0; shift--)
     {
      datetime barTime = iTime(_Symbol, signalTimeframe, shift);
      if(barTime == 0)
         continue;

      datetime sessionStart = GetSessionStart(barTime);
      int sessionIndex = FindSessionIndex(sessionStart, sessionStarts, sessionCount);
      if(sessionIndex < 0 || !sessionValid[sessionIndex])
         continue;

      datetime rangeEnd = sessionStart + (InpOpenRangeMinutes * 60);
      if(barTime < rangeEnd)
         continue;

      double orbHigh = sessionOrbHighs[sessionIndex];
      double orbLow = sessionOrbLows[sessionIndex];
      double vah = sessionVAHs[sessionIndex];
      double val = sessionVALs[sessionIndex];
      double poc = sessionPOCs[sessionIndex];

      double closePrice = iClose(_Symbol, signalTimeframe, shift);

      bool insideValueArea = (closePrice >= val && closePrice <= vah);
      bool breakoutBuy = InpShowBreakoutSignals && closePrice > vah;
      bool breakoutSell = InpShowBreakoutSignals && closePrice < val;

      bool fakeoutBuy = false;
      bool fakeoutSell = false;

      if(InpShowFakeoutSignals && insideValueArea)
        {
         for(int lookback = 1; lookback <= InpFakeoutLookbackBars; lookback++)
           {
            int prevShift = shift + lookback;
            if(prevShift >= signalBars)
               break;
            double prevClose = iClose(_Symbol, signalTimeframe, prevShift);
            double prevHigh = iHigh(_Symbol, signalTimeframe, prevShift);
            double prevLow = iLow(_Symbol, signalTimeframe, prevShift);

            if(prevHigh > orbHigh && prevClose > vah)
               fakeoutSell = true;
            if(prevLow < orbLow && prevClose < val)
               fakeoutBuy = true;
           }
        }

      int chartShift = iBarShift(_Symbol, chartTimeframe, barTime, true);
      if(chartShift < 0 || chartShift >= rates_total)
         continue;

      if(breakoutBuy && !fakeoutBuy && !fakeoutSell)
         breakoutBuyBuf[chartShift] = iLow(_Symbol, chartTimeframe, chartShift) - arrowOffset;
      if(breakoutSell && !fakeoutBuy && !fakeoutSell)
         breakoutSellBuf[chartShift] = iHigh(_Symbol, chartTimeframe, chartShift) + arrowOffset;

      if(fakeoutBuy)
         fakeoutBuyBuf[chartShift] = iLow(_Symbol, chartTimeframe, chartShift) - arrowOffset;
      if(fakeoutSell)
         fakeoutSellBuf[chartShift] = iHigh(_Symbol, chartTimeframe, chartShift) + arrowOffset;
     }

   return rates_total;
  }
