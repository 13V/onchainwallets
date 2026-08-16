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
--   entry_mcap      = the token's market cap when this wallet first bought.
--                     Absolute dollars, so it is interpretable and bounded. A
--                     first version used peak price / entry price instead; on
--                     bonding-curve launches the earliest print is ~\$0, which
--                     sent that ratio to 1e10 for 1,967 of 2,000 wallets and
--                     measured "sniped genesis" rather than "knew something".
--   buyer_rank      = position in the ordered list of that token's buyers.
--                     Rank 40 of 90,000 is not a coincidence you repeat.
--
-- A wallet in the first hundred buyers of ONE token that ran got lucky. A wallet
-- doing it across five tokens, at size, knew something each time.
--
-- Infrastructure has to be excluded or it takes every top slot: Jupiter DCA
-- program accounts (the JD... cluster) and vanity-prefixed service wallets
-- appear as trader_id with \$900M of entries across 120+ tokens. Labels catch
-- some; the token-count ceiling catches the rest, because a whale with genuine
-- early information does not have it on 130 of 169 names.
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
        10000             AS min_entry_usd,   -- whale-sized entry, not a nibble
        100               AS early_rank,      -- "first N buyers" threshold
        60                AS max_tokens       -- above this it is a bot or a service
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

-- Circulating supply, to turn an entry price into an entry market cap.
supply AS (
    SELECT token_mint_address AS mint, CAST(SUM(token_balance) AS DOUBLE) AS circulating_supply
    FROM solana_utils.latest_balances
    WHERE token_mint_address IN (SELECT mint FROM universe)
      AND token_balance > 0
    GROUP BY 1
),

labelled_infra AS (
    SELECT to_base58(address) AS addr
    FROM labels.addresses
    WHERE blockchain = 'solana'
      AND category IN ('cex', 'dex', 'bridge', 'contract', 'mev', 'infrastructure')
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
        e.entry_price * sp.circulating_supply                         AS entry_mcap,
        r.peak_price  * sp.circulating_supply                         AS peak_mcap,
        row_number() OVER (PARTITION BY e.mint ORDER BY e.first_buy)  AS buyer_rank,
        r.total_buyers,
        date_diff('hour', r.t0, e.first_buy)                          AS hours_after_first_trade
    FROM entries e
    CROSS JOIN params p
    JOIN token_ref r ON r.mint = e.mint
    JOIN supply    sp ON sp.mint = e.mint
    WHERE e.entry_usd >= p.min_entry_usd
      AND e.entry_price > 0
      AND e.wallet NOT IN (SELECT addr FROM labelled_infra)
)

SELECT
    wallet,
    COUNT(*)                                                    AS n_universe_tokens,
    -- the headline: what was the token worth when they got in
    CAST(ROUND(approx_percentile(entry_mcap, 0.5)) AS BIGINT)   AS median_entry_mcap,
    CAST(ROUND(MIN(entry_mcap)) AS BIGINT)                      AS earliest_entry_mcap,
    COUNT_IF(entry_mcap <=  5e6)                                AS n_entries_under_5m,
    COUNT_IF(entry_mcap <= 20e6)                                AS n_entries_under_20m,
    -- how far it went after they were in
    CAST(ROUND(approx_percentile(peak_mcap / NULLIF(entry_mcap, 0), 0.5)) AS BIGINT)
                                                                AS median_mcap_multiple,
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
   AND COUNT(*) <= (SELECT max_tokens FROM params)
   AND COUNT_IF(entry_mcap <= 20e6) >= 2
ORDER BY n_entries_under_5m DESC, median_entry_mcap ASC
LIMIT 2000
