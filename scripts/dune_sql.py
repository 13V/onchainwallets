#!/usr/bin/env python3
"""Run ad-hoc DuneSQL and print the result as a table.

    DUNE_API_KEY=... python3 scripts/dune_sql.py path/to/file.sql
    DUNE_API_KEY=... python3 scripts/dune_sql.py -    # read SQL from stdin

Reuses one scratch query (id cached in out/query_ids.json under "scratch") so
repeated debugging does not litter the account with new queries.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from find_whales import DuneError, ensure_query, fetch_rows, run_query  # noqa: E402


def main():
    key = os.environ.get("DUNE_API_KEY")
    if not key:
        print("error: set DUNE_API_KEY", file=sys.stderr)
        return 1

    source = sys.argv[1] if len(sys.argv) > 1 else "-"
    sql = sys.stdin.read() if source == "-" else open(source).read()
    performance = sys.argv[2] if len(sys.argv) > 2 else "medium"

    try:
        query_id = ensure_query(key, "scratch", "scratch (find_whales debug)", sql)
        rows = fetch_rows(key, run_query(key, query_id, performance))
    except DuneError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not rows:
        print("(0 rows)")
        return 0

    cols = list(rows[0].keys())
    widths = {c: max(len(c), *(len(str(r.get(c))) for r in rows)) for c in cols}
    print("  ".join(c.ljust(widths[c]) for c in cols))
    print("  ".join("-" * widths[c] for c in cols))
    for row in rows:
        print("  ".join(str(row.get(c)).ljust(widths[c]) for c in cols))
    print(f"\n({len(rows)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
