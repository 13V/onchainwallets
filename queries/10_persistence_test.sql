-- =============================================================================
-- 10 — PERSISTENCE TEST: does past performance predict future performance?
-- =============================================================================
-- The question everything else rests on. This pipeline selects wallets that
-- made money on tokens that already ran, then assumes the skill repeats. That
-- assumption has never been tested, and if it is false the wallet list is a
-- collection of coin-flip survivors and the whole exercise is theatre.
--
-- Splits every wallet's book at a cutoff date and returns performance either
-- side. A position belongs to the window its FIRST BUY falls in, so a bag
-- bought before the cutoff and sold after still counts as a pre-cutoff
-- position and cannot leak into the post-cutoff score.
--
-- Analysis happens outside: take wallets that look good using ONLY pre-cutoff
-- numbers, then read their post-cutoff column. If selected wallets do no better
-- afterwards than unselected ones, past performance carries no signal here.
--
-- KNOWN LEAK: open positions are valued at today's price in whichever window
-- they were opened, so pre-cutoff performance is flattered by bags still held.
-- Realized and open are reported separately so the test can be run on realized
-- cash flow alone, which has no leak.
--
-- Only positions that reconcile against DEX buys are counted, same rule as 08 —
-- otherwise received tokens contaminate both windows.
--
-- `('__WALLET_LIST__')` and the cutoff are filled by the runner.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,
        DATE '2025-06-01' AS cutoff,
        100               AS min_position_usd
),

quote_assets (mint) AS (
    VALUES
        ('So11111111111111111111111111111111111111112'),
        ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'),
        ('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB')
),

wallets (wallet) AS (
    VALUES
        ('__WALLET_LIST__')
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
    JOIN wallets w ON w.wallet = t.trader_id
    WHERE t.block_month >= (SELECT lookback_start FROM params)
      AND t.block_time  >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
),

legs AS (
    SELECT s.wallet, s.block_time, l.mint, l.side, l.usd, l.qty
    FROM scan s
    CROSS JOIN UNNEST(s.legs) AS l (mint, side, usd, qty)
    WHERE l.mint NOT IN (SELECT mint FROM quote_assets)
),

positions AS (
    SELECT
        wallet,
        mint,
        SUM(IF(side = 'buy',  usd, 0))          AS usd_in,
        SUM(IF(side = 'sell', usd, 0))          AS usd_out,
        SUM(IF(side = 'buy',  qty, 0))          AS qty_bought,
        SUM(IF(side = 'sell', qty, 0))          AS qty_sold,
        MIN(IF(side = 'buy', block_time, NULL)) AS first_buy
    FROM legs
    GROUP BY wallet, mint
),

holdings AS (
    SELECT token_balance_owner AS wallet, token_mint_address AS mint,
           CAST(SUM(token_balance) AS DOUBLE) AS qty_now
    FROM solana_utils.latest_balances
    WHERE token_balance_owner IN (SELECT wallet FROM wallets)
      AND token_balance > 0
    GROUP BY 1, 2
),

price_now AS (
    SELECT to_base58(contract_address) AS mint, MAX(price) AS price_usd
    FROM prices.latest
    WHERE blockchain = 'solana'
    GROUP BY 1
),

scored AS (
    SELECT
        p.wallet,
        p.first_buy < CAST(pr.cutoff AS TIMESTAMP)                 AS is_pre,
        p.usd_in,
        p.usd_out - p.usd_in                                       AS realized_usd,
        COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)         AS open_value_usd,
        (p.qty_sold + COALESCE(h.qty_now, 0)) / NULLIF(p.qty_bought, 0) AS qty_accounted_ratio
    FROM positions p
    CROSS JOIN params pr
    LEFT JOIN holdings  h  ON h.wallet = p.wallet AND h.mint = p.mint
    LEFT JOIN price_now px ON px.mint  = p.mint
    WHERE p.usd_in >= pr.min_position_usd
      AND p.first_buy IS NOT NULL
)

SELECT
    wallet,
    COUNT_IF(is_pre)                                                  AS pre_positions,
    ROUND(SUM(IF(is_pre, usd_in, 0)))                                 AS pre_invested_usd,
    ROUND(SUM(IF(is_pre, realized_usd, 0)))                           AS pre_realized_usd,
    ROUND(SUM(IF(is_pre, open_value_usd, 0)))                         AS pre_open_value_usd,
    COUNT_IF(NOT is_pre)                                              AS post_positions,
    ROUND(SUM(IF(NOT is_pre, usd_in, 0)))                             AS post_invested_usd,
    ROUND(SUM(IF(NOT is_pre, realized_usd, 0)))                       AS post_realized_usd,
    ROUND(SUM(IF(NOT is_pre, open_value_usd, 0)))                     AS post_open_value_usd,
    -- same reconciliation rule as 08: unreconciled positions are excluded from
    -- both windows rather than the wallet being dropped for owning them
    ROUND(SUM(IF(is_pre AND qty_accounted_ratio <= 1.10,
                 realized_usd + open_value_usd, 0)))                  AS pre_clean_pnl_usd,
    ROUND(SUM(IF(NOT is_pre AND qty_accounted_ratio <= 1.10,
                 realized_usd + open_value_usd, 0)))                  AS post_clean_pnl_usd,
    ROUND(SUM(IF(NOT is_pre AND qty_accounted_ratio <= 1.10, usd_in, 0))) AS post_clean_invested_usd
FROM scored
GROUP BY wallet
ORDER BY pre_clean_pnl_usd DESC
