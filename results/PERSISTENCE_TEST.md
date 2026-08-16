# Persistence test — the result that matters

**Run 2026-08-15. Dune query 8344869. 727 candidate wallets, cutoff 2025-06-01,
348 of them active in both windows.**

## Question

This pipeline selects wallets that made money on tokens that already ran, then
assumes the skill repeats. Does it?

Wallets were selected using **pre-cutoff numbers only**, then scored on
positions **opened after** the cutoff. A position belongs to the window its
first buy falls in, so a bag bought before and sold after cannot leak into the
post-cutoff score.

## Answer: no. Past PnL does not predict future PnL.

| group | n | post median PnL | % profitable | median ROI |
|---|---|---|---|---|
| selected (pre-cutoff PnL ≥ $25k, ≥3 positions) | 150 | **−$18,030** | 13% | −0.36 |
| control (everyone else) | 198 | −$11,334 | 12% | −0.35 |

The selected group did **worse** than the wallets we rejected. Both groups
traded the same post-cutoff market, so market conditions are controlled — this
is a like-for-like comparison, and selection added nothing.

## Raising the bar makes it worse, monotonically

| pre-cutoff PnL bar | n | post median PnL | % profitable | median ROI |
|---|---|---|---|---|
| $0 | 174 | −$14,169 | 14% | −0.36 |
| $25,000 | 150 | −$18,030 | 13% | −0.36 |
| $100,000 | 93 | −$26,511 | 11% | −0.39 |
| $250,000 | 55 | −$29,577 | 9% | −0.45 |
| $1,000,000 | 15 | −$70,193 | 20% | −0.52 |

The more a wallet made before the cutoff, the more it lost after. That is mean
reversion, which is the signature of luck rather than skill.

## Rank correlation between the two windows

| measure | Spearman |
|---|---|
| clean PnL, pre vs post | **−0.042** |
| realized only, no valuation leak | **−0.236** |

Zero would mean past rank tells you nothing about future rank. Both are at or
below zero. The realized figure — the one with no marking-to-today leak, and so
the cleanest number here — is meaningfully negative.

## What this does and does not establish

**Does:** ranking Solana memecoin wallets by historical PnL, at any threshold
tested, does not identify wallets that go on to make money. The 158-wallet list
in `wallets_verified.txt` should not be traded off.

**Does not:** prove no skill exists on Solana. It shows *this metric* fails to
find it. Three things remain untested and could differ:

- **Entry market cap.** PnL conflates selection, sizing and exit timing. Whether
  a wallet consistently enters below $5M on tokens that reach $50M+ is a direct
  measure of earliness, immune to position size and exit luck. Not yet computed.
- **Early-and-patient set intersection.** Wallets that bought within 48 hours
  and still held 30 days later, across three or more winners, defined without
  reference to PnL at all.
- **Consensus rather than individual wallets.** Several independent wallets
  accumulating the same token may carry signal even when no single one does.

Each needs to clear this same test before being trusted. The test is cheap now
and should be applied to any new metric before a wallet list is built on it.

## Caveats

- The 727 candidates were themselves pre-filtered by `06` over the full period,
  so both groups are already selected on outcome. That contamination would
  flatter both arms and cannot explain the negative slope between them.
- Both groups lost money post-cutoff, so the window was hostile in absolute
  terms. The comparison is relative and within the same window, which is what
  makes the null result meaningful.
- 348 wallets active in both windows is a reasonable sample; the $1M row is 15
  wallets and its 20% profitable rate is noise.
