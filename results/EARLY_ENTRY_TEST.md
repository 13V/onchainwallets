# Early-entry test — the denominator kills it

**Run 2026-08-15. Dune queries 11 + 08. 368 wallets with both an early-entry
profile and a full token count.**

## Question

The PnL approach failed because profit measures outcome, not information. So:
find wallets that were *early* — in before the move — repeatedly and at size.
Does that identify whales with information?

## Answer: no. Measured against everything they bought, these are sprayers.

| | value |
|---|---|
| tokens bought, median wallet | **6,909** |
| hit rate (early entries into $20M+ winners ÷ tokens bought), median | **0.3%** |
| hit rate, 90th percentile | 1.9% |
| hit rate, best in sample | 10.9% |

The wallets that look most "early" on winning tokens are wallets that buy
thousands of tokens. A handful run, because a handful of thousands always run.
That is volume, not information.

## The best hit rate in the sample loses $8.5M

| wallet | hit rate | winners | bought | median entry cap | clean PnL |
|---|---|---|---|---|---|
| `prUWZMpQAbRzmqnRqcoSh8jqcJ1M1g64uxsR7mq9bmv` | 11% | 20 | 184 | $26.4M | **−$8,513,547** |
| `44zas59yMsNv3nwsjtf9zPCxvaxyvuhLPx6x4ERKXPti` | 8% | 19 | 253 | $12.9M | −$474,080 |
| `4zwc95uMxhawmNFZMKHDeLYgKrBV1UjL4ekDctpqowsY` | 5% | 29 | 581 | $12.5M | +$109,609 |
| `moRseLnzCKEcy9nT3ktG7eMwW9qNcbvKuC44WfvCvXq` | 4% | 33 | 763 | $18.1M | +$4,068,422 |

Even the top of the distribution does not convert an apparent edge into money.

## Why the first cut looked promising and was not

Query 11 alone returned 2,000 wallets and *every one* had three or more entries
under a $5M market cap. That reads as a large population of early buyers. It is
an artifact of the universe containing only winners: with no count of the tokens
that went nowhere, a wallet buying 500 memecoins a year and catching 30 is
indistinguishable from one with genuine information.

Adding the denominator collapsed it.

## Infrastructure kept leaking in

Jupiter DCA program accounts appear as `trader_id` and carry no Dune labels.
`DCAKxn5PFNN1…` and `DCAK8tuwzsNow…` both scored near the top before being
removed by prefix. Vanity-prefixed service wallets (`moRse…`, `bob…`, `ben…`,
`gas…`, `prUWZ…`) recur throughout the results. Any wallet-ranking exercise on
Solana needs this handled explicitly; the label table is not sufficient.

## What this implies, taken with the persistence test

Two hypotheses tested, two failures, for different reasons:

- **Historical PnL** does not predict future PnL — mean reversion, rank
  correlation at or below zero.
- **Early entry into winners** does not survive its denominator — the wallets
  that look early are high-volume sprayers.

The likely reason is structural rather than a modelling failure. A wallet
holding genuine early information is not a persistent, discoverable identity:

- it buys **few** tokens, so it fails any "3+ universe tokens" screen designed
  to establish a track record
- it is often a **fresh wallet per play**, funded shortly before, so no history
  exists to rank it on
- by the time it has a legible track record, the information edge that produced
  it is spent

That is consistent with what the emptied burner wallets showed earlier, and it
means backward-looking wallet ranking cannot find this population by
construction — not with better metrics, not with better thresholds.

## The direction that remains

Stop trying to identify persistent wallets. Screen **tokens** instead, live:
for a token trading now, do its early buyers look like informed money — fresh
wallets, large size, funded from a common source, no history of spraying
thousands of names? That is a per-token classifier, not a watchlist, and the
features it needs are all things this repository already computes.

It also has an honest advantage: it does not require anyone's edge to persist.
