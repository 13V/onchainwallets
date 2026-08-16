> **START WITH `wallets_DORMANT.txt`** — 52 wallets that made real money at
> real size and have opened no new position in 180 days. The thesis is that
> they are waiting, and their next buy is the signal. This list is a
> descriptive screen, not a validated predictor: see the two test writeups
> below for what did and did not survive testing.

> **TWO HYPOTHESES TESTED, BOTH FAILED.** `PERSISTENCE_TEST.md` — historical
> PnL does not predict future PnL. `EARLY_ENTRY_TEST.md` — wallets that look
> early on winners buy ~6,900 tokens each; their hit rate is 0.3% and the best
> one loses $8.5M. Do not trade off the wallet lists here.
>
> **READ `PERSISTENCE_TEST.md` FIRST.** Wallets selected by historical PnL did
> not outperform wallets the same gates rejected over the following window —
> they did slightly worse, and raising the selection bar made it worse still.
> Do not trade off the wallet lists here until a metric clears that test.

# Run results — 2026-08-15

`scripts/find_whales.py` against Dune. Universe = `queries/universe_memecoins.txt`
(169 memecoin mints, $20M+ peak market cap, verified against `prices.day` and
`solana_utils.latest_balances`). Lookback from 2024-01-01.

## Files

| File | What it is |
|---|---|
| `PERSISTENCE_TEST.md` | **The result that matters.** Whether any of this predicts anything. |
| `wallets_verified.txt` | 158 wallets passing every gate. Not validated — see above. |
| `wallets_repeat_winners.txt` | The 81 of those still profitable with their single best position removed. |
| `verified_wallets.csv` | All 727 candidates with full metrics and a rejection reason each. |
| `token_universe_269.csv` | The 269 tokens that cleared the $20M screen, before classification. |

## How the 158 were selected

727 candidates from `06`, then `08` re-priced every token each one ever traded:

| verdict | n |
|---|---|
| pass | 158 |
| negative PnL once unreconciled positions removed | 367 |
| sells tokens it never bought | 126 |
| never sized up | 36 |
| trades too often | 17 |
| size went into losers | 15 |
| too few reconciled positions | 8 |

The gates encode the brief: ≥3 profitable positions, ≥5-day median hold, ≤20
transactions per token, biggest position ≥$25k, conviction ratio above 1.0, net
positive across the whole book including rugs.

## Why the list is not trade-ready

The gates are sound as *descriptions* — they do select wallets that sized up,
held, and made money. What `PERSISTENCE_TEST.md` shows is that this description
has no forward-looking value: wallets matching it in one window did not go on to
make money in the next, and the higher the past PnL, the worse the subsequent
performance.

Two things in the data are worth reading with that in mind:

- **PnL is concentrated.** Many of the 158 are carried by one position; 81
  survive with their best removed. `best_position_share` shows this per wallet.
- **Recent performance is separate.** `recent_pnl_180d_usd` scores positions
  *opened* in the last 180 days. Several top wallets by lifetime PnL are deeply
  negative there — the TRUMP wallet made $6.38M in Jan 2025 and has been bleeding
  since.

## Untested directions

These are different enough from PnL that they might behave differently, and each
should be put through `10_persistence_test.sql` before any list is built on it:

- **Entry market cap** — does the wallet enter below $5M on tokens reaching $50M+?
  Measures earliness directly, immune to sizing and exit luck.
- **Early-and-patient intersection** — wallets buying within 48h and holding 30+
  days, across three or more winners. Defined without PnL at all.
- **Consensus** — several independent wallets accumulating the same token, which
  may carry signal even when no single wallet does. `04_live_watchlist.sql`.
