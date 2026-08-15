-- =============================================================================
-- 06 — WHALE SHORTLIST: large, repeat winners on the main memecoins
-- =============================================================================
-- Step one of two. This scores wallets on the universe tokens only and emits a
-- shortlist. 07_wallet_risk_profile.sql then re-prices that shortlist across
-- EVERYTHING they traded, rugs included, and that is the number to trust.
--
-- Why split: an earlier single-query version made five passes over
-- dex_solana.trades (two for the universe legs, one for full history, two for
-- all-token PnL) and could not finish inside Dune's 30 minute execution limit.
-- Two queries of two passes each run comfortably, and the wallet list handed to
-- 07 is small enough to inline as literals, which filters far harder than a
-- correlated subquery over a billion-row table.
--
-- The gate that does the real work here is `min_pnl_excluding_best_usd`. Total
-- PnL is dominated by a wallet's single luckiest position, so a wallet that
-- caught one 100x looks identical to one that called four in a row. Subtracting
-- the best position first leaves what they made on everything ELSE.
--
-- `('__MINT_LIST__')` is replaced by scripts/find_whales.py from
-- queries/universe_memecoins.txt. Paste mints over that line for a manual run.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,
        25000             AS min_position_usd,            -- whale-sized position, not retail
        250000            AS min_invested_usd,            -- total capital deployed
        250000            AS min_total_pnl_usd,
        100000            AS min_pnl_excluding_best_usd,  -- >>> the "won more than once" gate
        3                 AS min_profitable_positions,
        0.30              AS min_roi,
        5                 AS min_median_hold_days,
        0.34              AS max_pct_flipped_same_day,
        -- "sized up on good plays": the single biggest position has to be real
        -- money, otherwise a wallet that spread $30k across ten names and got
        -- lucky twice ranks alongside one that put $400k on a conviction call.
        100000            AS min_best_position_usd,
        -- "doesn't trade often": buys once or twice and sits. A wallet
        -- averaging 20 transactions per token is scaling in and out constantly,
        -- which is a different strategy and not copyable on a slow feed.
        12                AS max_avg_txs_per_position
),

universe (mint) AS (
    VALUES
        ('__MINT_LIST__')
),

-- One row per buy leg and per sell leg touching a universe token. A Jupiter
-- route that hops through an intermediate pool emits a row per hop, but only
-- the hop touching our token matches the join, so nothing is double counted.
raw_legs AS (
    SELECT
        t.trader_id                 AS wallet,
        t.token_bought_mint_address AS mint,
        'buy'                       AS side,
        t.token_bought_amount       AS qty,
        t.amount_usd                AS usd,
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

-- A transaction that both buys and sells the same token is a routing artefact,
-- not an entry followed by an exit. Left in, it reads as a zero-second hold and
-- throws out exactly the wallets we are looking for.
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
        SUM(IF(side = 'buy',  usd, 0))           AS usd_in,
        SUM(IF(side = 'sell', usd, 0))           AS usd_out,
        SUM(IF(side = 'buy',  qty, 0))           AS qty_bought,
        SUM(IF(side = 'sell', qty, 0))           AS qty_sold,
        MIN(IF(side = 'buy',  block_time, NULL)) AS first_buy,
        MIN(CASE WHEN side = 'sell' AND NOT is_roundtrip THEN block_time END) AS first_real_sell,
        MAX(block_time)                          AS last_action,
        COUNT(DISTINCT tx_id)                    AS n_txs
    FROM legs
    GROUP BY wallet, mint
),

holdings AS (
    SELECT
        token_balance_owner                AS wallet,
        token_mint_address                 AS mint,
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
      AND contract_address IN (SELECT from_base58(mint) FROM universe)
    GROUP BY 1
),

position_pnl AS (
    SELECT
        p.wallet,
        p.usd_in,
        COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)            AS value_now_usd,
        p.usd_out - p.usd_in
            + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)      AS pnl_usd,
        -- Near 1.0 means every token is accounted for by DEX buys. Above ~1.1
        -- means tokens arrived off-DEX (airdrop, CEX, sibling wallet) and the
        -- PnL is overstated — usually one leg of a multi-wallet operation.
        (p.qty_sold + COALESCE(h.qty_now, 0)) / NULLIF(p.qty_bought, 0) AS qty_accounted_ratio,
        date_diff('day', p.first_buy,
                  COALESCE(p.first_real_sell, CAST(now() AS TIMESTAMP))) AS days_to_first_sell,
        p.first_real_sell,
        p.first_buy,
        p.last_action,
        p.n_txs
    FROM positions p
    CROSS JOIN params pr
    LEFT JOIN holdings  h  ON h.wallet = p.wallet AND h.mint = p.mint
    LEFT JOIN price_now px ON px.mint  = p.mint
    WHERE p.usd_in >= pr.min_position_usd
),

wallet_stats AS (
    SELECT
        wallet,
        COUNT(*)                                                    AS n_positions,
        COUNT_IF(pnl_usd > 0)                                       AS n_profitable_positions,
        SUM(usd_in)                                                 AS total_invested_usd,
        SUM(pnl_usd)                                                AS total_pnl_usd,
        MAX(pnl_usd)                                                AS best_position_pnl_usd,
        SUM(pnl_usd) - MAX(pnl_usd)                                 AS pnl_excluding_best_usd,
        SUM(value_now_usd)                                          AS still_held_value_usd,
        approx_percentile(CAST(days_to_first_sell AS DOUBLE), 0.5)  AS median_hold_days,
        COUNT_IF(days_to_first_sell < 1) * 1.0 / COUNT(*)           AS pct_flipped_same_day,
        COUNT_IF(first_real_sell IS NULL AND value_now_usd > 10000) AS positions_never_sold,
        COUNT_IF(qty_accounted_ratio > 1.10)                        AS n_positions_external_inflow,
        MAX(usd_in)                                                 AS biggest_position_usd,
        SUM(n_txs) * 1.0 / COUNT(*)                                 AS avg_txs_per_position,
        -- Conviction: do they bet BIGGER when they turn out to be right?
        -- Above 1.0 means their winners were larger positions than their
        -- losers, which is the shape being asked for. Below 1.0 means their
        -- size went into the wrong names and the wins were incidental.
        AVG(IF(pnl_usd > 0, usd_in, NULL))                          AS avg_winner_size_usd,
        AVG(IF(pnl_usd < 0, usd_in, NULL))                          AS avg_loser_size_usd,
        MIN(first_buy)                                              AS first_buy,
        MAX(last_action)                                            AS last_action
    FROM position_pnl
    GROUP BY wallet
),

-- Soft exclusion. Dune's Solana label coverage is partial, so this catches the
-- obvious infrastructure and is not a substitute for spot-checking the top rows.
labelled_infra AS (
    SELECT to_base58(address) AS wallet, MAX(name) AS label_name
    FROM labels.addresses
    WHERE blockchain = 'solana'
      AND category IN ('cex', 'dex', 'bridge', 'contract', 'mev', 'infrastructure')
    GROUP BY 1
)

SELECT
    s.wallet,
    ROUND(s.total_pnl_usd)                                       AS majors_pnl_usd,
    ROUND(s.pnl_excluding_best_usd)                              AS pnl_excluding_best_usd,
    ROUND(s.best_position_pnl_usd)                               AS best_position_pnl_usd,
    ROUND(s.total_pnl_usd / NULLIF(s.total_invested_usd, 0), 2)  AS roi,
    ROUND(s.total_invested_usd)                                  AS total_invested_usd,
    ROUND(s.still_held_value_usd)                                AS still_held_value_usd,
    s.n_positions,
    s.n_profitable_positions,
    ROUND(s.n_profitable_positions * 1.0 / s.n_positions, 2)     AS win_rate,
    ROUND(s.median_hold_days)                                    AS median_hold_days,
    ROUND(s.biggest_position_usd)                                AS biggest_position_usd,
    ROUND(s.avg_txs_per_position, 1)                             AS avg_txs_per_position,
    ROUND(s.avg_winner_size_usd)                                 AS avg_winner_size_usd,
    ROUND(s.avg_loser_size_usd)                                  AS avg_loser_size_usd,
    ROUND(s.avg_winner_size_usd / NULLIF(s.avg_loser_size_usd, 0), 2) AS conviction_ratio,
    s.positions_never_sold,
    ROUND(s.pct_flipped_same_day, 2)                             AS pct_flipped_same_day,
    s.n_positions_external_inflow,
    li.label_name                                                AS dune_label,
    s.first_buy,
    s.last_action
FROM wallet_stats s
CROSS JOIN params p
LEFT JOIN labelled_infra li ON li.wallet = s.wallet
WHERE li.wallet IS NULL
  AND s.n_positions            >= 2
  AND s.n_profitable_positions >= p.min_profitable_positions
  AND s.total_invested_usd     >= p.min_invested_usd
  AND s.total_pnl_usd          >= p.min_total_pnl_usd
  AND s.pnl_excluding_best_usd >= p.min_pnl_excluding_best_usd
  AND s.total_pnl_usd / NULLIF(s.total_invested_usd, 0) >= p.min_roi
  AND s.median_hold_days       >= p.min_median_hold_days
  AND s.pct_flipped_same_day   <= p.max_pct_flipped_same_day
  AND s.biggest_position_usd   >= p.min_best_position_usd
  AND s.avg_txs_per_position   <= p.max_avg_txs_per_position
ORDER BY pnl_excluding_best_usd DESC
LIMIT 500
