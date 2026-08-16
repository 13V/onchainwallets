-- =============================================================================
-- 11 — EARLY ENTRY: whales who were in before the move
-- =============================================================================
-- The target is information advantage, not profit. Those are different things,
-- and conflating them is why the PnL approach failed its persistence test:
-- a lifetime-PnL ranking is full of wallets that bought late into momentum and
-- got carried, which is luck and does not repeat.
--
-- Being early is a fact about WHEN you bought relative to everyone else. It does
-- not depend on how much you bet, when you sold, or what the bag is worth now —
-- so it sidesteps every artifact this pipeline has been fighting: transfers
-- inflating PnL, missing prices zeroing positions, rugs, cost-basis attribution.
--
-- Two measures per (wallet, token):
--
--   entry_multiple  = token peak price / the price this wallet first paid.
--                     20 means the token ran 20x from their entry. This is the
--                     one that matters — it is scale-free and directly answers
--                     "did they get in before the move".
--   buyer_rank      = position in the ordered list of that token's buyers.
--                     Rank 40 of 90,000 is not a coincidence you repeat.
--
-- A wallet in the first hundred buyers of ONE token that ran got lucky. A wallet
-- doing it across five tokens, at size, knew something each time.
--
-- WHAT THIS CANNOT SEE: the denominator. Every token here already reached $20M,
-- so a sniper bot that buys early into everything scores well on tokens that
-- happened to run while its hundreds of failures are invisible. The
-- n_universe_tokens count is the partial defence — a bot sprays far more names
-- than a whale — but the real fix is 12, which measures early entries into
-- tokens that went nowhere and turns this into a hit rate.
--
-- `('__MINT_LIST__')` is filled by scripts/find_whales.py.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,
        10000             AS min_entry_usd,  -- whale-sized entry, not a nibble
        100               AS early_rank      -- "first N buyers" threshold
),

universe (mint) AS (
    VALUES
        ('__MINT_LIST__')
),

scan AS (
    SELECT
        t.trader_id AS wallet,
        t.block_time,
        CAST(ARRAY[
            ROW(t.token_bought_mint_address, 'buy',  t.amount_usd, t.token_bought_amount),
            ROW(t.token_sold_mint_address,   'sell', t.amount_usd, t.token_sold_amount)
        ] AS ARRAY(ROW(mint VARCHAR, side VARCHAR, usd DOUBLE, qty DOUBLE))) AS legs
    FROM dex_solana.trades t
    WHERE t.block_month >= (SELECT lookback_start FROM params)
      AND t.block_time  >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
      AND (t.token_bought_mint_address IN (SELECT mint FROM universe)
        OR t.token_sold_mint_address   IN (SELECT mint FROM universe))
),

legs AS (
    SELECT s.wallet, s.block_time, l.mint, l.side, l.usd, l.qty,
           l.usd / NULLIF(l.qty, 0) AS unit_price
    FROM scan s
    CROSS JOIN UNNEST(s.legs) AS l (mint, side, usd, qty)
    WHERE l.mint IN (SELECT mint FROM universe)
      AND l.qty > 0
),

-- Token-level reference points. Peak uses the 99th percentile of trade prints
-- rather than the max so one fat-finger or sandwich cannot invent a high that
-- flatters every entry measured against it.
token_ref AS (
    SELECT
        mint,
        MIN(block_time)                        AS t0,
        approx_percentile(unit_price, 0.99)    AS peak_price,
        COUNT(DISTINCT wallet)                 AS total_buyers
    FROM legs
    WHERE side = 'buy'
    GROUP BY mint
),

-- One row per wallet per token: when they first bought, and at what price.
-- min_by picks the price of the EARLIEST buy, which is the entry that counts.
entries AS (
    SELECT
        wallet,
        mint,
        MIN(block_time)                     AS first_buy,
        min_by(unit_price, block_time)      AS entry_price,
        SUM(usd)                            AS entry_usd
    FROM legs
    WHERE side = 'buy'
    GROUP BY wallet, mint
),

ranked AS (
    SELECT
        e.wallet,
        e.mint,
        e.entry_usd,
        r.peak_price / NULLIF(e.entry_price, 0)                       AS entry_multiple,
        row_number() OVER (PARTITION BY e.mint ORDER BY e.first_buy)  AS buyer_rank,
        r.total_buyers,
        date_diff('hour', r.t0, e.first_buy)                          AS hours_after_first_trade
    FROM entries e
    CROSS JOIN params p
    JOIN token_ref r ON r.mint = e.mint
    WHERE e.entry_usd >= p.min_entry_usd
      AND e.entry_price > 0
)

SELECT
    wallet,
    COUNT(*)                                                    AS n_universe_tokens,
    -- the headline: how far the token ran from where they got in
    ROUND(approx_percentile(entry_multiple, 0.5), 1)            AS median_entry_multiple,
    ROUND(MAX(entry_multiple), 1)                               AS best_entry_multiple,
    COUNT_IF(entry_multiple >= 10)                              AS n_entries_before_10x,
    COUNT_IF(entry_multiple >= 3)                               AS n_entries_before_3x,
    -- position in the queue of buyers
    CAST(ROUND(approx_percentile(CAST(buyer_rank AS DOUBLE), 0.5)) AS BIGINT) AS median_buyer_rank,
    COUNT_IF(buyer_rank <= (SELECT early_rank FROM params))     AS n_top100_entries,
    ROUND(approx_percentile(
        CAST(buyer_rank AS DOUBLE) / NULLIF(total_buyers, 0), 0.5), 4) AS median_rank_pct,
    CAST(ROUND(approx_percentile(CAST(hours_after_first_trade AS DOUBLE), 0.5)) AS BIGINT)
                                                                AS median_hours_after_launch,
    ROUND(SUM(entry_usd))                                       AS total_entry_usd,
    ROUND(MAX(entry_usd))                                       AS biggest_entry_usd
FROM ranked
GROUP BY wallet
HAVING COUNT(*) >= 3
   AND COUNT_IF(entry_multiple >= 3) >= 2
ORDER BY n_entries_before_10x DESC, median_entry_multiple DESC
LIMIT 2000
