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
//|                                                                  |
//|  v3.00: TREND CONTINUATION + COMPLETE TREND REVERSAL PROTECTION  |
//|                                                                  |
//|  The original strategy above is unchanged. A trading state       |
//|  machine now decides WHEN it may place orders:                   |
//|                                                                  |
//|    UPTREND / DOWNTREND                                           |
//|      -> original pending-order strategy (pullbacks tolerated)    |
//|    SIDEWAYS / UNCERTAIN                                          |
//|      -> no new orders until a trend is confirmed                 |
//|    REVERSAL_DETECTED (multi-factor, multi-candle confirmation)   |
//|      -> cancel ALL EA pending orders                             |
//|      -> close  ALL EA open positions (activated pendings too)    |
//|      -> verify nothing is left, reset the old trend data         |
//|    WAITING_FOR_NEW_TREND                                         |
//|      -> no new orders until a NEW trend is confirmed, then the   |
//|         original strategy resumes in the new direction           |
//|                                                                  |
//|  Only orders/positions with THIS symbol AND InpMagicNumber are   |
//|  ever cancelled or closed. Manual trades are never touched.      |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property description "M1-only EMA9 trend-based pending-order EA - trend confirmed independently of signal candle"
#property description "v3.00: trend-reversal protection - cancels EA pending orders, closes EA positions, waits for a new trend"

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
// TRADING STATES (v3.00 REVERSAL PROTECTION STATE MACHINE)
//
// MarketState above is the ORIGINAL per-candle classification and is
// unchanged. Its STATE_REVERSAL value is only a one-candle warning
// (no new order on that candle, nothing is closed).
//
// TradingState is the EA-level state. It decides whether the original
// strategy may place orders and when the complete reversal cleanup
// (cancel pendings + close positions) must run.
//-------------------------------------------------------------------
enum TradingState
{
   TSTATE_UPTREND = 0,            // confirmed uptrend   -> bullish pending-order process
   TSTATE_DOWNTREND,              // confirmed downtrend -> bearish pending-order process
   TSTATE_SIDEWAYS_UNCERTAIN,     // no confirmed trend  -> no new orders
   TSTATE_REVERSAL_DETECTED,      // reversal confirmed  -> cleanup running, no new orders
   TSTATE_WAITING_FOR_NEW_TREND   // cleanup verified    -> no new orders until a new trend
};

//-------------------------------------------------------------------
// REVERSAL FACTORS (one bit per independent confirmation)
//-------------------------------------------------------------------
#define REV_F_EMA_SLOPE       1     // F1 EMA turned against the trend
#define REV_F_PRICE_CROSS     2     // F2 signal candle closed beyond the EMA
#define REV_F_CONSEC_CLOSES   4     // F3 consecutive closes beyond the EMA
#define REV_F_SWING_BREAK     8     // F4 close broke the recent swing low/high
#define REV_F_STRUCTURE       16    // F5 lower high + lower low (or HH + HL)
#define REV_F_STRONG_CANDLE   32    // F6 strong opposite-direction candle
#define REV_F_MOMENTUM        64    // F7 EMA momentum weakening
#define REV_F_TREND_LOST      128   // F8 original trend conditions not satisfied
#define REV_F_OPPOSITE_TREND  256   // F9 original logic classifies the opposite trend

// factors that prove a change of price structure
#define REV_F_STRUCTURAL      (REV_F_SWING_BREAK | REV_F_STRUCTURE | REV_F_OPPOSITE_TREND)

//-------------------------------------------------------------------
// STRUCTURE REQUIRED FOR A REVERSAL CONFIRMATION
//-------------------------------------------------------------------
enum ReversalStructureMode
{
   REV_STRUCT_NONE = 0,         // Not required
   REV_STRUCT_SWING_BREAK,      // Swing low/high break (F4) - recommended
   REV_STRUCT_ANY               // Any of F4 swing break, F5 structure, F9 opposite trend
};

#define REV_FACTOR_COUNT      9
#define CLASS_HISTORY_SIZE    64    // per-candle classifications kept for confirmations

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

//--- Trend state machine (v3.00)
input group "=== TREND STATE MACHINE (v3.00) ==="
input bool InpUseReversalProtection       = true;  // Enable trend-reversal protection (false = original v2.10 behaviour)
input int  InpTrendConfirmBars            = 1;     // Trend candles in a row to confirm a trend from SIDEWAYS/UNCERTAIN (1 = original)
input int  InpNewTrendConfirmBars         = 3;     // Trend candles needed to confirm a NEW trend after a reversal
input int  InpNewTrendWindowBars          = 6;     // ...within this many latest candles, with no opposite-trend candle
input int  InpTrendInvalidationBars       = 15;    // Candles in a row without a trend candle -> trend invalidated (0 = off)
input bool InpCancelPendingOnInvalidation = true;  // Cancel stale EA pending orders when the trend is invalidated

//--- Reversal confirmation (v3.00)
input group "=== REVERSAL CONFIRMATION (v3.00) ==="
input int  InpRevMinScore         = 4;     // Min reversal factors on one candle to count as one confirmation
input int  InpRevConfirmCandles   = 2;     // Confirmation candles required -> REVERSAL CONFIRMED
input int  InpRevWindowBars       = 5;     // Confirmations must occur within this many candles
input ReversalStructureMode InpRevStructureMode = REV_STRUCT_SWING_BREAK; // Structure a confirmation needs (a pullback keeps the last swing low/high)
input bool InpRevRequireEmaCross  = true;  // A confirmation needs the close beyond the EMA (F2) - ignores consolidation noise
input bool InpRevIgnoreSideways   = true;  // Candles the original logic classifies SIDEWAYS never count (consolidation is not a reversal)
input int  InpRevInstantScore     = 6;     // Factors on ONE strong opposite candle that confirm at once (0 = off)

//--- Reversal factors (v3.00)
input group "=== REVERSAL FACTORS (v3.00) ==="
input bool   InpRevUseEmaSlope      = true;  // F1: EMA turned against the trend
input int    InpRevEmaSlopeBars     = 2;     //     EMA candles in a row moving against the trend
input bool   InpRevUsePriceCross    = true;  // F2: signal candle closed on the opposite side of the EMA
input bool   InpRevUseConsecCloses  = true;  // F3: consecutive closes on the opposite side of the EMA
input int    InpRevConsecCloses     = 2;     //     number of consecutive closes
input bool   InpRevUseSwingBreak    = true;  // F4: close broke the recent swing low (uptrend) / swing high (downtrend)
input int    InpRevSwingLookback    = 30;    //     candles searched for the swing point
input int    InpRevSwingStrength    = 3;     //     candles on each side of a swing point
input double InpRevMinBreakPoints   = 10.0;  //     F2/F3/F4: min distance (points) a close must be beyond the EMA / swing level
input bool   InpRevUseStructure     = true;  // F5: structure change (lower high + lower low / higher high + higher low)
input int    InpRevStructureBars    = 4;     //     candles per structure block
input bool   InpRevUseStrongCandle  = true;  // F6: strong opposite-direction candle
input double InpRevStrongBodyMult   = 2.0;   //     body >= this x average body
input int    InpRevAvgBodyBars      = 10;    //     candles used for the average body
input bool   InpRevUseMomentum      = true;  // F7: momentum weakening (EMA slope)
input int    InpRevMomentumBars     = 3;     //     EMA slope window (candles)
input double InpRevMomentumRatio    = 0.5;   //     weak when current slope < ratio x previous slope
input bool   InpRevUseTrendLost     = true;  // F8: original trend conditions no longer satisfied
input bool   InpRevUseOppositeTrend = true;  // F9: original logic classifies the opposite trend

//--- Cleanup and restart recovery (v3.00)
input group "=== CLEANUP & RECOVERY (v3.00) ==="
input int InpCleanupRetries      = 3;      // Immediate retries per ticket on transient trade errors
input int InpCleanupRetryDelayMs = 250;    // Delay between immediate retries (ms)
input int InpRecoveryBars        = 300;    // Completed M1 candles replayed to rebuild the state after a restart

//-------------------------------------------------------------------
// GLOBAL VARIABLES
//-------------------------------------------------------------------
int          g_emaHandle       = INVALID_HANDLE;
datetime     g_lastProcessedBar = 0;
MarketState  g_previousState   = STATE_UNCERTAIN;

//-------------------------------------------------------------------
// GLOBAL VARIABLES - TREND STATE MACHINE / REVERSAL PROTECTION (v3.00)
//-------------------------------------------------------------------
TradingState g_tradeState       = TSTATE_SIDEWAYS_UNCERTAIN;
int          g_protectDir       = 0;     // trend whose orders/positions are protected: +1 buy, -1 sell, 0 none
int          g_lastTrendDir     = 0;     // last confirmed trend direction
int          g_invalidatedDir   = 0;     // trend direction invalidated by the last confirmed reversal
int          g_revCount         = 0;     // reversal confirmations in the current sequence
int          g_revAge           = 0;     // candles since the first confirmation of the sequence
int          g_nonTrendCount    = 0;     // candles in a row without a trend-direction classification
int          g_stateCandles     = 0;     // candles processed since the last trading-state change
int          g_classHist[CLASS_HISTORY_SIZE];  // latest per-candle classifications (oldest first)
int          g_classHistCount   = 0;
datetime     g_lastCleanupTry   = 0;     // time of the last cleanup attempt (retry throttling)
int          g_cleanupAttempts  = 0;
datetime     g_lastReversalTime = 0;     // candle time of the last confirmed reversal
bool         g_recoveryDone     = false; // restart recovery executed
bool         g_isReplaying      = false; // true while history is replayed (no trading, no logging)
int          g_shiftOffset      = 0;     // added to every M1 series shift; non-zero ONLY during the replay

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
   // INPUT VALIDATION - REVERSAL PROTECTION (v3.00)
   //===============================================================
   if(!ValidateProtectionInputs())
      return(INIT_PARAMETERS_INCORRECT);

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
   // REVERSAL PROTECTION STATE (v3.00)
   //
   // MT5 keeps global variables when an EA is re-initialised (input
   // change, chart symbol/period change), so every state variable is
   // reset here. The real state is rebuilt by RecoverState() on the
   // first tick from M1 history + the EA's existing orders/positions.
   //===============================================================
   ResetTradingState();

   g_tradeState       = TSTATE_SIDEWAYS_UNCERTAIN;
   g_lastTrendDir     = 0;
   g_invalidatedDir   = 0;
   g_lastReversalTime = 0;
   g_recoveryDone     = false;
   g_isReplaying      = false;
   g_shiftOffset      = 0;

   if(
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) !=
      ACCOUNT_MARGIN_MODE_RETAIL_HEDGING
   )
   {
      LogEvent(
         "Init",
         "WARNING: NETTING account. MT5 keeps ONE combined position per symbol, "
         "so a manual trade on " + _Symbol + " merges with the EA position and "
         "would be closed together with it. Use a hedging account or do not "
         "trade this symbol manually while the EA runs."
      );
   }

   if(InpUseReversalProtection)
   {
      LogEvent(
         "Init",
         StringFormat(
            "Reversal protection ON: %d confirmation candle(s) with >= %d of %d "
            "factors within %d candles (instant: %d factors on a strong candle). "
            "New trend after a reversal: %d of the last %d candles.",
            InpRevConfirmCandles,
            InpRevMinScore,
            CountEnabledFactors(),
            InpRevWindowBars,
            InpRevInstantScore,
            InpNewTrendConfirmBars,
            MathMax(InpNewTrendWindowBars, InpNewTrendConfirmBars)
         )
      );
   }
   else
   {
      LogEvent(
         "Init",
         "Reversal protection OFF - original v2.10 behaviour."
      );
   }

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

   if(InpUseReversalProtection)
   {
      LogEvent(
         "State",
         StringFormat(
            "EA stopped in state %s (%d EA pending order(s), %d EA position(s)). "
            "The state is rebuilt on the next start.",
            TradeStateToString(g_tradeState),
            CountEAPendingOrdersAll(),
            CountEAPositions()
         )
      );
   }
}

//-------------------------------------------------------------------
// ON TICK
//-------------------------------------------------------------------
void OnTick()
{
   //===============================================================
   // EVERYTHING USES M1
   //
   // EXECUTION PRIORITY (v3.00):
   //   0. Restart recovery (once): rebuild the trading state
   //   1. Manage existing EA positions + retry an unfinished
   //      reversal cleanup (risk actions are never candle-gated)
   //   2. New completed M1 candle -> original market classification
   //   3. Trend-reversal check -> cancel pendings + close positions
   //      (no order is ever placed on the cleanup candle/tick)
   //   4. WAITING_FOR_NEW_TREND -> new-trend confirmation
   //   5. Valid trend -> original pending-order strategy
   //===============================================================

   //--- 0. RESTART / RECOVERY
   if(!g_recoveryDone)
   {
      if(!RecoverState())
         return;   // M1 history / EMA not ready yet - retry on the next tick
   }

   //--- 1. MANAGE EXISTING EA POSITIONS
   ManageOpenPositions();

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
   // TREND STATE MACHINE + REVERSAL PROTECTION (v3.00)
   //
   // Runs BEFORE any order logic. When a reversal is confirmed here,
   // all EA pending orders are cancelled and all EA positions are
   // closed immediately, and NO order is placed on this candle.
   // false = the state machine does not allow an order on this
   // candle; true = the original rules below decide as before.
   //===============================================================
   bool tradingAllowed =
      ManageTrendState(
         state,
         signalCandle.time
      );

   if(InpUseReversalProtection)
   {
      DebugEvent(
         StringFormat(
            "Trade State = %s | reversal confirmations %d/%d | candles without trend %d",
            TradeStateToString(g_tradeState),
            g_revCount,
            InpRevConfirmCandles,
            g_nonTrendCount
         )
      );
   }

   if(!tradingAllowed)
   {
      g_previousState = state;
      return;
   }

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

   // g_shiftOffset is 0 in live trading; only the restart replay
   // (RecoverState) sets it to evaluate historical candles.
   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      shift + g_shiftOffset,
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

   // g_shiftOffset is 0 in live trading (replay only)
   int copied = CopyBuffer(
      g_emaHandle,
      0,
      shift + g_shiftOffset,
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

   // g_shiftOffset is 0 in live trading (replay only)
   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      1 + g_shiftOffset,
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

   // g_shiftOffset is 0 in live trading (replay only)
   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      startShift + g_shiftOffset,
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

   // g_shiftOffset is 0 in live trading (replay only)
   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      startShift + g_shiftOffset,
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

   // g_shiftOffset is 0 in live trading (replay only)
   int copied = CopyRates(
      _Symbol,
      EA_TIMEFRAME,
      1 + g_shiftOffset,
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

//===================================================================
//===================================================================
//
//   v3.00 - TREND STATE MACHINE + COMPLETE TREND REVERSAL PROTECTION
//
//   Everything below is new. The original strategy functions above
//   are unchanged apart from the replay offset (g_shiftOffset) in the
//   M1 data-access calls.
//
//===================================================================
//===================================================================

//-------------------------------------------------------------------
// LOG EVENT
//
// State, reversal and cleanup messages are ALWAYS printed (they do
// not depend on InpDebugLog) so the Experts journal shows exactly why
// the EA stopped, closed trades and restarted.
// Nothing is printed while history is replayed after a restart.
//-------------------------------------------------------------------
void LogEvent(string tag, string message)
{
   if(g_isReplaying)
      return;

   Print("[M1 EMA9 EA] [", tag, "] ", message);
}

//-------------------------------------------------------------------
// DEBUG EVENT (detail messages, controlled by InpDebugLog)
//-------------------------------------------------------------------
void DebugEvent(string message)
{
   if(InpDebugLog && !g_isReplaying)
      Print("[M1 EMA9 EA] ", message);
}

//-------------------------------------------------------------------
// TEXT HELPERS
//-------------------------------------------------------------------
string TradeStateToString(TradingState tradingState)
{
   switch(tradingState)
   {
      case TSTATE_UPTREND:
         return "UPTREND";

      case TSTATE_DOWNTREND:
         return "DOWNTREND";

      case TSTATE_SIDEWAYS_UNCERTAIN:
         return "SIDEWAYS/UNCERTAIN";

      case TSTATE_REVERSAL_DETECTED:
         return "REVERSAL_DETECTED";

      case TSTATE_WAITING_FOR_NEW_TREND:
         return "WAITING_FOR_NEW_TREND";
   }

   return "UNKNOWN";
}

string DirToString(int dir)
{
   if(dir > 0)
      return "UPTREND";

   if(dir < 0)
      return "DOWNTREND";

   return "NONE";
}

string TicketToString(ulong ticket)
{
   return IntegerToString((long)ticket);
}

string OrderTypeName(ENUM_ORDER_TYPE type)
{
   switch(type)
   {
      case ORDER_TYPE_BUY_LIMIT:
         return "BUY LIMIT";

      case ORDER_TYPE_BUY_STOP:
         return "BUY STOP";

      case ORDER_TYPE_SELL_LIMIT:
         return "SELL LIMIT";

      case ORDER_TYPE_SELL_STOP:
         return "SELL STOP";

      case ORDER_TYPE_BUY_STOP_LIMIT:
         return "BUY STOP LIMIT";

      case ORDER_TYPE_SELL_STOP_LIMIT:
         return "SELL STOP LIMIT";

      default:
         break;
   }

   return EnumToString(type);
}

//-------------------------------------------------------------------
// ORIGINAL TREND CLASSIFICATION OF A DIRECTION (+1 up / -1 down)
//-------------------------------------------------------------------
MarketState TrendStateOf(int dir)
{
   if(dir > 0)
      return STATE_UPTREND;

   return STATE_DOWNTREND;
}

//-------------------------------------------------------------------
// INPUT VALIDATION - REVERSAL PROTECTION
//-------------------------------------------------------------------
bool ValidateProtectionInputs()
{
   if(!InpUseReversalProtection)
      return true;

   bool ok = true;

   if(InpTrendConfirmBars < 1 || InpTrendConfirmBars > CLASS_HISTORY_SIZE)
   {
      Print("ERROR: InpTrendConfirmBars must be 1..", CLASS_HISTORY_SIZE, ".");
      ok = false;
   }

   if(InpNewTrendConfirmBars < 1)
   {
      Print("ERROR: InpNewTrendConfirmBars must be >= 1.");
      ok = false;
   }

   if(
      InpNewTrendWindowBars < InpNewTrendConfirmBars ||
      InpNewTrendWindowBars > CLASS_HISTORY_SIZE
   )
   {
      Print("ERROR: InpNewTrendWindowBars must be between InpNewTrendConfirmBars and ", CLASS_HISTORY_SIZE, ".");
      ok = false;
   }

   if(InpTrendInvalidationBars < 0)
   {
      Print("ERROR: InpTrendInvalidationBars must be >= 0.");
      ok = false;
   }

   if(InpRevMinScore < 1 || InpRevMinScore > REV_FACTOR_COUNT)
   {
      Print("ERROR: InpRevMinScore must be 1..", REV_FACTOR_COUNT, ".");
      ok = false;
   }

   if(InpRevConfirmCandles < 1)
   {
      Print("ERROR: InpRevConfirmCandles must be >= 1.");
      ok = false;
   }

   if(InpRevWindowBars < InpRevConfirmCandles)
   {
      Print("ERROR: InpRevWindowBars must be >= InpRevConfirmCandles.");
      ok = false;
   }

   if(InpRevInstantScore < 0 || InpRevInstantScore > REV_FACTOR_COUNT)
   {
      Print("ERROR: InpRevInstantScore must be 0 (off) or 1..", REV_FACTOR_COUNT, ".");
      ok = false;
   }

   if(
      InpRevEmaSlopeBars < 1 ||
      InpRevConsecCloses < 1 ||
      InpRevSwingStrength < 1 ||
      InpRevSwingLookback <= InpRevSwingStrength ||
      InpRevStructureBars < 1 ||
      InpRevAvgBodyBars < 1 ||
      InpRevMomentumBars < 1
   )
   {
      Print("ERROR: reversal factor lookbacks must be >= 1 and InpRevSwingLookback > InpRevSwingStrength.");
      ok = false;
   }

   if(
      InpRevStrongBodyMult <= 0.0 ||
      InpRevMomentumRatio < 0.0 ||
      InpRevMomentumRatio > 1.0 ||
      InpRevMinBreakPoints < 0.0
   )
   {
      Print("ERROR: InpRevStrongBodyMult must be > 0, InpRevMomentumRatio 0..1 and InpRevMinBreakPoints >= 0.");
      ok = false;
   }

   if(
      InpCleanupRetries < 1 ||
      InpCleanupRetryDelayMs < 0 ||
      InpRecoveryBars < 0
   )
   {
      Print("ERROR: InpCleanupRetries must be >= 1, InpCleanupRetryDelayMs and InpRecoveryBars >= 0.");
      ok = false;
   }

   int enabledFactors = CountEnabledFactors();

   if(enabledFactors < InpRevMinScore)
   {
      Print(
         "ERROR: only ", enabledFactors, " reversal factors are enabled but InpRevMinScore = ",
         InpRevMinScore, " - a reversal could never be confirmed."
      );
      ok = false;
   }

   if(InpRevStructureMode == REV_STRUCT_SWING_BREAK && !InpRevUseSwingBreak)
   {
      Print("ERROR: InpRevStructureMode = swing break needs F4 (InpRevUseSwingBreak) enabled.");
      ok = false;
   }

   if(
      InpRevStructureMode == REV_STRUCT_ANY &&
      !InpRevUseSwingBreak &&
      !InpRevUseStructure &&
      !InpRevUseOppositeTrend
   )
   {
      Print("ERROR: InpRevStructureMode = any needs F4, F5 or F9 enabled.");
      ok = false;
   }

   if(InpRevRequireEmaCross && !InpRevUsePriceCross)
   {
      Print("ERROR: InpRevRequireEmaCross needs F2 (InpRevUsePriceCross) enabled.");
      ok = false;
   }

   return ok;
}

//-------------------------------------------------------------------
// CANDLE CLASSIFICATION HISTORY
//
// Keeps the original per-candle classification of the latest
// candles. Used for trend confirmations. Cleared by every reversal
// cleanup so a new trend can only be confirmed by candles that
// closed AFTER the cleanup (no carry-over from the old trend).
//-------------------------------------------------------------------
void PushClassification(MarketState state)
{
   if(g_classHistCount >= CLASS_HISTORY_SIZE)
   {
      for(int i = 1; i < CLASS_HISTORY_SIZE; i++)
         g_classHist[i - 1] = g_classHist[i];

      g_classHistCount = CLASS_HISTORY_SIZE - 1;
   }

   g_classHist[g_classHistCount] = (int)state;
   g_classHistCount++;
}

int CountRecentClassifications(MarketState state, int window)
{
   int span  = MathMin(window, g_classHistCount);
   int count = 0;

   for(int i = g_classHistCount - span; i < g_classHistCount; i++)
   {
      if(g_classHist[i] == (int)state)
         count++;
   }

   return count;
}

//-------------------------------------------------------------------
// RESET TRADING STATE
//
// Clears everything that belongs to the old trend: protected
// direction, reversal counters, trend-invalidation counter, cleanup
// bookkeeping and the classification history. The original per-
// candle classification memory (g_previousState) is not touched.
//-------------------------------------------------------------------
void ResetTradingState()
{
   g_protectDir      = 0;
   g_revCount        = 0;
   g_revAge          = 0;
   g_nonTrendCount   = 0;
   g_stateCandles    = 0;
   g_classHistCount  = 0;
   g_lastCleanupTry  = 0;
   g_cleanupAttempts = 0;
}

//===================================================================
// OWNERSHIP + EXPOSURE (EVERY CHECK FILTERS BY SYMBOL AND MAGIC)
//===================================================================

//-------------------------------------------------------------------
// Pending types removed by the cleanup: every pending type, including
// stop-limit orders, in case one with this EA's magic exists.
//-------------------------------------------------------------------
bool IsCleanupPendingType(ENUM_ORDER_TYPE type)
{
   return(
      type == ORDER_TYPE_BUY_LIMIT ||
      type == ORDER_TYPE_BUY_STOP ||
      type == ORDER_TYPE_SELL_LIMIT ||
      type == ORDER_TYPE_SELL_STOP ||
      type == ORDER_TYPE_BUY_STOP_LIMIT ||
      type == ORDER_TYPE_SELL_STOP_LIMIT
   );
}

bool IsBuySideOrderType(ENUM_ORDER_TYPE type)
{
   return(
      type == ORDER_TYPE_BUY_LIMIT ||
      type == ORDER_TYPE_BUY_STOP ||
      type == ORDER_TYPE_BUY_STOP_LIMIT
   );
}

//-------------------------------------------------------------------
// The currently selected order belongs to this EA (symbol + magic)
//-------------------------------------------------------------------
bool IsEAOrderSelected()
{
   return(
      OrderGetString(ORDER_SYMBOL) == _Symbol &&
      (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber
   );
}

//-------------------------------------------------------------------
// The currently selected position belongs to this EA (symbol + magic)
//-------------------------------------------------------------------
bool IsEAPositionSelected()
{
   return(
      PositionGetString(POSITION_SYMBOL) == _Symbol &&
      (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
   );
}

int CountEAPendingOrdersAll()
{
   int count = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      if(!IsEAOrderSelected())
         continue;

      if(IsCleanupPendingType((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)))
         count++;
   }

   return count;
}

int CountEAPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(IsEAPositionSelected())
         count++;
   }

   return count;
}

//-------------------------------------------------------------------
// EA exposure per side: pending orders + open positions
//-------------------------------------------------------------------
void GetEAExposure(int &buySide, int &sellSide)
{
   buySide  = 0;
   sellSide = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      if(!IsEAOrderSelected())
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(!IsCleanupPendingType(type))
         continue;

      if(IsBuySideOrderType(type))
         buySide++;
      else
         sellSide++;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(!IsEAPositionSelected())
         continue;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         buySide++;
      else
         sellSide++;
   }
}

bool HasEAExposure(int dir)
{
   int buySide  = 0;
   int sellSide = 0;

   GetEAExposure(buySide, sellSide);

   if(dir > 0)
      return(buySide > 0);

   if(dir < 0)
      return(sellSide > 0);

   return false;
}

//-------------------------------------------------------------------
// Exposure check used by the state machine. During the restart
// replay the historical positions are unknown, so the positions of
// the last trend are assumed to still be open (the safer choice).
//-------------------------------------------------------------------
bool HasProtectedExposure(int dir)
{
   if(g_isReplaying)
      return(dir != 0 && g_protectDir == dir);

   return HasEAExposure(dir);
}

//===================================================================
// TREND STATE MACHINE
//===================================================================

//-------------------------------------------------------------------
// MANAGE TREND STATE  (once per completed M1 candle)
//
// Returns true  -> the ORIGINAL strategy code may run for this candle
//                  (it still applies all of its own rules).
// Returns false -> no new order on this candle.
//
// Order of checks:
//   1. reversal cleanup still in progress -> retry, no orders
//   2. trend-reversal check (HIGHEST PRIORITY) -> cleanup
//   3. WAITING_FOR_NEW_TREND -> new-trend confirmation
//   4. SIDEWAYS/UNCERTAIN    -> trend confirmation
//   5. UPTREND/DOWNTREND     -> continuation, pullback, invalidation
//-------------------------------------------------------------------
bool ManageTrendState(MarketState state, datetime candleTime)
{
   //--- protection disabled -> original v2.10 behaviour
   if(!InpUseReversalProtection)
      return true;

   PushClassification(state);
   g_stateCandles++;

   //===============================================================
   // 1. A CONFIRMED REVERSAL IS STILL BEING CLEANED UP
   //===============================================================
   if(g_tradeState == TSTATE_REVERSAL_DETECTED)
   {
      ProcessReversalCleanup(true);

      DebugEvent("NO ORDER: reversal cleanup in progress.");
      return false;
   }

   //===============================================================
   // 2. TREND REVERSAL CHECK (HIGHEST PRIORITY)
   //===============================================================
   if(ShouldMonitorReversal())
   {
      string reason = "";

      if(IsTrendReversalConfirmed(state, candleTime, reason))
      {
         TriggerReversalProtection(reason, candleTime);

         // Never place a new order on the candle/tick of the cleanup.
         return false;
      }
   }

   //===============================================================
   // 3. WAITING FOR A NEW TREND AFTER A REVERSAL
   //===============================================================
   if(g_tradeState == TSTATE_WAITING_FOR_NEW_TREND)
   {
      int newDir = 0;

      if(
         IsNewTrendConfirmed(
            state,
            InpNewTrendConfirmBars,
            InpNewTrendWindowBars,
            newDir
         )
      )
      {
         EnterTrend(newDir, true, candleTime);

         // The confirmation candle is a valid trend candle: the
         // original strategy decides its order as usual.
         return true;
      }

      LogWaitingProgress(state);
      return false;
   }

   //===============================================================
   // 4. SIDEWAYS / UNCERTAIN: WAIT FOR A CONFIRMED TREND
   //===============================================================
   if(g_tradeState == TSTATE_SIDEWAYS_UNCERTAIN)
   {
      // Not a trend candle: the original rules print "NO ORDER".
      if(state != STATE_UPTREND && state != STATE_DOWNTREND)
         return true;

      int dir = 0;

      if(
         !IsNewTrendConfirmed(
            state,
            InpTrendConfirmBars,
            InpTrendConfirmBars,
            dir
         )
      )
      {
         DebugEvent(
            StringFormat(
               "NO ORDER: %s candle %d/%d needed to confirm the trend.",
               StateToString(state),
               CountRecentClassifications(state, InpTrendConfirmBars),
               InpTrendConfirmBars
            )
         );
         return false;
      }

      // A trend opposite to still-open EA positions is a reversal
      // against those positions: the reversal detector decides, the
      // opposite side is not traded before they are closed.
      if(HasProtectedExposure(-dir))
      {
         DebugEvent(
            "NO ORDER: " + StateToString(state) + " candle while EA " +
            (dir > 0 ? "SELL" : "BUY") +
            " exposure is still open - waiting for the reversal detector."
         );
         return false;
      }

      EnterTrend(dir, false, candleTime);
      return true;
   }

   //===============================================================
   // 5. ACTIVE TREND (UPTREND / DOWNTREND)
   //===============================================================
   int trendDir = (g_tradeState == TSTATE_UPTREND) ? 1 : -1;

   //--- trend continues -> original strategy places its order
   if(state == TrendStateOf(trendDir))
   {
      g_nonTrendCount = 0;
      return true;
   }

   g_nonTrendCount++;

   //--- prolonged sideways / uncertain market invalidates the trend
   if(
      InpTrendInvalidationBars > 0 &&
      g_nonTrendCount >= InpTrendInvalidationBars
   )
   {
      InvalidateTrend(candleTime);
      return false;
   }

   //--- opposite trend candle: never traded before the old trend's
   //--- exposure is cleaned up through REVERSAL -> WAITING -> NEW TREND
   if(state == TrendStateOf(-trendDir))
   {
      DebugEvent(
         "NO ORDER: " + StateToString(state) + " candle inside an active " +
         DirToString(trendDir) + " - reversal not confirmed yet."
      );
      return false;
   }

   // SIDEWAYS / REVERSAL warning / UNCERTAIN inside the trend is a
   // normal pullback: the original rules print "NO ORDER" for it and
   // the trend (and its orders/positions) stays active.
   return true;
}

//-------------------------------------------------------------------
// SHOULD MONITOR REVERSAL
//
// UPTREND/DOWNTREND: always. SIDEWAYS/UNCERTAIN: only while EA
// positions/orders of one side are still open (after a trend was
// invalidated by sideways, or found at restart).
//-------------------------------------------------------------------
bool ShouldMonitorReversal()
{
   if(
      g_tradeState == TSTATE_UPTREND ||
      g_tradeState == TSTATE_DOWNTREND
   )
   {
      return(g_protectDir != 0);
   }

   if(g_tradeState != TSTATE_SIDEWAYS_UNCERTAIN)
      return false;

   if(g_isReplaying)
      return(g_protectDir != 0);

   int buySide  = 0;
   int sellSide = 0;

   GetEAExposure(buySide, sellSide);

   int exposureDir = 0;

   if(buySide > 0 && sellSide == 0)
      exposureDir = 1;
   else if(sellSide > 0 && buySide == 0)
      exposureDir = -1;
   else
      return false;

   if(exposureDir != g_protectDir)
   {
      g_protectDir = exposureDir;
      g_revCount   = 0;
      g_revAge     = 0;
   }

   return true;
}

//-------------------------------------------------------------------
// IS TREND REVERSAL CONFIRMED  (once per completed candle)
//
// The completed signal candle is scored against the protected trend.
// A candle with >= InpRevMinScore factors - including the required
// structure (InpRevStructureMode, default: swing break) and a close
// beyond the EMA (InpRevRequireEmaCross) - is ONE confirmation.
// Candles classified SIDEWAYS by the original logic never count
// (InpRevIgnoreSideways): consolidation is not a reversal.
//
// REVERSAL CONFIRMED when:
//   a) InpRevConfirmCandles confirmations occur within
//      InpRevWindowBars candles without the trend being restored, or
//   b) ONE strong opposite candle shows >= InpRevInstantScore
//      factors (crash protection; never a small candle), or
//   c) backstop: the original logic classified the OPPOSITE trend on
//      InpNewTrendConfirmBars of the last InpNewTrendWindowBars
//      candles (the old trend can never stay active against an
//      established opposite trend).
//
// A candle on which the original trend conditions are satisfied
// again clears the warning: it was a normal pullback.
//-------------------------------------------------------------------
bool IsTrendReversalConfirmed(MarketState state, datetime candleTime, string &reason)
{
   reason = "";

   int dir = g_protectDir;

   if(dir == 0)
      return false;

   string against = DirToString(dir);

   //--- confirmations expire when the window is over
   if(g_revCount > 0)
   {
      g_revAge++;

      if(g_revAge >= InpRevWindowBars)
      {
         LogEvent(
            "Reversal",
            StringFormat(
               "Confirmations expired (%d/%d within %d candles) - treated as a normal pullback, %s continues.",
               g_revCount,
               InpRevConfirmCandles,
               InpRevWindowBars,
               against
            )
         );

         g_revCount = 0;
         g_revAge   = 0;
      }
   }

   //--- reversal factors of the completed candle
   int factors = 0;
   int score   = ComputeReversalScore(dir, state, factors);

   if(score < 0)
   {
      DebugEvent("Reversal check skipped: M1 data not ready.");
      return false;
   }

   // Mandatory parts of a confirmation: a change of price structure
   // and the close on the opposite side of the EMA. A normal pullback
   // keeps the last swing low (uptrend) / swing high (downtrend).
   bool structureOk = true;

   if(InpRevStructureMode == REV_STRUCT_SWING_BREAK)
      structureOk = ((factors & REV_F_SWING_BREAK) != 0);
   else if(InpRevStructureMode == REV_STRUCT_ANY)
      structureOk = ((factors & REV_F_STRUCTURAL) != 0);

   bool emaCrossOk =
      (!InpRevRequireEmaCross || (factors & REV_F_PRICE_CROSS) != 0);

   // The original sideways filter defines consolidation: such a candle
   // is never a reversal confirmation (a real breakdown leaves the
   // sideways classification as soon as the range expands).
   bool notSideways =
      (!InpRevIgnoreSideways || state != STATE_SIDEWAYS);

   bool isConfirmation =
      (score >= InpRevMinScore && structureOk && emaCrossOk && notSideways);

   bool isInstant =
      (InpRevInstantScore > 0 &&
       score >= InpRevInstantScore &&
       structureOk &&
       emaCrossOk &&
       notSideways &&
       (factors & REV_F_STRONG_CANDLE) != 0);

   if(isConfirmation)
   {
      if(g_revCount == 0)
      {
         g_revAge = 0;

         LogEvent(
            "Trend",
            "Possible reversal detected against " + against + " on candle " +
            TimeToString(candleTime, TIME_DATE | TIME_MINUTES)
         );
      }

      g_revCount++;

      LogEvent(
         "Reversal",
         StringFormat(
            "Confirmation %d/%d (score %d/%d: %s)",
            g_revCount,
            InpRevConfirmCandles,
            score,
            CountEnabledFactors(),
            ReversalFactorsToString(factors)
         )
      );
   }
   else if(state == TrendStateOf(dir))
   {
      if(g_revCount > 0)
      {
         LogEvent(
            "Reversal",
            "Warning cleared - " + against + " conditions restored (normal pullback)."
         );
      }

      g_revCount = 0;
      g_revAge   = 0;
   }
   else if(score >= MathMax(2, InpRevMinScore - 1))
   {
      DebugEvent(
         StringFormat(
            "[Reversal] Warning factors %d/%d (%s) - %s, not a confirmation.",
            score,
            CountEnabledFactors(),
            ReversalFactorsToString(factors),
            !notSideways ? "SIDEWAYS candle (consolidation)" :
            (!structureOk ? "no structure break" : (!emaCrossOk ? "close not beyond the EMA" : "below the minimum score"))
         )
      );
   }

   //--- a) one strong opposite candle with many factors
   if(isInstant)
   {
      reason = StringFormat(
         "strong opposite candle with %d factors (%s)",
         score,
         ReversalFactorsToString(factors)
      );
      return true;
   }

   //--- b) required number of confirmation candles
   if(g_revCount >= InpRevConfirmCandles)
   {
      reason = StringFormat(
         "%d confirmation candle(s), last score %d (%s)",
         g_revCount,
         score,
         ReversalFactorsToString(factors)
      );
      return true;
   }

   //--- c) backstop: opposite trend already established
   int window   = MathMin(MathMax(InpNewTrendWindowBars, InpNewTrendConfirmBars), g_stateCandles);
   int opposite = CountRecentClassifications(TrendStateOf(-dir), window);

   if(opposite >= InpNewTrendConfirmBars)
   {
      reason = StringFormat(
         "opposite %s classified on %d of the last %d candles",
         DirToString(-dir),
         opposite,
         window
      );
      return true;
   }

   return false;
}

//-------------------------------------------------------------------
// BARS / EMA VALUES NEEDED BY THE REVERSAL FACTORS
//-------------------------------------------------------------------
int ReversalBarsNeeded()
{
   int needed = InpRevSwingLookback + InpRevSwingStrength + 1;

   needed = MathMax(needed, 2 * InpRevStructureBars);
   needed = MathMax(needed, InpRevAvgBodyBars + 1);
   needed = MathMax(needed, InpRevConsecCloses);

   return needed + 1;
}

int ReversalEmaNeeded()
{
   int needed = InpRevEmaSlopeBars + 1;

   needed = MathMax(needed, InpRevConsecCloses);
   needed = MathMax(needed, 2 * InpRevMomentumBars + 1);

   return needed;
}

//-------------------------------------------------------------------
// COMPUTE REVERSAL SCORE
//
// dir = protected trend (+1 up, -1 down). Evaluates the completed
// signal candle (shift 1) and the candles before it on M1 with the
// SAME EMA handle the original strategy uses. Returns the number of
// factors present (-1 when M1 data is not available) and the factor
// bit mask in `factors`.
//-------------------------------------------------------------------
int ComputeReversalScore(int dir, MarketState state, int &factors)
{
   factors = 0;

   if(dir == 0)
      return 0;

   int barsNeeded = ReversalBarsNeeded();
   int emaNeeded  = ReversalEmaNeeded();

   MqlRates rates[];
   double   ema[];

   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(ema, true);

   // g_shiftOffset is 0 in live trading (replay only)
   if(CopyRates(_Symbol, EA_TIMEFRAME, 1 + g_shiftOffset, barsNeeded, rates) != barsNeeded)
      return -1;

   if(g_emaHandle == INVALID_HANDLE)
      return -1;

   if(CopyBuffer(g_emaHandle, 0, 1 + g_shiftOffset, emaNeeded, ema) != emaNeeded)
      return -1;

   for(int i = 0; i < emaNeeded; i++)
   {
      if(ema[i] == EMPTY_VALUE || !MathIsValidNumber(ema[i]))
         return -1;
   }

   // Multiplying by d turns every check into "against the trend < 0".
   double d = (double)dir;

   // A close only counts as beyond the EMA / swing level when it is
   // at least this far beyond it (ignores insignificant noise).
   double minBreak = InpRevMinBreakPoints * _Point;

   //--- F1: EMA moved against the trend on the last N candles
   if(InpRevUseEmaSlope)
   {
      bool turned = true;

      for(int i = 0; i < InpRevEmaSlopeBars; i++)
      {
         if((ema[i] - ema[i + 1]) * d >= 0.0)
         {
            turned = false;
            break;
         }
      }

      if(turned)
         factors |= REV_F_EMA_SLOPE;
   }

   //--- F2: signal candle closed on the opposite side of the EMA
   if(InpRevUsePriceCross && (rates[0].close - ema[0]) * d < -minBreak)
      factors |= REV_F_PRICE_CROSS;

   //--- F3: N consecutive closes on the opposite side of the EMA
   if(InpRevUseConsecCloses)
   {
      bool allBeyond = true;

      for(int i = 0; i < InpRevConsecCloses; i++)
      {
         if((rates[i].close - ema[i]) * d >= -minBreak)
         {
            allBeyond = false;
            break;
         }
      }

      if(allBeyond)
         factors |= REV_F_CONSEC_CLOSES;
   }

   //--- F4: close broke the recent swing low (uptrend) / high (downtrend)
   if(InpRevUseSwingBreak)
   {
      double swingLevel = 0.0;

      if(
         FindRecentSwingLevel(rates, barsNeeded, dir, swingLevel) &&
         (rates[0].close - swingLevel) * d < -minBreak
      )
      {
         factors |= REV_F_SWING_BREAK;
      }
   }

   //--- F5: market structure change between two blocks of candles
   if(InpRevUseStructure)
   {
      int blockSize = InpRevStructureBars;

      double recentHigh = rates[0].high;
      double recentLow  = rates[0].low;
      double prevHigh   = rates[blockSize].high;
      double prevLow    = rates[blockSize].low;

      for(int i = 0; i < blockSize; i++)
      {
         recentHigh = MathMax(recentHigh, rates[i].high);
         recentLow  = MathMin(recentLow, rates[i].low);
         prevHigh   = MathMax(prevHigh, rates[i + blockSize].high);
         prevLow    = MathMin(prevLow, rates[i + blockSize].low);
      }

      bool lowerStructure  = (recentHigh < prevHigh && recentLow < prevLow);
      bool higherStructure = (recentHigh > prevHigh && recentLow > prevLow);

      if((dir > 0 && lowerStructure) || (dir < 0 && higherStructure))
         factors |= REV_F_STRUCTURE;
   }

   //--- F6: strong candle against the trend
   if(InpRevUseStrongCandle)
   {
      double body = rates[0].close - rates[0].open;

      if(body * d < 0.0)
      {
         double averageBody = 0.0;

         for(int i = 1; i <= InpRevAvgBodyBars; i++)
            averageBody += MathAbs(rates[i].close - rates[i].open);

         averageBody /= InpRevAvgBodyBars;

         if(MathAbs(body) >= InpRevStrongBodyMult * MathMax(averageBody, _Point))
            factors |= REV_F_STRONG_CANDLE;
      }
   }

   //--- F7: momentum weakening (EMA slope now vs. one window earlier)
   if(InpRevUseMomentum)
   {
      int window = InpRevMomentumBars;

      double slopeNow  = (ema[0] - ema[window]) * d;
      double slopePrev = (ema[window] - ema[2 * window]) * d;

      bool weak = (slopePrev > 0.0)
                  ? (slopeNow < slopePrev * InpRevMomentumRatio)
                  : (slopeNow <= 0.0);

      if(weak)
         factors |= REV_F_MOMENTUM;
   }

   //--- F8: the original trend conditions are no longer satisfied
   if(InpRevUseTrendLost && state != TrendStateOf(dir))
      factors |= REV_F_TREND_LOST;

   //--- F9: the original logic classifies the opposite trend
   if(InpRevUseOppositeTrend && state == TrendStateOf(-dir))
      factors |= REV_F_OPPOSITE_TREND;

   return CountFactorBits(factors);
}

//-------------------------------------------------------------------
// FIND RECENT SWING LEVEL
//
// Most recent confirmed swing LOW (dir > 0) or swing HIGH (dir < 0)
// that formed BEFORE the signal candle: a candle whose low (high) is
// beyond the InpRevSwingStrength candles on each side. If no swing
// exists in the lookback (steady trend without pullbacks), the
// extreme of the last 2*strength+1 candles before the signal candle
// is used. `rates` is a series array (index 0 = signal candle).
//-------------------------------------------------------------------
bool FindRecentSwingLevel(const MqlRates &rates[], int count, int dir, double &level)
{
   int strength = InpRevSwingStrength;
   int last     = MathMin(InpRevSwingLookback, count - 1 - strength);

   for(int i = strength + 1; i <= last; i++)
   {
      bool isSwing = true;

      for(int j = 1; j <= strength && isSwing; j++)
      {
         if(dir > 0)
         {
            // newer candles must not trade below it, older ones must stay above it
            if(rates[i - j].low < rates[i].low || rates[i + j].low <= rates[i].low)
               isSwing = false;
         }
         else
         {
            // newer candles must not trade above it, older ones must stay below it
            if(rates[i - j].high > rates[i].high || rates[i + j].high >= rates[i].high)
               isSwing = false;
         }
      }

      if(isSwing)
      {
         level = (dir > 0) ? rates[i].low : rates[i].high;
         return true;
      }
   }

   //--- fallback: extreme of the most recent candles before the signal candle
   int span = MathMin(2 * strength + 1, count - 1);

   if(span < 1)
      return false;

   level = (dir > 0) ? rates[1].low : rates[1].high;

   for(int i = 2; i <= span; i++)
      level = (dir > 0) ? MathMin(level, rates[i].low) : MathMax(level, rates[i].high);

   return true;
}

int CountFactorBits(int factors)
{
   int count = 0;

   for(int bit = 0; bit < REV_FACTOR_COUNT; bit++)
   {
      if((factors & (1 << bit)) != 0)
         count++;
   }

   return count;
}

int CountEnabledFactors()
{
   int count = 0;

   if(InpRevUseEmaSlope)      count++;
   if(InpRevUsePriceCross)    count++;
   if(InpRevUseConsecCloses)  count++;
   if(InpRevUseSwingBreak)    count++;
   if(InpRevUseStructure)     count++;
   if(InpRevUseStrongCandle)  count++;
   if(InpRevUseMomentum)      count++;
   if(InpRevUseTrendLost)     count++;
   if(InpRevUseOppositeTrend) count++;

   return count;
}

string ReversalFactorsToString(int factors)
{
   string text = "";

   if((factors & REV_F_EMA_SLOPE) != 0)      text += "EMA-turned ";
   if((factors & REV_F_PRICE_CROSS) != 0)    text += "close-beyond-EMA ";
   if((factors & REV_F_CONSEC_CLOSES) != 0)  text += "consecutive-closes-beyond-EMA ";
   if((factors & REV_F_SWING_BREAK) != 0)    text += "swing-break ";
   if((factors & REV_F_STRUCTURE) != 0)      text += "structure-change ";
   if((factors & REV_F_STRONG_CANDLE) != 0)  text += "strong-opposite-candle ";
   if((factors & REV_F_MOMENTUM) != 0)       text += "momentum-weakening ";
   if((factors & REV_F_TREND_LOST) != 0)     text += "trend-conditions-lost ";
   if((factors & REV_F_OPPOSITE_TREND) != 0) text += "opposite-trend ";

   if(StringLen(text) == 0)
      return "none";

   return StringSubstr(text, 0, StringLen(text) - 1);
}

//-------------------------------------------------------------------
// IS NEW TREND CONFIRMED
//
// The candle must be classified as a trend by the ORIGINAL logic and
// at least `required` of the latest `window` candles must show that
// same trend with no opposite-trend candle among them.
// After a reversal the history only contains candles closed after the
// cleanup, so the old trend can never confirm the new one.
//-------------------------------------------------------------------
bool IsNewTrendConfirmed(MarketState state, int required, int window, int &dir)
{
   dir = 0;

   if(state != STATE_UPTREND && state != STATE_DOWNTREND)
      return false;

   MarketState opposite = (state == STATE_UPTREND) ? STATE_DOWNTREND : STATE_UPTREND;

   int span = MathMax(window, required);

   if(CountRecentClassifications(state, span) < required)
      return false;

   if(CountRecentClassifications(opposite, span) > 0)
      return false;

   dir = (state == STATE_UPTREND) ? 1 : -1;
   return true;
}

void LogWaitingProgress(MarketState state)
{
   int span = MathMax(InpNewTrendWindowBars, InpNewTrendConfirmBars);

   DebugEvent(
      StringFormat(
         "[State] WAITING_FOR_NEW_TREND (old %s) - NO ORDER (candle %s; last %d candles: %d UPTREND / %d DOWNTREND, %d needed)",
         DirToString(g_invalidatedDir),
         StateToString(state),
         MathMin(span, g_classHistCount),
         CountRecentClassifications(STATE_UPTREND, span),
         CountRecentClassifications(STATE_DOWNTREND, span),
         InpNewTrendConfirmBars
      )
   );
}

//-------------------------------------------------------------------
// ENTER TREND (UPTREND or DOWNTREND confirmed)
//-------------------------------------------------------------------
void EnterTrend(int dir, bool afterReversal, datetime candleTime)
{
   g_tradeState    = (dir > 0) ? TSTATE_UPTREND : TSTATE_DOWNTREND;
   g_protectDir    = dir;
   g_lastTrendDir  = dir;
   g_revCount      = 0;
   g_revAge        = 0;
   g_nonTrendCount = 0;
   g_stateCandles  = 0;

   string process = (dir > 0)
                    ? "bullish pending-order process (BUY LIMIT / BUY STOP)"
                    : "bearish pending-order process (SELL LIMIT / SELL STOP)";

   string when = TimeToString(candleTime, TIME_DATE | TIME_MINUTES);

   if(afterReversal)
   {
      LogEvent("Trend", "New " + DirToString(dir) + " confirmed on candle " + when);
      LogEvent("State", "Resuming trading - " + process);
   }
   else
   {
      LogEvent("Trend", DirToString(dir) + " confirmed on candle " + when);
      LogEvent("State", TradeStateToString(g_tradeState) + " - " + process + " active");
   }
}

//-------------------------------------------------------------------
// INVALIDATE TREND (prolonged sideways / uncertain market)
//
// Not a reversal: open EA positions are kept and stay protected by
// the reversal detector. Stale pending orders of the old trend are
// cancelled (InpCancelPendingOnInvalidation) and no new order is
// placed until a trend is confirmed again.
//-------------------------------------------------------------------
void InvalidateTrend(datetime candleTime)
{
   int oldDir = (g_tradeState == TSTATE_UPTREND) ? 1 : -1;

   g_tradeState    = TSTATE_SIDEWAYS_UNCERTAIN;
   g_lastTrendDir  = oldDir;
   g_protectDir    = oldDir;   // keep protecting the old trend's positions
   g_nonTrendCount = 0;
   g_stateCandles  = 0;

   LogEvent(
      "Trend",
      StringFormat(
         "%s invalidated: %d candles in a row without trend confirmation (sideways/uncertain) on candle %s",
         DirToString(oldDir),
         InpTrendInvalidationBars,
         TimeToString(candleTime, TIME_DATE | TIME_MINUTES)
      )
   );

   LogEvent(
      "State",
      "SIDEWAYS/UNCERTAIN - no new orders until a trend is confirmed; open EA positions stay protected"
   );

   if(InpCancelPendingOnInvalidation && !g_isReplaying)
      CancelAllEAPendingOrders("Trend");
}

//===================================================================
// REVERSAL PROTECTION + CLEANUP
//===================================================================

//-------------------------------------------------------------------
// TRIGGER REVERSAL PROTECTION
//
//   REVERSAL DETECTED -> STOP NEW ORDERS -> CANCEL ALL EA PENDING
//   ORDERS -> CLOSE ALL EA OPEN POSITIONS -> VERIFY -> RESET OLD
//   TREND DATA -> WAITING_FOR_NEW_TREND
//-------------------------------------------------------------------
void TriggerReversalProtection(string reason, datetime candleTime)
{
   int oldDir = g_protectDir;

   g_tradeState      = TSTATE_REVERSAL_DETECTED;
   g_cleanupAttempts = 0;
   g_lastCleanupTry  = 0;
   g_stateCandles    = 0;

   if(oldDir != 0)
   {
      g_invalidatedDir   = oldDir;
      g_lastReversalTime = candleTime;
   }

   //--- restart replay: only the state is simulated, nothing is traded
   if(g_isReplaying)
   {
      FinishReversalCleanup();
      return;
   }

   if(oldDir != 0)
   {
      LogEvent(
         "Reversal",
         "REVERSAL CONFIRMED against " + DirToString(oldDir) + " on candle " +
         TimeToString(candleTime, TIME_DATE | TIME_MINUTES) + " - " + reason
      );
   }
   else
   {
      LogEvent("Reversal", "Cleanup required - " + reason);
   }

   LogEvent("State", "REVERSAL_DETECTED - new orders stopped, cleaning up all EA orders and positions");

   //--- the cleanup runs immediately (not on the next candle)
   ProcessReversalCleanup(true);
}

//-------------------------------------------------------------------
// PROCESS REVERSAL CLEANUP
//
// One complete cleanup attempt (cancel + close + verify). When no EA
// order or position is left the state becomes WAITING_FOR_NEW_TREND.
// Otherwise it stays REVERSAL_DETECTED (no new orders) and the attempt
// is repeated on the next ticks after 1, 2, 4, 8, 16, then 30 seconds.
//-------------------------------------------------------------------
bool ProcessReversalCleanup(bool force)
{
   if(g_tradeState != TSTATE_REVERSAL_DETECTED)
      return true;

   datetime now = TimeCurrent();

   if(!force && g_lastCleanupTry > 0)
   {
      int waitSeconds = 1;

      for(int i = 1; i < g_cleanupAttempts && waitSeconds < 30; i++)
         waitSeconds *= 2;

      if(waitSeconds > 30)
         waitSeconds = 30;

      if(now - g_lastCleanupTry < waitSeconds)
         return false;
   }

   g_lastCleanupTry = now;
   g_cleanupAttempts++;

   //--- AutoTrading off / EA not allowed to trade: requests would only
   //--- be rejected, so nothing is sent until trading is permitted
   if(!IsTradingPermitted())
   {
      LogEvent(
         "Reversal",
         StringFormat(
            "Cleanup postponed (attempt %d): trading is not permitted - enable AutoTrading / "
            "'Allow Algo Trading'. %d EA pending order(s) and %d EA position(s) remain, new orders stay blocked.",
            g_cleanupAttempts,
            CountEAPendingOrdersAll(),
            CountEAPositions()
         )
      );
      return false;
   }

   if(ExecuteCleanup())
   {
      FinishReversalCleanup();
      return true;
   }

   LogEvent(
      "Reversal",
      StringFormat(
         "Cleanup NOT complete after attempt %d: %d EA pending order(s) and %d EA position(s) remain - "
         "retrying, new orders stay blocked.",
         g_cleanupAttempts,
         CountEAPendingOrdersAll(),
         CountEAPositions()
      )
   );

   return false;
}

//-------------------------------------------------------------------
// EXECUTE CLEANUP
//
// Up to 3 passes per attempt: a pending order that triggers while the
// cleanup runs becomes a position and is closed in the next pass.
// Returns true only when the terminal shows NO EA pending order and
// NO EA position any more (verified, never assumed).
//-------------------------------------------------------------------
bool ExecuteCleanup()
{
   int pendingBefore   = CountEAPendingOrdersAll();
   int positionsBefore = CountEAPositions();

   for(int pass = 1; pass <= 3; pass++)
   {
      CancelAllEAPendingOrders("Reversal");
      CloseAllEAOpenPositions("Reversal");

      int pending   = CountEAPendingOrdersAll();
      int positions = CountEAPositions();

      if(pending == 0 && positions == 0)
         return true;

      DebugEvent(
         StringFormat(
            "[Reversal] Verification pass %d: %d EA pending order(s) / %d EA position(s) still present.",
            pass,
            pending,
            positions
         )
      );

      // Nothing could be removed in this pass (e.g. market closed or
      // freeze level): more passes now are pointless - the next
      // attempt follows on a later tick.
      if(pending >= pendingBefore && positions >= positionsBefore)
         break;

      pendingBefore   = pending;
      positionsBefore = positions;

      if(pass < 3)
         Sleep(InpCleanupRetryDelayMs);
   }

   return false;
}

//-------------------------------------------------------------------
// FINISH REVERSAL CLEANUP (verified) -> WAITING_FOR_NEW_TREND
//-------------------------------------------------------------------
void FinishReversalCleanup()
{
   int attempts = g_cleanupAttempts;

   ResetTradingState();

   g_tradeState = TSTATE_WAITING_FOR_NEW_TREND;

   LogEvent(
      "Reversal",
      StringFormat(
         "Cleanup completed - verified: no EA pending orders and no EA positions remain (%d attempt(s)).",
         attempts
      )
   );

   LogEvent(
      "State",
      "WAITING_FOR_NEW_TREND - old " + DirToString(g_invalidatedDir) +
      " data cleared, no new orders until a new trend is confirmed"
   );
}

//-------------------------------------------------------------------
// CANCEL ALL EA PENDING ORDERS
//
// Deletes EVERY pending order (Buy/Sell Limit, Buy/Sell Stop, Stop
// Limit) whose symbol AND magic number belong to this EA. Manual
// orders and other EAs' orders are never touched.
// Returns the number of orders that could NOT be deleted.
//-------------------------------------------------------------------
int CancelAllEAPendingOrders(string logTag = "Reversal")
{
   int total = CountEAPendingOrdersAll();

   if(total == 0)
      return 0;

   LogEvent(logTag, StringFormat("Cancelling all EA pending orders (%d)", total));

   int    failed        = 0;
   int    frozenCount   = 0;
   string frozenTickets = "";

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      if(!IsEAOrderSelected())
         continue;

      if(!IsCleanupPendingType((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)))
         continue;

      bool frozen = false;

      if(!DeleteEAPendingOrder(ticket, logTag, frozen))
      {
         failed++;

         if(frozen)
         {
            frozenCount++;
            frozenTickets += (frozenTickets == "" ? "" : ", ") + TicketToString(ticket);
         }
      }
   }

   //--- one line per attempt instead of one line per frozen order
   if(frozenCount > 0)
   {
      LogEvent(
         logTag,
         StringFormat(
            "%d EA pending order(s) inside the broker freeze level - they cannot be deleted now, retrying later. Tickets: %s",
            frozenCount,
            frozenTickets
         )
      );
   }

   return failed;
}

//-------------------------------------------------------------------
// DELETE ONE EA PENDING ORDER (ownership re-checked, retries)
// `frozen` = true when the order is inside the freeze level (the
// caller reports those tickets in one line).
//-------------------------------------------------------------------
bool DeleteEAPendingOrder(ulong ticket, string logTag, bool &frozen)
{
   frozen = false;

   for(int attempt = 1; attempt <= InpCleanupRetries; attempt++)
   {
      //--- re-select and re-check ownership right before the request
      if(!OrderSelect(ticket))
         return true;   // no longer pending (filled or removed)

      if(!IsEAOrderSelected())
         return true;   // never touch an order that is not ours

      ENUM_ORDER_TYPE type  = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double          price = OrderGetDouble(ORDER_PRICE_OPEN);

      //--- inside the freeze level the server rejects the deletion
      if(IsInsideFreezeLevel(type, price))
      {
         frozen = true;
         return false;
      }

      ResetLastError();

      bool sent = trade.OrderDelete(ticket);
      uint rc   = trade.ResultRetcode();

      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      {
         LogEvent(
            logTag,
            "Cancelled EA pending order ticket: " + TicketToString(ticket) + " (" +
            OrderTypeName(type) + " @ " + DoubleToString(price, _Digits) + ")"
         );
         return true;
      }

      if(!OrderSelect(ticket))
      {
         LogEvent(
            logTag,
            "Pending order ticket " + TicketToString(ticket) +
            " no longer exists (filled or removed) - a resulting position is closed separately."
         );
         return true;
      }

      LogEvent(
         logTag,
         StringFormat(
            "FAILED to cancel pending order ticket %s (attempt %d/%d): retcode=%u %s, error=%d",
            TicketToString(ticket),
            attempt,
            InpCleanupRetries,
            rc,
            trade.ResultRetcodeDescription(),
            GetLastError()
         )
      );

      if(!IsRetryableRetcode(rc))
         return false;

      Sleep(InpCleanupRetryDelayMs);
   }

   return false;
}

//-------------------------------------------------------------------
// CLOSE ALL EA OPEN POSITIONS
//
// Closes EVERY open position whose symbol AND magic number belong to
// this EA - including the positions created when the EA's pending
// orders were activated. Manual positions (magic 0) and positions of
// other EAs are never touched.
// Returns the number of positions that could NOT be closed.
//-------------------------------------------------------------------
int CloseAllEAOpenPositions(string logTag = "Reversal")
{
   int total = CountEAPositions();

   if(total == 0)
      return 0;

   LogEvent(logTag, StringFormat("Closing all EA open positions (%d)", total));

   int failed = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(!IsEAPositionSelected())
         continue;

      if(!CloseEAPosition(ticket, logTag))
         failed++;
   }

   return failed;
}

//-------------------------------------------------------------------
// CLOSE ONE EA POSITION (ownership re-checked, retries)
//-------------------------------------------------------------------
bool CloseEAPosition(ulong ticket, string logTag)
{
   for(int attempt = 1; attempt <= InpCleanupRetries; attempt++)
   {
      //--- re-select and re-check ownership right before the request
      if(!PositionSelectByTicket(ticket))
         return true;   // already closed

      if(!IsEAPositionSelected())
         return true;   // never touch a position that is not ours

      string side   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double volume = PositionGetDouble(POSITION_VOLUME);
      double opened = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      LogEvent(
         logTag,
         StringFormat(
            "Closing EA position ticket: %s (%s %.2f lots, open %s, floating P/L %.2f)",
            TicketToString(ticket),
            side,
            volume,
            DoubleToString(opened, _Digits),
            profit
         )
      );

      ResetLastError();

      bool sent = trade.PositionClose(ticket, (ulong)InpDeviationPoints);
      uint rc   = trade.ResultRetcode();

      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      {
         LogEvent(
            logTag,
            "Position ticket " + TicketToString(ticket) + " closed (deal " +
            TicketToString(trade.ResultDeal()) + ")"
         );
         return true;
      }

      if(rc == TRADE_RETCODE_DONE_PARTIAL)
      {
         LogEvent(
            logTag,
            "Position ticket " + TicketToString(ticket) +
            " partially closed - closing the remaining volume."
         );
         continue;
      }

      if(rc == TRADE_RETCODE_POSITION_CLOSED || !PositionSelectByTicket(ticket))
      {
         LogEvent(logTag, "Position ticket " + TicketToString(ticket) + " is already closed.");
         return true;
      }

      LogEvent(
         logTag,
         StringFormat(
            "FAILED to close position ticket %s (attempt %d/%d): retcode=%u %s, error=%d",
            TicketToString(ticket),
            attempt,
            InpCleanupRetries,
            rc,
            trade.ResultRetcodeDescription(),
            GetLastError()
         )
      );

      if(!IsRetryableRetcode(rc))
         return false;

      Sleep(InpCleanupRetryDelayMs);
   }

   return !PositionSelectByTicket(ticket);
}

//-------------------------------------------------------------------
// TRADING PERMITTED (AutoTrading button, EA setting, account)
//-------------------------------------------------------------------
bool IsTradingPermitted()
{
   if(!MQLInfoInteger(MQL_TESTER))
   {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
         return false;

      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
         return false;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return false;

   return true;
}

//-------------------------------------------------------------------
// FREEZE LEVEL CHECK FOR A PENDING ORDER
//-------------------------------------------------------------------
bool IsInsideFreezeLevel(ENUM_ORDER_TYPE type, double price)
{
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   if(freezeLevel <= 0)
      return false;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double market = IsBuySideOrderType(type) ? tick.ask : tick.bid;

   return(MathAbs(price - market) <= (double)freezeLevel * _Point);
}

//-------------------------------------------------------------------
// TRANSIENT TRADE ERRORS WORTH AN IMMEDIATE RETRY
//-------------------------------------------------------------------
bool IsRetryableRetcode(uint rc)
{
   return(
      rc == TRADE_RETCODE_REQUOTE ||
      rc == TRADE_RETCODE_REJECT ||
      rc == TRADE_RETCODE_ERROR ||
      rc == TRADE_RETCODE_TIMEOUT ||
      rc == TRADE_RETCODE_INVALID_PRICE ||
      rc == TRADE_RETCODE_PRICE_CHANGED ||
      rc == TRADE_RETCODE_PRICE_OFF ||
      rc == TRADE_RETCODE_TOO_MANY_REQUESTS ||
      rc == TRADE_RETCODE_LOCKED ||
      rc == TRADE_RETCODE_CONNECTION
   );
}

//-------------------------------------------------------------------
// MANAGE OPEN POSITIONS  (every tick, before any candle logic)
//
// The original strategy places its orders without SL/TP and has no
// trailing logic, so no position is modified here. This step
// enforces the protection rules:
//   - a confirmed reversal whose cleanup is not verified yet is
//     retried immediately (risk actions are not candle-gated);
//   - while WAITING_FOR_NEW_TREND the EA must own nothing: anything
//     found (e.g. a pending order that triggered inside the freeze
//     level) is cleaned up at once.
//-------------------------------------------------------------------
void ManageOpenPositions()
{
   if(!InpUseReversalProtection)
      return;

   if(g_tradeState == TSTATE_REVERSAL_DETECTED)
   {
      ProcessReversalCleanup(false);
      return;
   }

   if(g_tradeState == TSTATE_WAITING_FOR_NEW_TREND)
   {
      int pending   = CountEAPendingOrdersAll();
      int positions = CountEAPositions();

      if(pending > 0 || positions > 0)
      {
         TriggerReversalProtection(
            StringFormat(
               "%d EA pending order(s) and %d EA position(s) found while WAITING_FOR_NEW_TREND",
               pending,
               positions
            ),
            iTime(_Symbol, EA_TIMEFRAME, 1)
         );
      }
   }
}

//===================================================================
// RESTART / RECOVERY
//===================================================================

//-------------------------------------------------------------------
// RECOVER STATE  (first tick after start, restart or re-init)
//
// 1. Replays the last InpRecoveryBars completed M1 candles through
//    the ORIGINAL classification and the trend state machine
//    (simulation only: no orders, no cleanup, no log output).
// 2. Compares the rebuilt state with the EA's existing orders and
//    positions (symbol + magic). The reversal cleanup runs at once
//    when the EA still owns something while
//      - a reversal is confirmed (WAITING_FOR_NEW_TREND),
//      - its exposure is against the confirmed trend, or
//      - it owns buy-side AND sell-side orders/positions.
//    Otherwise the EA continues from the rebuilt state and existing
//    positions stay protected.
// No order is re-created: a candle already replayed is never traded
// again, and the original duplicate check stays active.
//-------------------------------------------------------------------
bool RecoverState()
{
   if(!InpUseReversalProtection)
   {
      g_recoveryDone = true;
      return true;
   }

   int bars       = Bars(_Symbol, EA_TIMEFRAME);
   int calculated = BarsCalculated(g_emaHandle);

   if(bars <= 0 || calculated <= 0)
      return false;   // history / EMA not ready yet - retry on the next tick

   //--- a newly completed candle that is still waiting for the normal
   //--- processing is NOT replayed (it would be counted twice)
   datetime currentBarTime  = iTime(_Symbol, EA_TIMEFRAME, 0);
   int      lastReplayShift = (currentBarTime != g_lastProcessedBar) ? 2 : 1;

   int lookback =
      MathMax(
         MathMax(ReversalBarsNeeded() + 2, InpSidewaysLookback + 3),
         MathMax(InpTrendLookback + 4, InpReversalLookback + 2)
      );

   int available = MathMin(bars, calculated);
   int maxShift  = MathMin(InpRecoveryBars + lastReplayShift - 1, available - lookback - 1);

   //--- rebuild from scratch
   ResetTradingState();

   g_tradeState       = TSTATE_SIDEWAYS_UNCERTAIN;
   g_lastTrendDir     = 0;
   g_invalidatedDir   = 0;
   g_lastReversalTime = 0;

   int replayed = 0;

   if(maxShift >= lastReplayShift)
   {
      g_isReplaying   = true;
      g_previousState = STATE_UNCERTAIN;

      for(int shift = maxShift; shift >= lastReplayShift; shift--)
      {
         // "shift 1" of every original function now means this candle
         g_shiftOffset = shift - 1;

         MqlRates candle;

         if(!GetM1Candle(1, candle))
            continue;

         MarketState state = DetermineMarketState();

         ManageTrendState(state, candle.time);

         g_previousState = state;
         replayed++;
      }

      g_shiftOffset = 0;
      g_isReplaying = false;
   }

   g_recoveryDone = true;

   //--- what the EA really owns (symbol + magic)
   int buySide  = 0;
   int sellSide = 0;

   GetEAExposure(buySide, sellSide);

   LogEvent(
      "Recovery",
      StringFormat(
         "State rebuilt from %d completed M1 candles: %s (last confirmed trend %s%s) | "
         "EA exposure: %d buy-side, %d sell-side order(s)/position(s)",
         replayed,
         TradeStateToString(g_tradeState),
         DirToString(g_lastTrendDir),
         (g_lastReversalTime > 0
            ? ", last reversal on " + TimeToString(g_lastReversalTime, TIME_DATE | TIME_MINUTES)
            : ""),
         buySide,
         sellSide
      )
   );

   int referenceDir = 0;

   if(g_tradeState == TSTATE_UPTREND)
      referenceDir = 1;
   else if(g_tradeState == TSTATE_DOWNTREND)
      referenceDir = -1;
   else if(g_tradeState == TSTATE_SIDEWAYS_UNCERTAIN)
      referenceDir = g_lastTrendDir;

   string conflict = "";

   if(buySide > 0 && sellSide > 0)
      conflict = "the EA owns buy-side AND sell-side orders/positions";
   else if(g_tradeState == TSTATE_WAITING_FOR_NEW_TREND && buySide + sellSide > 0)
      conflict = "a trend reversal was confirmed while EA orders/positions are still open";
   else if(referenceDir > 0 && sellSide > 0)
      conflict = "EA sell-side orders/positions are against the confirmed UPTREND";
   else if(referenceDir < 0 && buySide > 0)
      conflict = "EA buy-side orders/positions are against the confirmed DOWNTREND";

   if(conflict != "")
   {
      if(buySide > 0 && sellSide == 0)
         g_protectDir = 1;
      else if(sellSide > 0 && buySide == 0)
         g_protectDir = -1;
      else
         g_protectDir = 0;

      TriggerReversalProtection(
         "restart recovery: " + conflict,
         iTime(_Symbol, EA_TIMEFRAME, 1)
      );
      return true;
   }

   if(buySide + sellSide > 0)
   {
      int    exposureDir  = (buySide > 0) ? 1 : -1;
      string exposureSide = (exposureDir > 0) ? "BUY" : "SELL";

      if(g_tradeState == TSTATE_SIDEWAYS_UNCERTAIN)
      {
         g_protectDir = exposureDir;

         if(InpCancelPendingOnInvalidation)
            CancelAllEAPendingOrders("Recovery");
      }

      LogEvent(
         "Recovery",
         "Existing EA " + exposureSide +
         " orders/positions kept and protected by the reversal detector."
      );
   }

   LogEvent(
      "State",
      TradeStateToString(g_tradeState) +
      ((g_tradeState == TSTATE_UPTREND || g_tradeState == TSTATE_DOWNTREND)
         ? " - trading active"
         : " - no new orders until a trend is confirmed")
   );

   return true;
}

//-------------------------------------------------------------------
// TRADE TRANSACTIONS (journal only)
//
// Reports when an EA pending order is activated (becomes a position)
// and when an EA position is closed. Filtered by symbol + magic.
//-------------------------------------------------------------------
void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(trans.symbol != _Symbol)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   ENUM_DEAL_ENTRY entry  = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ENUM_DEAL_TYPE  type   = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double          volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double          price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);

   if(entry == DEAL_ENTRY_IN)
   {
      LogEvent(
         "Position",
         StringFormat(
            "EA pending order %s activated -> position %s: %s %.2f lots @ %s (state %s)",
            TicketToString(trans.order),
            TicketToString(trans.position),
            (type == DEAL_TYPE_BUY) ? "BUY" : "SELL",
            volume,
            DoubleToString(price, _Digits),
            TradeStateToString(g_tradeState)
         )
      );
   }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      LogEvent(
         "Position",
         StringFormat(
            "EA position %s closed: %.2f lots @ %s, profit %.2f",
            TicketToString(trans.position),
            volume,
            DoubleToString(price, _Digits),
            HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
         )
      );
   }
}

//+------------------------------------------------------------------+
