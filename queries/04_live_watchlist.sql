-- =============================================================================
-- 04 — LIVE WATCHLIST: what the tracked wallets are accumulating right now
-- =============================================================================
-- Once 02 + 03 have produced a vetted wallet list, this is the query you keep.
-- It shows fresh accumulation across the tracked set, weighted by how many
-- independent wallets are buying the same thing.
--
-- The `n_wallets_buying` column is the signal. One tracked wallet buying a token
-- is noise. Four of them buying the same token inside a week, none of them
-- selling, is the pattern this whole exercise exists to surface.
--
-- Set up as a Dune query alert (bell icon -> "Alert when new rows appear") so
-- consensus buys reach you without checking the dashboard.
--
-- LATENCY WARNING: Dune's Solana tables land in batches, typically tens of
-- minutes to a few hours behind the chain. This finds accumulation, it does not
-- front-run it. For same-block copy trading feed the wallet list into a
-- streaming provider (Helius/Yellowstone webhooks) instead.
-- =============================================================================

WITH params AS (
    SELECT
        30    AS lookback_days,       -- window for "recent" buying
        1000  AS min_buy_usd,         -- ignore dust and test transactions
        1     AS min_wallets_buying   -- raise to 2-3 to see consensus only
),

quote_assets (mint) AS (
    VALUES
        ('So11111111111111111111111111111111111111112'),
        ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'),
        ('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB')
),

-- ####################### EDIT ME #######################
-- Paste the vetted wallets from 02 / 03 here.
tracked_wallets (wallet) AS (
    VALUES
        ('PASTE_WALLET_FROM_QUERY_02_HERE_1'),
        ('PASTE_WALLET_FROM_QUERY_02_HERE_2'),
        ('PASTE_WALLET_FROM_QUERY_02_HERE_3')
),
-- #######################################################

recent_legs AS (
    SELECT
        t.trader_id                 AS wallet,
        t.block_time,
        t.tx_id,
        t.token_bought_mint_address AS mint,
        'buy'                       AS side,
        t.amount_usd                AS usd
    FROM dex_solana.trades t
    JOIN tracked_wallets w ON w.wallet = t.trader_id
    WHERE t.block_time >= CAST(now() AS TIMESTAMP) - INTERVAL '90' DAY
      AND t.amount_usd > 0
      AND t.token_bought_mint_address NOT IN (SELECT mint FROM quote_assets)

    UNION ALL

    SELECT
        t.trader_id,
        t.block_time,
        t.tx_id,
        t.token_sold_mint_address,
        'sell',
        t.amount_usd
    FROM dex_solana.trades t
    JOIN tracked_wallets w ON w.wallet = t.trader_id
    WHERE t.block_time >= CAST(now() AS TIMESTAMP) - INTERVAL '90' DAY
      AND t.amount_usd > 0
      AND t.token_sold_mint_address NOT IN (SELECT mint FROM quote_assets)
),

-- Buying inside the alert window.
buys AS (
    SELECT
        r.mint,
        COUNT(DISTINCT r.wallet)  AS n_wallets_buying,
        SUM(r.usd)                AS bought_usd,
        MIN(r.block_time)         AS first_buy,
        MAX(r.block_time)         AS last_buy,
        array_join(array_agg(DISTINCT r.wallet), ', ') AS buyers
    FROM recent_legs r
    CROSS JOIN params p
    WHERE r.side = 'buy'
      AND r.block_time >= CAST(now() AS TIMESTAMP) - (p.lookback_days * INTERVAL '1' DAY)
      AND r.usd >= p.min_buy_usd
    GROUP BY r.mint
),

-- Selling over the full 90 days. A token the tracked set is quietly distributing
-- into is the opposite of a signal, so it needs to be visible next to the buys.
sells AS (
    SELECT
        mint,
        COUNT(DISTINCT wallet) AS n_wallets_selling,
        SUM(usd)               AS sold_usd
    FROM recent_legs
    WHERE side = 'sell'
    GROUP BY mint
),

-- Token age. Deliberately unbounded in time: bounding this to the 30-day
-- window would floor every token's age at 30 days and hide exactly the thing
-- it exists to reveal — a brand new launch sneaking into the feed.
token_first_seen AS (
    SELECT t.token_bought_mint_address AS mint, MIN(t.block_date) AS first_seen_date
    FROM dex_solana.trades t
    WHERE t.token_bought_mint_address IN (SELECT mint FROM buys)
    GROUP BY 1
),

-- Is the wider market in this too, or are the tracked wallets alone in it?
token_market_30d AS (
    SELECT
        t.token_bought_mint_address AS mint,
        SUM(t.amount_usd)           AS market_volume_30d_usd,
        COUNT(DISTINCT t.trader_id) AS market_traders_30d
    FROM dex_solana.trades t
    WHERE t.token_bought_mint_address IN (SELECT mint FROM buys)
      AND t.block_time >= CAST(now() AS TIMESTAMP) - INTERVAL '30' DAY
      AND t.amount_usd > 0
    GROUP BY 1
),

-- Do they actually still hold what they bought, or was it already round-tripped?
current_holdings AS (
    SELECT
        lb.token_mint_address              AS mint,
        COUNT(DISTINCT lb.token_balance_owner) AS n_wallets_holding,
        CAST(SUM(lb.token_balance) AS DOUBLE)  AS qty_held
    FROM solana_utils.latest_balances lb
    JOIN tracked_wallets w ON w.wallet = lb.token_balance_owner
    WHERE lb.token_mint_address IN (SELECT mint FROM buys)
      AND lb.token_balance > 0
    GROUP BY 1
),

price_now AS (
    SELECT to_base58(contract_address) AS mint, MAX(price) AS price_usd
    FROM prices.latest
    WHERE blockchain = 'solana'
      AND contract_address IN (SELECT from_base58(mint) FROM buys)
    GROUP BY 1
)

SELECT
    COALESCE(f.symbol, '?')                              AS symbol,
    b.mint,
    b.n_wallets_buying,
    ROUND(b.bought_usd)                                  AS bought_usd,
    COALESCE(s.n_wallets_selling, 0)                     AS n_wallets_selling,
    ROUND(COALESCE(s.sold_usd, 0))                       AS sold_usd_90d,
    COALESCE(ch.n_wallets_holding, 0)                    AS n_wallets_still_holding,
    ROUND(COALESCE(ch.qty_held, 0) * COALESCE(px.price_usd, 0)) AS tracked_position_value_usd,
    fs.first_seen_date,
    date_diff('day', fs.first_seen_date, current_date)   AS token_age_days,
    ROUND(tm.market_volume_30d_usd)                      AS market_volume_30d_usd,
    tm.market_traders_30d,
    b.first_buy,
    b.last_buy,
    b.buyers
FROM buys b
CROSS JOIN params p
LEFT JOIN sells s             ON s.mint  = b.mint
LEFT JOIN token_first_seen fs ON fs.mint = b.mint
LEFT JOIN token_market_30d tm ON tm.mint = b.mint
LEFT JOIN current_holdings ch ON ch.mint = b.mint
LEFT JOIN price_now px        ON px.mint = b.mint
LEFT JOIN tokens_solana.fungible f ON f.token_mint_address = b.mint
WHERE b.n_wallets_buying >= p.min_wallets_buying
ORDER BY b.n_wallets_buying DESC, b.bought_usd DESC
