//+------------------------------------------------------------------+
//|              M1_EMA9_Pending_Strategy_FIXED.mq5                 |
//|                                                                  |
//|  EVERYTHING USES M1 DATA ONLY                                    |
//|                                                                  |
//|  UPTREND:                                                        |
//|    Bearish completed candle -> BUY LIMIT                         |
//|    Bullish completed candle -> BUY STOP                          |
//|                                                                  |
//|  DOWNTREND:                                                      |
//|    Bullish completed candle -> SELL LIMIT                        |
//|    Bearish completed candle -> SELL STOP                         |
//|                                                                  |
//|  SIDEWAYS / REVERSAL / UNCERTAIN -> NO NEW ORDER                |
//|                                                                  |
//|  TREND IS CONFIRMED USING CANDLES BEFORE THE SIGNAL CANDLE       |
//+------------------------------------------------------------------+
#property strict
#property version   "2.10"
#property description "M1-only EMA9 trend-based pending-order EA - trend confirmed independently of signal candle"

//-------------------------------------------------------------------
// INCLUDE
//-------------------------------------------------------------------
#include <Trade/Trade.mqh>

CTrade trade;

//-------------------------------------------------------------------
// CONSTANT
//-------------------------------------------------------------------
#define EA_TIMEFRAME PERIOD_M1

//-------------------------------------------------------------------
// MARKET STATES
//-------------------------------------------------------------------
enum MarketState
{
   STATE_UPTREND = 0,
   STATE_DOWNTREND,
   STATE_SIDEWAYS,
   STATE_REVERSAL,
   STATE_UNCERTAIN
};

//-------------------------------------------------------------------
// INPUTS
//-------------------------------------------------------------------

//--- EMA
input group "=== EMA TREND SETTINGS ==="
input int                  InpEMAPeriod = 9;
input ENUM_APPLIED_PRICE   InpEMAPrice  = PRICE_CLOSE;

//--- Trend confirmation
input group "=== TREND CONFIRMATION ==="
input int    InpTrendLookback          = 3;
input double InpMinEMASlopePoints      = 5.0;
input double InpMinPriceDistancePoints = 10.0;

//--- Sideways filter
input group "=== SIDEWAYS FILTER ==="
input int    InpSidewaysLookback                = 6;
input double InpMaxRangePointsForSideways       = 100.0;
input double InpMaxEMASlopePointsForSideways    = 5.0;
input double InpMaxAvgDistancePointsForSideways = 30.0;

//--- Reversal filter
input group "=== REVERSAL FILTER ==="
input int InpReversalLookback     = 3;
input int InpRequiredReversalBars = 2;

//--- Pending orders
input group "=== PENDING ORDER SETTINGS ==="
input double InpLotSize             = 0.01;
input double InpPendingOffsetPoints = 0.0;
input int    InpExpirationMinutes   = 0;
input int    InpMaxPendingOrders    = 100;
input int    InpMaxOrdersPerCandle  = 1;

//--- Order management
input group "=== ORDER MANAGEMENT ==="
input bool InpDeleteOppositeOnTrendChange = true;
input bool InpDeleteStalePendingOrders    = true;

//--- Trade settings
input group "=== TRADE SETTINGS ==="
input ulong InpMagicNumber     = 9001001;
input int   InpDeviationPoints = 20;

//--- Debug
input group "=== DEBUG ==="
input bool InpDebugLog = true;

//-------------------------------------------------------------------
// GLOBAL VARIABLES
//-------------------------------------------------------------------
int          g_emaHandle       = INVALID_HANDLE;
datetime     g_lastProcessedBar = 0;
MarketState  g_previousState   = STATE_UNCERTAIN;

//-------------------------------------------------------------------
// DEBUG
//-------------------------------------------------------------------
void DebugPrint(string message)
{
   if(InpDebugLog)
      Print("[M1 EMA9 EA] ", message);
}

//-------------------------------------------------------------------
// INITIALIZATION
//-------------------------------------------------------------------
int OnInit()
{
   ResetLastError();

   //===============================================================
   // INPUT VALIDATION
   //===============================================================
   if(InpEMAPeriod < 1)
   {
      Print("ERROR: EMA period must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpTrendLookback < 1)
   {
      Print("ERROR: Trend lookback must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpSidewaysLookback < 2)
   {
      Print("ERROR: Sideways lookback must be >= 2.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpReversalLookback < 3)
   {
      Print("ERROR: Reversal lookback must be >= 3.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpRequiredReversalBars < 1)
   {
      Print("ERROR: Required reversal bars must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpLotSize <= 0.0)
   {
      Print("ERROR: Lot size must be greater than 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpMaxPendingOrders < 1)
   {
      Print("ERROR: Max pending orders must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   //===============================================================
   // M1 ONLY
   //===============================================================
   DebugPrint(
      "EA initialized. Strategy timeframe is M1 only. "
      "Chart timeframe is ignored."
   );

   //===============================================================
   // CREATE EMA HANDLE ON M1
   //===============================================================
   ResetLastError();

   g_emaHandle = iMA(
      _Symbol,
      EA_TIMEFRAME,
      InpEMAPeriod,
      0,
      MODE_EMA,
      InpEMAPrice
   );

   if(g_emaHandle == INVALID_HANDLE)
   {
      int errorCode = GetLastError();

      Print(
         "ERROR: Could not create M1 EMA handle. Error = ",
         errorCode
      );

      return(INIT_FAILED);
   }

   //===============================================================
   // TRADE CONFIGURATION
   //===============================================================
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   //===============================================================
   // INITIAL BAR TIME
   //===============================================================
   datetime currentBarTime =
      iTime(_Symbol, EA_TIMEFRAME, 0);

   if(currentBarTime > 0)
      g_lastProcessedBar = currentBarTime;

   //===============================================================
   // SUCCESS
   //===============================================================
   DebugPrint("Initialization successful.");
   DebugPrint("Symbol = " + _Symbol);
   DebugPrint("Timeframe used internally = M1");

   DebugPrint(
      "EMA Period = " +
      IntegerToString(InpEMAPeriod)
   );

   DebugPrint(
      "Lot Size = " +
      DoubleToString(InpLotSize, 2)
   );

   return(INIT_SUCCEEDED);
}

//-------------------------------------------------------------------
// DEINITIALIZATION
//-------------------------------------------------------------------
void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_emaHandle);
      g_emaHandle = INVALID_HANDLE;
   }

   DebugPrint(
      "EA stopped. Reason = " +
      IntegerToString(reason)
   );
}

//-------------------------------------------------------------------
// ON TICK
//-------------------------------------------------------------------
void OnTick()
{
   //===============================================================
   // EVERYTHING USES M1
   //===============================================================

   ManagePendingOrders();

   datetime currentBarTime =
      iTime(_Symbol, EA_TIMEFRAME, 0);

   if(currentBarTime <= 0)
      return;

   if(currentBarTime == g_lastProcessedBar)
      return;

   //===============================================================
   // NEW M1 CANDLE
   //===============================================================
   g_lastProcessedBar = currentBarTime;

   // Shift 0 = running candle.
   // Shift 1 = completed candle.
   //
   // ONLY SHIFT 1 IS USED AS THE SIGNAL CANDLE.
   ProcessCompletedCandle();
}

//-------------------------------------------------------------------
// PROCESS COMPLETED CANDLE
//-------------------------------------------------------------------
void ProcessCompletedCandle()
{
   int requiredBars = MathMax(
      MathMax(
         InpTrendLookback + 5,
         InpSidewaysLookback + 5
      ),
      InpReversalLookback + 5
   );

   if(Bars(_Symbol, EA_TIMEFRAME) < requiredBars)
   {
      DebugPrint("Waiting for sufficient M1 history.");
      return;
   }

   //===============================================================
   // SIGNAL CANDLE
   //===============================================================
   MqlRates signalCandle;

   if(!GetM1Candle(1, signalCandle))
      return;

   //===============================================================
   // DETERMINE MARKET STATE
   //===============================================================
   MarketState state = DetermineMarketState();

   DebugPrint(
      "Completed M1 candle: " +
      TimeToString(
         signalCandle.time,
         TIME_DATE | TIME_MINUTES
      )
   );

   DebugPrint(
      "Open=" +
      DoubleToString(signalCandle.open, _Digits) +
      " High=" +
      DoubleToString(signalCandle.high, _Digits) +
      " Low=" +
      DoubleToString(signalCandle.low, _Digits) +
      " Close=" +
      DoubleToString(signalCandle.close, _Digits)
   );

   DebugPrint(
      "Market State = " +
      StateToString(state)
   );

   //===============================================================
   // NO TRADING CONDITIONS
   //===============================================================
   if(
      state == STATE_SIDEWAYS ||
      state == STATE_REVERSAL ||
      state == STATE_UNCERTAIN
   )
   {
      DebugPrint(
         "NO ORDER: sideways/reversal/uncertain. State=" +
         StateToString(state)
      );

      g_previousState = state;
      return;
   }

   //===============================================================
   // TREND CHANGE
   //===============================================================
   if(
      InpDeleteOppositeOnTrendChange &&
      g_previousState != STATE_UNCERTAIN &&
      g_previousState != STATE_SIDEWAYS &&
      g_previousState != STATE_REVERSAL &&
      g_previousState != state
   )
   {
      DeleteOppositePendingOrders(state);
   }

   //===============================================================
   // MAX PENDING ORDERS
   //===============================================================
   if(
      CountOurPendingOrders() >=
      InpMaxPendingOrders
   )
   {
      DebugPrint(
         "Maximum pending orders reached."
      );

      g_previousState = state;
      return;
   }

   //===============================================================
   // CANDLE TYPE
   //===============================================================
   bool bullish =
      signalCandle.close > signalCandle.open;

   bool bearish =
      signalCandle.close < signalCandle.open;

   //===============================================================
   // DOJI
   //===============================================================
   if(!bullish && !bearish)
   {
      DebugPrint("Doji -> NO ORDER.");
      g_previousState = state;
      return;
   }

   //===============================================================
   // UPTREND
   //===============================================================
   if(state == STATE_UPTREND)
   {
      //============================================================
      // BEARISH CANDLE CLOSE -> BUY LIMIT
      // ENTRY REFERENCE = CANDLE CLOSE
      //============================================================
      if(bearish)
      {
         DebugPrint(
            "UPTREND + BEARISH CLOSE -> BUY LIMIT at CANDLE CLOSE"
         );

         PlaceBuyLimitFromCandle(
            signalCandle
         );
      }

      //============================================================
      // BULLISH CANDLE CLOSE -> BUY STOP
      // ENTRY REFERENCE = CANDLE CLOSE
      //============================================================
      else if(bullish)
      {
         DebugPrint(
            "UPTREND + BULLISH CLOSE -> BUY STOP at CANDLE CLOSE"
         );

         PlaceBuyStopFromCandle(
            signalCandle
         );
      }
   }

   //===============================================================
   // DOWNTREND
   //===============================================================
   else if(state == STATE_DOWNTREND)
   {
      //============================================================
      // BULLISH CANDLE CLOSE -> SELL LIMIT
      // ENTRY REFERENCE = CANDLE CLOSE
      //============================================================
      if(bullish)
      {
         DebugPrint(
            "DOWNTREND + BULLISH CLOSE -> SELL LIMIT at CANDLE CLOSE"
         );

         PlaceSellLimitFromCandle(
            signalCandle
         );
      }

      //============================================================
      // BEARISH CANDLE CLOSE -> SELL STOP
      // ENTRY REFERENCE = CANDLE CLOSE
      //============================================================
      else if(bearish)
      {
         DebugPrint(
            "DOWNTREND + BEARISH CLOSE -> SELL STOP at CANDLE CLOSE"
         );

         PlaceSellStopFromCandle(
            signalCandle
         );
      }
   }

   g_previousState = state;
}

//-------------------------------------------------------------------
// GET M1 CANDLE
//-------------------------------------------------------------------
bool GetM1Candle(
   int shift,
   MqlRates &candle
)
{
   MqlRates rates[];

   ArraySetAsSeries(
      rates,
      true
   );

   ResetLastError();

   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      shift,
      1,
      rates
   );

   if(copied != 1)
   {
      DebugPrint(
         "CopyRates failed. Error = " +
         IntegerToString(GetLastError())
      );

      return false;
   }

   candle = rates[0];

   return true;
}

//-------------------------------------------------------------------
// GET EMA
//-------------------------------------------------------------------
double GetEMA(int shift)
{
   if(g_emaHandle == INVALID_HANDLE)
      return EMPTY_VALUE;

   double buffer[];

   ArraySetAsSeries(
      buffer,
      true
   );

   ResetLastError();

   int copied = CopyBuffer(
      g_emaHandle,
      0,
      shift,
      1,
      buffer
   );

   if(copied != 1)
      return EMPTY_VALUE;

   return buffer[0];
}

//-------------------------------------------------------------------
// DETERMINE MARKET STATE
//-------------------------------------------------------------------
MarketState DetermineMarketState()
{
   //===============================================================
   // SIDEWAYS HAS HIGHEST PRIORITY
   //===============================================================
   if(IsSideways())
      return STATE_SIDEWAYS;

   //===============================================================
   // REVERSAL HAS SECOND PRIORITY
   //===============================================================
   if(IsReversal())
      return STATE_REVERSAL;

   //===============================================================
   // IMPORTANT TREND LOGIC
   //
   // The signal candle is shift 1.
   //
   // We MUST NOT use the signal candle itself to decide whether
   // the established market trend is bullish or bearish.
   //
   // This allows:
   //
   // UPTREND:
   //    bearish signal candle -> BUY LIMIT
   //    bullish signal candle -> BUY STOP
   //
   // DOWNTREND:
   //    bullish signal candle -> SELL LIMIT
   //    bearish signal candle -> SELL STOP
   //
   // Therefore trend confirmation starts from SHIFT 2.
   //===============================================================

   MqlRates trendCandle;

   if(!GetM1Candle(2, trendCandle))
      return STATE_UNCERTAIN;

   double emaCurrent =
      GetEMA(2);

   double emaPast =
      GetEMA(
         2 + InpTrendLookback
      );

   if(
      emaCurrent == EMPTY_VALUE ||
      emaPast == EMPTY_VALUE
   )
   {
      return STATE_UNCERTAIN;
   }

   //===============================================================
   // EMA SLOPE
   //===============================================================
   double slopePoints =
      (emaCurrent - emaPast) / _Point;

   //===============================================================
   // PRICE DISTANCE FROM EMA
   //
   // IMPORTANT:
   // Use trend-reference candle shift 2, not signal candle shift 1.
   //===============================================================
   double priceDistancePoints =
      (trendCandle.close - emaCurrent) / _Point;

   //===============================================================
   // UPTREND
   //===============================================================
   if(
      slopePoints >=
      InpMinEMASlopePoints &&

      priceDistancePoints >=
      InpMinPriceDistancePoints &&

      HasBullishStructure(2)
   )
   {
      return STATE_UPTREND;
   }

   //===============================================================
   // DOWNTREND
   //===============================================================
   if(
      slopePoints <=
      -InpMinEMASlopePoints &&

      priceDistancePoints <=
      -InpMinPriceDistancePoints &&

      HasBearishStructure(2)
   )
   {
      return STATE_DOWNTREND;
   }

   return STATE_UNCERTAIN;
}

//-------------------------------------------------------------------
// SIDEWAYS DETECTION
//-------------------------------------------------------------------
bool IsSideways()
{
   double emaCurrent =
      GetEMA(1);

   double emaPast =
      GetEMA(
         1 + InpSidewaysLookback
      );

   if(
      emaCurrent == EMPTY_VALUE ||
      emaPast == EMPTY_VALUE
   )
   {
      return true;
   }

   double emaSlopePoints =
      MathAbs(
         emaCurrent - emaPast
      ) / _Point;

   MqlRates rates[];

   ArraySetAsSeries(
      rates,
      true
   );

   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      1,
      InpSidewaysLookback,
      rates
   );

   if(
      copied <
      InpSidewaysLookback
   )
   {
      return true;
   }

   double highest =
      rates[0].high;

   double lowest =
      rates[0].low;

   double totalDistance = 0.0;
   int validEMAValues = 0;

   for(
      int i = 0;
      i < copied;
      i++
   )
   {
      if(rates[i].high > highest)
         highest = rates[i].high;

      if(rates[i].low < lowest)
         lowest = rates[i].low;

      double ema =
         GetEMA(i + 1);

      if(ema != EMPTY_VALUE)
      {
         totalDistance +=
            MathAbs(
               rates[i].close - ema
            ) / _Point;

         validEMAValues++;
      }
   }

   if(validEMAValues == 0)
      return true;

   double rangePoints =
      (highest - lowest) / _Point;

   double averageDistance =
      totalDistance /
      validEMAValues;

   bool weakSlope =
      emaSlopePoints <=
      InpMaxEMASlopePointsForSideways;

   bool smallRange =
      rangePoints <=
      InpMaxRangePointsForSideways;

   bool closeToEMA =
      averageDistance <=
      InpMaxAvgDistancePointsForSideways;

   int score = 0;

   if(weakSlope)
      score++;

   if(smallRange)
      score++;

   if(closeToEMA)
      score++;

   return(score >= 2);
}

//-------------------------------------------------------------------
// BULLISH STRUCTURE
//
// startShift = 1 normally.
// For trend confirmation we use startShift = 2 so the signal
// candle does not invalidate the established trend.
//-------------------------------------------------------------------
bool HasBullishStructure(
   int startShift = 1
)
{
   MqlRates rates[];

   ArraySetAsSeries(
      rates,
      true
   );

   int needed =
      MathMax(
         InpTrendLookback,
         2
      );

   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      startShift,
      needed,
      rates
   );

   if(copied < needed)
      return false;

   // Latest trend-reference candle close >
   // previous trend-reference close.
   if(
      rates[0].close <=
      rates[1].close
   )
   {
      return false;
   }

   // Latest trend-reference high >=
   // previous trend-reference high.
   if(
      rates[0].high <
      rates[1].high
   )
   {
      return false;
   }

   return true;
}

//-------------------------------------------------------------------
// BEARISH STRUCTURE
//
// startShift = 1 normally.
// For trend confirmation we use startShift = 2 so the signal
// candle does not invalidate the established trend.
//-------------------------------------------------------------------
bool HasBearishStructure(
   int startShift = 1
)
{
   MqlRates rates[];

   ArraySetAsSeries(
      rates,
      true
   );

   int needed =
      MathMax(
         InpTrendLookback,
         2
      );

   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      startShift,
      needed,
      rates
   );

   if(copied < needed)
      return false;

   // Latest trend-reference close <
   // previous trend-reference close.
   if(
      rates[0].close >=
      rates[1].close
   )
   {
      return false;
   }

   // Latest trend-reference low <=
   // previous trend-reference low.
   if(
      rates[0].low >
      rates[1].low
   )
   {
      return false;
   }

   return true;
}

//-------------------------------------------------------------------
// REVERSAL DETECTION
//-------------------------------------------------------------------
bool IsReversal()
{
   MqlRates rates[];

   ArraySetAsSeries(
      rates,
      true
   );

   int count =
      MathMax(
         InpReversalLookback,
         3
      );

   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      1,
      count,
      rates
   );

   if(copied < count)
      return true;

   int bullishBars = 0;
   int bearishBars = 0;

   for(
      int i = 0;
      i < count;
      i++
   )
   {
      if(
         rates[i].close >
         rates[i].open
      )
      {
         bullishBars++;
      }

      if(
         rates[i].close <
         rates[i].open
      )
      {
         bearishBars++;
      }
   }

   double ema1 = GetEMA(1);
   double ema2 = GetEMA(2);
   double ema3 = GetEMA(3);

   if(
      ema1 == EMPTY_VALUE ||
      ema2 == EMPTY_VALUE ||
      ema3 == EMPTY_VALUE
   )
   {
      return true;
   }

   double recentSlope =
      ema1 - ema2;

   double previousSlope =
      ema2 - ema3;

   bool slopeChanged =
      (
         (recentSlope > 0.0 &&
          previousSlope < 0.0)
         ||
         (recentSlope < 0.0 &&
          previousSlope > 0.0)
      );

   if(slopeChanged)
      return true;

   //===============================================================
   // EMA CROSSING
   //===============================================================
   bool crossUp =
      rates[1].close < ema2 &&
      rates[0].close > ema1;

   bool crossDown =
      rates[1].close > ema2 &&
      rates[0].close < ema1;

   if(crossUp || crossDown)
      return true;

   //===============================================================
   // OPPOSITE CANDLE PRESSURE
   //===============================================================
   bool strongBullishShift =
      bullishBars >=
      InpRequiredReversalBars &&
      rates[0].close > ema1;

   bool strongBearishShift =
      bearishBars >=
      InpRequiredReversalBars &&
      rates[0].close < ema1;

   if(
      g_previousState ==
      STATE_UPTREND &&
      strongBearishShift
   )
   {
      return true;
   }

   if(
      g_previousState ==
      STATE_DOWNTREND &&
      strongBullishShift
   )
   {
      return true;
   }

   return false;
}

//-------------------------------------------------------------------
// NORMALIZE PRICE
//-------------------------------------------------------------------
double NormalizePrice(double price)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   if(tickSize <= 0.0)
      tickSize = _Point;

   price =
      MathRound(
         price / tickSize
      ) * tickSize;

   return NormalizeDouble(
      price,
      _Digits
   );
}

//-------------------------------------------------------------------
// NORMALIZE LOT
//-------------------------------------------------------------------
double NormalizeLot(double volume)
{
   double minLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   double maxLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );

   double step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(step <= 0.0)
      step = minLot;

   volume =
      MathMax(
         minLot,
         MathMin(
            maxLot,
            volume
         )
      );

   volume =
      MathFloor(
         volume / step
      ) * step;

   int volumeDigits = 2;

   if(step >= 1.0)
      volumeDigits = 0;
   else if(step >= 0.1)
      volumeDigits = 1;
   else if(step >= 0.01)
      volumeDigits = 2;
   else
      volumeDigits = 3;

   return NormalizeDouble(
      volume,
      volumeDigits
   );
}

//-------------------------------------------------------------------
// MINIMUM PENDING DISTANCE
//-------------------------------------------------------------------
double GetMinimumDistancePrice()
{
   long stopsLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   long freezeLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );

   long maximumLevel =
      MathMax(
         stopsLevel,
         freezeLevel
      );

   double distance =
      (double)maximumLevel *
      _Point;

   distance +=
      MathMax(
         0.0,
         InpPendingOffsetPoints
      ) * _Point;

   return distance;
}

//-------------------------------------------------------------------
// CALCULATE BUY LIMIT PRICE
//-------------------------------------------------------------------
double GetValidBuyLimitPrice(
   double requestedPrice
)
{
   MqlTick tick;

   if(!SymbolInfoTick(
      _Symbol,
      tick
   ))
   {
      return 0.0;
   }

   double minimumDistance =
      GetMinimumDistancePrice();

   double maximumAllowed =
      tick.ask -
      minimumDistance;

   double price =
      requestedPrice;

   if(price >= maximumAllowed)
      price = maximumAllowed;

   price =
      NormalizePrice(price);

   if(
      price <= 0.0 ||
      price >= tick.ask
   )
   {
      return 0.0;
   }

   return price;
}

//-------------------------------------------------------------------
// CALCULATE BUY STOP PRICE
//-------------------------------------------------------------------
double GetValidBuyStopPrice(
   double requestedPrice
)
{
   MqlTick tick;

   if(!SymbolInfoTick(
      _Symbol,
      tick
   ))
   {
      return 0.0;
   }

   double minimumDistance =
      GetMinimumDistancePrice();

   double minimumAllowed =
      tick.ask +
      minimumDistance;

   double price =
      requestedPrice;

   if(price <= minimumAllowed)
      price = minimumAllowed;

   price =
      NormalizePrice(price);

   if(price <= tick.ask)
      return 0.0;

   return price;
}

//-------------------------------------------------------------------
// CALCULATE SELL LIMIT PRICE
//-------------------------------------------------------------------
double GetValidSellLimitPrice(
   double requestedPrice
)
{
   MqlTick tick;

   if(!SymbolInfoTick(
      _Symbol,
      tick
   ))
   {
      return 0.0;
   }

   double minimumDistance =
      GetMinimumDistancePrice();

   double minimumAllowed =
      tick.bid +
      minimumDistance;

   double price =
      requestedPrice;

   if(price <= minimumAllowed)
      price = minimumAllowed;

   price =
      NormalizePrice(price);

   if(price <= tick.bid)
      return 0.0;

   return price;
}

//-------------------------------------------------------------------
// CALCULATE SELL STOP PRICE
//-------------------------------------------------------------------
double GetValidSellStopPrice(
   double requestedPrice
)
{
   MqlTick tick;

   if(!SymbolInfoTick(
      _Symbol,
      tick
   ))
   {
      return 0.0;
   }

   double minimumDistance =
      GetMinimumDistancePrice();

   double maximumAllowed =
      tick.bid -
      minimumDistance;

   double price =
      requestedPrice;

   if(price >= maximumAllowed)
      price = maximumAllowed;

   price =
      NormalizePrice(price);

   if(
      price <= 0.0 ||
      price >= tick.bid
   )
   {
      return 0.0;
   }

   return price;
}

//-------------------------------------------------------------------
// CREATE ORDER EXPIRATION
//-------------------------------------------------------------------
ENUM_ORDER_TYPE_TIME GetOrderTimeType()
{
   if(InpExpirationMinutes > 0)
      return ORDER_TIME_SPECIFIED;

   return ORDER_TIME_GTC;
}

//-------------------------------------------------------------------
// GET EXPIRATION
//-------------------------------------------------------------------
datetime GetExpirationTime()
{
   if(InpExpirationMinutes <= 0)
      return 0;

   return(
      TimeCurrent() +
      (InpExpirationMinutes * 60)
   );
}

//-------------------------------------------------------------------
// ORDER COMMENT
//-------------------------------------------------------------------
string MakeOrderComment(
   string orderType,
   datetime candleTime
)
{
   return(
      "M1 EMA9 " +
      orderType +
      " " +
      TimeToString(
         candleTime,
         TIME_DATE |
         TIME_MINUTES
      )
   );
}

//-------------------------------------------------------------------
// BUY LIMIT
//-------------------------------------------------------------------
void PlaceBuyLimitFromCandle(
   MqlRates &candle
)
{
   //===============================================================
   // UPTREND + BEARISH CANDLE CLOSE
   //
   // BUY LIMIT ENTRY REFERENCE = COMPLETED CANDLE CLOSE
   //
   // IMPORTANT:
   // DO NOT USE candle.low.
   //===============================================================
   double requestedPrice =
      candle.close;

   double price =
      GetValidBuyLimitPrice(
         requestedPrice
      );

   if(price <= 0.0)
   {
      DebugPrint(
         "BUY LIMIT: invalid price at candle close."
      );

      return;
   }

   if(
      HasPendingOrderForCandle(
         candle.time
      )
   )
   {
      DebugPrint(
         "BUY LIMIT: duplicate prevented."
      );

      return;
   }

   double volume =
      NormalizeLot(
         InpLotSize
      );

   if(volume <= 0.0)
   {
      DebugPrint(
         "BUY LIMIT: invalid volume."
      );

      return;
   }

   string comment =
      MakeOrderComment(
         "BUY LIMIT",
         candle.time
      );

   bool result =
      trade.BuyLimit(
         volume,
         price,
         _Symbol,
         0.0,
         0.0,
         GetOrderTimeType(),
         GetExpirationTime(),
         comment
      );

   if(result)
   {
      DebugPrint(
         "BUY LIMIT placed. "
         "Candle Close=" +
         DoubleToString(
            candle.close,
            _Digits
         ) +
         " Entry=" +
         DoubleToString(
            price,
            _Digits
         ) +
         " Volume=" +
         DoubleToString(
            volume,
            2
         )
      );
   }
   else
   {
      DebugPrint(
         "BUY LIMIT FAILED. Retcode=" +
         IntegerToString(
            (int)trade.ResultRetcode()
         ) +
         " " +
         trade.ResultRetcodeDescription()
      );
   }
}

//-------------------------------------------------------------------
// BUY STOP
//-------------------------------------------------------------------
void PlaceBuyStopFromCandle(
   MqlRates &candle
)
{
   //===============================================================
   // UPTREND + BULLISH CANDLE CLOSE
   //
   // BUY STOP ENTRY REFERENCE = COMPLETED CANDLE CLOSE
   //
   // IMPORTANT:
   // DO NOT USE candle.high.
   //===============================================================
   double requestedPrice =
      candle.close;

   double price =
      GetValidBuyStopPrice(
         requestedPrice
      );

   if(price <= 0.0)
   {
      DebugPrint(
         "BUY STOP: invalid price at candle close."
      );

      return;
   }

   if(
      HasPendingOrderForCandle(
         candle.time
      )
   )
   {
      DebugPrint(
         "BUY STOP: duplicate prevented."
      );

      return;
   }

   double volume =
      NormalizeLot(
         InpLotSize
      );

   if(volume <= 0.0)
   {
      DebugPrint(
         "BUY STOP: invalid volume."
      );

      return;
   }

   string comment =
      MakeOrderComment(
         "BUY STOP",
         candle.time
      );

   bool result =
      trade.BuyStop(
         volume,
         price,
         _Symbol,
         0.0,
         0.0,
         GetOrderTimeType(),
         GetExpirationTime(),
         comment
      );

   if(result)
   {
      DebugPrint(
         "BUY STOP placed. "
         "Candle Close=" +
         DoubleToString(
            candle.close,
            _Digits
         ) +
         " Entry=" +
         DoubleToString(
            price,
            _Digits
         ) +
         " Volume=" +
         DoubleToString(
            volume,
            2
         )
      );
   }
   else
   {
      DebugPrint(
         "BUY STOP FAILED. Retcode=" +
         IntegerToString(
            (int)trade.ResultRetcode()
         ) +
         " " +
         trade.ResultRetcodeDescription()
      );
   }
}

//-------------------------------------------------------------------
// SELL LIMIT
//-------------------------------------------------------------------
void PlaceSellLimitFromCandle(
   MqlRates &candle
)
{
   //===============================================================
   // DOWNTREND + BULLISH CANDLE CLOSE
   //
   // SELL LIMIT ENTRY REFERENCE = COMPLETED CANDLE CLOSE
   //
   // IMPORTANT:
   // DO NOT USE candle.high.
   //===============================================================
   double requestedPrice =
      candle.close;

   double price =
      GetValidSellLimitPrice(
         requestedPrice
      );

   if(price <= 0.0)
   {
      DebugPrint(
         "SELL LIMIT: invalid price at candle close."
      );

      return;
   }

   if(
      HasPendingOrderForCandle(
         candle.time
      )
   )
   {
      DebugPrint(
         "SELL LIMIT: duplicate prevented."
      );

      return;
   }

   double volume =
      NormalizeLot(
         InpLotSize
      );

   if(volume <= 0.0)
   {
      DebugPrint(
         "SELL LIMIT: invalid volume."
      );

      return;
   }

   string comment =
      MakeOrderComment(
         "SELL LIMIT",
         candle.time
      );

   bool result =
      trade.SellLimit(
         volume,
         price,
         _Symbol,
         0.0,
         0.0,
         GetOrderTimeType(),
         GetExpirationTime(),
         comment
      );

   if(result)
   {
      DebugPrint(
         "SELL LIMIT placed. "
         "Candle Close=" +
         DoubleToString(
            candle.close,
            _Digits
         ) +
         " Entry=" +
         DoubleToString(
            price,
            _Digits
         ) +
         " Volume=" +
         DoubleToString(
            volume,
            2
         )
      );
   }
   else
   {
      DebugPrint(
         "SELL LIMIT FAILED. Retcode=" +
         IntegerToString(
            (int)trade.ResultRetcode()
         ) +
         " " +
         trade.ResultRetcodeDescription()
      );
   }
}

//-------------------------------------------------------------------
// SELL STOP
//-------------------------------------------------------------------
void PlaceSellStopFromCandle(
   MqlRates &candle
)
{
   //===============================================================
   // DOWNTREND + BEARISH CANDLE CLOSE
   //
   // SELL STOP ENTRY REFERENCE = COMPLETED CANDLE CLOSE
   //
   // IMPORTANT:
   // DO NOT USE candle.low.
   //===============================================================
   double requestedPrice =
      candle.close;

   double price =
      GetValidSellStopPrice(
         requestedPrice
      );

   if(price <= 0.0)
   {
      DebugPrint(
         "SELL STOP: invalid price at candle close."
      );

      return;
   }

   if(
      HasPendingOrderForCandle(
         candle.time
      )
   )
   {
      DebugPrint(
         "SELL STOP: duplicate prevented."
      );

      return;
   }

   double volume =
      NormalizeLot(
         InpLotSize
      );

   if(volume <= 0.0)
   {
      DebugPrint(
         "SELL STOP: invalid volume."
      );

      return;
   }

   string comment =
      MakeOrderComment(
         "SELL STOP",
         candle.time
      );

   bool result =
      trade.SellStop(
         volume,
         price,
         _Symbol,
         0.0,
         0.0,
         GetOrderTimeType(),
         GetExpirationTime(),
         comment
      );

   if(result)
   {
      DebugPrint(
         "SELL STOP placed. "
         "Candle Close=" +
         DoubleToString(
            candle.close,
            _Digits
         ) +
         " Entry=" +
         DoubleToString(
            price,
            _Digits
         ) +
         " Volume=" +
         DoubleToString(
            volume,
            2
         )
      );
   }
   else
   {
      DebugPrint(
         "SELL STOP FAILED. Retcode=" +
         IntegerToString(
            (int)trade.ResultRetcode()
         ) +
         " " +
         trade.ResultRetcodeDescription()
      );
   }
}

//-------------------------------------------------------------------
// COUNT OUR PENDING ORDERS
//-------------------------------------------------------------------
int CountOurPendingOrders()
{
   int count = 0;

   for(
      int i = OrdersTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
      {
         continue;
      }

      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != InpMagicNumber
      )
      {
         continue;
      }

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)
         OrderGetInteger(
            ORDER_TYPE
         );

      if(IsPendingOrderType(type))
         count++;
   }

   return count;
}

//-------------------------------------------------------------------
// PENDING ORDER TYPE
//-------------------------------------------------------------------
bool IsPendingOrderType(
   ENUM_ORDER_TYPE type
)
{
   return(
      type == ORDER_TYPE_BUY_LIMIT ||
      type == ORDER_TYPE_BUY_STOP ||
      type == ORDER_TYPE_SELL_LIMIT ||
      type == ORDER_TYPE_SELL_STOP
   );
}

//-------------------------------------------------------------------
// CHECK DUPLICATE CANDLE ORDER
//-------------------------------------------------------------------
bool HasPendingOrderForCandle(
   datetime candleTime
)
{
   string candleText =
      TimeToString(
         candleTime,
         TIME_DATE |
         TIME_MINUTES
      );

   for(
      int i = OrdersTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
      {
         continue;
      }

      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != InpMagicNumber
      )
      {
         continue;
      }

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)
         OrderGetInteger(
            ORDER_TYPE
         );

      if(!IsPendingOrderType(type))
         continue;

      string comment =
         OrderGetString(
            ORDER_COMMENT
         );

      if(
         StringFind(
            comment,
            candleText
         ) >= 0
      )
      {
         return true;
      }
   }

   return false;
}

//-------------------------------------------------------------------
// DELETE OPPOSITE PENDING ORDERS
//-------------------------------------------------------------------
void DeleteOppositePendingOrders(
   MarketState newState
)
{
   for(
      int i = OrdersTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
      {
         continue;
      }

      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != InpMagicNumber
      )
      {
         continue;
      }

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)
         OrderGetInteger(
            ORDER_TYPE
         );

      bool deleteOrder = false;

      //============================================================
      // NEW UPTREND -> REMOVE SELL PENDING ORDERS
      //============================================================
      if(newState == STATE_UPTREND)
      {
         if(
            type == ORDER_TYPE_SELL_LIMIT ||
            type == ORDER_TYPE_SELL_STOP
         )
         {
            deleteOrder = true;
         }
      }

      //============================================================
      // NEW DOWNTREND -> REMOVE BUY PENDING ORDERS
      //============================================================
      if(newState == STATE_DOWNTREND)
      {
         if(
            type == ORDER_TYPE_BUY_LIMIT ||
            type == ORDER_TYPE_BUY_STOP
         )
         {
            deleteOrder = true;
         }
      }

      if(deleteOrder)
      {
         if(trade.OrderDelete(ticket))
         {
            DebugPrint(
               "Deleted opposite pending order. Ticket=" +
               IntegerToString(
                  (int)ticket
               )
            );
         }
         else
         {
            DebugPrint(
               "Could not delete pending order. Ticket=" +
               IntegerToString(
                  (int)ticket
               ) +
               " Error=" +
               trade.ResultRetcodeDescription()
            );
         }
      }
   }
}

//-------------------------------------------------------------------
// MANAGE PENDING ORDERS
//-------------------------------------------------------------------
void ManagePendingOrders()
{
   // Broker handles specified expiration.
   //
   // No new signal is generated here.
}

//-------------------------------------------------------------------
// STATE TO STRING
//-------------------------------------------------------------------
string StateToString(
   MarketState state
)
{
   switch(state)
   {
      case STATE_UPTREND:
         return "UPTREND";

      case STATE_DOWNTREND:
         return "DOWNTREND";

      case STATE_SIDEWAYS:
         return "SIDEWAYS";

      case STATE_REVERSAL:
         return "REVERSAL";

      case STATE_UNCERTAIN:
         return "UNCERTAIN";
   }

   return "UNKNOWN";
}

//+------------------------------------------------------------------+
