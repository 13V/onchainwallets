-- =============================================================================
-- 01 — TOKEN UNIVERSE: "OG" Solana memecoins that actually reached $100M+ mcap
-- =============================================================================
-- Run this FIRST. It builds the list of tokens whose holders we care about.
--
-- Why derive the list instead of hardcoding mint addresses:
--   Solana token symbols are not unique. There are dozens of mints called
--   "PNUT", "MOODENG", "TROLL" etc. Filtering by symbol will pull in fakes and
--   silently poison every downstream PnL number. So we select purely on
--   measured behaviour (real volume, real trader counts, real peak market cap)
--   and read the symbols off the result for sanity only.
--
-- Peak market cap = circulating supply (mintTo - burn) x peak daily price.
--
-- Expected output: a few dozen rows. TROLL / PNUT / PENGU / MOODENG / GOAT /
-- FWOG / CHILLGUY / POPCAT / WIF / BONK / Fartcoin-class tokens should appear.
-- Copy the `mint` column of the rows you want into the `universe` CTE of 02.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,          -- how far back to scan
        100e6             AS min_peak_mcap_usd,       -- "went to 100M"
        75e6              AS min_lifetime_volume_usd, -- real liquidity, not a wash-traded ghost
        90                AS min_active_days,         -- not a 3-day pump and dump
        20000             AS min_distinct_traders,    -- genuinely widely held
        50000             AS min_day_volume_for_price -- ignore thin days when picking peak price
),

-- Quote assets. A trade is "token X vs quote" — X is what we want to price.
-- Only mints that are unambiguous are listed. Add LSTs (mSOL, jitoSOL, bSOL)
-- and other stables here if you see them show up as "memecoins" in the output;
-- look their mints up in tokens_solana.fungible first rather than trusting a symbol.
quote_assets (mint) AS (
    VALUES
        ('So11111111111111111111111111111111111111112'),  -- Wrapped SOL
        ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'), -- USDC
        ('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB')  -- USDT
),

-- One row per trade leg, reduced to (non-quote token, its unit price, size).
-- Token<->token trades with no quote leg are dropped; they are a rounding error
-- in volume terms and would need a price oracle to value anyway.
legs AS (
    SELECT
        t.block_date,
        CASE
            WHEN t.token_sold_mint_address   IN (SELECT mint FROM quote_assets) THEN t.token_bought_mint_address
            WHEN t.token_bought_mint_address IN (SELECT mint FROM quote_assets) THEN t.token_sold_mint_address
        END AS mint,
        CASE
            WHEN t.token_sold_mint_address   IN (SELECT mint FROM quote_assets) THEN t.amount_usd / NULLIF(t.token_bought_amount, 0)
            WHEN t.token_bought_mint_address IN (SELECT mint FROM quote_assets) THEN t.amount_usd / NULLIF(t.token_sold_amount, 0)
        END AS unit_price_usd,
        t.amount_usd,
        t.trader_id
    FROM dex_solana.trades t
    WHERE t.block_time >= (SELECT lookback_start FROM params)
      -- drop dust and drop absurd prints that corrupt medians
      AND t.amount_usd BETWEEN 1 AND 50e6
),

-- First pass: cheap volume/liveness screen so the expensive joins below only
-- ever touch a few hundred mints instead of every token on Solana.
candidates AS (
    SELECT
        l.mint,
        SUM(l.amount_usd)              AS lifetime_volume_usd,
        COUNT(*)                       AS n_trade_legs,
        COUNT(DISTINCT l.trader_id)    AS n_distinct_traders,
        COUNT(DISTINCT l.block_date)   AS n_active_days,
        MIN(l.block_date)              AS first_trade_date,
        MAX(l.block_date)              AS last_trade_date
    FROM legs l
    CROSS JOIN params p
    WHERE l.mint IS NOT NULL
    GROUP BY l.mint
    HAVING SUM(l.amount_usd)            >= MAX(p.min_lifetime_volume_usd)
       AND COUNT(DISTINCT l.block_date) >= MAX(p.min_active_days)
       AND COUNT(DISTINCT l.trader_id)  >= MAX(p.min_distinct_traders)
),

-- Peak price from on-chain DEX prints, ignoring illiquid days.
-- Median-of-day is used rather than max-of-day so one fat-finger or sandwich
-- print cannot manufacture a fake all-time high.
dex_daily_price AS (
    SELECT
        l.mint,
        l.block_date,
        approx_percentile(l.unit_price_usd, 0.5) AS median_price_usd,
        SUM(l.amount_usd)                        AS day_volume_usd
    FROM legs l
    WHERE l.mint IN (SELECT mint FROM candidates)
      AND l.unit_price_usd > 0
    GROUP BY l.mint, l.block_date
),

dex_peak_price AS (
    SELECT d.mint, MAX(d.median_price_usd) AS peak_price_dex
    FROM dex_daily_price d
    CROSS JOIN params p
    WHERE d.day_volume_usd >= p.min_day_volume_for_price
    GROUP BY d.mint
),

-- Dune's own curated daily prices, where coverage exists. Preferred when present.
oracle_peak_price AS (
    SELECT to_base58(pr.contract_address) AS mint, MAX(pr.price) AS peak_price_oracle
    FROM prices.day pr
    WHERE pr.blockchain = 'solana'
      AND pr.contract_address IN (SELECT from_base58(mint) FROM candidates)
    GROUP BY 1
),

-- Circulating supply straight from mint/burn events.
-- NOTE: intentionally unbounded in time — a 2022 token's mintTo event predates
-- the lookback window and would otherwise be missed, giving supply = 0.
token_supply AS (
    SELECT
        tr.token_mint_address AS mint,
        SUM(
            CASE tr.action
                WHEN 'mintTo' THEN  tr.amount_display
                WHEN 'burn'   THEN -tr.amount_display
                ELSE 0
            END
        ) AS circulating_supply
    FROM tokens_solana.transfers tr
    WHERE tr.action IN ('mintTo', 'burn')
      AND tr.token_mint_address IN (SELECT mint FROM candidates)
    GROUP BY 1
)

SELECT
    f.symbol,
    f.name,
    c.mint,
    ROUND(s.circulating_supply)                                              AS circulating_supply,
    COALESCE(o.peak_price_oracle, d.peak_price_dex)                          AS peak_price_usd,
    ROUND(s.circulating_supply * COALESCE(o.peak_price_oracle, d.peak_price_dex)) AS peak_mcap_usd,
    ROUND(c.lifetime_volume_usd)                                             AS lifetime_volume_usd,
    c.n_distinct_traders,
    c.n_active_days,
    c.first_trade_date,
    c.last_trade_date,
    date_diff('day', c.first_trade_date, current_date)                       AS age_days,
    CASE WHEN o.peak_price_oracle IS NOT NULL THEN 'prices.day' ELSE 'dex-derived' END AS price_source
FROM candidates c
JOIN token_supply s        ON s.mint = c.mint
LEFT JOIN dex_peak_price d ON d.mint = c.mint
LEFT JOIN oracle_peak_price o ON o.mint = c.mint
LEFT JOIN tokens_solana.fungible f ON f.token_mint_address = c.mint
CROSS JOIN params p
WHERE s.circulating_supply > 0
  AND s.circulating_supply * COALESCE(o.peak_price_oracle, d.peak_price_dex) >= p.min_peak_mcap_usd
ORDER BY peak_mcap_usd DESC
