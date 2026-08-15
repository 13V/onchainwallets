# Run results — 2026-08-15

Output of `scripts/find_whales.py` against Dune, universe =
`queries/universe_memecoins.txt` (32 verified memecoin mints), lookback from
2024-01-01.

## Files

| File | What it is |
|------|-----------|
| `wallets_clean.txt` | **16 wallets.** Every position accounted for by DEX buys. Start here. |
| `wallets_flagged.txt` | 86 wallets whose PnL is inflated by tokens received off-DEX. Not tradeable as-is — see below. |
| `wallets.txt` | All 102, unsplit. |
| `whale_wallets.csv` | Full metrics per wallet. |
| `token_universe_150.csv` | The 150 tokens that cleared a $100M peak-cap screen, before curation. |

## Read this before using the list

**86 of the 102 wallets did not buy what they sold.** Their tokens arrived by
transfer, so a position reads as "bought $0, sold $34,500" and scores as
infinite profit. These are distribution wallets — one leg of a multi-wallet
operation, receiving bags and selling them. Copying them is pointless: by the
time they receive tokens, the entry decision was made in a different wallet.

That is what `n_positions_external_inflow` counts, and it is why the list is
split. `wallets_clean.txt` is the 16 where the ratio of (tokens sold + tokens
still held) to tokens bought sits near 1.0 — self-contained traders.

The flagged 86 are not garbage, they are a lead. Each one has a counterparty
that sent it the tokens, and *that* wallet made the entry. `07_wallet_clusters.sql`
walks those edges.

## What has NOT been done

- **No out-of-sample validation.** `05_out_of_sample_validation.sql` has not been
  run against this list. Until it is, treat these as candidates selected on past
  winners — which includes wallets that were lucky once and wallets that are
  genuinely skilled, with no way yet to tell them apart.
- **No rug accounting.** These PnL figures cover the 32 universe tokens only.
  A wallet here could be down more than this on tokens outside the universe.
  That was the job of the all-token pass, which did not run.
- **16 is a small sample.** Several clear the bar on exactly 3 profitable
  positions, which is the minimum. Weak evidence of repeat skill.

## Numbers

The clean 16, sorted by PnL excluding their single best position — the column
that separates a repeat winner from one lucky moonshot:

| wallet | excl. best | majors PnL | ROI | wins | median hold (d) |
|---|---|---|---|---|---|
| `Ad3grcn4kAtybmUKbYY5LRxvPN9bMsCLxACctFFyB7nN` | $2,541,071 | $4,193,011 | 1.03 | 4/7 | 15 |
| `4QmkHvmqoUkMvno8DRwvUkVYXCR4sRGvR7TjLPrgmQ1p` | $1,395,891 | $2,347,980 | 1.73 | 5/7 | 5 |
| `DAGf9kro3K3rWz7UFWVFdUmWmgZGRokS4rcXQzCTdzgS` | $1,240,955 | $2,837,159 | 8.39 | 3/3 | 21 |
| `gHBS7PwSsXn3whdiAc2WWhbT3dDTqkooMG4TJWBuLVw` | $432,019 | $817,289 | 0.94 | 3/3 | 5 |
| `CF59pv4Aa7V2ESYr21M1gw6LuaswgJfTJqzY2pxcSrDs` | $397,741 | $2,130,086 | 0.61 | 6/8 | 6 |
| `8kGE25NBABuU17aajpEeRwV441RtYZxBWyqYK6cptYpS` | $296,516 | $656,282 | 0.90 | 3/3 | 8 |
| `5z7atUKAymgT7hX5sg6jyHD14j13M8XoENGGQQPmFZu6` | $275,517 | $680,360 | 0.62 | 3/4 | 52 |
| `5JPuWicdjfDb4CQqbZg3WKWNya89qtX8vstc3ZVBRaSY` | $269,543 | $684,609 | 0.39 | 3/3 | 47 |
| `7Yi1NwbCWzqqEZTSF6SrmvsYEUqVC2SgYGNmfdnERpvc` | $258,719 | $938,539 | 0.92 | 3/5 | 18 |
| `FQ5YFztypZwMWKQhMWvuzEqPNGH2yuwCTiqStW2mrW1J` | $233,518 | $853,553 | 1.32 | 3/3 | 16 |
| `GrL8ftjy4Gc14sxcemwfJ6M4gXVJnidXUpHFcchZACfW` | $220,678 | $340,331 | 0.75 | 3/3 | 48 |
| `GKndNQALBLECv3iVXELWe6KwH5DfJXgunmCBQVk6VYGY` | $220,355 | $688,937 | 0.48 | 4/6 | 22 |
| `4uPJYegTLzXH9hLhj63xw3dnJMvcmG5yBRozBTyPnC26` | $211,112 | $367,169 | 1.41 | 4/5 | 13 |
| `82qDmg3SgzdXMhNUKhogPaURjNsw5XGA2bk8Pj5PhnJj` | $150,020 | $419,744 | 0.58 | 5/5 | 6 |
| `ELcFWwNzKFXs8LHkkfhppEr6VXH4eBaCHvdszCCcoAPH` | $127,564 | $298,997 | 0.65 | 5/5 | 6 |
| `E1humH4sxuBZ6whLPbaxi3k3eu8EECG6PVQjdc9jYMkL` | $119,416 | $271,451 | 0.80 | 3/4 | 7 |

`DAGf9kro...` at 8.39 ROI on only 3 positions is the one to check by hand
first — that shape is as consistent with an undetected external inflow as with
skill.

## Credits

This run cost roughly 2,225 of a 2,500 monthly allowance, most of it wasted on
a first universe query that scanned `dex_solana.trades` and timed out at 30
minutes. The current `01` avoids that table entirely and is cheap. Reruns
should cost a fraction of this.
