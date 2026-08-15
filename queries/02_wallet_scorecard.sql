-- =============================================================================
-- 02 — WALLET SCORECARD: profitable buy-and-hold wallets in the OG memecoin set
-- =============================================================================
-- The main query. Produces a ranked shortlist of wallets that:
--   * made real money on tokens that reached $100M+ (not one lucky hit)
--   * HELD — median time from first buy to first sell measured in weeks, not minutes
--   * are not bots, aggregators, CEX hot wallets or MEV searchers
--   * spend most of their volume on the majors rather than spraying new launches
--
-- >>> BEFORE RUNNING: run 01_token_universe.sql, then paste the mints you want
-- >>> into the `universe` CTE below. Left unedited this returns zero rows.
--
-- Cost note: this scans dex_solana.trades twice with a join filter plus once
-- more for the shortlist's full history. Keep `lookback_start` tight the first
-- few runs while you calibrate the thresholds.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,
        500               AS min_position_usd,          -- ignore dust positions
        3                 AS min_positions,             -- must have traded >= 3 of the majors
        3                 AS min_profitable_positions,  -- must be right repeatedly, not once
        100000            AS min_total_pnl_usd,
        0.5               AS min_roi,                   -- 0.5 = +50%
        7                 AS min_median_hold_days,      -- the buy-and-hold gate
        0.25              AS max_pct_flipped_same_day,  -- allows some trimming, not day trading
        30                AS max_txs_per_active_day,    -- bot / market-maker cutoff
        400               AS max_distinct_tokens,       -- spray-and-pray degen cutoff
        0.40              AS min_universe_volume_share  -- "only trades high mc coins"
),

quote_assets (mint) AS (
    VALUES
        ('So11111111111111111111111111111111111111112'),  -- Wrapped SOL
        ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'), -- USDC
        ('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB')  -- USDT
),

-- ####################### EDIT ME #######################
-- Paste the `mint` values from 01_token_universe.sql here, one per line.
-- Keep the memecoins, drop the LSTs / bridged majors / infra tokens that the
-- market-cap screen also catches (JUP, JTO, RAY, PYTH, wBTC, ...).
universe (mint) AS (
    VALUES
        ('PASTE_MINT_FROM_QUERY_01_HERE_1'),
        ('PASTE_MINT_FROM_QUERY_01_HERE_2'),
        ('PASTE_MINT_FROM_QUERY_01_HERE_3')
),
-- #######################################################

-- Every buy leg and every sell leg touching a universe token.
-- A Jupiter route that hops through an intermediate pool emits one row per hop,
-- but only the hop that actually touches our token matches the join, so nothing
-- is double counted.
raw_legs AS (
    SELECT
        t.trader_id                AS wallet,
        t.token_bought_mint_address AS mint,
        'buy'                      AS side,
        t.token_bought_amount      AS qty,
        t.amount_usd               AS usd,
        t.block_time,
        t.tx_id
    FROM dex_solana.trades t
    JOIN universe u ON u.mint = t.token_bought_mint_address
    WHERE t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0

    UNION ALL

    SELECT
        t.trader_id,
        t.token_sold_mint_address,
        'sell',
        t.token_sold_amount,
        t.amount_usd,
        t.block_time,
        t.tx_id
    FROM dex_solana.trades t
    JOIN universe u ON u.mint = t.token_sold_mint_address
    WHERE t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
),

-- A transaction that both buys and sells the same token is an arb/route artefact,
-- not a real entry followed by a real exit. Without this the hold-time metric
-- reads "held for 0 seconds" and every legitimate holder gets thrown out.
roundtrip_txs AS (
    SELECT wallet, mint, tx_id
    FROM raw_legs
    GROUP BY wallet, mint, tx_id
    HAVING COUNT(DISTINCT side) = 2
),

legs AS (
    SELECT l.*, (r.tx_id IS NOT NULL) AS is_roundtrip
    FROM raw_legs l
    LEFT JOIN roundtrip_txs r
           ON r.wallet = l.wallet AND r.mint = l.mint AND r.tx_id = l.tx_id
),

positions AS (
    SELECT
        wallet,
        mint,
        SUM(IF(side = 'buy',  usd, 0))                              AS usd_in,
        SUM(IF(side = 'sell', usd, 0))                              AS usd_out,
        SUM(IF(side = 'buy',  qty, 0))                              AS qty_bought,
        SUM(IF(side = 'sell', qty, 0))                              AS qty_sold,
        MIN(IF(side = 'buy',  block_time, NULL))                    AS first_buy,
        MAX(IF(side = 'buy',  block_time, NULL))                    AS last_buy,
        MIN(CASE WHEN side = 'sell' AND NOT is_roundtrip THEN block_time END) AS first_real_sell,
        MAX(IF(side = 'sell', block_time, NULL))                    AS last_sell,
        COUNT(DISTINCT tx_id)                                       AS n_txs,
        COUNT(DISTINCT IF(side = 'buy',  tx_id, NULL))              AS n_buy_txs,
        COUNT(DISTINCT IF(side = 'sell', tx_id, NULL))              AS n_sell_txs,
        COUNT(DISTINCT IF(is_roundtrip,  tx_id, NULL))              AS n_roundtrip_txs
    FROM legs
    GROUP BY wallet, mint
),

-- Current holdings. `token_balance_owner` is the wallet that owns the token
-- account, which is what dex_solana.trades.trader_id refers to.
holdings AS (
    SELECT
        token_balance_owner              AS wallet,
        token_mint_address               AS mint,
        CAST(SUM(token_balance) AS DOUBLE) AS qty_now
    FROM solana_utils.latest_balances
    WHERE token_mint_address IN (SELECT mint FROM universe)
    GROUP BY 1, 2
),

price_now AS (
    SELECT to_base58(contract_address) AS mint, MAX(price) AS price_usd
    FROM prices.latest
    WHERE blockchain = 'solana'
      AND contract_address IN (SELECT from_base58(mint) FROM universe)
    GROUP BY 1
),

position_pnl AS (
    SELECT
        p.wallet,
        p.mint,
        p.usd_in,
        p.usd_out,
        COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)                AS value_now_usd,
        p.usd_out - p.usd_in
            + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)         AS pnl_usd,
        -- Sanity ratio: of everything they bought on a DEX, how much is
        -- accounted for by DEX sells + what they still hold? >1.1 means tokens
        -- arrived from somewhere we cannot see (airdrop, CEX, another wallet)
        -- and PnL is overstated. <0.9 means they sent tokens away and PnL is
        -- understated. Either way the number needs a human look.
        (p.qty_sold + COALESCE(h.qty_now, 0)) / NULLIF(p.qty_bought, 0)   AS qty_accounted_ratio,
        date_diff('day', p.first_buy,
                  COALESCE(p.first_real_sell, CAST(now() AS TIMESTAMP)))  AS days_to_first_sell,
        p.first_buy,
        p.last_buy,
        p.first_real_sell,
        p.last_sell,
        p.n_txs,
        p.n_roundtrip_txs
    FROM positions p
    CROSS JOIN params pr
    LEFT JOIN holdings  h  ON h.wallet = p.wallet AND h.mint = p.mint
    LEFT JOIN price_now px ON px.mint  = p.mint
    WHERE p.usd_in >= pr.min_position_usd
),

wallet_stats AS (
    SELECT
        wallet,
        COUNT(*)                                                        AS n_positions,
        COUNT_IF(pnl_usd > 0)                                           AS n_profitable_positions,
        SUM(usd_in)                                                     AS total_invested_usd,
        SUM(pnl_usd)                                                    AS total_pnl_usd,
        SUM(pnl_usd) / NULLIF(SUM(usd_in), 0)                           AS roi,
        SUM(value_now_usd)                                              AS open_value_usd,
        approx_percentile(CAST(days_to_first_sell AS DOUBLE), 0.5)      AS median_hold_days,
        COUNT_IF(days_to_first_sell < 1) * 1.0 / COUNT(*)               AS pct_flipped_same_day,
        COUNT_IF(first_real_sell IS NULL AND value_now_usd > 1000)      AS n_never_sold,
        COUNT_IF(qty_accounted_ratio > 1.10)                            AS n_positions_external_inflow,
        SUM(n_roundtrip_txs)                                            AS n_roundtrip_txs,
        MIN(first_buy)                                                  AS first_universe_buy,
        MAX(COALESCE(last_sell, last_buy))                              AS last_universe_action
    FROM position_pnl
    GROUP BY wallet
),

-- Cheap gates first, so the full-history scan below only touches a small set.
shortlist AS (
    SELECT w.*
    FROM wallet_stats w
    CROSS JOIN params p
    WHERE w.n_positions             >= p.min_positions
      AND w.n_profitable_positions  >= p.min_profitable_positions
      AND w.total_pnl_usd           >= p.min_total_pnl_usd
      AND w.roi                     >= p.min_roi
      AND w.median_hold_days        >= p.min_median_hold_days
      AND w.pct_flipped_same_day    <= p.max_pct_flipped_same_day
),

-- Everything these wallets did across all of Solana DEX, not just our tokens.
-- This is what separates "disciplined major-coin holder" from "degen who also
-- happened to hold PENGU while flipping 900 pump.fun launches".
full_history AS (
    SELECT
        t.trader_id                     AS wallet,
        COUNT(DISTINCT t.tx_id)         AS n_txs_all,
        COUNT(DISTINCT t.block_date)    AS n_active_days_all,
        SUM(t.amount_usd)               AS volume_all_usd,
        COUNT(DISTINCT CASE
            WHEN t.token_bought_mint_address NOT IN (SELECT mint FROM quote_assets)
            THEN t.token_bought_mint_address
        END)                            AS n_distinct_tokens_bought
    FROM dex_solana.trades t
    WHERE t.trader_id IN (SELECT wallet FROM shortlist)
      AND t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
    GROUP BY 1
),

universe_volume AS (
    SELECT wallet, SUM(usd) AS volume_universe_usd
    FROM legs
    WHERE wallet IN (SELECT wallet FROM shortlist)
    GROUP BY 1
),

-- Soft exclusion. Dune's Solana label coverage is partial, so this removes the
-- obvious infrastructure addresses but is not a substitute for eyeballing the
-- top of the list in 03_wallet_deep_dive.sql.
labelled_infra AS (
    SELECT to_base58(address) AS wallet, MAX(name) AS label_name
    FROM labels.addresses
    WHERE blockchain = 'solana'
      AND category IN ('cex', 'dex', 'bridge', 'contract', 'mev', 'infrastructure')
    GROUP BY 1
)

SELECT
    s.wallet,
    ROUND(s.total_pnl_usd)                                       AS total_pnl_usd,
    ROUND(s.roi, 2)                                              AS roi,
    ROUND(s.total_invested_usd)                                  AS total_invested_usd,
    ROUND(s.open_value_usd)                                      AS still_held_value_usd,
    s.n_positions,
    s.n_profitable_positions,
    ROUND(s.n_profitable_positions * 1.0 / s.n_positions, 2)     AS win_rate,
    ROUND(s.median_hold_days)                                    AS median_hold_days,
    s.n_never_sold                                               AS positions_never_sold,
    ROUND(s.pct_flipped_same_day, 2)                             AS pct_flipped_same_day,
    -- behaviour / purity
    fh.n_distinct_tokens_bought,
    ROUND(uv.volume_universe_usd / NULLIF(fh.volume_all_usd, 0), 2) AS universe_volume_share,
    fh.n_txs_all,
    ROUND(fh.n_txs_all * 1.0 / NULLIF(fh.n_active_days_all, 0), 1)  AS txs_per_active_day,
    -- integrity flags to check before trusting a row
    s.n_positions_external_inflow,
    s.n_roundtrip_txs,
    li.label_name                                                AS dune_label,
    s.first_universe_buy,
    s.last_universe_action,
    date_diff('day', s.last_universe_action, CAST(now() AS TIMESTAMP)) AS days_since_last_action
FROM shortlist s
JOIN full_history    fh ON fh.wallet = s.wallet
JOIN universe_volume uv ON uv.wallet = s.wallet
LEFT JOIN labelled_infra li ON li.wallet = s.wallet
CROSS JOIN params p
WHERE li.wallet IS NULL
  AND fh.n_distinct_tokens_bought <= p.max_distinct_tokens
  AND fh.n_txs_all * 1.0 / NULLIF(fh.n_active_days_all, 0) <= p.max_txs_per_active_day
  AND uv.volume_universe_usd / NULLIF(fh.volume_all_usd, 0)  >= p.min_universe_volume_share
ORDER BY total_pnl_usd DESC
LIMIT 200
