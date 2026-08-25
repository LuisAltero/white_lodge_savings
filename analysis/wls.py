"""Query and formatting helpers for the live sessions.

Three query helpers and two formatters. That is deliberately all of it: charts
are plain `plotly.express` in the notebook, because in a live session the fastest
chart to change is the one whose API the room already knows.

    from analysis.wls import q, tables, columns, usd, pct
    import plotly.express as px

    df = q("select partner, net_wls_revenue_cents as rev from marts.mart_partner_performance")
    px.bar(df, x="rev", y="partner", orientation="h")

Every query opens its own read-only connection and closes it, so an open notebook
never blocks `python -m pipeline.run` — the detail that decides whether you can
rebuild a model without restarting a kernel. See `q()`.
"""

from __future__ import annotations

import time
from pathlib import Path

import duckdb
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATABASE = PROJECT_ROOT / "data" / "duckdb" / "warehouse.duckdb"


# How long a query waits for a rebuild to finish before giving up. A full
# `python -m pipeline.run` takes ~10 s; 60 covers it with room to spare.
_LOCK_WAIT_SECONDS = 60


def q(sql: str) -> pd.DataFrame:
    """Run SQL, return a DataFrame. **One connection per call, opened and closed.**

    Not tidiness — this is the most important decision in the file for a live
    session. DuckDB allows one writer per file, and its *read* lock excludes that
    writer too. A notebook holding an open connection blocks
    `python -m pipeline.run` for as long as the kernel lives, and a kernel lives
    invisibly long after you stopped looking at it. The failure lands exactly
    when you want to rebuild a model and re-query it — the whole loop of a live
    debug session. Opening per call costs ~13 ms against ~250 ms for a real
    group-by: roughly 5%, invisible while a human types.

    The lock is exclusive both ways, so during the ~10 s of a build a reader
    can't open the file either. Hence the wait rather than a raise: a cell that
    takes a moment longer beats a traceback with an audience.
    """
    if not DATABASE.exists():
        raise FileNotFoundError(
            f"{DATABASE} does not exist. Run `python -m pipeline.run` first."
        )

    deadline = time.monotonic() + _LOCK_WAIT_SECONDS
    while True:
        try:
            with duckdb.connect(str(DATABASE), read_only=True) as con:
                return con.execute(sql).df()
        except duckdb.IOException:
            if time.monotonic() >= deadline:
                raise RuntimeError(
                    f"{DATABASE} stayed locked for {_LOCK_WAIT_SECONDS}s. A "
                    "rebuild takes ~10s, so this is probably a process holding "
                    "it open — check for a stray python or duckdb CLI."
                ) from None
            time.sleep(0.25)


def tables() -> pd.DataFrame:
    """What exists in the warehouse — the first command of every session."""
    return q("""
        select schema_name as schema, table_name as table, estimated_size as rows
        from duckdb_tables()
        where schema_name in ('marts', 'staging', 'intermediate', 'raw')
        order by case schema_name
            when 'marts' then 1 when 'intermediate' then 2
            when 'staging' then 3 else 4 end, table_name
    """)


def columns(table: str) -> pd.DataFrame:
    """Columns and types of a table. `columns('marts.fct_claim')`."""
    schema, _, name = table.rpartition(".")
    return q(f"""
        select column_name as column, data_type as type
        from information_schema.columns
        where table_name = '{name}'
          {f"and table_schema = '{schema}'" if schema else ""}
        order by ordinal_position
    """)


# ---------------------------------------------------------------------------
# Formatting
#
# These two exist because money in this warehouse is always integer cents. That
# convention is what makes sums exact, and it's also what makes a raw column
# unreadable in a table — 1312707 is $13,127.07.
# ---------------------------------------------------------------------------

def usd(cents) -> str:
    """Integer cents -> dollar string. Compacts above $1k."""
    if cents is None or pd.isna(cents):
        return "—"
    value = float(cents) / 100
    if abs(value) >= 1_000_000:
        return f"${value / 1_000_000:,.1f}M"
    if abs(value) >= 1_000:
        return f"${value / 1_000:,.1f}k"
    return f"${value:,.2f}"


def pct(fraction, places: int = 1) -> str:
    if fraction is None or pd.isna(fraction):
        return "—"
    return f"{float(fraction) * 100:.{places}f}%"
