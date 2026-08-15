-- =============================================================================
-- 07 — WALLET CLUSTERS: find the entity behind a distribution wallet
-- =============================================================================
-- Most wallets that top a naive PnL leaderboard did not buy what they sold.
-- Tokens arrived by transfer, so "bought $0, sold $34.5K" scores as infinite
-- profit. Those wallets are one leg of a multi-wallet operation, and copying
-- them is worthless: by the time they receive tokens the entry already happened
-- somewhere else.
--
-- That flaw is the lead. A transfer edge names the wallet that DID buy.
-- This query walks tokens_solana.transfers around a wallet list and returns the
-- counterparty edges, so the operation can be reassembled and scored as one
-- entity — and so the buying wallet, the one actually worth tracking, is named.
--
-- Inflow edges are the valuable ones: whoever sent the tokens is upstream of
-- the sell. Outflow edges matter too — a wallet that ships bags out before a
-- top is running the same play in reverse.
--
-- `('__WALLET_LIST__')` and `('__MINT_LIST__')` are filled by the runner.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,
        5000              AS min_edge_usd  -- ignore dust and airdrop spam
),

wallets (wallet) AS (
    VALUES
        ('__WALLET_LIST__')
),

universe (mint) AS (
    VALUES
        ('__MINT_LIST__')
),

-- Only real transfers of universe tokens. mintTo/burn are not counterparty
-- evidence, and filtering on the 32 mints first keeps this off a full scan of
-- what is a very large table.
edges AS (
    SELECT
        tr.from_owner,
        tr.to_owner,
        tr.token_mint_address AS mint,
        tr.amount_usd,
        tr.block_time
    FROM tokens_solana.transfers tr
    JOIN universe u ON u.mint = tr.token_mint_address
    WHERE tr.block_time >= (SELECT lookback_start FROM params)
      AND tr.action = 'transfer'
      AND tr.from_owner IS NOT NULL
      AND tr.to_owner IS NOT NULL
      AND tr.from_owner <> tr.to_owner
      AND (tr.to_owner   IN (SELECT wallet FROM wallets)
        OR tr.from_owner IN (SELECT wallet FROM wallets))
),

-- Anything labelled as exchange or infrastructure is not evidence of common
-- ownership — everybody sends to Binance. Dropping these stops the clustering
-- from collapsing every wallet into one giant blob through a CEX hot wallet.
labelled_infra AS (
    SELECT to_base58(address) AS addr
    FROM labels.addresses
    WHERE blockchain = 'solana'
      AND category IN ('cex', 'dex', 'bridge', 'contract', 'mev', 'infrastructure')
),

-- A wallet that transacts with hundreds of counterparties is a service, not a
-- sibling. Degree is computed before filtering so the cutoff is meaningful.
counterparty_degree AS (
    SELECT addr, COUNT(DISTINCT peer) AS degree
    FROM (
        SELECT from_owner AS addr, to_owner   AS peer FROM edges
        UNION ALL
        SELECT to_owner   AS addr, from_owner AS peer FROM edges
    ) x
    GROUP BY addr
),

directed AS (
    SELECT
        CASE WHEN e.to_owner IN (SELECT wallet FROM wallets) THEN e.to_owner ELSE e.from_owner END AS wallet,
        CASE WHEN e.to_owner IN (SELECT wallet FROM wallets) THEN e.from_owner ELSE e.to_owner END AS counterparty,
        CASE WHEN e.to_owner IN (SELECT wallet FROM wallets) THEN 'inflow' ELSE 'outflow' END      AS direction,
        e.mint,
        e.amount_usd,
        e.block_time
    FROM edges e
)

SELECT
    d.wallet,
    d.counterparty,
    d.direction,
    COUNT(*)                          AS n_transfers,
    COUNT(DISTINCT d.mint)            AS n_mints,
    ROUND(SUM(d.amount_usd))          AS total_usd,
    cd.degree                         AS counterparty_degree,
    CAST(MIN(d.block_time) AS DATE)   AS first_transfer,
    CAST(MAX(d.block_time) AS DATE)   AS last_transfer
FROM directed d
CROSS JOIN params p
LEFT JOIN counterparty_degree cd ON cd.addr = d.counterparty
WHERE d.counterparty NOT IN (SELECT addr FROM labelled_infra)
  AND d.counterparty NOT IN (SELECT wallet FROM wallets)
GROUP BY d.wallet, d.counterparty, d.direction, cd.degree
HAVING SUM(d.amount_usd) >= MAX(p.min_edge_usd)
ORDER BY total_usd DESC
LIMIT 2000
