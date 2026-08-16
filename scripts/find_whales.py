#!/usr/bin/env python3
"""Run the Dune whale-wallet pipeline end to end.

Two phases:

  tokens  Runs 01_token_universe.sql, classifies memecoins out of the result.
  whales  Injects those mints into 06_whale_wallets.sql, writes the shortlist.
  verify  Re-prices the shortlist across every token it traded (the gate).
  regate  Re-applies thresholds to the last verify output. Costs nothing.
  all     tokens -> whales -> verify.

The wallet list lands in out/wallets.txt (one address per line) plus a CSV with
the supporting numbers.

Auth: set DUNE_API_KEY in the environment, or pass --api-key. The key is never
written to disk and out/ is gitignored.

Creating queries via the API needs a Dune Analyst plan or higher. On a lower
plan, save the SQL as queries in the Dune UI and pass --universe-query-id /
--whale-query-id so the script executes those instead of creating its own.

Two account limits worth knowing, both hit in practice:
  * Private queries are capped (30 on lower plans). On hitting it this falls
    back to creating the query PUBLIC and says so — a public query exposes the
    method and the wallet list, so archive unused queries instead if that
    matters.
  * A query created through the API can land on Dune's deprecated query engine,
    which then refuses to execute. Fix is to open it in the Dune UI, switch the
    engine to DuneSQL, save, and pass its id via --universe-query-id /
    --whale-query-id. Queries created in the UI never have this problem.

Stdlib only — no pip install needed.
"""

import argparse
import csv
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.dune.com/api/v1"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUERY_DIR = os.path.join(ROOT, "queries")
OUT_DIR = os.path.join(ROOT, "out")
STATE_FILE = os.path.join(OUT_DIR, "query_ids.json")

# Classifying memecoins out of a market-cap ranking. At a $20M floor the raw
# list runs to several hundred tokens, too many to eyeball, and symbol
# denylists alone proved leaky — the first attempt let PUMP, ME, IO, GRASS,
# LAYER and SONIC through into the top 20.
#
# Launchpad mint suffixes are the strongest cheap signal available: a mint
# ending in "pump" came off pump.fun and "bonk" off letsbonk.fun, and those are
# memecoins essentially by construction.
LAUNCHPAD_SUFFIXES = ("pump", "bonk", "moon")

# Symbol fragments that mark a token as something other than a memecoin.
# Matched case-insensitively as substrings, so this also catches the LST family
# (jitoSOL, bSOL, mSOL, ...) and the stable family without listing each one.
NON_MEME_FRAGMENTS = (
    "USD", "SOL", "BTC", "ETH", "EUR", "DAI",
)

# Infra, DeFi, L2, AI-infra and governance tokens that clear the cap but are not
# what is being searched for. Exact symbol matches.
NON_MEME_SYMBOLS = {
    "JUP", "JTO", "PYTH", "RAY", "ORCA", "W", "DRIFT", "KMNO", "CLOUD", "MPLX",
    "RENDER", "RNDR", "HNT", "MOBILE", "IOT", "SHDW", "METAPLEX", "PUMP", "ME",
    "IO", "GRASS", "LAYER", "SONIC", "NEON", "SAROS", "ZEUS", "DBR", "ZBCN",
    "TNSR", "PRCL", "NOS", "FIDA", "SRM", "MNDE", "ATLAS", "POLIS", "AURY",
    "GMT", "GST", "MAPS", "OXY", "STEP", "SBR", "PORT", "LARIX", "SLND",
    "HUMA", "VIRTUAL", "SNS", "CRP", "SC", "HXRO", "ACS", "PHY", "MET", "2Z",
    "JLP", "USX", "CASH", "FRAG", "ONYC", "CROWN", "OTK", "HXD", "CYS",
}


def is_memecoin(symbol, mint):
    """Best-effort classifier. Launchpad mints win outright; otherwise fall back
    to symbol screening. Errs toward inclusion — a stray infra token in the
    universe dilutes the profile, but dropping a real memecoin loses wallets."""
    if mint and mint.lower().endswith(LAUNCHPAD_SUFFIXES):
        return True
    if not symbol:
        return True
    sym = symbol.upper().lstrip("$")
    if sym in NON_MEME_SYMBOLS:
        return False
    if any(frag in sym for frag in NON_MEME_FRAGMENTS):
        return False
    # Tokenised equities are published as TSLAx / AMZNx / CRCLx / MSTRx.
    if len(sym) >= 4 and symbol.endswith("x") and symbol[:-1].isupper():
        return False
    return True


class DuneError(RuntimeError):
    pass


def _ssl_context():
    """Trust the agent proxy's CA bundle when one is configured."""
    for candidate in (
        os.environ.get("SSL_CERT_FILE"),
        os.environ.get("REQUESTS_CA_BUNDLE"),
        "/root/.ccr/ca-bundle.crt",
    ):
        if candidate and os.path.exists(candidate):
            return ssl.create_default_context(cafile=candidate)
    return ssl.create_default_context()


def _request(method, path, key, body=None, timeout=120):
    url = f"{API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-DUNE-API-KEY", key)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:600]
        if exc.code in (402, 403):
            detail += (
                "\n\nIf this is the create-query call, your plan does not allow it. "
                "Save the SQL as a query in the Dune UI and rerun with "
                "--universe-query-id / --whale-query-id."
            )
        raise DuneError(f"{method} {path} -> HTTP {exc.code}: {detail}") from None
    except urllib.error.URLError as exc:
        raise DuneError(f"{method} {path} -> {exc.reason}") from None


def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(STATE_FILE, "w") as fh:
        json.dump(state, fh, indent=2)


def ensure_query(key, slot, name, sql, explicit_id=None, args_public=False):
    """Reuse a saved query when we can; only create one the first time.

    Without this every run would litter the account with near-identical queries.
    """
    if explicit_id:
        _request("PATCH", f"/query/{explicit_id}", key, {"query_sql": sql})
        return int(explicit_id)

    state = load_state()
    query_id = state.get(slot)
    if query_id:
        try:
            _request("PATCH", f"/query/{query_id}", key, {"query_sql": sql})
            return int(query_id)
        except DuneError as exc:
            print(f"  ! could not update saved query {query_id} ({exc}); creating a new one",
                  file=sys.stderr)

    body = {"name": name, "description": "Generated by scripts/find_whales.py",
            "query_sql": sql, "is_private": not args_public}
    try:
        created = _request("POST", "/query", key, body)
    except DuneError as exc:
        # Free plans cap private queries (30). Public queries are unlimited, so
        # fall back rather than dead-ending — the user is told, because a public
        # query exposes both the method and the wallet list it returns.
        if "private queries" not in str(exc):
            raise
        print("  ! private-query limit reached; creating this one PUBLIC instead.",
              file=sys.stderr)
        print("  ! archive unused queries in the Dune UI to keep them private.",
              file=sys.stderr)
        body["is_private"] = False
        created = _request("POST", "/query", key, body)
    query_id = created["query_id"]
    state[slot] = query_id
    save_state(state)
    print(f"  created query {query_id} (https://dune.com/queries/{query_id})")
    return int(query_id)


def run_query(key, query_id, performance="medium", poll=15, timeout=2700):
    execution_id = _request(
        "POST", f"/query/{query_id}/execute", key, {"performance": performance}
    )["execution_id"]
    print(f"  execution {execution_id} started ({performance} tier)")

    deadline = time.time() + timeout
    last_state = None
    while time.time() < deadline:
        status = _request("GET", f"/execution/{execution_id}/status", key)
        state = status.get("state")
        if state != last_state:
            print(f"  {state}")
            last_state = state
        if state == "QUERY_STATE_COMPLETED":
            return execution_id
        if state in ("QUERY_STATE_FAILED", "QUERY_STATE_CANCELLED", "QUERY_STATE_EXPIRED"):
            raise DuneError(
                f"execution {execution_id} ended in {state}: "
                f"{status.get('error') or status}"
            )
        time.sleep(poll)
    raise DuneError(f"execution {execution_id} still running after {timeout}s")


def fetch_rows(key, execution_id, page=5000):
    rows, offset = [], 0
    while True:
        payload = _request(
            "GET", f"/execution/{execution_id}/results?limit={page}&offset={offset}", key
        )
        batch = payload.get("result", {}).get("rows", [])
        rows.extend(batch)
        if len(batch) < page:
            return rows
        offset += page


def write_csv(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not rows:
        open(path, "w").close()
        return
    with open(path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def read_sql(filename):
    with open(os.path.join(QUERY_DIR, filename)) as fh:
        return fh.read()


def load_universe_file(path):
    """Read a curated mint list: one mint per line, '#' starts a comment."""
    tokens = []
    with open(path) as fh:
        for line in fh:
            body, _, comment = line.partition("#")
            mint = body.strip()
            if mint:
                tokens.append({"mint": mint, "symbol": comment.split()[0] if comment.split() else None})
    return tokens


def phase_tokens(args, key):
    print("[1/2] token universe")
    sql = read_sql("01_token_universe.sql")
    if args.lookback:
        sql = sql.replace("DATE '2024-01-01' AS lookback_start",
                          f"DATE '{args.lookback}' AS lookback_start")
    query_id = ensure_query(key, "universe", "OG Solana memecoin universe (auto)",
                            sql, args.universe_query_id)
    rows = fetch_rows(key, run_query(key, query_id, args.performance))
    write_csv(os.path.join(OUT_DIR, "tokens.csv"), rows)
    print(f"  {len(rows)} tokens cleared the market-cap screen -> out/tokens.csv")

    kept = [r for r in rows if is_memecoin(r.get("symbol"), r.get("mint"))]
    dropped = [r for r in rows if r not in kept]
    if args.top_tokens:
        kept = kept[: args.top_tokens]

    print(f"  {len(dropped)} classified as non-memecoin, {len(kept)} kept")
    print(f"\n  sample of what was dropped: "
          f"{', '.join((r.get('symbol') or '?') for r in dropped[:20])}")
    print(f"\n  top of the kept universe:\n")
    for row in kept[:30]:
        mcap = row.get("peak_mcap_usd") or 0
        print(f"    {(row.get('symbol') or '?'):>14}  ${mcap/1e6:>9,.1f}M  {row.get('mint')}")

    with open(os.path.join(OUT_DIR, "universe_mints.json"), "w") as fh:
        json.dump([{"symbol": r.get("symbol"), "mint": r.get("mint")} for r in kept], fh, indent=2)
    return kept


def phase_whales(args, key, tokens):
    print("\n[2/2] whale wallets")
    if not tokens:
        raise DuneError("no tokens in the universe — nothing to search against")

    mint_list = ",\n".join(f"        ('{t['mint']}')" for t in tokens)
    # Compare against the template rather than scanning for the placeholder
    # string, which also appears in that file's header comment.
    template = read_sql("06_whale_wallets.sql")
    sql = template.replace("        ('__MINT_LIST__')", mint_list)
    if sql == template:
        raise DuneError("mint placeholder row not found in 06_whale_wallets.sql")

    replacements = {
        "min_position_usd": args.min_position,
        "min_invested_usd": args.min_invested,
        "min_total_pnl_usd": args.min_pnl,
        "min_pnl_excluding_best_usd": args.min_pnl_excluding_best,
        "min_median_hold_days": args.min_hold_days,
    }
    for name, value in replacements.items():
        if value is None:
            continue
        # Keeps the trailing inline comment on the param line intact.
        sql, count = re.subn(rf"^(\s*)\S+(\s+AS {name}\b.*)$",
                             rf"\g<1>{value}\g<2>", sql, count=1, flags=re.M)
        if count != 1:
            raise DuneError(f"could not override {name} in 06_whale_wallets.sql")
    if args.lookback:
        sql = sql.replace("DATE '2024-01-01' AS lookback_start",
                          f"DATE '{args.lookback}' AS lookback_start")

    if args.dry_run:
        print(sql)
        return []

    query_id = ensure_query(key, "whales", "Solana memecoin whale wallets (auto)",
                            sql, args.whale_query_id)
    rows = fetch_rows(key, run_query(key, query_id, args.performance))

    write_csv(os.path.join(OUT_DIR, "whale_wallets.csv"), rows)
    with open(os.path.join(OUT_DIR, "wallets.txt"), "w") as fh:
        for row in rows:
            fh.write(f"{row['wallet']}\n")

    print(f"\n  {len(rows)} wallets -> out/whale_wallets.csv, out/wallets.txt")
    if rows:
        print(f"\n  {'wallet':<46}{'pnl':>14}{'excl. best':>14}{'wins':>7}{'hold d':>8}")
        for row in rows[:25]:
            print(f"  {row['wallet']:<46}"
                  f"{(row.get('total_pnl_usd') or 0):>14,.0f}"
                  f"{(row.get('pnl_excluding_best_usd') or 0):>14,.0f}"
                  f"{str(row.get('n_profitable_positions')) + '/' + str(row.get('n_positions')):>7}"
                  f"{(row.get('median_hold_days') or 0):>8,.0f}")
    return rows


def score(args, row):
    """Apply the gates to one merged row. Pure function of the stored numbers,
    so thresholds can be retuned offline without re-executing anything."""
    net = float(row.get("clean_pnl_usd") or 0)
    n_clean = int(row.get("n_clean_positions") or 0)
    sold_unbought = float(row.get("sold_without_buying_usd") or 0)
    unbought_share = sold_unbought / max(abs(net), 1.0)
    excl_best = float(row.get("clean_pnl_excluding_best_usd") or 0)
    n_pos = int(row.get("n_positions_all") or 0)
    conviction = float(row.get("conviction_ratio") or 0)
    biggest = float(row.get("biggest_position_all_usd") or 0)
    min_net = args.min_net_pnl_all if args.min_net_pnl_all is not None else 0
    if not row.get("n_positions_all"):
        return "no data"
    if net < min_net:
        return "REJECT: negative PnL once unreconciled positions removed"
    if n_clean < args.min_clean_positions:
        return "REJECT: too few reconciled positions"
    if unbought_share > args.max_unbought_share:
        return "REJECT: sells tokens it never bought"
    if args.min_excl_best_all is not None and excl_best < args.min_excl_best_all:
        return "REJECT: one trade carries all the PnL"
    if n_pos > args.max_positions_all:
        return "REJECT: trades too often"
    if biggest < args.min_biggest_position:
        return "REJECT: never sized up"
    if conviction < args.min_conviction:
        return "REJECT: size went into losers"
    # Mechanical sizing and round-the-clock activity are the two bot signatures
    # that practitioners report most; both are cheap to measure here.
    size_var = float(row.get("size_variation") or 999)
    if size_var < args.min_size_variation:
        return "REJECT: mechanical position sizing (bot)"
    if int(row.get("active_hours_of_day") or 0) >= args.max_active_hours:
        return "REJECT: active around the clock (bot)"
    return "pass"


def phase_regate(args):
    """Re-apply thresholds to the last verify output. Costs nothing."""
    path = os.path.join(OUT_DIR, "verified_wallets.csv")
    with open(path) as fh:
        rows = list(csv.DictReader(fh))
    for row in rows:
        row["verdict"] = score(args, row)
    rows.sort(key=lambda r: -float(r.get("clean_pnl_usd") or 0))
    passed = [r for r in rows if r["verdict"] == "pass"]
    write_csv(path, rows)
    with open(os.path.join(OUT_DIR, "wallets.txt"), "w") as fh:
        for row in passed:
            fh.write(f"{row['wallet']}\n")
    counts = {}
    for row in rows:
        counts[row["verdict"]] = counts.get(row["verdict"], 0) + 1
    print(f"re-gated {len(rows)} wallets offline (no credits spent)")
    for verdict, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {n:>4}  {verdict}")
    return passed


def phase_verify(args, key, shortlist):
    """Re-price the shortlist across every token they traded, rugs included.

    06 scores the universe tokens only, which flatters anyone who won on a
    major while bleeding out everywhere else. Nothing leaves this script
    without clearing this gate.
    """
    print("\n[3/3] all-token PnL (the gate)")
    if not shortlist:
        print("  nothing to verify")
        return []

    wallets = [r["wallet"] for r in shortlist]
    template = read_sql("08_all_token_pnl.sql")
    sql = template.replace("        ('__WALLET_LIST__')",
                           ",\n".join(f"        ('{w}')" for w in wallets))
    if sql == template:
        raise DuneError("wallet placeholder row not found in 08_all_token_pnl.sql")
    if args.lookback:
        sql = sql.replace("DATE '2024-01-01' AS lookback_start",
                          f"DATE '{args.lookback}' AS lookback_start")

    query_id = ensure_query(key, "verify", "All-token PnL gate (auto)", sql)
    verdicts = {r["wallet"]: r for r in fetch_rows(key, run_query(key, query_id, args.performance))}

    min_net = args.min_net_pnl_all if args.min_net_pnl_all is not None else 0
    merged, passed = [], []
    for row in shortlist:
        v = verdicts.get(row["wallet"], {})
        combined = dict(row)
        combined.update({k: v.get(k) for k in (
            "net_pnl_all_usd", "roi_all", "n_positions_all", "n_losers", "n_winners",
            "gross_losses_usd", "worst_position_usd", "n_total_wipeouts",
            "wipeout_loss_usd", "n_positions_external_inflow", "n_txs_all",
            "avg_txs_per_position", "biggest_position_all_usd",
            "avg_winner_size_usd", "avg_loser_size_usd", "conviction_ratio",
            "clean_pnl_usd", "clean_invested_usd", "inflow_pnl_usd",
            "n_clean_positions", "n_sold_without_buying",
            "sold_without_buying_usd", "best_clean_position_usd",
            "clean_pnl_excluding_best_usd", "recent_pnl_180d_usd",
            "recent_positions_180d", "size_variation", "active_hours_of_day")})
        combined["best_position_share"] = (
            round(float(v.get("best_clean_position_usd") or 0)
                  / float(v["clean_pnl_usd"]), 2)
            if v.get("clean_pnl_usd") and float(v["clean_pnl_usd"]) > 0 else None)
        combined["verdict"] = "no data" if not v else score(args, combined)
        merged.append(combined)
        if combined["verdict"] == "pass":
            passed.append(combined)

    merged.sort(key=lambda r: -float(r.get("clean_pnl_usd") or 0))
    passed.sort(key=lambda r: -float(r.get("clean_pnl_usd") or 0))
    write_csv(os.path.join(OUT_DIR, "verified_wallets.csv"), merged)
    with open(os.path.join(OUT_DIR, "wallets.txt"), "w") as fh:
        for row in passed:
            fh.write(f"{row['wallet']}\n")

    rejected = len(merged) - len(passed)
    print(f"\n  {len(passed)} passed, {rejected} rejected -> out/wallets.txt")
    print(f"\n  {'wallet':<45}{'clean PnL':>14}{'majors':>14}{'rugs':>6}  verdict")
    for row in merged[:30]:
        print(f"  {row['wallet']:<45}"
              f"{float(row.get('clean_pnl_usd') or 0):>14,.0f}"
              f"{float(row.get('majors_pnl_usd') or 0):>14,.0f}"
              f"{str(row.get('n_total_wipeouts') or '-'):>6}  {row['verdict']}")
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("phase", nargs="?", default="all",
                        choices=["tokens", "whales", "verify", "regate", "all"])
    # Off by default. A wallet whose profit is one huge conviction position is
    # the target, not a defect — sizing up on a good play is the whole point.
    # Concentration is reported so it can be judged, not silently filtered.
    parser.add_argument("--min-excl-best-all", type=int, default=None,
                        help="optional: clean PnL with the single best position removed")
    parser.add_argument("--max-unbought-share", type=float, default=0.15,
                        help="USD sold of never-bought tokens, as a share of clean PnL")
    parser.add_argument("--min-size-variation", type=float, default=0.30,
                        help="coefficient of variation of position sizes; below this is mechanical")
    parser.add_argument("--max-active-hours", type=int, default=24,
                        help="distinct hours-of-day active; 24 means it never sleeps")
    parser.add_argument("--min-clean-positions", type=int, default=5,
                        help="positions that reconcile against DEX buys, required")
    parser.add_argument("--max-positions-all", type=int, default=260,
                        help="distinct tokens ever traded; ~260 over the window is about one a week")
    parser.add_argument("--min-biggest-position", type=int, default=50000,
                        help="biggest single position across all tokens — the 'sized up' gate")
    parser.add_argument("--min-conviction", type=float, default=1.0,
                        help="avg winning position size / avg losing position size")
    parser.add_argument("--api-key", default=os.environ.get("DUNE_API_KEY"))
    parser.add_argument("--top-tokens", type=int, default=0,
                        help="cap the universe size; 0 keeps every classified memecoin")
    parser.add_argument("--lookback", default=None, metavar="YYYY-MM-DD")
    parser.add_argument("--performance", default="medium", choices=["medium", "large"])
    parser.add_argument("--min-position", type=int, default=None,
                        help="minimum USD bought in a single token to count as a position")
    parser.add_argument("--min-invested", type=int, default=None)
    parser.add_argument("--min-pnl", type=int, default=None)
    parser.add_argument("--min-pnl-excluding-best", type=int, default=None,
                        help="PnL ignoring the single best position — the repeat-winner gate")
    parser.add_argument("--min-net-pnl-all", type=int, default=None,
                        help="net PnL across every token, rugs included")
    parser.add_argument("--min-hold-days", type=int, default=None)
    parser.add_argument("--universe-file",
                        default=os.path.join(QUERY_DIR, "universe_memecoins.txt"),
                        help="curated mint list used by the whales phase")
    parser.add_argument("--universe-query-id", default=None)
    parser.add_argument("--whale-query-id", default=None)
    parser.add_argument("--dry-run", action="store_true",
                        help="print the whale SQL with mints injected, run nothing")
    args = parser.parse_args()

    # regate reads the stored verify output; it never calls Dune.
    if not args.api_key and not args.dry_run and args.phase != "regate":
        parser.error("no API key: set DUNE_API_KEY or pass --api-key")

    os.makedirs(OUT_DIR, exist_ok=True)
    try:
        tokens = []
        if args.phase in ("tokens", "all"):
            tokens = phase_tokens(args, args.api_key)
        elif args.phase == "whales":
            # Prefer the hand-curated list: the raw mcap ranking mixes in infra
            # tokens, LSTs and tokenised equities that no symbol denylist
            # reliably separates from memecoins.
            if os.path.exists(args.universe_file):
                tokens = load_universe_file(args.universe_file)
                print(f"  universe: {len(tokens)} mints from {args.universe_file}")
            else:
                with open(os.path.join(OUT_DIR, "universe_mints.json")) as fh:
                    tokens = json.load(fh)

        if args.phase == "regate":
            phase_regate(args)
            return 0

        shortlist = []
        if args.phase in ("whales", "all"):
            shortlist = phase_whales(args, args.api_key, tokens)
        elif args.phase == "verify":
            with open(os.path.join(OUT_DIR, "whale_wallets.csv")) as fh:
                shortlist = list(csv.DictReader(fh))

        # The gate is not optional: a universe-only list flatters wallets that
        # won on a major while bleeding out on everything else.
        if args.phase in ("whales", "verify", "all") and not args.dry_run:
            phase_verify(args, args.api_key, shortlist)
    except DuneError as exc:
        print(f"\nerror: {exc}", file=sys.stderr)
        return 1
    except FileNotFoundError:
        print("\nerror: run the `tokens` phase first — out/universe_mints.json is missing",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
