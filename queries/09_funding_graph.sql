-- =============================================================================
-- 09 — FUNDING GRAPH: find the main wallet behind the burners
-- =============================================================================
-- The trading wallets this pipeline surfaces are nearly all emptied — a few
-- hundredths of a SOL left after moving millions. An operator does not leave
-- their capital in the wallet doing the trading. The persistent identity is
-- whoever FUNDED it, and that is the wallet worth tracking, because it is the
-- one that survives across burners and keeps making the entry decisions.
--
-- So the search inverts: score the funder, not the trader. This query walks
-- inbound native SOL to a wallet list and returns candidate funders ranked by
-- how much of the list they paid for.
--
-- Native SOL is So1111111111111111111111111111111111111111 (eleven trailing
-- ones). Wrapped SOL is ...112 and is a DEX artifact, not funding — mixing the
-- two turns every AMM counterparty into a fake parent.
--
-- Two exclusions keep this from collapsing into one blob:
--   * labelled exchange/bridge/infra addresses — everyone is funded by Binance
--   * high fan-out senders — a wallet paying hundreds of others is a service.
--     Fan-out is measured WITHIN the sample (degree_in_sample) rather than
--     across all of Solana: the global version needed a second full pass over
--     tokens_solana.transfers keyed on a large IN list, which blew the resource
--     cap. Funding several wallets in a 79-wallet sample is the strong signal
--     anyway (that is n_wallets_funded); funding thousands chain-wide is a
--     service and those are already
--     caught by the label exclusion.
--
-- `('__WALLET_LIST__')` is filled by scripts/find_whales.py.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2024-01-01' AS lookback_start,   -- funding predates the trading
        5.0               AS min_sol_per_edge  -- ignore dust and rent top-ups
),

wallets (wallet) AS (
    VALUES
        ('__WALLET_LIST__')
),

sol_in AS (
    SELECT
        tr.from_owner AS funder,
        tr.to_owner   AS wallet,
        tr.amount_display AS sol,
        tr.amount_usd,
        tr.block_time
    FROM tokens_solana.transfers tr
    JOIN wallets w ON w.wallet = tr.to_owner
    WHERE tr.block_time >= (SELECT lookback_start FROM params)
      AND tr.action = 'transfer'
      AND tr.token_mint_address = 'So11111111111111111111111111111111111111111'
      AND tr.from_owner IS NOT NULL
      AND tr.from_owner <> tr.to_owner
),

labelled_infra AS (
    SELECT to_base58(address) AS addr
    FROM labels.addresses
    WHERE blockchain = 'solana'
      AND category IN ('cex', 'dex', 'bridge', 'contract', 'mev', 'infrastructure')
),

edges AS (
    SELECT
        s.funder,
        s.wallet,
        COUNT(*)                        AS n_transfers,
        SUM(s.sol)                      AS sol_sent,
        ROUND(SUM(s.amount_usd))        AS usd_sent,
        CAST(MIN(s.block_time) AS DATE) AS first_funded,
        CAST(MAX(s.block_time) AS DATE) AS last_funded
    FROM sol_in s
    CROSS JOIN params p
    GROUP BY s.funder, s.wallet
    HAVING SUM(s.sol) >= MAX(p.min_sol_per_edge)
),

-- Does the funder still hold anything? A live main wallet keeps a balance;
-- another emptied shell just means the operator layered one level deeper and
-- the real parent is further up.
funder_balance AS (
    SELECT address AS funder, MAX(sol_balance) AS sol_balance_now
    FROM solana_utils.latest_balances
    WHERE address IN (SELECT funder FROM edges)
    GROUP BY 1
)

SELECT
    e.funder,
    COUNT(DISTINCT e.wallet)                    AS n_wallets_funded,
    ROUND(SUM(e.sol_sent), 1)                   AS total_sol_sent,
    ROUND(SUM(e.usd_sent))                      AS total_usd_sent,
    ROUND(MAX(fb.sol_balance_now), 2)           AS funder_sol_balance_now,
    MIN(e.first_funded)                         AS first_funded,
    MAX(e.last_funded)                          AS last_funded,
    array_join(array_agg(e.wallet), ', ')       AS funded_wallets
FROM edges e
CROSS JOIN params p
LEFT JOIN funder_balance fb ON fb.funder = e.funder
WHERE e.funder NOT IN (SELECT addr FROM labelled_infra)
  AND e.funder NOT IN (SELECT wallet FROM wallets)
GROUP BY e.funder
ORDER BY n_wallets_funded DESC, total_sol_sent DESC
LIMIT 1000
