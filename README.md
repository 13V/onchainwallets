# Finding buy-and-hold Solana wallets on Dune

A five-query workflow for locating wallets that made real money holding the
majors — the TROLL / PNUT / PENGU / MOODENG class of token that actually reached
$100M+ — while filtering out the flippers, bots and one-hit survivors that
dominate any naive "top PnL wallets" leaderboard.

Everything here is DuneSQL (Trino) against Dune's curated Solana tables. No API
key, no infra. Paste into the Dune query editor and run.

## Quick start — just get me the wallet list

```bash
export DUNE_API_KEY=...          # never pass it on the command line in shared shells
python3 scripts/find_whales.py   # stdlib only, no pip install
```

Two phases, automatic: it runs the universe query, drops the LSTs / stables /
infra tokens that also clear $100M, injects the surviving mints into the whale
query, and writes:

- `out/wallets.txt` — one address per line, the list
- `out/whale_wallets.csv` — the same wallets with the numbers behind them
- `out/tokens.csv` — the token universe it searched across

Useful flags: `--top-tokens 15`, `--min-pnl 500000`,
`--min-pnl-excluding-best 150000`, `--min-position 50000`, `--dry-run` to print
the generated SQL without spending credits.

Creating queries via API needs a Dune **Analyst** plan or higher. On a lower
plan, paste the two SQL files into saved queries in the UI and pass
`--universe-query-id` / `--whale-query-id`; the script will execute those
instead of creating its own. Query IDs it creates are cached in
`out/query_ids.json` and reused, so repeat runs don't litter your account.

## The queries

| # | Query | What it does |
|---|-------|--------------|
| 01 | `01_token_universe.sql` | Finds tokens that genuinely reached $100M+ peak market cap, from supply × peak price |
| 06 | `06_whale_wallets.sql` | **The whale list.** Large positions, repeat winners, held not flipped |
| 02 | `02_wallet_scorecard.sql` | Same idea at retail size — wider net, more noise |
| 03 | `03_wallet_deep_dive.sql` | Audits one wallet in detail |
| 04 | `04_live_watchlist.sql` | What the vetted set is accumulating now |
| 05 | `05_out_of_sample_validation.sql` | Tests whether the filters found skill or luck |

06 is what the script runs and what you want for a whale list. 02 is the same
machinery with retail-sized thresholds, kept for when you want a wider net.

Run 05 before you trust the output of 04. It is the only query here that can
tell you the others are lying to you.

## The repeat-winner gate

The most important column in 06 is `pnl_excluding_best_usd` — total PnL minus
the single best position.

Total PnL is dominated by a wallet's luckiest trade. Sorted by it, a wallet that
bought one token that 100x'd is indistinguishable from a wallet that called four
in a row, and the first kind vastly outnumbers the second. Subtracting the best
position before applying the threshold separates them: what remains is what they
made on *everything else*. A wallet clearing $150k with its best position
removed was right repeatedly.

The results are sorted by this column, not by total PnL, for the same reason.

## Why the universe is derived, not hardcoded

Solana token symbols are not unique. There are dozens of mints called `PNUT`,
`MOODENG` and `TROLL`, most of them worthless copies of the real thing. A query
that filters `WHERE symbol = 'PNUT'` silently mixes fakes into the PnL and the
output looks completely normal.

So 01 selects on measured behaviour only — lifetime DEX volume, distinct trader
count, days active, and a peak market cap computed from real circulating supply
(`mintTo` minus `burn`) times peak daily price. Symbols are attached at the end
for reading convenience and are never used as a filter. Sanity-check that the
names you expect appear, then copy the `mint` column forward.

Peak price uses the **median** price of each day rather than the max, and
ignores days under $50k volume. One sandwich attack or fat-finger print should
not be able to manufacture an all-time high.

## How "buy and hold" is defined

The behavioural gates in 02 are where the actual filtering happens. PnL alone
selects for bots.

| Gate | 06 (whale) | 02 (retail) | Rejects |
|------|-----------|-------------|---------|
| `min_position_usd` | 25,000 | 500 | Positions too small to be a whale's |
| `min_invested_usd` | 250,000 | — | Wallets not deploying real size |
| `min_pnl_excluding_best_usd` | 100,000 | — | One lucky moonshot |
| `min_profitable_positions` | 3 | 3 | Same, by count |
| `min_median_hold_days` | 5 | 7 | Day traders and snipers |
| `max_pct_flipped_same_day` | 0.34 | 0.25 | Wallets whose usual pattern is in-and-out same day |
| `max_txs_per_active_day` | 50 | 30 | Bots, market makers, aggregator infrastructure |
| `min_universe_volume_share` | 0.25 | 0.40 | Wallets whose real business is elsewhere |

The whale thresholds are looser on behaviour and much tighter on size. A wallet
running eight figures will trim and rebalance in ways a retail holder does not,
so hold-time gates that are correct at retail size throw out real whales.

Two details that matter more than they look:

**Same-transaction round trips are excluded from hold-time.** A Jupiter route
can buy and sell the same token inside one transaction as a routing artefact. If
you count those as an entry and an exit, hold time reads as zero seconds and
every genuine holder gets filtered out. `roundtrip_txs` catches and excludes
them from the timing metrics while leaving them in the PnL, where they correctly
net to roughly nothing.

**Multi-hop routes are not double counted.** `dex_solana.trades` emits one row
per pool hop, so a USDC → SOL → PNUT route is two rows. Only the hop that
touches a universe token matches the join, so the intermediate leg is invisible
to the PnL, which is the correct behaviour.

## Reading the integrity flags

Two columns in 02 exist to stop you trusting a number you shouldn't.

`qty_accounted_ratio` = (tokens sold on a DEX + tokens still held) ÷ tokens
bought on a DEX. It should be near 1.0.

- **Above ~1.1** — tokens arrived from somewhere the DEX tables cannot see: an
  airdrop, a CEX withdrawal, or another wallet the same person controls. PnL is
  overstated, sometimes wildly. Usually this is one leg of a multi-wallet
  operation.
- **Below ~0.9** — tokens were sent away rather than sold. PnL is understated,
  and the wallet may be a funding or distribution address rather than a trader.

`n_positions_external_inflow` counts how many of a wallet's positions trip the
high side. A wallet with several is not a clean trading wallet; skip it.

## What this cannot see

Be honest with yourself about these before sizing anything off the output.

- **Multi-wallet operators.** Serious traders split across many wallets and move
  inventory between them. Any single-wallet PnL for such an operation is
  fiction. The `qty_accounted_ratio` flag catches the obvious cases only.
- **Off-DEX acquisition.** OTC, airdrops and CEX buys never appear in
  `dex_solana.trades`. A wallet that received a large allocation and sold it on
  a DEX looks like an infinitely profitable trader.
- **Survivorship.** Selecting wallets that won on tokens that already 100x'd
  selects the survivors of a coin flip alongside the genuinely skilled. This is
  the single biggest risk in the whole exercise and is exactly what 05 measures.
- **Insiders and teams.** Some of the most "profitable holders" of a memecoin
  are the people who launched it. Their edge does not transfer to anything you
  can copy.
- **Price coverage.** Unrealised PnL uses `prices.latest`. Coverage of the long
  tail is imperfect; a missing price silently values an open position at zero,
  understating PnL for wallets still holding obscure bags.
- **Latency.** Dune's Solana tables land in batches, typically tens of minutes to
  a few hours behind the chain. This workflow finds accumulation. It does not
  front-run it.

## Turning the shortlist into a signal

`04_live_watchlist.sql` is the query you keep running. The column that matters
is `n_wallets_buying` — one tracked wallet buying something is noise, four
independent ones buying the same token in a week while none of them sell is the
pattern this whole exercise exists to surface. `n_wallets_still_holding` tells
you whether they kept it or already round-tripped out.

Set it up as a Dune query alert (bell icon → alert when new rows appear) with
`min_wallets_buying` raised to 2 or 3, so only consensus reaches you.

For same-block copy trading, Dune is the wrong tool — take the vetted wallet
list and feed it to a streaming provider (Helius or Yellowstone webhooks). Use
Dune to decide *who* to follow, not *when* to act.

## Credit cost

The expensive query is 02: it scans `dex_solana.trades` twice with a join
filter, then once more for the shortlist's full history. Ways to keep it cheap:

- Keep `lookback_start` tight while calibrating thresholds, then widen it.
- Trim the universe in 02 to the 10–20 tokens you actually care about. Cost
  scales with how much of the trades table the join touches.
- 01 is the second most expensive because the supply CTE reads
  `tokens_solana.transfers` unbounded in time. That is deliberate — a 2022
  token's `mintTo` predates any sane lookback window, and bounding it would
  report supply as zero — but it means you should run 01 once and reuse the
  output rather than rerunning it.
- Never remove the mint or wallet filters on `solana_utils.latest_balances`. It
  carries a row per address per token for all of Solana.

## Tuning

The defaults are a starting point, not a calibration. The intended loop:

1. Run 02, look at the top 50.
2. Deep-dive five of them in 03. Note what makes the bad ones bad.
3. Run 05. If median test ROI is near zero and only about half the wallets stay
   green after the split, the filters are fitting noise — raise
   `min_median_hold_days` and `min_profitable_positions` and go again.
4. Only once 05 looks healthy should the list go into 04.

If 05 shows most selected wallets going inactive after the split rather than
reverting, that is its own finding: the cohort made money in one cycle and left.
Those wallets are history, not a signal.

## Tables used

- `dex_solana.trades` — all Solana DEX trade legs
- `tokens_solana.transfers` — mint/burn events for supply
- `tokens_solana.fungible` — token symbol and name metadata
- `solana_utils.latest_balances` — current holdings, for unrealised PnL
- `prices.latest` / `prices.day` — USD prices; Solana mints are stored as
  varbinary, so joins go through `from_base58()` / `to_base58()`
- `labels.addresses` — soft exclusion of CEX/bridge/infrastructure addresses.
  Solana label coverage is partial, so this supplements eyeballing rather than
  replacing it.
