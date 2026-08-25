"""Land raw files into `raw.*` DuckDB tables. Nothing is interpreted here.

**Every column lands as VARCHAR**, and the reason is **determinism**, not any
single field.

DuckDB's type inference samples roughly the first 20k rows and commits to a type
from what it sees, so how a file lands depends on what else arrived in the same
batch. 25,000 clean prices followed by one `"one hundred"` makes the sampler pick
DOUBLE and the read dies with `JSON transform error` — one bad row out of 25,001
takes the whole ingest down, and *which* row does that depends on where it sat in
the file. Declaring the schema means the same input always lands the same way,
and a bad value becomes one documented row in `dq_rejects` instead of a failed
run. Every cast then happens in dbt staging, where a failed cast gets a reason
rather than becoming an orphaned NULL.

Second reason: the raw text is the audit trail. `price: "one hundred"` has to
survive verbatim, or `dq_rejects` can say "unreadable number" without being able
to show what the number was. `_source_file` and `_ingested_at` are on every table
for the same purpose — when a number looks wrong live, step one is finding the
file that carried it.

*Not* a reason, despite being the obvious one to reach for: leading zeros.
Current DuckDB preserves `"00078050161"` on its own, in JSON (the value is
quoted) and in CSV (the sniffer detects the zero and declines to numerify).
Verified in both. The test in `tests/test_landing.py` stays as a regression
guard, but the zero is not what this decision buys.
"""

from __future__ import annotations

from pathlib import Path

import duckdb

# Schema declared explicitly per source. Declaring it (rather than letting DuckDB
# union whatever keys it finds) guarantees that a field missing from *every* file
# in a batch still shows up as a NULL column — the raw table has the same shape
# regardless of batch composition.
EVENT_COLUMNS: dict[str, dict[str, str]] = {
    "claims": {
        "id": "VARCHAR",
        "npi": "VARCHAR",
        "ndc": "VARCHAR",
        "price": "VARCHAR",
        "quantity": "VARCHAR",
        "pbm_fee": "VARCHAR",
        "timestamp": "VARCHAR",
    },
    "reverts": {
        "id": "VARCHAR",
        "claim_id": "VARCHAR",
        "timestamp": "VARCHAR",
    },
    "lookups": {
        "id": "VARCHAR",
        "claim_id": "VARCHAR",
        "ndc": "VARCHAR",
        "partner": "VARCHAR",
        "channel": "VARCHAR",
        "timestamp": "VARCHAR",
    },
}

# We keep 9 of NADAC's 12 columns. The brief explicitly says not to ingest
# everything, so:
#   * `nadac_per_unit` + `effective_date` + `as_of_date` are the cost and the
#     timeline — the core of the as-of join.
#   * `classification_for_rate_setting` (B/G) and
#     `corresponding_generic_drug_nadac_per_unit` carry the margin question: what
#     the equivalent generic would cost for every brand fill we dispense.
#   * `ndc_description`, `pricing_unit` and `otc` are human-readable labels.
# Left out: `explanation_code`, `pharmacy_type_indicator` and
# `corresponding_generic_drug_effective_date` — no question in scope uses them.
NADAC_COLUMNS: dict[str, str] = {
    "NDC": "ndc",
    "NDC Description": "ndc_description",
    "NADAC Per Unit": "nadac_per_unit",
    "Effective Date": "effective_date",
    "As of Date": "as_of_date",
    "Pricing Unit": "pricing_unit",
    "Classification for Rate Setting": "classification_for_rate_setting",
    "OTC": "otc",
    "Corresponding Generic Drug NADAC Per Unit": "generic_nadac_per_unit",
}


def _quote(path: Path | str) -> str:
    """SQL literal for a path. Slashes normalised for DuckDB on Windows."""
    return "'" + str(path).replace("\\", "/").replace("'", "''") + "'"


def _columns_struct(columns: dict[str, str]) -> str:
    inner = ", ".join(f"'{name}': '{dtype}'" for name, dtype in columns.items())
    return "{" + inner + "}"


def _land(con: duckdb.DuckDBPyConnection, table: str, select_sql: str) -> int:
    con.execute(f"create or replace table raw.{table} as {select_sql}")
    (count,) = con.execute(f"select count(*) from raw.{table}").fetchone()
    print(f"[land] raw.{table}: {count:,} rows", flush=True)
    return count


def land_events(con: duckdb.DuckDBPyConnection, source: str, directory: Path) -> int:
    """Land a directory of JSON events (claims / reverts / lookups)."""
    columns = EVENT_COLUMNS[source]
    quoted = ", ".join(f'"{c}"' for c in columns)
    return _land(
        con,
        source,
        f"""
        select {quoted}, filename as _source_file, now() as _ingested_at
        from read_json(
            {_quote(Path(directory) / '*.json')},
            columns = {_columns_struct(columns)},
            format = 'array',
            filename = true
        )
        """,
    )


def land_pharmacies(con: duckdb.DuckDBPyConnection, directory: Path) -> int:
    return _land(
        con,
        "pharmacies",
        f"""
        select npi, chain, filename as _source_file, now() as _ingested_at
        from read_csv({_quote(Path(directory) / '*.csv')}, all_varchar = true, filename = true)
        """,
    )


def land_partners(con: duckdb.DuckDBPyConnection, directory: Path) -> int:
    return _land(
        con,
        "partners",
        f"""
        select partner, fee_cents, fee_percentage,
               filename as _source_file, now() as _ingested_at
        from read_csv({_quote(Path(directory) / '*.csv')}, all_varchar = true, filename = true)
        """,
    )


def land_nadac(con: duckdb.DuckDBPyConnection, csv_path: Path) -> int:
    projection = ",\n               ".join(
        f'"{src}" as {dest}' for src, dest in NADAC_COLUMNS.items()
    )
    return _land(
        con,
        "nadac",
        f"""
        select {projection},
               filename as _source_file, now() as _ingested_at
        from read_csv({_quote(csv_path)}, all_varchar = true, filename = true)
        """,
    )
