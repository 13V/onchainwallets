-- =============================================================================
-- 06 — WHALE WALLETS: large, repeat winners on the main tokens
-- =============================================================================
-- Narrower and blunter than 02. The goal here is a list of wallets, sized for
-- whales, that were right MORE THAN ONCE.
--
-- The gate that does the real work is `min_pnl_excluding_best_usd`. Total PnL
-- is dominated by a wallet's single luckiest position, so a wallet that bought
-- one token that 100x'd looks identical to a wallet that called four in a row.
-- Subtracting the best position before applying the threshold makes the two
-- distinguishable: what is left is what they made on everything ELSE.
--
-- `('__MINT_LIST__')` is replaced automatically by scripts/find_whales.py.
-- For a manual run, paste the mints from 01_token_universe.sql over that line.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,
        25000             AS min_position_usd,            -- whale-sized position, not retail
        250000            AS min_invested_usd,            -- total capital deployed across the majors
        250000            AS min_total_pnl_usd,
        100000            AS min_pnl_excluding_best_usd,  -- >>> the "won more than once" gate
        250000            AS min_net_pnl_all_usd,          -- >>> net of every rug they ate
        3                 AS min_profitable_positions,
        0.30              AS min_roi,
        5                 AS min_median_hold_days,
        0.34              AS max_pct_flipped_same_day,
        50                AS max_txs_per_active_day,      -- bot / market-maker cutoff
        0.25              AS min_universe_volume_share    -- keeps the majors as their main business
),

quote_assets (mint) AS (
    VALUES
        ('So11111111111111111111111111111111111111112'),  -- Wrapped SOL
        ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'), -- USDC
        ('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB')  -- USDT
),

universe (mint) AS (
    VALUES
        ('__MINT_LIST__')
),

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
        SUM(IF(side = 'buy',  usd, 0))                              AS usd_in,
        SUM(IF(side = 'sell', usd, 0))                              AS usd_out,
        SUM(IF(side = 'buy',  qty, 0))                              AS qty_bought,
        SUM(IF(side = 'sell', qty, 0))                              AS qty_sold,
        MIN(IF(side = 'buy',  block_time, NULL))                    AS first_buy,
        MIN(CASE WHEN side = 'sell' AND NOT is_roundtrip THEN block_time END) AS first_real_sell,
        MAX(IF(side = 'sell', block_time, NULL))                    AS last_sell,
        MAX(block_time)                                             AS last_action,
        COUNT(DISTINCT tx_id)                                       AS n_txs
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
        p.mint,
        p.usd_in,
        p.usd_out,
        COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)            AS value_now_usd,
        p.usd_out - p.usd_in
            + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)      AS pnl_usd,
        -- Near 1.0 means every token is accounted for by DEX buys. Above ~1.1
        -- means tokens arrived off-DEX (airdrop, CEX, sibling wallet) and the
        -- PnL is overstated — usually one leg of a multi-wallet operation.
        (p.qty_sold + COALESCE(h.qty_now, 0)) / NULLIF(p.qty_bought, 0) AS qty_accounted_ratio,
        date_diff('day', p.first_buy,
                  COALESCE(p.first_real_sell, CAST(now() AS TIMESTAMP))) AS days_to_first_sell,
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
        COUNT(*)                                                   AS n_positions,
        COUNT_IF(pnl_usd > 0)                                      AS n_profitable_positions,
        SUM(usd_in)                                                AS total_invested_usd,
        SUM(pnl_usd)                                               AS total_pnl_usd,
        MAX(pnl_usd)                                               AS best_position_pnl_usd,
        SUM(pnl_usd) - MAX(pnl_usd)                                AS pnl_excluding_best_usd,
        SUM(value_now_usd)                                         AS still_held_value_usd,
        approx_percentile(CAST(days_to_first_sell AS DOUBLE), 0.5) AS median_hold_days,
        COUNT_IF(days_to_first_sell < 1) * 1.0 / COUNT(*)          AS pct_flipped_same_day,
        COUNT_IF(first_real_sell IS NULL AND value_now_usd > 10000) AS positions_never_sold,
        COUNT_IF(qty_accounted_ratio > 1.10)                       AS n_positions_external_inflow,
        MIN(first_buy)                                             AS first_buy,
        MAX(last_action)                                           AS last_action
    FROM position_pnl
    GROUP BY wallet
),

-- Cheap gates first so the full-history scan below touches a small set only.
shortlist AS (
    SELECT w.*
    FROM wallet_stats w
    CROSS JOIN params p
    WHERE w.n_positions            >= 2
      AND w.n_profitable_positions >= p.min_profitable_positions
      AND w.total_invested_usd     >= p.min_invested_usd
      AND w.total_pnl_usd          >= p.min_total_pnl_usd
      AND w.pnl_excluding_best_usd >= p.min_pnl_excluding_best_usd
      AND w.total_pnl_usd / NULLIF(w.total_invested_usd, 0) >= p.min_roi
      AND w.median_hold_days       >= p.min_median_hold_days
      AND w.pct_flipped_same_day   <= p.max_pct_flipped_same_day
),

full_history AS (
    SELECT
        t.trader_id                  AS wallet,
        COUNT(DISTINCT t.tx_id)      AS n_txs_all,
        COUNT(DISTINCT t.block_date) AS n_active_days_all,
        SUM(t.amount_usd)            AS volume_all_usd,
        COUNT(DISTINCT CASE
            WHEN t.token_bought_mint_address NOT IN (SELECT mint FROM quote_assets)
            THEN t.token_bought_mint_address
        END)                         AS n_distinct_tokens_bought
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

-- ---------------------------------------------------------------------------
-- NET PnL ACROSS EVERYTHING, INCLUDING THE RUGS
-- ---------------------------------------------------------------------------
-- Everything above scores wallets on the majors only. On its own that is a trap:
-- a wallet up $2M on PENGU and down $5M on rugs scores identically to one that
-- only ever traded the majors. These CTEs price every non-quote token the
-- shortlist ever touched so the losses are on the books too.
--
-- A rugged token prices correctly without special handling: buys land in usd_in,
-- there are usually no sells, and the remaining bag is worth ~nothing, so the
-- position reads as a near-total loss. The edge case is an illiquid-but-alive
-- token with no row in prices.latest — that is valued at zero and overstates the
-- loss. n_total_wipeouts is the column to sanity-check when a number looks odd.
all_legs AS (
    SELECT t.trader_id AS wallet, t.token_bought_mint_address AS mint,
           'buy' AS side, t.amount_usd AS usd, t.token_bought_amount AS qty
    FROM dex_solana.trades t
    WHERE t.trader_id IN (SELECT wallet FROM shortlist)
      AND t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
      AND t.token_bought_mint_address NOT IN (SELECT mint FROM quote_assets)

    UNION ALL

    SELECT t.trader_id, t.token_sold_mint_address,
           'sell', t.amount_usd, t.token_sold_amount
    FROM dex_solana.trades t
    WHERE t.trader_id IN (SELECT wallet FROM shortlist)
      AND t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
      AND t.token_sold_mint_address NOT IN (SELECT mint FROM quote_assets)
),

all_positions AS (
    SELECT
        wallet,
        mint,
        SUM(IF(side = 'buy',  usd, 0)) AS usd_in,
        SUM(IF(side = 'sell', usd, 0)) AS usd_out
    FROM all_legs
    GROUP BY wallet, mint
),

-- Scoped by wallet rather than by mint: these wallets hold arbitrary tokens.
all_holdings AS (
    SELECT token_balance_owner AS wallet, token_mint_address AS mint,
           CAST(SUM(token_balance) AS DOUBLE) AS qty_now
    FROM solana_utils.latest_balances
    WHERE token_balance_owner IN (SELECT wallet FROM shortlist)
      AND token_balance > 0
    GROUP BY 1, 2
),

all_prices AS (
    SELECT to_base58(contract_address) AS mint, MAX(price) AS price_usd
    FROM prices.latest
    WHERE blockchain = 'solana'
    GROUP BY 1
),

all_pnl AS (
    SELECT
        ap.wallet,
        ap.usd_in,
        ap.usd_out,
        COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)          AS value_now_usd,
        ap.usd_out - ap.usd_in
            + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)    AS pnl_usd
    FROM all_positions ap
    LEFT JOIN all_holdings h  ON h.wallet = ap.wallet AND h.mint = ap.mint
    LEFT JOIN all_prices   px ON px.mint  = ap.mint
    WHERE ap.usd_in >= 100
),

all_stats AS (
    SELECT
        wallet,
        SUM(pnl_usd)                                     AS net_pnl_all_usd,
        COUNT(*)                                         AS n_positions_all,
        COUNT_IF(pnl_usd < 0)                            AS n_losing_positions,
        SUM(IF(pnl_usd < 0, pnl_usd, 0))                 AS gross_losses_usd,
        MIN(pnl_usd)                                     AS worst_position_usd,
        -- recovered less than a tenth of cost and the bag is worth nothing:
        -- rugged, or dead enough that the difference does not matter
        COUNT_IF(usd_out + value_now_usd < 0.10 * usd_in) AS n_total_wipeouts,
        SUM(IF(usd_out + value_now_usd < 0.10 * usd_in,
               usd_in - usd_out - value_now_usd, 0))     AS wipeout_loss_usd
    FROM all_pnl
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
    ROUND(a.net_pnl_all_usd)                                        AS net_pnl_all_tokens_usd,
    ROUND(s.total_pnl_usd)                                          AS majors_pnl_usd,
    ROUND(s.pnl_excluding_best_usd)                                 AS pnl_excluding_best_usd,
    ROUND(a.gross_losses_usd)                                       AS gross_losses_usd,
    a.n_total_wipeouts,
    ROUND(a.wipeout_loss_usd)                                       AS wipeout_loss_usd,
    ROUND(a.worst_position_usd)                                     AS worst_position_usd,
    a.n_losing_positions,
    a.n_positions_all,
    ROUND(s.best_position_pnl_usd)                                  AS best_position_pnl_usd,
    ROUND(s.total_pnl_usd / NULLIF(s.total_invested_usd, 0), 2)     AS roi,
    ROUND(s.total_invested_usd)                                     AS total_invested_usd,
    ROUND(s.still_held_value_usd)                                   AS still_held_value_usd,
    s.n_positions,
    s.n_profitable_positions,
    ROUND(s.n_profitable_positions * 1.0 / s.n_positions, 2)        AS win_rate,
    ROUND(s.median_hold_days)                                       AS median_hold_days,
    s.positions_never_sold,
    ROUND(s.pct_flipped_same_day, 2)                                AS pct_flipped_same_day,
    fh.n_distinct_tokens_bought,
    ROUND(uv.volume_universe_usd / NULLIF(fh.volume_all_usd, 0), 2) AS universe_volume_share,
    ROUND(fh.n_txs_all * 1.0 / NULLIF(fh.n_active_days_all, 0), 1)  AS txs_per_active_day,
    s.n_positions_external_inflow,
    li.label_name                                                   AS dune_label,
    s.first_buy,
    s.last_action,
    date_diff('day', s.last_action, CAST(now() AS TIMESTAMP))       AS days_since_last_action
FROM shortlist s
JOIN full_history    fh ON fh.wallet = s.wallet
JOIN universe_volume uv ON uv.wallet = s.wallet
JOIN all_stats       a  ON a.wallet  = s.wallet
LEFT JOIN labelled_infra li ON li.wallet = s.wallet
CROSS JOIN params p
WHERE li.wallet IS NULL
  AND fh.n_txs_all * 1.0 / NULLIF(fh.n_active_days_all, 0) <= p.max_txs_per_active_day
  AND uv.volume_universe_usd / NULLIF(fh.volume_all_usd, 0) >= p.min_universe_volume_share
  AND a.net_pnl_all_usd >= p.min_net_pnl_all_usd
ORDER BY net_pnl_all_tokens_usd DESC
LIMIT 500
