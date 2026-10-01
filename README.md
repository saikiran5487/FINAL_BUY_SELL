# EMA9 M1 Pending-Order Expert Advisor (MetaTrader 5)

File: `EMA9_M1_PendingOrders.mq5`

## Install
1. Copy the file to `MQL5/Experts/` in your MT5 data folder.
2. Open it in MetaEditor and press **Compile** (F7).
3. Attach it to any chart of the symbol. The EA reads **M1 data only**, whatever the chart timeframe.

## Strategy mapping (fixed)

| M1 Trend | Completed candle | Pending order |
|---|---|---|
| UPTREND | Bearish | BUY LIMIT |
| UPTREND | Bullish | BUY STOP |
| DOWNTREND | Bullish | SELL LIMIT |
| DOWNTREND | Bearish | SELL STOP |
| SIDEWAYS / REVERSAL / UNCERTAIN | Any | No order |

A doji (open == close) is neither bullish nor bearish, so it gets no order.

## Execution flow (once per completed M1 candle)
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

## Key inputs
- **EMA:** `InpEmaPeriod` = 9, `InpEmaPrice` = Close.
- **Trend:** slope, distance, EMA-direction, close-side and structure thresholds, plus the number of confirmation bars.
- **Sideways:** each filter can be switched on or off and has its own threshold.
- **Reversal:** EMA-cross, EMA-turn bars, strong opposite body, and confirmation bars after a reversal.
- **Orders:** reference price, offsets, expiration, max pending orders, max orders per candle, max positions, max spread, deviation.
- **Management:** delete opposite / stale / on-sideways / on-reversal.
- **Volume / SL / TP:** fixed lot or risk % of equity; SL/TP off, in points, or as ATR multiples. The default is 2×ATR for both. SL/TP is not part of the strategy specification, so set `InpSLTPMode = SLTP_NONE` to disable it.

Only orders that match **this symbol and `InpMagic`** are ever counted, modified or deleted.
