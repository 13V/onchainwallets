-- =============================================================================
-- 03 — WALLET DEEP DIVE: audit one candidate before you track it
-- =============================================================================
-- Never add a wallet to a watchlist straight off the leaderboard. Run it through
-- here first. You are looking for reasons to REJECT it:
--
--   * position_ledger — is the PnL one moonshot or a repeated pattern?
--   * qty_accounted_ratio far from 1.0 — tokens arrived or left off-DEX, which
--     means it is one leg of a multi-wallet operation and the PnL is fiction
--   * every_token_traded — if the tail is 500 pump.fun tickers, it is a degen
--     that got lucky on the majors, not a disciplined holder
--   * monthly_activity — steady, or one hot streak 14 months ago and then dead?
--
-- Set the `wallet_address` parameter (Dune: "Add parameter" -> Text) or replace
-- {{wallet_address}} inline.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01'     AS lookback_start,
        '{{wallet_address}}'  AS wallet
),

quote_assets (mint) AS (
    VALUES
        ('So11111111111111111111111111111111111111112'),
        ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'),
        ('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB')
),

-- Every DEX leg this wallet ever traded, reduced to (non-quote token, side).
legs AS (
    SELECT
        t.block_time,
        t.block_date,
        t.tx_id,
        t.project,
        t.trade_source,
        t.token_bought_mint_address AS mint,
        'buy'                       AS side,
        t.token_bought_amount       AS qty,
        t.amount_usd                AS usd
    FROM dex_solana.trades t
    CROSS JOIN params p
    WHERE t.trader_id = p.wallet
      AND t.block_time >= p.lookback_start
      AND t.amount_usd > 0
      AND t.token_bought_mint_address NOT IN (SELECT mint FROM quote_assets)

    UNION ALL

    SELECT
        t.block_time,
        t.block_date,
        t.tx_id,
        t.project,
        t.trade_source,
        t.token_sold_mint_address,
        'sell',
        t.token_sold_amount,
        t.amount_usd
    FROM dex_solana.trades t
    CROSS JOIN params p
    WHERE t.trader_id = p.wallet
      AND t.block_time >= p.lookback_start
      AND t.amount_usd > 0
      AND t.token_sold_mint_address NOT IN (SELECT mint FROM quote_assets)
),

roundtrip_txs AS (
    SELECT mint, tx_id
    FROM legs
    GROUP BY mint, tx_id
    HAVING COUNT(DISTINCT side) = 2
),

positions AS (
    SELECT
        l.mint,
        SUM(IF(l.side = 'buy',  l.usd, 0))          AS usd_in,
        SUM(IF(l.side = 'sell', l.usd, 0))          AS usd_out,
        SUM(IF(l.side = 'buy',  l.qty, 0))          AS qty_bought,
        SUM(IF(l.side = 'sell', l.qty, 0))          AS qty_sold,
        MIN(IF(l.side = 'buy',  l.block_time, NULL)) AS first_buy,
        MAX(IF(l.side = 'buy',  l.block_time, NULL)) AS last_buy,
        MIN(CASE WHEN l.side = 'sell' AND r.tx_id IS NULL THEN l.block_time END) AS first_real_sell,
        MAX(IF(l.side = 'sell', l.block_time, NULL)) AS last_sell,
        COUNT(DISTINCT l.tx_id)                      AS n_txs
    FROM legs l
    LEFT JOIN roundtrip_txs r ON r.mint = l.mint AND r.tx_id = l.tx_id
    GROUP BY l.mint
),

holdings AS (
    SELECT
        token_mint_address                 AS mint,
        CAST(SUM(token_balance) AS DOUBLE) AS qty_now
    FROM solana_utils.latest_balances
    WHERE token_balance_owner = (SELECT wallet FROM params)
    GROUP BY 1
),

price_now AS (
    SELECT to_base58(contract_address) AS mint, MAX(price) AS price_usd
    FROM prices.latest
    WHERE blockchain = 'solana'
    GROUP BY 1
)

-- ---------------------------------------------------------------------------
-- POSITION LEDGER — one row per token, biggest winners first.
-- Swap this final SELECT for one of the alternates at the bottom of the file.
-- ---------------------------------------------------------------------------
SELECT
    COALESCE(f.symbol, '?')                                           AS symbol,
    p.mint,
    ROUND(p.usd_in)                                                   AS usd_in,
    ROUND(p.usd_out)                                                  AS usd_out,
    ROUND(COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0))         AS value_now_usd,
    ROUND(p.usd_out - p.usd_in
          + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0))       AS pnl_usd,
    ROUND((p.usd_out - p.usd_in
          + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0))
          / NULLIF(p.usd_in, 0), 2)                                   AS roi,
    date_diff('day', p.first_buy,
              COALESCE(p.first_real_sell, CAST(now() AS TIMESTAMP)))  AS days_to_first_sell,
    date_diff('day', p.first_buy, COALESCE(p.last_sell, CAST(now() AS TIMESTAMP))) AS days_in_position,
    p.n_txs,
    ROUND((p.qty_sold + COALESCE(h.qty_now, 0)) / NULLIF(p.qty_bought, 0), 3) AS qty_accounted_ratio,
    p.first_buy,
    p.first_real_sell,
    p.last_sell
FROM positions p
LEFT JOIN holdings  h  ON h.mint  = p.mint
LEFT JOIN price_now px ON px.mint = p.mint
LEFT JOIN tokens_solana.fungible f ON f.token_mint_address = p.mint
WHERE p.usd_in >= 100
ORDER BY pnl_usd DESC

-- ---------------------------------------------------------------------------
-- ALTERNATE 1 — every token they ever touched, to see the real tail.
-- Comment out the SELECT above and uncomment this.
-- ---------------------------------------------------------------------------
-- SELECT
--     COUNT(*)                                        AS tokens_traded,
--     COUNT_IF(usd_in >= 1000)                        AS tokens_with_1k_plus,
--     COUNT_IF(usd_in <  200)                         AS tokens_under_200,
--     ROUND(SUM(usd_in))                              AS lifetime_usd_deployed,
--     ROUND(approx_percentile(usd_in, 0.5))           AS median_position_usd
-- FROM positions

-- ---------------------------------------------------------------------------
-- ALTERNATE 2 — activity over time. Looking for consistency, not one hot month.
-- ---------------------------------------------------------------------------
-- SELECT
--     date_trunc('month', block_time)  AS month,
--     COUNT(DISTINCT tx_id)            AS n_txs,
--     COUNT(DISTINCT mint)             AS n_tokens,
--     ROUND(SUM(usd))                  AS volume_usd
-- FROM legs
-- GROUP BY 1
-- ORDER BY 1

-- ---------------------------------------------------------------------------
-- ALTERNATE 3 — raw trade tape, most recent first.
-- ---------------------------------------------------------------------------
-- SELECT block_time, side, mint, ROUND(usd) AS usd, qty, project, trade_source, tx_id
-- FROM legs
-- ORDER BY block_time DESC
-- LIMIT 500
