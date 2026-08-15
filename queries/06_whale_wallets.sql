-- =============================================================================
-- 06 — WHALE SHORTLIST: large, repeat winners on the main memecoins
-- =============================================================================
-- Step one of two. Scores wallets on the universe tokens and emits a shortlist.
-- 08_all_token_pnl.sql then re-prices that shortlist across EVERYTHING they
-- traded, rugs included, and that is the number to trust.
--
-- COST NOTES — this is the expensive query in the set, because unlike 08 it
-- cannot filter by wallet. Three things keep it affordable:
--
--   1. block_month is the PARTITION KEY. Filtering block_time alone still reads
--      every partition; the block_month predicate is what actually prunes them.
--      Biggest single saving available, and it applies to every query here that
--      touches dex_solana.trades.
--   2. One scan, not two. Each trade carries its buy and sell leg as an array
--      expanded after the read, instead of UNIONing a bought-side scan with a
--      sold-side scan of the same table.
--   3. Collapse early. Rows aggregate to (wallet, mint, tx) immediately, so the
--      roundtrip flag falls out of that aggregate rather than needing a
--      self-join back against the full leg set.
--
-- The gate doing the real work is `min_pnl_excluding_best_usd`. Total PnL is
-- dominated by a wallet's single luckiest position, so a wallet that caught one
-- 100x looks identical to one that called four in a row. Subtracting the best
-- position leaves what they made on everything else.
--
-- `('__MINT_LIST__')` is replaced by scripts/find_whales.py from
-- queries/universe_memecoins.txt. Paste mints over that line for a manual run.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,
        5000              AS min_position_usd,            -- floor for a position to count at all
        25000             AS min_invested_usd,            -- total capital deployed
        25000             AS min_total_pnl_usd,
        10000             AS min_pnl_excluding_best_usd,  -- >>> the "won more than once" gate
        3                 AS min_profitable_positions,
        0.20              AS min_roi,
        5                 AS min_median_hold_days,
        0.34              AS max_pct_flipped_same_day,
        -- "sized up on good plays": the single biggest position has to be real
        -- money, otherwise a wallet that spread small tickets across ten names
        -- and got lucky twice ranks alongside a real conviction call.
        25000             AS min_best_position_usd,
        -- "doesn't trade often": about once a week is fine, so this only has to
        -- catch genuine churn — scaling in and out of one name dozens of times.
        20                AS max_avg_txs_per_position
),

universe (mint) AS (
    VALUES
        ('__MINT_LIST__')
),

-- Single scan. block_month prunes partitions; block_time trims the edge.
scan AS (
    SELECT
        t.trader_id AS wallet,
        t.tx_id,
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

-- A Jupiter route hopping through an intermediate pool emits a row per hop, but
-- only the leg touching a universe token survives this filter, so the
-- intermediate hop never reaches the PnL.
legs AS (
    SELECT s.wallet, s.tx_id, s.block_time, l.mint, l.side, l.usd, l.qty
    FROM scan s
    CROSS JOIN UNNEST(s.legs) AS l (mint, side, usd, qty)
    WHERE l.mint IN (SELECT mint FROM universe)
),

-- Collapsing to (wallet, mint, tx) here makes the roundtrip flag an aggregate
-- over this group rather than a join back against every leg.
-- A transaction that both buys and sells the same token is a routing artefact,
-- not an entry followed by an exit; left in it reads as a zero-second hold and
-- throws out exactly the wallets being looked for.
tx_level AS (
    SELECT
        wallet,
        mint,
        tx_id,
        MIN(block_time)                                            AS block_time,
        SUM(IF(side = 'buy',  usd, 0))                             AS buy_usd,
        SUM(IF(side = 'sell', usd, 0))                             AS sell_usd,
        SUM(IF(side = 'buy',  qty, 0))                             AS buy_qty,
        SUM(IF(side = 'sell', qty, 0))                             AS sell_qty,
        COUNT_IF(side = 'buy') > 0 AND COUNT_IF(side = 'sell') > 0 AS is_roundtrip
    FROM legs
    GROUP BY wallet, mint, tx_id
),

positions AS (
    SELECT
        wallet,
        mint,
        SUM(buy_usd)                            AS usd_in,
        SUM(sell_usd)                           AS usd_out,
        SUM(buy_qty)                            AS qty_bought,
        SUM(sell_qty)                           AS qty_sold,
        MIN(IF(buy_usd  > 0, block_time, NULL)) AS first_buy,
        MIN(CASE WHEN sell_usd > 0 AND NOT is_roundtrip THEN block_time END) AS first_real_sell,
        MAX(block_time)                         AS last_action,
        COUNT(*)                                AS n_txs
    FROM tx_level
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
        -- losers, which is the shape being looked for.
        AVG(IF(pnl_usd > 0, usd_in, NULL))                          AS avg_winner_size_usd,
        AVG(IF(pnl_usd < 0, usd_in, NULL))                          AS avg_loser_size_usd,
        MIN(first_buy)                                              AS first_buy,
        MAX(last_action)                                            AS last_action
    FROM position_pnl
    GROUP BY wallet
),

-- Soft exclusion. Dune's Solana label coverage is partial, so this catches the
-- obvious infrastructure and is not a substitute for spot-checking top rows.
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
LIMIT 2000
