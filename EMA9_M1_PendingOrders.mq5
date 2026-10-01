//+------------------------------------------------------------------+
//|                                        EMA9_M1_PendingOrders.mq5 |
//|              M1-only EMA9 trend-based pending order Expert Advisor |
//+------------------------------------------------------------------+
//| Strategy mapping (fixed, not configurable):                       |
//|   UPTREND   + completed bearish M1 candle -> BUY LIMIT            |
//|   UPTREND   + completed bullish M1 candle -> BUY STOP             |
//|   DOWNTREND + completed bullish M1 candle -> SELL LIMIT           |
//|   DOWNTREND + completed bearish M1 candle -> SELL STOP            |
//|   SIDEWAYS / REVERSAL / UNCERTAIN         -> NO ORDER             |
//|                                                                  |
//| Every series, indicator and bar calculation uses PERIOD_M1,       |
//| independent of the chart timeframe the EA is attached to.         |
//+------------------------------------------------------------------+
#property copyright   "EMA9 M1 Pending Order Strategy"
#property version     "1.00"
#property description "M1-only EMA9 trend EA."
#property description "UPTREND: bearish candle -> BUY LIMIT, bullish candle -> BUY STOP."
#property description "DOWNTREND: bullish candle -> SELL LIMIT, bearish candle -> SELL STOP."
#property description "No orders in SIDEWAYS, REVERSAL or UNCERTAIN markets. Completed candles only."

#include <Trade\Trade.mqh>

//--- the only timeframe this EA ever uses
#define EA_TF PERIOD_M1

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_MARKET_STATE
  {
   STATE_UPTREND = 0,   // Uptrend
   STATE_DOWNTREND,     // Downtrend
   STATE_SIDEWAYS,      // Sideways
   STATE_REVERSAL,      // Trend reversal
   STATE_UNCERTAIN      // Uncertain
  };

enum ENUM_RAW_SIGNAL
  {
   RAW_UP = 0,
   RAW_DOWN,
   RAW_SIDEWAYS,
   RAW_MIXED
  };

enum ENUM_TREND_DIR
  {
   DIR_NONE = 0,
   DIR_UP   = 1,
   DIR_DOWN = -1
  };

enum ENUM_LIMIT_REF
  {
   LIMIT_REF_EXTREME = 0, // Candle extreme (Buy Limit @ Low, Sell Limit @ High)
   LIMIT_REF_CLOSE   = 1, // Candle close
   LIMIT_REF_MID     = 2  // Candle midpoint (High+Low)/2
  };

enum ENUM_STOP_REF
  {
   STOP_REF_EXTREME = 0,  // Candle extreme (Buy Stop @ High, Sell Stop @ Low)
   STOP_REF_CLOSE   = 1   // Candle close
  };

enum ENUM_INVALID_PRICE_ACTION
  {
   INVALID_SKIP   = 0,    // Skip the order
   INVALID_ADJUST = 1     // Move to the nearest valid price
  };

enum ENUM_SLTP_MODE
  {
   SLTP_NONE   = 0,       // No SL/TP
   SLTP_POINTS = 1,       // SL/TP in points
   SLTP_ATR    = 2        // SL/TP as multiples of M1 ATR
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,  // Fixed lot
   LOT_RISK_PERCENT = 1   // Risk % of equity (requires SL)
  };

//--- sideways reason flags
#define SW_SLOPE   1
#define SW_RANGE   2
#define SW_CROSS   4
#define SW_ER      8
#define SW_HUG     16

//--- reversal reason flags
#define REV_CROSS  1
#define REV_EMA    2
#define REV_BODY   4
#define REV_OPP    8

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input ulong  InpMagic              = 9090901;   // Magic number (unique per EA instance)
input string InpOrderComment       = "E9M1";    // Order comment prefix (max 10 chars)
input bool   InpDebug              = true;      // Enable debug logging
input bool   InpShowPanel          = true;      // Show state panel on chart
input int    InpWarmupBars         = 200;       // M1 bars replayed at start to seed trend state

input group "=== EMA (M1 only) ==="
input int                InpEmaPeriod = 9;            // EMA period
input ENUM_APPLIED_PRICE InpEmaPrice  = PRICE_CLOSE;  // EMA price
input int                InpAtrPeriod = 14;           // M1 ATR period (volatility unit for thresholds)

input group "=== Trend confirmation (M1) ==="
input int    InpSlopeBars          = 5;     // EMA slope lookback (bars)
input double InpTrendMinSlopeATR   = 0.30;  // Min |EMA slope| over lookback (x ATR)
input int    InpMinEmaDirBars      = 4;     // Min EMA bars moving in trend direction (of slope lookback)
input double InpMinDistanceATR     = 0.05;  // Min close distance from EMA on trend side (x ATR)
input int    InpCloseSideBars      = 5;     // Close-vs-EMA lookback (bars)
input int    InpMinClosesOnSide    = 4;     // Min closes on trend side of EMA (of lookback)
input bool   InpUseStructure       = true;  // Require HH/HL (up) or LL/LH (down) structure
input int    InpStructureBars      = 5;     // Structure block size (bars)
input int    InpTrendConfirmBars   = 2;     // Consecutive candles to confirm a new trend

input group "=== Sideways filter (M1) ==="
input bool   InpSwUseSlope         = true;  // Flat EMA check
input double InpSwMaxSlopeATR      = 0.20;  //   Sideways if |EMA slope| below (x ATR)
input bool   InpSwUseRange         = true;  // Range compression check
input int    InpSwRangeBars        = 10;    //   Range lookback (bars)
input double InpSwMinRangeATR      = 1.50;  //   Sideways if High-Low range below (x ATR)
input bool   InpSwUseCrosses       = true;  // EMA whipsaw check
input int    InpSwCrossBars        = 10;    //   Cross lookback (bars)
input int    InpSwMaxCrosses       = 3;     //   Sideways if close/EMA crosses >= this
input bool   InpSwUseEfficiency    = true;  // Directional efficiency check
input int    InpSwErBars           = 10;    //   Efficiency lookback (bars)
input double InpSwMinEfficiency    = 0.25;  //   Sideways if efficiency ratio below (0..1)
input bool   InpSwUseHugging       = true;  // Price hugging EMA check
input int    InpSwHugBars          = 5;     //   Hugging lookback (bars)
input double InpSwHugATR           = 0.15;  //   Sideways if avg |close-EMA| below (x ATR)

input group "=== Reversal protection (M1) ==="
input bool   InpRevOnEmaCross      = true;  // Close on wrong side of EMA -> reversal
input int    InpRevEmaBars         = 2;     // EMA moving against trend N consecutive bars -> reversal (0=off)
input double InpRevBodyATR         = 1.50;  // Opposite candle body >= x ATR -> reversal (0=off)
input int    InpRevConfirmBars     = 3;     // Consecutive candles to confirm a trend opposite to the previous one

input group "=== Pending orders ==="
input ENUM_LIMIT_REF            InpLimitRef          = LIMIT_REF_EXTREME; // Limit order reference price
input ENUM_STOP_REF             InpStopRef           = STOP_REF_EXTREME;  // Stop order reference price
input int                       InpLimitOffsetPoints = 0;      // Limit offset (points, away from market)
input int                       InpStopOffsetPoints  = 0;      // Stop offset (points, away from market)
input int                       InpExtraDistPoints   = 0;      // Extra distance beyond broker stops/freeze level (points)
input ENUM_INVALID_PRICE_ACTION InpInvalidPriceAction= INVALID_SKIP; // When price violates broker rules
input int                       InpExpiryMinutes     = 5;      // Pending order expiration (minutes, 0=none)
input int                       InpMaxPendingOrders  = 4;      // Max EA pending orders on symbol (0=unlimited)
input int                       InpMaxOrdersPerCandle= 1;      // Max orders generated from one candle
input int                       InpMaxOpenPositions  = 0;      // Max EA open positions on symbol (0=unlimited)
input int                       InpMaxSpreadPoints   = 0;      // Max spread to place orders (points, 0=off)
input int                       InpDeviationPoints   = 10;     // Slippage / deviation (points)
input int                       InpMaxRetries        = 2;      // Retries on transient trade errors

input group "=== Pending order management ==="
input bool   InpDeleteOpposite     = true;  // Delete opposite-direction pendings after confirmed trend
input bool   InpDeleteStale        = true;  // Delete stale pendings
input int    InpStaleBars          = 5;     //   Stale after N M1 bars
input bool   InpDeleteOnSideways   = false; // Delete all EA pendings when market is SIDEWAYS
input bool   InpDeleteOnReversal   = true;  // Delete all EA pendings on REVERSAL

input group "=== Volume / SL / TP ==="
input ENUM_LOT_MODE  InpLotMode    = LOT_FIXED; // Lot mode
input double         InpFixedLot   = 0.01;      // Fixed lot
input double         InpRiskPercent= 0.5;       // Risk % of equity (risk mode)
input ENUM_SLTP_MODE InpSLTPMode   = SLTP_ATR;  // SL/TP mode
input double         InpSLValue    = 2.0;       // SL (points or ATR multiple, 0=off)
input double         InpTPValue    = 2.0;       // TP (points or ATR multiple, 0=off)

//+------------------------------------------------------------------+
//| Analysis of one completed M1 candle                              |
//+------------------------------------------------------------------+
struct SAnalysis
  {
   datetime          time;
   double            open;
   double            high;
   double            low;
   double            close;
   double            ema;
   double            atr;
   double            slopeAtr;
   double            distAtr;
   double            rangeAtr;
   double            efficiency;
   double            hugAtr;
   int               crosses;
   int               emaUpBars;
   int               emaDnBars;
   int               closesAbove;
   int               closesBelow;
   bool              higherStructure;
   bool              lowerStructure;
   bool              upOk;
   bool              downOk;
   int               swFlags;
   int               revUpFlags;
   int               revDnFlags;
   ENUM_RAW_SIGNAL   raw;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade            g_trade;
int               g_emaHandle      = INVALID_HANDLE;
int               g_atrHandle      = INVALID_HANDLE;
bool              g_ready          = false;
datetime          g_lastBarOpen    = 0;   // open time of the forming M1 bar already seen
datetime          g_lastStateBar   = 0;   // open time of the last completed M1 bar fed to the state machine
datetime          g_lastSignalBar  = 0;   // open time of the last completed M1 bar processed for signals
int               g_ordersThisCandle = 0;
string            g_commentPrefix  = "";

ENUM_TREND_DIR    g_confirmed      = DIR_NONE; // currently confirmed trend
ENUM_TREND_DIR    g_lastDir        = DIR_NONE; // last trend that was confirmed (memory for reversal)
ENUM_TREND_DIR    g_candDir        = DIR_NONE; // candidate trend awaiting confirmation
int               g_candCount      = 0;
ENUM_MARKET_STATE g_state          = STATE_UNCERTAIN;
SAnalysis         g_last;

MqlRates          g_rates[];
double            g_ema[];
double            g_atr[];

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void Log(const string msg)   { Print("[EMA9-M1 ", _Symbol, " #", InpMagic, "] ", msg); }
void Debug(const string msg) { if(InpDebug) Log(msg); }

string StateToString(const ENUM_MARKET_STATE s)
  {
   switch(s)
     {
      case STATE_UPTREND:   return "UPTREND";
      case STATE_DOWNTREND: return "DOWNTREND";
      case STATE_SIDEWAYS:  return "SIDEWAYS";
      case STATE_REVERSAL:  return "REVERSAL";
      default:              return "UNCERTAIN";
     }
  }

string OrderTypeToString(const ENUM_ORDER_TYPE t)
  {
   switch(t)
     {
      case ORDER_TYPE_BUY_LIMIT:  return "BUY LIMIT";
      case ORDER_TYPE_BUY_STOP:   return "BUY STOP";
      case ORDER_TYPE_SELL_LIMIT: return "SELL LIMIT";
      case ORDER_TYPE_SELL_STOP:  return "SELL STOP";
      default:                    return EnumToString(t);
     }
  }

string SidewaysReasons(const int f)
  {
   string s = "";
   if((f & SW_SLOPE) != 0) s += "flat-EMA ";
   if((f & SW_RANGE) != 0) s += "compressed-range ";
   if((f & SW_CROSS) != 0) s += "EMA-whipsaw ";
   if((f & SW_ER)    != 0) s += "low-efficiency ";
   if((f & SW_HUG)   != 0) s += "price-hugging-EMA ";
   return s;
  }

string ReversalReasons(const int f)
  {
   string s = "";
   if((f & REV_CROSS) != 0) s += "close-across-EMA ";
   if((f & REV_EMA)   != 0) s += "EMA-turned ";
   if((f & REV_BODY)  != 0) s += "strong-opposite-candle ";
   if((f & REV_OPP)   != 0) s += "opposite-trend-conditions ";
   return s;
  }

//+------------------------------------------------------------------+
//| Price / symbol helpers                                           |
//+------------------------------------------------------------------+
double SymPoint()  { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int    SymDigits() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

double TickSize()
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      ts = SymPoint();
   return ts;
  }

double RoundToTick(const double p)
  {
   double ts = TickSize();
   return NormalizeDouble(MathRound(p / ts) * ts, SymDigits());
  }

double RoundDownToTick(const double p)
  {
   double ts = TickSize();
   return NormalizeDouble(MathFloor(p / ts + 1e-9) * ts, SymDigits());
  }

double RoundUpToTick(const double p)
  {
   double ts = TickSize();
   return NormalizeDouble(MathCeil(p / ts - 1e-9) * ts, SymDigits());
  }

//--- minimum distance of a pending price from the market (stops level, freeze level, extra buffer)
double MinPendingDistance()
  {
   long   stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double dist   = (double)MathMax(stops, freeze) * SymPoint() + InpExtraDistPoints * SymPoint();
   return MathMax(dist, TickSize());
  }

//--- minimum SL/TP distance from the entry price
double MinStopDistance()
  {
   long   stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double dist  = (double)stops * SymPoint() + InpExtraDistPoints * SymPoint();
   return MathMax(dist, TickSize());
  }

bool IsPendingType(const ENUM_ORDER_TYPE t)
  {
   return (t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_BUY_STOP ||
           t == ORDER_TYPE_SELL_LIMIT || t == ORDER_TYPE_SELL_STOP);
  }

bool IsBuyType(const ENUM_ORDER_TYPE t)
  {
   return (t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_BUY);
  }

bool IsLimitType(const ENUM_ORDER_TYPE t)
  {
   return (t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT);
  }

int Sgn(const double v) { return (v > 0.0) ? 1 : ((v < 0.0) ? -1 : 0); }

//+------------------------------------------------------------------+
//| M1 data loading (completed candles only)                         |
//+------------------------------------------------------------------+
int RequiredBars()
  {
   int n = InpSlopeBars + 1;
   n = MathMax(n, InpCloseSideBars);
   n = MathMax(n, InpStructureBars * 2);
   n = MathMax(n, InpSwRangeBars);
   n = MathMax(n, InpSwCrossBars + 1);
   n = MathMax(n, InpSwErBars + 1);
   n = MathMax(n, InpSwHugBars);
   n = MathMax(n, InpRevEmaBars + 1);
   return n + 1;
  }

//--- loads `count` M1 bars starting at `shift` (shift >= 1, never the forming bar)
//--- index 0 of every array is the bar at `shift`
bool LoadSeries(const int shift, const int count)
  {
   if(shift < 1)
      return false; // the running candle is never analysed

   ArraySetAsSeries(g_rates, true);
   ArraySetAsSeries(g_ema, true);
   ArraySetAsSeries(g_atr, true);

   if(CopyRates(_Symbol, EA_TF, shift, count, g_rates) != count)
      return false;
   if(CopyBuffer(g_emaHandle, 0, shift, count, g_ema) != count)
      return false;
   if(CopyBuffer(g_atrHandle, 0, shift, count, g_atr) != count)
      return false;

   for(int i = 0; i < count; i++)
     {
      if(g_ema[i] == EMPTY_VALUE || !MathIsValidNumber(g_ema[i]))
         return false;
     }
   if(g_atr[0] == EMPTY_VALUE || !MathIsValidNumber(g_atr[0]) || g_atr[0] <= 0.0)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Objective M1 classification of one completed candle              |
//+------------------------------------------------------------------+
bool Analyze(const int shift, SAnalysis &a)
  {
   const int need = RequiredBars();
   if(!LoadSeries(shift, need))
      return false;

   a.time  = g_rates[0].time;
   a.open  = g_rates[0].open;
   a.high  = g_rates[0].high;
   a.low   = g_rates[0].low;
   a.close = g_rates[0].close;
   a.ema   = g_ema[0];
   a.atr   = g_atr[0];

   const double atr = a.atr;

//--- EMA slope and direction
   a.slopeAtr  = (g_ema[0] - g_ema[InpSlopeBars]) / atr;
   a.emaUpBars = 0;
   a.emaDnBars = 0;
   for(int i = 0; i < InpSlopeBars; i++)
     {
      if(g_ema[i] > g_ema[i + 1])
         a.emaUpBars++;
      else
         if(g_ema[i] < g_ema[i + 1])
            a.emaDnBars++;
     }

//--- price relationship with EMA
   a.distAtr     = (a.close - a.ema) / atr;
   a.closesAbove = 0;
   a.closesBelow = 0;
   for(int i = 0; i < InpCloseSideBars; i++)
     {
      if(g_rates[i].close > g_ema[i])
         a.closesAbove++;
      else
         if(g_rates[i].close < g_ema[i])
            a.closesBelow++;
     }

//--- price structure: recent block vs previous block
   const int S = InpStructureBars;
   double recentHigh = g_rates[0].high, recentLow = g_rates[0].low;
   double prevHigh   = g_rates[S].high, prevLow   = g_rates[S].low;
   for(int i = 0; i < S; i++)
     {
      recentHigh = MathMax(recentHigh, g_rates[i].high);
      recentLow  = MathMin(recentLow,  g_rates[i].low);
      prevHigh   = MathMax(prevHigh,   g_rates[i + S].high);
      prevLow    = MathMin(prevLow,    g_rates[i + S].low);
     }
   a.higherStructure = (recentHigh > prevHigh && recentLow > prevLow);
   a.lowerStructure  = (recentHigh < prevHigh && recentLow < prevLow);

//--- range compression
   double hh = g_rates[0].high, ll = g_rates[0].low;
   for(int i = 1; i < InpSwRangeBars; i++)
     {
      hh = MathMax(hh, g_rates[i].high);
      ll = MathMin(ll, g_rates[i].low);
     }
   a.rangeAtr = (hh - ll) / atr;

//--- close/EMA crosses (whipsaw)
   a.crosses = 0;
   for(int i = 0; i < InpSwCrossBars; i++)
     {
      int s0 = Sgn(g_rates[i].close - g_ema[i]);
      int s1 = Sgn(g_rates[i + 1].close - g_ema[i + 1]);
      if(s0 != 0 && s1 != 0 && s0 != s1)
         a.crosses++;
     }

//--- efficiency ratio (directional movement / total path)
   double net  = MathAbs(g_rates[0].close - g_rates[InpSwErBars].close);
   double path = 0.0;
   for(int i = 0; i < InpSwErBars; i++)
      path += MathAbs(g_rates[i].close - g_rates[i + 1].close);
   a.efficiency = (path > 0.0) ? net / path : 0.0;

//--- price hugging EMA
   double hug = 0.0;
   for(int i = 0; i < InpSwHugBars; i++)
      hug += MathAbs(g_rates[i].close - g_ema[i]);
   a.hugAtr = (hug / InpSwHugBars) / atr;

//--- sideways filter
   a.swFlags = 0;
   if(InpSwUseSlope      && MathAbs(a.slopeAtr) < InpSwMaxSlopeATR) a.swFlags |= SW_SLOPE;
   if(InpSwUseRange      && a.rangeAtr   < InpSwMinRangeATR)        a.swFlags |= SW_RANGE;
   if(InpSwUseCrosses    && a.crosses   >= InpSwMaxCrosses)         a.swFlags |= SW_CROSS;
   if(InpSwUseEfficiency && a.efficiency < InpSwMinEfficiency)      a.swFlags |= SW_ER;
   if(InpSwUseHugging    && a.hugAtr     < InpSwHugATR)             a.swFlags |= SW_HUG;

//--- trend conditions
   a.upOk = (a.distAtr     >= InpMinDistanceATR   &&
             a.slopeAtr    >= InpTrendMinSlopeATR &&
             a.emaUpBars   >= InpMinEmaDirBars    &&
             a.closesAbove >= InpMinClosesOnSide  &&
             (!InpUseStructure || a.higherStructure));

   a.downOk = (-a.distAtr     >= InpMinDistanceATR   &&
               -a.slopeAtr    >= InpTrendMinSlopeATR &&
               a.emaDnBars    >= InpMinEmaDirBars    &&
               a.closesBelow  >= InpMinClosesOnSide  &&
               (!InpUseStructure || a.lowerStructure));

   if(a.swFlags != 0)
      a.raw = RAW_SIDEWAYS;
   else
      if(a.upOk && !a.downOk)
         a.raw = RAW_UP;
      else
         if(a.downOk && !a.upOk)
            a.raw = RAW_DOWN;
         else
            a.raw = RAW_MIXED;

//--- reversal warnings against each direction
   int emaDownRun = 0, emaUpRun = 0;
   for(int i = 0; i < InpRevEmaBars; i++)
     {
      if(g_ema[i] < g_ema[i + 1]) emaDownRun++;
      else break;
     }
   for(int i = 0; i < InpRevEmaBars; i++)
     {
      if(g_ema[i] > g_ema[i + 1]) emaUpRun++;
      else break;
     }
   const double body = MathAbs(a.close - a.open);

   a.revUpFlags = 0;
   if(InpRevOnEmaCross && a.close < a.ema)                                    a.revUpFlags |= REV_CROSS;
   if(InpRevEmaBars > 0 && emaDownRun >= InpRevEmaBars)                       a.revUpFlags |= REV_EMA;
   if(InpRevBodyATR > 0.0 && a.close < a.open && body >= InpRevBodyATR * atr) a.revUpFlags |= REV_BODY;
   if(a.downOk)                                                               a.revUpFlags |= REV_OPP;

   a.revDnFlags = 0;
   if(InpRevOnEmaCross && a.close > a.ema)                                    a.revDnFlags |= REV_CROSS;
   if(InpRevEmaBars > 0 && emaUpRun >= InpRevEmaBars)                         a.revDnFlags |= REV_EMA;
   if(InpRevBodyATR > 0.0 && a.close > a.open && body >= InpRevBodyATR * atr) a.revDnFlags |= REV_BODY;
   if(a.upOk)                                                                 a.revDnFlags |= REV_OPP;

   return true;
  }

//+------------------------------------------------------------------+
//| Trend state machine (one call per completed M1 candle)           |
//+------------------------------------------------------------------+
void ResetCandidate()
  {
   g_candDir   = DIR_NONE;
   g_candCount = 0;
  }

ENUM_MARKET_STATE UpdateTrendState(const SAnalysis &a, bool &trendChanged)
  {
   trendChanged = false;

//--- 1. sideways always wins: any confirmed trend must be re-confirmed afterwards
   if(a.raw == RAW_SIDEWAYS)
     {
      if(g_confirmed != DIR_NONE)
         g_lastDir = g_confirmed;
      g_confirmed = DIR_NONE;
      ResetCandidate();
      return STATE_SIDEWAYS;
     }

//--- 2. a confirmed trend is kept only while it stays intact
   if(g_confirmed == DIR_UP)
     {
      if(a.revUpFlags != 0)
        {
         g_lastDir = DIR_UP;
         g_confirmed = DIR_NONE;
         ResetCandidate();
         return STATE_REVERSAL;
        }
      if(a.raw == RAW_UP)
         return STATE_UPTREND;
      g_lastDir = DIR_UP;
      g_confirmed = DIR_NONE;
      ResetCandidate();
      return STATE_UNCERTAIN;
     }

   if(g_confirmed == DIR_DOWN)
     {
      if(a.revDnFlags != 0)
        {
         g_lastDir = DIR_DOWN;
         g_confirmed = DIR_NONE;
         ResetCandidate();
         return STATE_REVERSAL;
        }
      if(a.raw == RAW_DOWN)
         return STATE_DOWNTREND;
      g_lastDir = DIR_DOWN;
      g_confirmed = DIR_NONE;
      ResetCandidate();
      return STATE_UNCERTAIN;
     }

//--- 3. no confirmed trend: require consecutive clean trend candles
   ENUM_TREND_DIR dir = DIR_NONE;
   if(a.raw == RAW_UP && a.revUpFlags == 0)
      dir = DIR_UP;
   else
      if(a.raw == RAW_DOWN && a.revDnFlags == 0)
         dir = DIR_DOWN;

   if(dir == DIR_NONE)
     {
      ResetCandidate();
      if(a.raw == RAW_UP || a.raw == RAW_DOWN)
         return STATE_REVERSAL; // trend conditions present but reversal warnings active
      return STATE_UNCERTAIN;
     }

   if(g_candDir == dir)
      g_candCount++;
   else
     {
      g_candDir   = dir;
      g_candCount = 1;
     }

   const bool opposite = (g_lastDir != DIR_NONE && g_lastDir != dir);
   int required = InpTrendConfirmBars;
   if(opposite)
      required = MathMax(required, InpRevConfirmBars);

   if(g_candCount >= required)
     {
      g_confirmed  = dir;
      trendChanged = opposite;
      g_lastDir    = dir;
      ResetCandidate();
      return (dir == DIR_UP) ? STATE_UPTREND : STATE_DOWNTREND;
     }

   return opposite ? STATE_REVERSAL : STATE_UNCERTAIN;
  }

//--- analyses the completed candle at `shift` and advances the state machine
bool AdvanceState(const int shift)
  {
   SAnalysis a;
   if(!Analyze(shift, a))
      return false;

   bool changed = false;
   ENUM_MARKET_STATE st = UpdateTrendState(a, changed);

   g_state        = st;
   g_last         = a;
   g_lastStateBar = a.time;

   if(changed && g_ready)
      Log(StringFormat("TREND CHANGE confirmed -> %s on candle %s",
                       StateToString(st), TimeToString(a.time, TIME_DATE | TIME_MINUTES)));
   return true;
  }

//+------------------------------------------------------------------+
//| Warm-up: replay history so the state machine is seeded           |
//+------------------------------------------------------------------+
bool WarmUp()
  {
   const int need = RequiredBars();
   const int bars = Bars(_Symbol, EA_TF);
   if(bars < need + InpEmaPeriod * 3 + 2)
      return false;
   if(BarsCalculated(g_emaHandle) < bars - 1 || BarsCalculated(g_atrHandle) < bars - 1)
      return false;

   int maxShift = MathMin(InpWarmupBars, bars - need - InpEmaPeriod * 3 - 1);
   if(maxShift < 1)
      return false;

   g_confirmed = DIR_NONE;
   g_lastDir   = DIR_NONE;
   ResetCandidate();
   g_state = STATE_UNCERTAIN;

   for(int s = maxShift; s >= 1; s--)
     {
      if(!AdvanceState(s))
         return false;
     }

   const datetime bar0 = iTime(_Symbol, EA_TF, 0);
   const datetime bar1 = iTime(_Symbol, EA_TF, 1);
   if(bar0 == 0 || bar1 == 0)
      return false;

//--- the last completed candle may have closed long ago: do not trade it, wait for the next close
   g_lastBarOpen   = bar0;
   if(bar1 > g_lastSignalBar)
      g_lastSignalBar = bar1;
   g_ready         = true;

   Log(StringFormat("Warm-up done over %d M1 candles. State=%s. Waiting for next M1 candle close.",
                    maxShift, StateToString(g_state)));
   UpdatePanel();
   return true;
  }

//+------------------------------------------------------------------+
//| Trading permission checks                                        |
//+------------------------------------------------------------------+
bool CheckTradingAllowed(const ENUM_ORDER_TYPE type)
  {
   if(!MQLInfoInteger(MQL_TESTER))
     {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
        { Log("Trading blocked: terminal not connected."); return false; }
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        { Log("Trading blocked: AutoTrading disabled in terminal."); return false; }
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     { Log("Trading blocked: live trading not allowed for this EA (check EA properties)."); return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     { Log("Trading blocked: trading not allowed on this account."); return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     { Log("Trading blocked: expert trading not allowed by broker on this account."); return false; }

   const bool isBuy = IsBuyType(type);
   ENUM_SYMBOL_TRADE_MODE tm = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tm == SYMBOL_TRADE_MODE_DISABLED || tm == SYMBOL_TRADE_MODE_CLOSEONLY)
     { Log("Trading blocked: symbol trade mode is " + EnumToString(tm)); return false; }
   if(tm == SYMBOL_TRADE_MODE_LONGONLY && !isBuy)
     { Log("Trading blocked: symbol allows long only."); return false; }
   if(tm == SYMBOL_TRADE_MODE_SHORTONLY && isBuy)
     { Log("Trading blocked: symbol allows short only."); return false; }

   const long om = SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE);
   if(IsLimitType(type) && (om & SYMBOL_ORDER_LIMIT) == 0)
     { Log("Trading blocked: limit orders not allowed on symbol."); return false; }
   if(!IsLimitType(type) && (om & SYMBOL_ORDER_STOP) == 0)
     { Log("Trading blocked: stop orders not allowed on symbol."); return false; }

   return true;
  }

//+------------------------------------------------------------------+
//| Counting helpers (EA orders only: same symbol + magic)           |
//+------------------------------------------------------------------+
int CountPendingOrders()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(IsPendingType((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)))
         n++;
     }
   return n;
  }

int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
     }
   return n;
  }

string BuildComment(const datetime barTime)
  {
   return g_commentPrefix + "|" + IntegerToString((long)barTime);
  }

//--- true if an order (pending, filled or cancelled) was already created from this candle
bool OrderExistsForBar(const datetime barTime)
  {
   const string tag = BuildComment(barTime);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(StringFind(OrderGetString(ORDER_COMMENT), tag) == 0)
         return true;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), tag) == 0)
         return true;
     }

   if(HistorySelect(barTime, TimeCurrent() + 60))
     {
      for(int i = HistoryOrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = HistoryOrderGetTicket(i);
         if(t == 0) continue;
         if(HistoryOrderGetString(t, ORDER_SYMBOL) != _Symbol) continue;
         if((ulong)HistoryOrderGetInteger(t, ORDER_MAGIC) != InpMagic) continue;
         if(StringFind(HistoryOrderGetString(t, ORDER_COMMENT), tag) == 0)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Pending price derived from the completed signal candle           |
//+------------------------------------------------------------------+
double RawEntryPrice(const ENUM_ORDER_TYPE type, const SAnalysis &a)
  {
   const double pt  = SymPoint();
   const double mid = (a.high + a.low) / 2.0;
   double ref = 0.0;

   switch(type)
     {
      case ORDER_TYPE_BUY_LIMIT: // completed bearish candle, below market
         ref = (InpLimitRef == LIMIT_REF_EXTREME) ? a.low : (InpLimitRef == LIMIT_REF_CLOSE ? a.close : mid);
         return ref - InpLimitOffsetPoints * pt;
      case ORDER_TYPE_SELL_LIMIT: // completed bullish candle, above market
         ref = (InpLimitRef == LIMIT_REF_EXTREME) ? a.high : (InpLimitRef == LIMIT_REF_CLOSE ? a.close : mid);
         return ref + InpLimitOffsetPoints * pt;
      case ORDER_TYPE_BUY_STOP: // completed bullish candle, above market
         ref = (InpStopRef == STOP_REF_EXTREME) ? a.high : a.close;
         return ref + InpStopOffsetPoints * pt;
      case ORDER_TYPE_SELL_STOP: // completed bearish candle, below market
         ref = (InpStopRef == STOP_REF_EXTREME) ? a.low : a.close;
         return ref - InpStopOffsetPoints * pt;
      default:
         return 0.0;
     }
  }

//--- validates (and optionally adjusts) the pending price against market and broker limits
bool ValidateEntryPrice(const ENUM_ORDER_TYPE type, double &price)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
     {
      Log("Price validation failed: no valid tick.");
      return false;
     }

   const double minDist = MinPendingDistance();
   const int    dg      = SymDigits();
   double       limit   = 0.0;
   bool         valid   = false;

   switch(type)
     {
      case ORDER_TYPE_BUY_LIMIT:
         price = RoundDownToTick(price);
         limit = RoundDownToTick(tick.ask - minDist);
         valid = (price <= limit);
         break;
      case ORDER_TYPE_BUY_STOP:
         price = RoundUpToTick(price);
         limit = RoundUpToTick(tick.ask + minDist);
         valid = (price >= limit);
         break;
      case ORDER_TYPE_SELL_LIMIT:
         price = RoundUpToTick(price);
         limit = RoundUpToTick(tick.bid + minDist);
         valid = (price >= limit);
         break;
      case ORDER_TYPE_SELL_STOP:
         price = RoundDownToTick(price);
         limit = RoundDownToTick(tick.bid - minDist);
         valid = (price <= limit);
         break;
      default:
         return false;
     }

   if(!valid)
     {
      if(InpInvalidPriceAction == INVALID_ADJUST)
        {
         Debug(StringFormat("%s price %s violates broker distance (bid=%s ask=%s minDist=%s) -> adjusted to %s",
                            OrderTypeToString(type), DoubleToString(price, dg),
                            DoubleToString(tick.bid, dg), DoubleToString(tick.ask, dg),
                            DoubleToString(minDist, dg), DoubleToString(limit, dg)));
         price = limit;
        }
      else
        {
         Log(StringFormat("%s skipped: price %s invalid vs market (bid=%s ask=%s, required limit %s).",
                          OrderTypeToString(type), DoubleToString(price, dg),
                          DoubleToString(tick.bid, dg), DoubleToString(tick.ask, dg),
                          DoubleToString(limit, dg)));
         return false;
        }
     }

   if(price <= 0.0)
     {
      Log(OrderTypeToString(type) + " skipped: non-positive price.");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| SL / TP                                                          |
//+------------------------------------------------------------------+
bool BuildStops(const ENUM_ORDER_TYPE type, const double price, const double atr, double &sl, double &tp)
  {
   sl = 0.0;
   tp = 0.0;
   if(InpSLTPMode == SLTP_NONE)
      return true;

   double slDist = 0.0, tpDist = 0.0;
   if(InpSLTPMode == SLTP_POINTS)
     {
      slDist = InpSLValue * SymPoint();
      tpDist = InpTPValue * SymPoint();
     }
   else
     {
      slDist = InpSLValue * atr;
      tpDist = InpTPValue * atr;
     }

   const double minStop = MinStopDistance();
   if(slDist > 0.0 && slDist < minStop)
     {
      Debug("SL distance below broker stops level -> widened to minimum.");
      slDist = minStop;
     }
   if(tpDist > 0.0 && tpDist < minStop)
     {
      Debug("TP distance below broker stops level -> widened to minimum.");
      tpDist = minStop;
     }

   if(IsBuyType(type))
     {
      if(slDist > 0.0) sl = RoundDownToTick(price - slDist);
      if(tpDist > 0.0) tp = RoundUpToTick(price + tpDist);
     }
   else
     {
      if(slDist > 0.0) sl = RoundUpToTick(price + slDist);
      if(tpDist > 0.0) tp = RoundDownToTick(price - tpDist);
     }

   if((slDist > 0.0 && sl <= 0.0) || (tpDist > 0.0 && tp <= 0.0))
     {
      Log("Order skipped: computed SL/TP is not a valid positive price.");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Volume                                                           |
//+------------------------------------------------------------------+
int VolumeDigits(const double step)
  {
   int    d = 0;
   double s = step;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1e-8)
     {
      s *= 10.0;
      d++;
     }
   return d;
  }

double CalcVolume(const ENUM_ORDER_TYPE type, const double price, const double sl)
  {
   const double vMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double       vStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vStep <= 0.0)
      vStep = vMin;

   double vol       = InpFixedLot;
   bool   riskBased = false;

   if(InpLotMode == LOT_RISK_PERCENT)
     {
      if(sl <= 0.0)
         Log("Risk-% lot mode needs an SL; falling back to fixed lot.");
      else
        {
         double loss = 0.0;
         ENUM_ORDER_TYPE calcType = IsBuyType(type) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         if(OrderCalcProfit(calcType, _Symbol, 1.0, price, sl, loss) && loss < 0.0)
           {
            double risk = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
            vol = risk / (-loss);
            riskBased = true;
           }
         else
            Log("OrderCalcProfit failed; falling back to fixed lot.");
        }
     }

   vol = MathFloor(vol / vStep + 1e-9) * vStep;
   vol = NormalizeDouble(vol, VolumeDigits(vStep));

   if(vol < vMin)
     {
      if(riskBased)
        {
         Log(StringFormat("Order skipped: risk-based volume %.4f below symbol minimum %.4f.", vol, vMin));
         return 0.0;
        }
      vol = vMin;
     }
   if(vMax > 0.0 && vol > vMax)
      vol = vMax;
   return vol;
  }

//--- SYMBOL_VOLUME_LIMIT: max aggregate position + pending volume in one direction
bool CheckVolumeLimit(const ENUM_ORDER_TYPE type, const double vol)
  {
   const double limit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(limit <= 0.0)
      return true;

   const bool isBuy = IsBuyType(type);
   double total = vol;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      bool posBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(posBuy == isBuy)
         total += PositionGetDouble(POSITION_VOLUME);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(IsPendingType(ot) && IsBuyType(ot) == isBuy)
         total += OrderGetDouble(ORDER_VOLUME_CURRENT);
     }

   if(total > limit + 1e-9)
     {
      Log(StringFormat("Order skipped: symbol volume limit %.2f would be exceeded (%.2f).", limit, total));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Expiration and filling                                           |
//+------------------------------------------------------------------+
void GetExpiration(ENUM_ORDER_TYPE_TIME &typeTime, datetime &expiration)
  {
   const int mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   typeTime   = ORDER_TIME_GTC;
   expiration = 0;

   if(InpExpiryMinutes > 0 && (mode & SYMBOL_EXPIRATION_SPECIFIED) != 0)
     {
      typeTime   = ORDER_TIME_SPECIFIED;
      expiration = TimeCurrent() + InpExpiryMinutes * 60;
      return;
     }
   // broker-side expiration unavailable: the EA deletes expired orders itself (see ManagePendingOrders)
   if((mode & SYMBOL_EXPIRATION_GTC) == 0 && (mode & SYMBOL_EXPIRATION_DAY) != 0)
      typeTime = ORDER_TIME_DAY;
  }

int FillingCandidates(ENUM_ORDER_TYPE_FILLING &fills[])
  {
   ArrayResize(fills, 0);
   const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   int n = 0;
   ArrayResize(fills, 3);
   fills[n++] = ORDER_FILLING_RETURN;
   if((fm & SYMBOL_FILLING_FOK) != 0) fills[n++] = ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) != 0) fills[n++] = ORDER_FILLING_IOC;
   ArrayResize(fills, n);
   return n;
  }

bool IsTransientRetcode(const uint rc)
  {
   return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TIMEOUT ||
           rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_TOO_MANY_REQUESTS ||
           rc == TRADE_RETCODE_INVALID_PRICE);
  }

//--- OrderCheck + send; tries each allowed filling policy. Returns final retcode in `rc`.
bool SendPending(const ENUM_ORDER_TYPE type, const double vol, const double price,
                 const double sl, const double tp, const ENUM_ORDER_TYPE_TIME typeTime,
                 const datetime expiration, const string comment, uint &rc)
  {
   ENUM_ORDER_TYPE_FILLING fills[];
   const int n = FillingCandidates(fills);
   rc = 0;

   for(int f = 0; f < n; f++)
     {
      MqlTradeRequest     req = {};
      MqlTradeCheckResult chk = {};
      req.action       = TRADE_ACTION_PENDING;
      req.magic        = InpMagic;
      req.symbol       = _Symbol;
      req.volume       = vol;
      req.price        = price;
      req.sl           = sl;
      req.tp           = tp;
      req.deviation    = (ulong)InpDeviationPoints;
      req.type         = type;
      req.type_filling = fills[f];
      req.type_time    = typeTime;
      req.expiration   = expiration;
      req.comment      = comment;

      if(!OrderCheck(req, chk))
        {
         rc = chk.retcode;
         if(rc == TRADE_RETCODE_INVALID_FILL)
            continue;
         Log(StringFormat("OrderCheck rejected %s: retcode=%u (%s)",
                          OrderTypeToString(type), rc, chk.comment));
         return false;
        }

      g_trade.SetTypeFilling(fills[f]);
      g_trade.OrderOpen(_Symbol, type, vol, 0.0, price, sl, tp, typeTime, expiration, comment);
      rc = g_trade.ResultRetcode();
      if(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED)
         return true;
      if(rc == TRADE_RETCODE_INVALID_FILL)
         continue;

      Log(StringFormat("OrderSend %s failed: retcode=%u (%s)",
                       OrderTypeToString(type), rc, g_trade.ResultRetcodeDescription()));
      return false;
     }

   Log(StringFormat("%s failed: no accepted filling policy (retcode=%u).", OrderTypeToString(type), rc));
   return false;
  }

//+------------------------------------------------------------------+
//| Full pending order placement pipeline                            |
//+------------------------------------------------------------------+
bool PlacePending(const ENUM_ORDER_TYPE type, const SAnalysis &a)
  {
   const string name = OrderTypeToString(type);
   const int    dg   = SymDigits();

   if(!CheckTradingAllowed(type))
      return false;

   if(InpMaxSpreadPoints > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
        {
         Log(StringFormat("%s skipped: spread %d > max %d points.", name, (int)spread, InpMaxSpreadPoints));
         return false;
        }
     }

   if(InpMaxPendingOrders > 0 && CountPendingOrders() >= InpMaxPendingOrders)
     {
      Log(StringFormat("%s skipped: max pending orders (%d) reached.", name, InpMaxPendingOrders));
      return false;
     }

   if(InpMaxOpenPositions > 0 && CountPositions() >= InpMaxOpenPositions)
     {
      Log(StringFormat("%s skipped: max open positions (%d) reached.", name, InpMaxOpenPositions));
      return false;
     }

   if(OrderExistsForBar(a.time))
     {
      Log(name + " skipped: an order already exists for candle " + TimeToString(a.time, TIME_DATE | TIME_MINUTES));
      return false;
     }

   const string comment = BuildComment(a.time);
   const double rawPrice = RawEntryPrice(type, a);

   for(int attempt = 0; attempt <= InpMaxRetries; attempt++)
     {
      double price = rawPrice;
      if(!ValidateEntryPrice(type, price))
         return false;

      double sl = 0.0, tp = 0.0;
      if(!BuildStops(type, price, a.atr, sl, tp))
         return false;

      const double vol = CalcVolume(type, price, sl);
      if(vol <= 0.0)
         return false;
      if(!CheckVolumeLimit(type, vol))
         return false;

      ENUM_ORDER_TYPE_TIME typeTime;
      datetime expiration;
      GetExpiration(typeTime, expiration);

      uint rc = 0;
      if(SendPending(type, vol, price, sl, tp, typeTime, expiration, comment, rc))
        {
         Log(StringFormat("PLACED %s #%I64u | candle %s O=%s H=%s L=%s C=%s | price=%s sl=%s tp=%s vol=%s exp=%s",
                          name, g_trade.ResultOrder(),
                          TimeToString(a.time, TIME_DATE | TIME_MINUTES),
                          DoubleToString(a.open, dg), DoubleToString(a.high, dg),
                          DoubleToString(a.low, dg), DoubleToString(a.close, dg),
                          DoubleToString(price, dg), DoubleToString(sl, dg), DoubleToString(tp, dg),
                          DoubleToString(vol, VolumeDigits(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP))),
                          (expiration > 0 ? TimeToString(expiration, TIME_DATE | TIME_MINUTES) : "GTC/EA-managed")));
         return true;
        }

      if(!IsTransientRetcode(rc) || attempt == InpMaxRetries)
         return false;

      Debug(StringFormat("Transient error %u, retrying %s (%d/%d).", rc, name, attempt + 1, InpMaxRetries));
      Sleep(250);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Pending order management (EA's own orders only)                  |
//+------------------------------------------------------------------+
bool DeletePending(const ulong ticket, const string reason)
  {
   if(!OrderSelect(ticket))
      return false;

   const double price  = OrderGetDouble(ORDER_PRICE_OPEN);
   const double freeze = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * SymPoint();
   if(freeze > 0.0)
     {
      MqlTick tick;
      if(SymbolInfoTick(_Symbol, tick))
        {
         ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         double ref = IsBuyType(t) ? tick.ask : tick.bid;
         if(MathAbs(price - ref) <= freeze)
           {
            Debug(StringFormat("Cannot delete #%I64u now (inside freeze level); will retry next candle.", ticket));
            return false;
           }
        }
     }

   if(g_trade.OrderDelete(ticket))
     {
      Log(StringFormat("Deleted pending #%I64u (%s).", ticket, reason));
      return true;
     }
   Log(StringFormat("Failed to delete #%I64u (%s): retcode=%u (%s)", ticket, reason,
                    g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
   return false;
  }

void ManagePendingOrders(const ENUM_MARKET_STATE state)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(!IsPendingType(type)) continue;

      const bool     isBuy = IsBuyType(type);
      const datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      string reason = "";

      if(state == STATE_SIDEWAYS && InpDeleteOnSideways)
         reason = "market SIDEWAYS";
      else
         if(state == STATE_REVERSAL && InpDeleteOnReversal)
            reason = "trend REVERSAL";
         else
            if(InpDeleteOpposite && ((state == STATE_UPTREND && !isBuy) || (state == STATE_DOWNTREND && isBuy)))
               reason = "opposite to confirmed " + StateToString(state);
            else
               if(InpExpiryMinutes > 0 && TimeCurrent() - setup >= InpExpiryMinutes * 60)
                  reason = "expired";
               else
                  if(InpDeleteStale && InpStaleBars > 0)
                    {
                     int age = iBarShift(_Symbol, EA_TF, setup, false);
                     if(age >= InpStaleBars)
                        reason = StringFormat("stale (%d M1 bars)", age);
                    }

      if(reason != "")
         DeletePending(ticket, reason);
     }
  }

//+------------------------------------------------------------------+
//| Signal: strict mapping trend x candle -> pending order type      |
//+------------------------------------------------------------------+
void ProcessSignal(const SAnalysis &a, const ENUM_MARKET_STATE state)
  {
   const string bar = TimeToString(a.time, TIME_DATE | TIME_MINUTES);

   if(state == STATE_SIDEWAYS)
     {
      Debug("Candle " + bar + ": SIDEWAYS (" + SidewaysReasons(a.swFlags) + ") -> NO ORDER");
      return;
     }
   if(state == STATE_REVERSAL)
     {
      string why = ReversalReasons(g_lastDir == DIR_DOWN ? a.revDnFlags : a.revUpFlags);
      Debug("Candle " + bar + ": REVERSAL (" + why + ") -> NO ORDER");
      return;
     }
   if(state != STATE_UPTREND && state != STATE_DOWNTREND)
     {
      Debug("Candle " + bar + ": UNCERTAIN -> NO ORDER");
      return;
     }

   const bool bullish = (a.close > a.open);
   const bool bearish = (a.close < a.open);
   if(!bullish && !bearish)
     {
      Debug("Candle " + bar + ": doji (open == close), neither bullish nor bearish -> NO ORDER");
      return;
     }

   ENUM_ORDER_TYPE type = ORDER_TYPE_BUY_LIMIT;
   if(state == STATE_UPTREND)
      type = bearish ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_BUY_STOP;
   else
      type = bullish ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_SELL_STOP;

   if(g_ordersThisCandle >= InpMaxOrdersPerCandle)
     {
      Debug("Candle " + bar + ": max orders per candle reached.");
      return;
     }

   Debug(StringFormat("Candle %s: %s + %s candle -> %s", bar, StateToString(state),
                      bullish ? "bullish" : "bearish", OrderTypeToString(type)));

   if(PlacePending(type, a))
      g_ordersThisCandle++;
  }

//+------------------------------------------------------------------+
//| Main M1 engine                                                   |
//+------------------------------------------------------------------+
void ProcessM1()
  {
   if(!g_ready)
     {
      WarmUp();
      return;
     }

//--- 1. detect a new M1 candle
   const datetime bar0 = iTime(_Symbol, EA_TF, 0);
   if(bar0 == 0 || bar0 == g_lastBarOpen)
      return; // still inside the same running candle: do nothing

//--- 2. confirm the previous M1 candle is completely closed
   const datetime bar1 = iTime(_Symbol, EA_TF, 1);
   if(bar1 == 0 || bar1 >= bar0)
      return;
   if(TimeCurrent() < bar1 + PeriodSeconds(EA_TF))
      return;

//--- 3-5. feed every completed candle since the last update into the state machine
   int lastShift = iBarShift(_Symbol, EA_TF, g_lastStateBar, true);
   if(lastShift < 1 || lastShift > InpWarmupBars)
     {
      Log("M1 history gap detected; rebuilding trend state (current candle will not be traded).");
      g_ready = false;
      WarmUp();
      return;
     }
   for(int s = lastShift - 1; s >= 1; s--)
     {
      if(!AdvanceState(s))
         return; // data not ready yet, retry on next tick
     }
   if(g_last.time != bar1)
      return;

   g_lastBarOpen = bar0;

   Debug(StringFormat("M1 %s O=%s H=%s L=%s C=%s EMA=%s ATR=%s | slope=%.2f dist=%.2f range=%.2f ER=%.2f hug=%.2f x=%d | %s",
                      TimeToString(g_last.time, TIME_DATE | TIME_MINUTES),
                      DoubleToString(g_last.open, SymDigits()), DoubleToString(g_last.high, SymDigits()),
                      DoubleToString(g_last.low, SymDigits()), DoubleToString(g_last.close, SymDigits()),
                      DoubleToString(g_last.ema, SymDigits()), DoubleToString(g_last.atr, SymDigits()),
                      g_last.slopeAtr, g_last.distAtr, g_last.rangeAtr, g_last.efficiency, g_last.hugAtr,
                      g_last.crosses, StateToString(g_state)));

//--- order management on the new M1 state (before any new order)
   ManagePendingOrders(g_state);

//--- duplicate protection: each completed candle is processed once
   if(g_last.time <= g_lastSignalBar)
     {
      UpdatePanel();
      return;
     }
   g_lastSignalBar    = g_last.time;
   g_ordersThisCandle = 0;

//--- 6-12. filters, mapping, validation, placement
   ProcessSignal(g_last, g_state);
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Chart panel                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(!InpShowPanel)
      return;
   string s = "EMA9 M1 Pending Order EA (all logic on M1)\n";
   s += StringFormat("State: %s   (confirmed=%d last=%d candidate=%d x%d)\n",
                     StateToString(g_state), (int)g_confirmed, (int)g_lastDir, (int)g_candDir, g_candCount);
   if(g_last.time > 0)
     {
      s += StringFormat("Last closed M1: %s  EMA%d=%s\n", TimeToString(g_last.time, TIME_DATE | TIME_MINUTES),
                        InpEmaPeriod, DoubleToString(g_last.ema, SymDigits()));
      s += StringFormat("slope=%.2f ATR  dist=%.2f ATR  range=%.2f ATR  ER=%.2f  crosses=%d\n",
                        g_last.slopeAtr, g_last.distAtr, g_last.rangeAtr, g_last.efficiency, g_last.crosses);
      if(g_last.swFlags != 0)
         s += "Sideways: " + SidewaysReasons(g_last.swFlags) + "\n";
     }
   s += StringFormat("EA pending: %d   EA positions: %d", CountPendingOrders(), CountPositions());
   Comment(s);
  }

//+------------------------------------------------------------------+
//| Input validation                                                 |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   bool ok = true;
   if(InpEmaPeriod < 1)                         { Log("InpEmaPeriod must be >= 1"); ok = false; }
   if(InpAtrPeriod < 1)                         { Log("InpAtrPeriod must be >= 1"); ok = false; }
   if(InpSlopeBars < 1)                         { Log("InpSlopeBars must be >= 1"); ok = false; }
   if(InpMinEmaDirBars < 0 || InpMinEmaDirBars > InpSlopeBars)
                                                { Log("InpMinEmaDirBars must be 0..InpSlopeBars"); ok = false; }
   if(InpCloseSideBars < 1)                     { Log("InpCloseSideBars must be >= 1"); ok = false; }
   if(InpMinClosesOnSide < 0 || InpMinClosesOnSide > InpCloseSideBars)
                                                { Log("InpMinClosesOnSide must be 0..InpCloseSideBars"); ok = false; }
   if(InpStructureBars < 1)                     { Log("InpStructureBars must be >= 1"); ok = false; }
   if(InpTrendConfirmBars < 1)                  { Log("InpTrendConfirmBars must be >= 1"); ok = false; }
   if(InpRevConfirmBars < 1)                    { Log("InpRevConfirmBars must be >= 1"); ok = false; }
   if(InpRevEmaBars < 0)                        { Log("InpRevEmaBars must be >= 0"); ok = false; }
   if(InpSwRangeBars < 1 || InpSwCrossBars < 1 || InpSwErBars < 1 || InpSwHugBars < 1)
                                                { Log("Sideways lookbacks must be >= 1"); ok = false; }
   if(InpWarmupBars < RequiredBars() + 1)       { Log("InpWarmupBars too small for configured lookbacks"); ok = false; }
   if(InpMaxOrdersPerCandle < 1)                { Log("InpMaxOrdersPerCandle must be >= 1"); ok = false; }
   if(InpFixedLot <= 0.0)                       { Log("InpFixedLot must be > 0"); ok = false; }
   if(InpLotMode == LOT_RISK_PERCENT && InpRiskPercent <= 0.0)
                                                { Log("InpRiskPercent must be > 0"); ok = false; }
   if(InpLimitOffsetPoints < 0 || InpStopOffsetPoints < 0 || InpExtraDistPoints < 0)
                                                { Log("Offsets must be >= 0"); ok = false; }
   if(InpExpiryMinutes < 0 || InpMaxPendingOrders < 0 || InpMaxOpenPositions < 0 ||
      InpMaxSpreadPoints < 0 || InpDeviationPoints < 0 || InpMaxRetries < 0 || InpStaleBars < 0)
                                                { Log("Counts/limits must be >= 0"); ok = false; }
   if(InpSLValue < 0.0 || InpTPValue < 0.0)     { Log("SL/TP values must be >= 0"); ok = false; }
   if(InpTrendMinSlopeATR < InpSwMaxSlopeATR)
      Log("Warning: InpTrendMinSlopeATR < InpSwMaxSlopeATR; the flat-EMA filter will dominate.");
   if(InpEmaPeriod != 9)
      Log(StringFormat("Warning: EMA period is %d; the strategy specification uses 9.", InpEmaPeriod));
   if(InpEmaPrice != PRICE_CLOSE)
      Log("Warning: EMA price is not Close; the strategy specification uses Close.");
   return ok;
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   if(!SymbolInfoInteger(_Symbol, SYMBOL_EXIST))
     {
      Log("Symbol does not exist.");
      return INIT_FAILED;
     }
   if(!SymbolSelect(_Symbol, true))
     {
      Log("Cannot select symbol in Market Watch.");
      return INIT_FAILED;
     }

   g_commentPrefix = StringSubstr(InpOrderComment, 0, 10);

   g_emaHandle = iMA(_Symbol, EA_TF, InpEmaPeriod, 0, MODE_EMA, InpEmaPrice);
   g_atrHandle = iATR(_Symbol, EA_TF, InpAtrPeriod);
   if(g_emaHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
     {
      Log(StringFormat("Failed to create M1 indicator handles (error %d).", GetLastError()));
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpDeviationPoints);
   g_trade.SetAsyncMode(false);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_ready         = false;
   g_lastBarOpen   = 0;
   g_lastStateBar  = 0;
   g_lastSignalBar = 0;
   ZeroMemory(g_last);

   if(_Period != EA_TF)
      Log("Note: chart timeframe is " + EnumToString(_Period) +
          ". The EA ignores it and uses M1 data exclusively.");

   EventSetTimer(1); // lets the engine detect M1 closes even when ticks are sparse

   Log(StringFormat("Initialized. EMA%d(M1,%s), ATR%d(M1). Digits=%d Point=%s TickSize=%s StopsLevel=%d FreezeLevel=%d",
                    InpEmaPeriod, EnumToString(InpEmaPrice), InpAtrPeriod, SymDigits(),
                    DoubleToString(SymPoint(), SymDigits()), DoubleToString(TickSize(), SymDigits()),
                    (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                    (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_emaHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   g_emaHandle = INVALID_HANDLE;
   g_atrHandle = INVALID_HANDLE;
   Comment("");
  }

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
void OnTick()  { ProcessM1(); }
void OnTimer() { ProcessM1(); }
//+------------------------------------------------------------------+
