# MT5 EMA9 M1 Pending-Order Expert Advisors

| File | Description |
|---|---|
| `M1_EMA9_Pending_Strategy_FIXED.mq5` | **v3.00**: the M1 EMA9 pending-order strategy with trend-continuation and complete trend-reversal protection |
| `EMA9_M1_PendingOrders.mq5` | Earlier ATR-based version, unchanged (documented at the end) |

---

## M1_EMA9_Pending_Strategy_FIXED.mq5 (v3.00)

### Install
1. Copy the file to `MQL5/Experts/` in your MT5 data folder.
2. Open it in MetaEditor and press **Compile** (F7).
3. Attach it to any chart of the symbol. The EA reads **M1 data only**, whatever the chart timeframe.
4. Use a **hedging** account. On a netting account MT5 merges every trade on the symbol into one position, so a manual trade would be closed together with the EA position. The EA prints a warning at start-up in that case.

### Strategy (unchanged from v2.10)

| M1 trend (from the candles before the signal candle) | Completed signal candle | Pending order at the candle close |
|---|---|---|
| UPTREND | Bearish | BUY LIMIT |
| UPTREND | Bullish | BUY STOP |
| DOWNTREND | Bullish | SELL LIMIT |
| DOWNTREND | Bearish | SELL STOP |
| SIDEWAYS / REVERSAL warning / UNCERTAIN | Any | No order |

The EMA, trend, sideways and reversal-warning filters, entry prices, lot size, magic number, SL/TP (none) and
expiration are exactly as in v2.10. With `InpUseReversalProtection = false` the EA behaves exactly like v2.10.

The strategy places its orders **without SL/TP**, so the EA itself closes positions only through the reversal protection described below.

### What v3.00 adds: trend reversal protection

A trading state machine decides **when** the original strategy may place orders:

```
UPTREND / DOWNTREND   -> original strategy runs; pullbacks and consolidations are tolerated
SIDEWAYS / UNCERTAIN  -> no new orders until a trend is confirmed
REVERSAL_DETECTED     -> cancel ALL EA pending orders, close ALL EA positions, verify
WAITING_FOR_NEW_TREND -> no new orders until a NEW trend is confirmed, then the
                         original strategy resumes in the new direction
```

```
UPTREND -> pending orders -> possible bearish reversal -> confirmation 1/2 -> 2/2
   -> REVERSAL CONFIRMED -> cancel all EA pending orders -> close all EA positions
   -> cleanup verified -> WAITING_FOR_NEW_TREND -> new DOWNTREND confirmed
   -> bearish pending-order process (and the mirror image for a DOWNTREND)
```

#### Reversal detection (once per completed M1 candle)
Each completed candle is scored against the active trend using the same M1 EMA:

| | Factor (shown for an uptrend; mirrored for a downtrend) |
|---|---|
| F1 | EMA falling for `InpRevEmaSlopeBars` candles |
| F2 | Close below the EMA by at least `InpRevMinBreakPoints` |
| F3 | `InpRevConsecCloses` consecutive closes below the EMA |
| F4 | Close below the most recent swing low (`InpRevSwingStrength` candles each side, searched over `InpRevSwingLookback`) |
| F5 | Lower high and lower low versus the previous block of `InpRevStructureBars` candles |
| F6 | Bearish body ≥ `InpRevStrongBodyMult` × the average body |
| F7 | EMA momentum weakening (`InpRevMomentumBars`, `InpRevMomentumRatio`) |
| F8 | The original uptrend conditions are no longer satisfied |
| F9 | The original logic classifies a DOWNTREND |

A candle counts as **one confirmation** only when all of these hold:
- at least `InpRevMinScore` factors are present;
- the required structure is present (`InpRevStructureMode`, default: swing break F4). A normal pullback keeps the last swing low;
- the close is beyond the EMA (`InpRevRequireEmaCross`);
- the original logic does not classify the candle SIDEWAYS (`InpRevIgnoreSideways`), because consolidation is not a reversal.

**REVERSAL CONFIRMED** when any of these happens:
- `InpRevConfirmCandles` confirmations occur within `InpRevWindowBars` candles. A candle on which the original trend conditions hold again clears the warning, because it was a pullback.
- One strong opposite candle (F6) shows at least `InpRevInstantScore` factors (crash protection, `0` = off).
- Backstop: the original logic has classified the opposite trend on `InpNewTrendConfirmBars` of the last `InpNewTrendWindowBars` candles.

#### Cleanup
- Detection uses completed candles; the cleanup runs immediately, and no order is placed on the cleanup candle or tick.
- Every EA pending order (any pending type) is cancelled first, then every EA position is closed, including positions created when EA pending orders were activated.
- Only orders and positions with **this symbol and `InpMagicNumber`** are touched. Ownership is re-checked right before each request, so manual trades and other EAs are never closed.
- Each ticket gets up to `InpCleanupRetries` immediate retries on transient errors (requote, price changed, timeout and similar). Each failure is logged with the ticket, retcode and error.
- The result is verified by re-scanning the terminal. Until nothing is left the state stays `REVERSAL_DETECTED`, new orders stay blocked, and the cleanup is retried on later ticks after 1, 2, 4, 8, 16 and then 30 seconds. Market closed, freeze level and AutoTrading off are all handled this way.
- After a verified cleanup the old trend data is cleared (counters and candle history) and the state becomes `WAITING_FOR_NEW_TREND`.

#### New trend, sideways, restart
- **New trend after a reversal:** at least `InpNewTrendConfirmBars` of the latest `InpNewTrendWindowBars` candles must be classified as the same trend by the original logic, with no opposite-trend candle. Only candles that closed after the cleanup count, which prevents the close/re-open loop.
- **Sideways:** sideways and uncertain candles inside a trend place no order, as before. After `InpTrendInvalidationBars` candles in a row without a trend candle, the trend is invalidated and the state becomes `SIDEWAYS/UNCERTAIN`: stale EA pending orders are cancelled (`InpCancelPendingOnInvalidation`) and open positions are kept but stay protected by the reversal detector.
- **Restart / re-initialisation:** on the first tick the EA replays the last `InpRecoveryBars` completed M1 candles to rebuild its state, then compares it with its existing orders and positions. If a reversal is confirmed, if the EA's exposure is against the confirmed trend, or if it holds buy-side and sell-side exposure together, the cleanup runs immediately. Otherwise the EA continues and protects the existing positions. Candles that were already processed are never traded again.

#### Journal messages
```
[Trend] UPTREND confirmed on candle ...
[Trend] Possible reversal detected against UPTREND on candle ...
[Reversal] Confirmation 1/2 (score 5/9: close-beyond-EMA swing-break ...)
[Reversal] Confirmation 2/2 (score 7/9: ...)
[Reversal] REVERSAL CONFIRMED against UPTREND on candle ... - 2 confirmation candle(s) ...
[Reversal] Cancelling all EA pending orders (3)
[Reversal] Closing EA position ticket: 123456 (BUY 0.01 lots, open ..., floating P/L ...)
[Reversal] Cleanup completed - verified: no EA pending orders and no EA positions remain
[State] WAITING_FOR_NEW_TREND - old UPTREND data cleared, no new orders until a new trend is confirmed
[Trend] New DOWNTREND confirmed on candle ...
[State] Resuming trading - bearish pending-order process (SELL LIMIT / SELL STOP)
```
State, trend, reversal and cleanup messages are always printed. Per-candle details follow `InpDebugLog`.

### New inputs (v3.00)

| Input | Default | Meaning |
|---|---|---|
| `InpUseReversalProtection` | true | `false` = exact v2.10 behaviour |
| `InpTrendConfirmBars` | 1 | Trend candles in a row to confirm a trend from SIDEWAYS/UNCERTAIN (1 = original) |
| `InpNewTrendConfirmBars` / `InpNewTrendWindowBars` | 3 / 6 | New-trend confirmation after a reversal |
| `InpTrendInvalidationBars` | 15 | Candles without a trend candle before the trend is invalidated (0 = off) |
| `InpCancelPendingOnInvalidation` | true | Cancel stale pending orders on invalidation |
| `InpRevMinScore` | 4 | Factors needed on one confirmation candle |
| `InpRevConfirmCandles` / `InpRevWindowBars` | 2 / 5 | Confirmation candles needed, and the window they must fall in |
| `InpRevStructureMode` | Swing break | Structure needed for a confirmation (none / swing break / any of F4, F5, F9) |
| `InpRevRequireEmaCross` | true | A confirmation needs the close beyond the EMA |
| `InpRevIgnoreSideways` | true | SIDEWAYS candles never count as confirmations |
| `InpRevInstantScore` | 6 | Factors on one strong candle that confirm at once (0 = off) |
| `InpRevUse*` + parameters | see EA | Enable and tune each factor F1–F9 |
| `InpRevMinBreakPoints` | 10 | Minimum distance (points) beyond the EMA or swing level for F2, F3 and F4 |
| `InpCleanupRetries` / `InpCleanupRetryDelayMs` | 3 / 250 | Immediate retries per ticket |
| `InpRecoveryBars` | 300 | M1 candles replayed after a restart |

To make the protection more sensitive, lower `InpRevConfirmCandles` or `InpRevSwingStrength`, or set
`InpRevStructureMode = any`. To make it calmer, raise `InpRevConfirmCandles`, `InpRevMinScore` or `InpRevMinBreakPoints`.

Two original inputs, `InpMaxOrdersPerCandle` and `InpDeleteStalePendingOrders`, are not used by the strategy code (unchanged since v2.10).

---

## EMA9_M1_PendingOrders.mq5 (earlier ATR-based version)

### Install
1. Copy the file to `MQL5/Experts/` in your MT5 data folder.
2. Open it in MetaEditor and press **Compile** (F7).
3. Attach it to any chart of the symbol. The EA reads **M1 data only**, whatever the chart timeframe.

### Strategy mapping (fixed)

| M1 Trend | Completed candle | Pending order |
|---|---|---|
| UPTREND | Bearish | BUY LIMIT |
| UPTREND | Bullish | BUY STOP |
| DOWNTREND | Bullish | SELL LIMIT |
| DOWNTREND | Bearish | SELL STOP |
| SIDEWAYS / REVERSAL / UNCERTAIN | Any | No order |

A doji (open == close) is neither bullish nor bearish, so it gets no order.

### Execution flow (once per completed M1 candle)
1. Detect a new M1 bar (`iTime(_Symbol, PERIOD_M1, 0)` changes). The running candle is never analysed.
2. Analyse the just-closed candle (shift 1) with EMA(9, Close, M1) and M1 ATR. ATR is only a volatility unit, so thresholds carry across symbols and brokers.
3. Classify the trend with a state machine:
   - **Sideways** if any enabled filter fires: flat EMA slope, compressed High-Low range, repeated close/EMA crosses, low efficiency ratio, or price hugging the EMA.
   - **Uptrend/Downtrend candidate** requires all of these: close beyond the EMA by a minimum distance, EMA slope above a threshold, most EMA bars moving in the trend direction, most closes on the trend side, and an HH/HL (or LL/LH) structure.
   - A trend is **confirmed** only after `InpTrendConfirmBars` consecutive clean candidates. If the new trend is opposite to the previous one, it needs `InpRevConfirmBars`.
   - A confirmed trend turns into **REVERSAL** on any of these: a close across the EMA, the EMA turning against the trend for N bars, a strong opposite candle, or opposite-trend conditions. The trend must then be confirmed again.
4. Manage existing EA orders: delete opposite-direction orders, expired or stale orders, and (optionally) orders still pending during sideways or reversal.
5. If the candle has not been processed yet (tracked by bar time, plus a comment tag `E9M1|<bar time>` that survives restarts), apply the mapping above.
6. Derive the price from the signal candle (extreme, close or midpoint, plus an offset). Check it against Ask/Bid, the stops level and the freeze level, and align it to the tick size. Invalid prices are skipped by default, or moved to the nearest valid price if you choose that option.
7. Run `OrderCheck`, then send the order with `CTrade`. The EA tries each allowed filling policy and retries on transient errors.

### Key inputs
- **EMA:** `InpEmaPeriod` = 9, `InpEmaPrice` = Close.
- **Trend:** slope, distance, EMA-direction, close-side and structure thresholds, plus the number of confirmation bars.
- **Sideways:** each filter can be switched on or off and has its own threshold.
- **Reversal:** EMA-cross, EMA-turn bars, strong opposite body, and confirmation bars after a reversal.
- **Orders:** reference price, offsets, expiration, max pending orders, max orders per candle, max positions, max spread, deviation.
- **Management:** delete opposite / stale / on-sideways / on-reversal.
- **Volume / SL / TP:** fixed lot or risk % of equity; SL/TP off, in points, or as ATR multiples. The default is 2×ATR for both. SL/TP is not part of the strategy specification, so set `InpSLTPMode = SLTP_NONE` to disable it.

Only orders that match **this symbol and `InpMagic`** are ever counted, modified or deleted.
