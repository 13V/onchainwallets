-- =============================================================================
-- 08 — ALL-TOKEN PnL: the honest number, rugs included
-- =============================================================================
-- THE GATE. Nothing goes on a watchlist until it passes this.
--
-- 06 scores wallets on the universe tokens only. On its own that is worse than
-- useless: a wallet up $600k on PENGU and down $2M across a hundred other
-- tokens scores as a winner. Wallet explorers price everything, which is why
-- names off a universe-only list can show deep red the moment you look them up.
--
-- This prices every non-quote token a wallet touched and returns net PnL. Run
-- it on the 06 shortlist and drop anything not comfortably positive here.
--
-- Rugs need no special handling: buys land in usd_in, there are no sells, and
-- the leftover bag prices at ~zero, so the position reads as a near-total loss.
-- The one soft spot is an illiquid-but-alive token missing from prices.latest —
-- valued at zero, which overstates the loss. n_total_wipeouts is the column to
-- sanity-check when a number looks too ugly to be true.
--
-- COST: one pass over dex_solana.trades. The array/UNNEST shape below expands
-- each trade into its buy and sell leg after the scan rather than UNIONing two
-- separate scans of the same table — same result, half the read. With a wallet
-- list inlined as literals this is the cheap way round; deriving the list in a
-- subquery here instead would put the filter back on the wrong side of the scan.
--
-- `('__WALLET_LIST__')` is filled by scripts/find_whales.py.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,
        100               AS min_position_usd  -- ignore dust and airdrop spam
),

quote_assets (mint) AS (
    VALUES
        ('So11111111111111111111111111111111111111112'),  -- Wrapped SOL
        ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'), -- USDC
        ('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB')  -- USDT
),

wallets (wallet) AS (
    VALUES
        ('__WALLET_LIST__')
),

-- Single scan. Each trade carries both of its legs as an array.
scan AS (
    SELECT
        t.trader_id AS wallet,
        t.tx_id,
        CAST(ARRAY[
            ROW(t.token_bought_mint_address, 'buy',  t.amount_usd, t.token_bought_amount),
            ROW(t.token_sold_mint_address,   'sell', t.amount_usd, t.token_sold_amount)
        ] AS ARRAY(ROW(mint VARCHAR, side VARCHAR, usd DOUBLE, qty DOUBLE))) AS legs
    FROM dex_solana.trades t
    JOIN wallets w ON w.wallet = t.trader_id
    WHERE t.block_time >= (SELECT lookback_start FROM params)
      AND t.amount_usd > 0
),

legs AS (
    SELECT s.wallet, s.tx_id, l.mint, l.side, l.usd, l.qty
    FROM scan s
    CROSS JOIN UNNEST(s.legs) AS l (mint, side, usd, qty)
    WHERE l.mint NOT IN (SELECT mint FROM quote_assets)
),

positions AS (
    SELECT
        wallet,
        mint,
        SUM(IF(side = 'buy',  usd, 0)) AS usd_in,
        SUM(IF(side = 'sell', usd, 0)) AS usd_out,
        SUM(IF(side = 'buy',  qty, 0)) AS qty_bought,
        SUM(IF(side = 'sell', qty, 0)) AS qty_sold,
        COUNT(DISTINCT tx_id)          AS n_txs
    FROM legs
    GROUP BY wallet, mint
),

-- Scoped by wallet, not by mint: these wallets hold arbitrary tokens.
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

position_pnl AS (
    SELECT
        p.wallet,
        p.usd_in,
        p.usd_out,
        COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)         AS value_now_usd,
        p.usd_out - p.usd_in
            + COALESCE(h.qty_now, 0) * COALESCE(px.price_usd, 0)   AS pnl_usd,
        (p.qty_sold + COALESCE(h.qty_now, 0)) / NULLIF(p.qty_bought, 0) AS qty_accounted_ratio,
        p.n_txs
    FROM positions p
    CROSS JOIN params pr
    LEFT JOIN holdings  h  ON h.wallet = p.wallet AND h.mint = p.mint
    LEFT JOIN price_now px ON px.mint  = p.mint
    WHERE p.usd_in >= pr.min_position_usd
)

SELECT
    wallet,
    ROUND(SUM(pnl_usd))                                        AS net_pnl_all_usd,
    ROUND(SUM(usd_in))                                         AS total_invested_all_usd,
    ROUND(SUM(pnl_usd) / NULLIF(SUM(usd_in), 0), 2)            AS roi_all,
    COUNT(*)                                                   AS n_positions_all,
    COUNT_IF(pnl_usd > 0)                                      AS n_winners,
    COUNT_IF(pnl_usd < 0)                                       AS n_losers,
    ROUND(SUM(IF(pnl_usd > 0, pnl_usd, 0)))                    AS gross_wins_usd,
    ROUND(SUM(IF(pnl_usd < 0, pnl_usd, 0)))                    AS gross_losses_usd,
    ROUND(MIN(pnl_usd))                                        AS worst_position_usd,
    ROUND(SUM(value_now_usd))                                  AS open_value_usd,
    -- recovered under a tenth of cost and the bag is worth nothing: rugged,
    -- or dead enough that the difference does not matter
    COUNT_IF(usd_out + value_now_usd < 0.10 * usd_in)          AS n_total_wipeouts,
    ROUND(SUM(IF(usd_out + value_now_usd < 0.10 * usd_in,
                 usd_in - usd_out - value_now_usd, 0)))        AS wipeout_loss_usd,
    COUNT_IF(qty_accounted_ratio > 1.10)                       AS n_positions_external_inflow,
    -- The honest PnL. Positions whose token count does not reconcile against
    -- DEX buys are dropped rather than the whole wallet being rejected for
    -- owning them: airdrops are universal on Solana, so demanding a wallet
    -- never received a token throws out every active trader. What matters is
    -- whether the profit survives once the unreconciled positions are removed.
    -- (Positions with no buys at all are already gone — usd_in fails the floor.)
    ROUND(SUM(IF(qty_accounted_ratio <= 1.10, pnl_usd, 0)))    AS clean_pnl_usd,
    ROUND(SUM(IF(qty_accounted_ratio <= 1.10, usd_in,  0)))    AS clean_invested_usd,
    ROUND(SUM(IF(qty_accounted_ratio >  1.10, pnl_usd, 0)))    AS inflow_pnl_usd,
    COUNT_IF(qty_accounted_ratio <= 1.10)                      AS n_clean_positions,
    -- "doesn't trade often", measured across everything rather than just the
    -- universe. n_positions_all is the blunt version: a wallet holding 600
    -- names is a churner regardless of what its PnL says. Tx count is summed
    -- per token, so a single transaction touching two tokens counts twice —
    -- fine for a frequency heuristic, not exact.
    SUM(n_txs)                                                 AS n_txs_all,
    ROUND(SUM(n_txs) * 1.0 / COUNT(*), 1)                      AS avg_txs_per_position,
    -- "sized up on good plays", same measure as 06 but over the full book.
    ROUND(MAX(usd_in))                                         AS biggest_position_all_usd,
    ROUND(AVG(IF(pnl_usd > 0, usd_in, NULL)))                  AS avg_winner_size_usd,
    ROUND(AVG(IF(pnl_usd < 0, usd_in, NULL)))                  AS avg_loser_size_usd,
    ROUND(AVG(IF(pnl_usd > 0, usd_in, NULL))
          / NULLIF(AVG(IF(pnl_usd < 0, usd_in, NULL)), 0), 2)  AS conviction_ratio
FROM position_pnl
GROUP BY wallet
ORDER BY net_pnl_all_usd DESC
