-- =============================================================================
-- 05 — OUT-OF-SAMPLE VALIDATION: is the wallet good, or did you just pick winners?
-- =============================================================================
-- This is the query that decides whether the other four are worth anything.
--
-- The problem: selecting wallets that got rich on TROLL/PNUT/PENGU/MOODENG is
-- selecting on the outcome. Thousands of wallets bought those tokens; the ones
-- still holding at the top are, by construction, the ones the sample kept.
-- Some are genuinely skilled. Many are survivors of a coin flip that landed
-- their way, and they will hand back the money on the next one.
--
-- The test: pick wallets using ONLY trades that started before `split_date`,
-- then score them on positions they opened AFTER it. A wallet with skill keeps
-- earning across the boundary. A lucky one reverts.
--
-- A position belongs to whichever side of the split its FIRST BUY falls on, so
-- a bag bought in the train window and sold in the test window still counts as
-- a train position and cannot leak into the test score.
--
-- Read the result as a cohort: if median test ROI is near zero and only half
-- the wallets are green, your filters in 02 are fitting noise — tighten
-- min_median_hold_days and min_profitable_positions and run it again.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01'  AS lookback_start,
        DATE '2025-06-01'  AS split_date,          -- train < split_date <= test
        500                AS min_position_usd,
        3                  AS min_train_positions,
        50000              AS min_train_pnl_usd,
        7                  AS min_train_hold_days
),

quote_assets (mint) AS (
    VALUES
        ('So11111111111111111111111111111111111111112'),
        ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'),
        ('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB')
),

-- ####################### EDIT ME #######################
-- Same universe list as 02. Only used for wallet SELECTION (the train side).
universe (mint) AS (
    VALUES
        ('PASTE_MINT_FROM_QUERY_01_HERE_1'),
        ('PASTE_MINT_FROM_QUERY_01_HERE_2'),
        ('PASTE_MINT_FROM_QUERY_01_HERE_3')
),
-- #######################################################

train_legs AS (
    SELECT t.trader_id AS wallet, t.token_bought_mint_address AS mint, 'buy' AS side,
           t.token_bought_amount AS qty, t.amount_usd AS usd, t.block_time, t.tx_id
    FROM dex_solana.trades t
    JOIN universe u ON u.mint = t.token_bought_mint_address
    WHERE t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0

    UNION ALL

    SELECT t.trader_id, t.token_sold_mint_address, 'sell',
           t.token_sold_amount, t.amount_usd, t.block_time, t.tx_id
    FROM dex_solana.trades t
    JOIN universe u ON u.mint = t.token_sold_mint_address
    WHERE t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
),

train_roundtrips AS (
    SELECT wallet, mint, tx_id FROM train_legs
    GROUP BY wallet, mint, tx_id HAVING COUNT(DISTINCT side) = 2
),

train_positions AS (
    SELECT
        l.wallet,
        l.mint,
        SUM(IF(l.side = 'buy',  l.usd, 0))           AS usd_in,
        SUM(IF(l.side = 'sell', l.usd, 0))           AS usd_out,
        SUM(IF(l.side = 'buy',  l.qty, 0))           AS qty_bought,
        SUM(IF(l.side = 'sell', l.qty, 0))           AS qty_sold,
        MIN(IF(l.side = 'buy',  l.block_time, NULL)) AS first_buy,
        MIN(CASE WHEN l.side = 'sell' AND r.tx_id IS NULL THEN l.block_time END) AS first_real_sell
    FROM train_legs l
    LEFT JOIN train_roundtrips r
           ON r.wallet = l.wallet AND r.mint = l.mint AND r.tx_id = l.tx_id
    GROUP BY l.wallet, l.mint
),

-- Filtered to universe mints. solana_utils.latest_balances holds a row per
-- (address, token) for all of Solana, so an unfiltered scan here is the
-- difference between a query that runs and one that eats your credits.
train_holdings AS (
    SELECT token_balance_owner AS wallet, token_mint_address AS mint,
           CAST(SUM(token_balance) AS DOUBLE) AS qty_now
    FROM solana_utils.latest_balances
    WHERE token_mint_address IN (SELECT mint FROM universe)
      AND token_balance > 0
    GROUP BY 1, 2
),

price_now AS (
    SELECT to_base58(contract_address) AS mint, MAX(price) AS price_usd
    FROM prices.latest
    WHERE blockchain = 'solana'
    GROUP BY 1
),

-- Wallets selected on the train window alone. No test-window information
-- touches this CTE.
selected_wallets AS (
    SELECT
        tp.wallet,
        SUM(tp.usd_out - tp.usd_in
            + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0))  AS train_pnl_usd,
        SUM(tp.usd_in)                                             AS train_invested_usd,
        COUNT(*)                                                   AS train_positions,
        approx_percentile(
            CAST(date_diff('day', tp.first_buy,
                 COALESCE(tp.first_real_sell, CAST(now() AS TIMESTAMP))) AS DOUBLE), 0.5
        )                                                          AS train_median_hold_days
    FROM train_positions tp
    CROSS JOIN params p
    LEFT JOIN train_holdings h ON h.wallet = tp.wallet AND h.mint = tp.mint
    LEFT JOIN price_now     px ON px.mint  = tp.mint
    WHERE tp.usd_in >= p.min_position_usd
      AND tp.first_buy < CAST(p.split_date AS TIMESTAMP)
    GROUP BY tp.wallet
    HAVING COUNT(*) >= MAX(p.min_train_positions)
       AND SUM(tp.usd_out - tp.usd_in
               + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)) >= MAX(p.min_train_pnl_usd)
       AND approx_percentile(
               CAST(date_diff('day', tp.first_buy,
                    COALESCE(tp.first_real_sell, CAST(now() AS TIMESTAMP))) AS DOUBLE), 0.5
           ) >= MAX(p.min_train_hold_days)
),

-- Everything the selected wallets traded afterwards, across all of Solana —
-- not just the universe. The question is whether they kept picking winners at
-- all, not whether they kept trading the same four coins.
test_legs AS (
    SELECT t.trader_id AS wallet, t.token_bought_mint_address AS mint, 'buy' AS side,
           t.token_bought_amount AS qty, t.amount_usd AS usd, t.block_time, t.tx_id
    FROM dex_solana.trades t
    JOIN selected_wallets sw ON sw.wallet = t.trader_id
    WHERE t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
      AND t.token_bought_mint_address NOT IN (SELECT mint FROM quote_assets)

    UNION ALL

    SELECT t.trader_id, t.token_sold_mint_address, 'sell',
           t.token_sold_amount, t.amount_usd, t.block_time, t.tx_id
    FROM dex_solana.trades t
    JOIN selected_wallets sw ON sw.wallet = t.trader_id
    WHERE t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
      AND t.token_sold_mint_address NOT IN (SELECT mint FROM quote_assets)
),

test_roundtrips AS (
    SELECT wallet, mint, tx_id FROM test_legs
    GROUP BY wallet, mint, tx_id HAVING COUNT(DISTINCT side) = 2
),

test_positions AS (
    SELECT
        l.wallet,
        l.mint,
        SUM(IF(l.side = 'buy',  l.usd, 0))           AS usd_in,
        SUM(IF(l.side = 'sell', l.usd, 0))           AS usd_out,
        MIN(IF(l.side = 'buy',  l.block_time, NULL)) AS first_buy,
        MIN(CASE WHEN l.side = 'sell' AND r.tx_id IS NULL THEN l.block_time END) AS first_real_sell
    FROM test_legs l
    LEFT JOIN test_roundtrips r
           ON r.wallet = l.wallet AND r.mint = l.mint AND r.tx_id = l.tx_id
    GROUP BY l.wallet, l.mint
),

-- Test-side holdings span every token these wallets bought after the split, so
-- this one is scoped by wallet rather than by mint. Defined here rather than up
-- top because it depends on selected_wallets.
test_holdings AS (
    SELECT token_balance_owner AS wallet, token_mint_address AS mint,
           CAST(SUM(token_balance) AS DOUBLE) AS qty_now
    FROM solana_utils.latest_balances
    WHERE token_balance_owner IN (SELECT wallet FROM selected_wallets)
      AND token_balance > 0
    GROUP BY 1, 2
),

test_scored AS (
    SELECT
        tp.wallet,
        COUNT(*)                                                   AS test_positions,
        SUM(tp.usd_in)                                             AS test_invested_usd,
        SUM(tp.usd_out - tp.usd_in
            + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0))  AS test_pnl_usd,
        COUNT_IF(tp.usd_out - tp.usd_in
            + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0) > 0) AS test_wins,
        approx_percentile(
            CAST(date_diff('day', tp.first_buy,
                 COALESCE(tp.first_real_sell, CAST(now() AS TIMESTAMP))) AS DOUBLE), 0.5
        )                                                          AS test_median_hold_days
    FROM test_positions tp
    CROSS JOIN params p
    LEFT JOIN test_holdings h ON h.wallet = tp.wallet AND h.mint = tp.mint
    LEFT JOIN price_now    px ON px.mint  = tp.mint
    WHERE tp.usd_in >= p.min_position_usd
      AND tp.first_buy >= CAST(p.split_date AS TIMESTAMP)
    GROUP BY tp.wallet
)

-- ---------------------------------------------------------------------------
-- PER-WALLET: did each pick survive the split?
-- ---------------------------------------------------------------------------
SELECT
    sw.wallet,
    ROUND(sw.train_pnl_usd)                                        AS train_pnl_usd,
    ROUND(sw.train_pnl_usd / NULLIF(sw.train_invested_usd, 0), 2)  AS train_roi,
    sw.train_positions,
    ROUND(sw.train_median_hold_days)                               AS train_median_hold_days,
    COALESCE(ts.test_positions, 0)                                 AS test_positions,
    ROUND(COALESCE(ts.test_pnl_usd, 0))                            AS test_pnl_usd,
    ROUND(ts.test_pnl_usd / NULLIF(ts.test_invested_usd, 0), 2)    AS test_roi,
    ROUND(ts.test_wins * 1.0 / NULLIF(ts.test_positions, 0), 2)    AS test_win_rate,
    ROUND(ts.test_median_hold_days)                                AS test_median_hold_days,
    CASE
        WHEN ts.test_positions IS NULL   THEN 'inactive after split'
        WHEN ts.test_pnl_usd > 0         THEN 'held up'
        ELSE                                  'reverted'
    END                                                            AS verdict
FROM selected_wallets sw
LEFT JOIN test_scored ts ON ts.wallet = sw.wallet
ORDER BY test_pnl_usd DESC NULLS LAST

-- ---------------------------------------------------------------------------
-- ALTERNATE — cohort summary. This single row is the honest verdict on the
-- whole method. Comment out the SELECT above and uncomment this.
-- ---------------------------------------------------------------------------
-- SELECT
--     COUNT(*)                                                        AS wallets_selected,
--     COUNT_IF(ts.test_positions IS NULL)                             AS went_inactive,
--     COUNT_IF(ts.test_pnl_usd > 0)                                   AS profitable_after_split,
--     ROUND(COUNT_IF(ts.test_pnl_usd > 0) * 1.0
--           / NULLIF(COUNT_IF(ts.test_positions IS NOT NULL), 0), 2)  AS pct_held_up,
--     ROUND(approx_percentile(ts.test_pnl_usd, 0.5))                  AS median_test_pnl_usd,
--     ROUND(approx_percentile(
--           ts.test_pnl_usd / NULLIF(ts.test_invested_usd, 0), 0.5), 2) AS median_test_roi
-- FROM selected_wallets sw
-- LEFT JOIN test_scored ts ON ts.wallet = sw.wallet
