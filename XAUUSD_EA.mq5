//+------------------------------------------------------------------+
//|                                                    XAUUSD_EA.mq5 |
//|                                          Ovidhub/Trading (2026)  |
//|  Strategy : EMA trend filter + ATR-based SL/TP                   |
//|  Risk      : Balance-aware risk cap for small accounts            |
//|  Platform  : Deriv / MetaTrader 5                                 |
//|  Symbol    : XAUUSD                                               |
//+------------------------------------------------------------------+
#property copyright "Ovidhub/Trading"
#property version   "1.11"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input parameters
input group "=== Risk Management ==="
input double   InpRiskUSD       = 3.0;      // Max risk cap per trade (USD)
input double   InpRiskPercent   = 5.0;      // Risk as % of equity (used up to USD cap)
input double   InpMaxLotSize    = 5.0;      // Maximum lot size cap
input double   InpMinLotSize    = 0.01;     // Minimum lot size
input bool     InpAllowMinLotFallback = true; // Allow broker min lot when risk stays reasonable
input double   InpMaxMinLotRiskPct = 6.0;  // Max equity risk allowed for min-lot fallback
input double   InpMinFreeMarginUSD = 10.0; // Keep this free margin after entry

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
input int      InpMaxSpreadPts  = 35;       // Max allowed spread (points)
input bool     InpTradeSession  = true;     // Filter by London/NY overlap session
input int      InpSessionStart  = 12;       // Session start hour (UTC)
input int      InpSessionEnd    = 17;       // Session end hour (UTC)

input group "=== Signal Settings ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M15; // Signal timeframe
input int      InpSignalBars    = 2;        // Closed-bar confirmation window, including the crossover bar

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
//| Expert initialisation                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(30);
   Trade.SetTypeFilling(ORDER_FILLING_IOC);

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

   ArraySetAsSeries(fastEMABuf,  true);
   ArraySetAsSeries(slowEMABuf,  true);
   ArraySetAsSeries(trendEMABuf, true);
   ArraySetAsSeries(atrBuf,      true);

   Print("XAUUSD EA initialised. Risk cap: $", DoubleToString(InpRiskUSD, 2),
         " | Risk %: ", DoubleToString(InpRiskPercent, 2),
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
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // Check spread
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPts)
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
                     trendEMABuf[1], iClose(_Symbol, InpTimeframe, 1));
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
   int crossoverBarIndex = InpSignalBars;
   double trendNow = trendEMABuf[1];

   // Trend filter: price (close) must be above/below 200 EMA
   double closePrice = iClose(_Symbol, InpTimeframe, 1);

   bool bullTrend = (closePrice > trendNow);
   bool bearTrend = (closePrice < trendNow);

   // EMA crossover must happen on the confirmation window's oldest bar and remain intact.
   bool bullCross = (fastEMABuf[crossoverBarIndex + 1] <= slowEMABuf[crossoverBarIndex + 1]) &&
                    (fastEMABuf[crossoverBarIndex] > slowEMABuf[crossoverBarIndex]);
   bool bearCross = (fastEMABuf[crossoverBarIndex + 1] >= slowEMABuf[crossoverBarIndex + 1]) &&
                    (fastEMABuf[crossoverBarIndex] < slowEMABuf[crossoverBarIndex]);

   if(bullCross)
     {
      for(int i = crossoverBarIndex - 1; i >= 1; i--)
        {
         if(fastEMABuf[i] <= slowEMABuf[i])
           {
            bullCross = false;
            break;
           }
        }
     }

   if(bearCross)
     {
      for(int i = crossoverBarIndex - 1; i >= 1; i--)
        {
         if(fastEMABuf[i] >= slowEMABuf[i])
           {
            bearCross = false;
            break;
           }
        }
     }

   if(bullCross && bullTrend) return 1;
   if(bearCross && bearTrend) return -1;

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
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct = PercentOf(equity, InpRiskPercent);

   if(InpRiskPercent > 0 && InpRiskUSD > 0)
      return MathMin(riskPct, InpRiskUSD);

   if(InpRiskPercent > 0)
      return riskPct;

   return InpRiskUSD;
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

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double minLotRiskUSD = EstimateRiskUSD(minLot, slInPoints);
      double allowedMinLotRiskUSD = PercentOf(equity, InpMaxMinLotRiskPct);

      if(minLotRiskUSD > allowedMinLotRiskUSD)
        {
         Print("Skipped: min lot risk too high for equity. Risk=", DoubleToString(minLotRiskUSD, 2),
               " USD | Allowed=", DoubleToString(allowedMinLotRiskUSD, 2), " USD");
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
   double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);

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
