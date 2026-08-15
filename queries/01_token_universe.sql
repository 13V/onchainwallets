-- =============================================================================
-- 01 — TOKEN UNIVERSE: "OG" Solana memecoins that actually reached $100M+ mcap
-- =============================================================================
-- Run this FIRST. It builds the list of tokens whose holders we care about.
--
-- Why derive the list instead of hardcoding mint addresses:
--   Solana token symbols are not unique. There are dozens of mints called
--   "PNUT", "MOODENG", "TROLL" etc. Filtering by symbol will pull in fakes and
--   silently poison every downstream PnL number. So we select on measured
--   behaviour and read the symbols off the result for sanity only.
--
-- PERFORMANCE: this deliberately never touches dex_solana.trades. An earlier
-- version derived volume and price from the raw trade legs and hit the 30
-- minute execution timeout — that table holds billions of Solana rows and
-- scanning it twice to rank a few dozen tokens is the wrong tool. prices.day
-- carries one row per token per day with a volume column already attached, and
-- solana_utils.latest_balances gives supply from an indexed lookup instead of
-- replaying every mint and burn event. Same answer, small fraction of the scan.
--
-- Expected output: a few dozen rows. TROLL / PNUT / PENGU / MOODENG / GOAT /
-- FWOG / CHILLGUY / POPCAT / WIF / BONK / Fartcoin-class tokens should appear,
-- mixed in with LSTs and infra tokens that also clear $100M — the runner script
-- strips those by symbol, or drop them by eye for a manual run.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,
        100e6             AS min_peak_mcap_usd,  -- "went to 100M"
        90                AS min_active_days     -- not a 3-day pump and dump
),

-- prices.day is a hybrid feed: coinpaprika for the ~2k majors, DEX-derived
-- prices for the long tail. Every token we are after is in here.
--
-- NOTE: the `volume` column is NULL for every Solana row, so there is no volume
-- gate to apply — an earlier version filtered on SUM(volume) and returned zero
-- rows. Liveness comes from the number of priced days instead, and size comes
-- from market cap, which is the thing actually being asked about anyway.
daily AS (
    SELECT contract_address, symbol, timestamp, price
    FROM prices.day
    WHERE blockchain = 'solana'
      AND timestamp >= (SELECT lookback_start FROM params)
      AND price > 0
),

candidates AS (
    SELECT
        d.contract_address,
        MAX(d.symbol)    AS symbol,
        COUNT(*)         AS n_active_days,
        MIN(d.timestamp) AS first_priced_day,
        MAX(d.timestamp) AS last_priced_day
    FROM daily d
    CROSS JOIN params p
    GROUP BY d.contract_address
    HAVING COUNT(*) >= MAX(p.min_active_days)
),

-- Peak daily close. These are exchange-aggregated for the majors and outlier
-- filtered for the DEX-derived tail, so a plain MAX is safe enough here; the
-- mcap threshold does the real work of throwing out junk.
peak AS (
    SELECT d.contract_address, MAX(d.price) AS peak_price_usd
    FROM daily d
    WHERE d.contract_address IN (SELECT contract_address FROM candidates)
    GROUP BY d.contract_address
),

-- Circulating supply as the sum of all current balances. Cheaper than replaying
-- mintTo/burn from tokens_solana.transfers, and this table is indexed on mint.
-- Note this is CURRENT supply against a PAST peak price, which is exact for the
-- fixed-supply 1B memecoins we are after and approximate for anything that has
-- minted or burned since its high.
supply AS (
    SELECT
        token_mint_address                 AS mint,
        CAST(SUM(token_balance) AS DOUBLE) AS circulating_supply
    FROM solana_utils.latest_balances
    WHERE token_mint_address IN (SELECT to_base58(contract_address) FROM candidates)
      AND token_balance > 0
    GROUP BY 1
)

SELECT
    c.symbol,
    to_base58(c.contract_address)                     AS mint,
    ROUND(s.circulating_supply)                       AS circulating_supply,
    pk.peak_price_usd,
    ROUND(s.circulating_supply * pk.peak_price_usd)   AS peak_mcap_usd,
    c.n_active_days,
    CAST(c.first_priced_day AS DATE)                  AS first_priced_day,
    CAST(c.last_priced_day  AS DATE)                  AS last_priced_day,
    date_diff('day', c.first_priced_day, CAST(now() AS TIMESTAMP)) AS age_days
FROM candidates c
JOIN peak   pk ON pk.contract_address = c.contract_address
JOIN supply s  ON s.mint = to_base58(c.contract_address)
CROSS JOIN params p
WHERE s.circulating_supply * pk.peak_price_usd >= p.min_peak_mcap_usd
ORDER BY peak_mcap_usd DESC
