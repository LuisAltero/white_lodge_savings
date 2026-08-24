"""Pipeline entry point: one command, end to end.

    python -m pipeline.run

The brief asks that the application accept directory paths for each source, so
all of them are flags defaulting to `sample-data/`.

Why no Airflow / Dagster / Prefect: this pipeline has four steps, runs in one
process, and has no schedule, no partial retry and no SLA. An orchestrator here
would add a service to keep alive without making anything easier to run or
change — and the brief puts it explicitly out of scope. `dbt build` is already
the scheduler: it resolves the model DAG and interleaves the tests.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

import duckdb

from pipeline import land, nadac

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SAMPLE = PROJECT_ROOT / "sample-data"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="pipeline.run",
        description="Build the White Lodge Savings mini-warehouse in DuckDB.",
    )
    src = p.add_argument_group("data sources")
    src.add_argument("--claims", type=Path, default=DEFAULT_SAMPLE / "claims")
    src.add_argument("--reverts", type=Path, default=DEFAULT_SAMPLE / "reverts")
    src.add_argument("--lookups", type=Path, default=DEFAULT_SAMPLE / "lookups")
    src.add_argument("--pharmacies", type=Path, default=DEFAULT_SAMPLE / "pharmacies")
    src.add_argument("--partners", type=Path, default=DEFAULT_SAMPLE / "partners")
    src.add_argument(
        "--nadac",
        type=Path,
        default=PROJECT_ROOT / "data" / "raw" / "nadac",
        help="Cache directory for the NADAC CSV (downloaded if empty).",
    )

    out = p.add_argument_group("output and control")
    out.add_argument(
        "--database",
        type=Path,
        default=PROJECT_ROOT / "data" / "duckdb" / "warehouse.duckdb",
    )
    out.add_argument(
        "--refresh-nadac",
        action="store_true",
        help="Re-download NADAC even if a cached copy exists.",
    )
    out.add_argument(
        "--skip-land",
        action="store_true",
        help="Skip ingestion and run dbt only (handy while iterating on SQL).",
    )
    out.add_argument(
        "--skip-dbt", action="store_true", help="Land the raw data and stop."
    )
    out.add_argument(
        "--select",
        default=None,
        help="Passed through to `dbt build --select` (e.g. 'marts+').",
    )
    return p.parse_args(argv)


def landing(args: argparse.Namespace) -> None:
    nadac_csv = nadac.ensure_nadac(args.nadac, refresh=args.refresh_nadac)

    args.database.parent.mkdir(parents=True, exist_ok=True)
    # Our own write connection, closed before dbt starts: DuckDB allows a single
    # writer per file and dbt needs that lock next.
    con = duckdb.connect(str(args.database))
    try:
        con.execute("create schema if not exists raw")
        land.land_events(con, "claims", args.claims)
        land.land_events(con, "reverts", args.reverts)
        land.land_events(con, "lookups", args.lookups)
        land.land_pharmacies(con, args.pharmacies)
        land.land_partners(con, args.partners)
        land.land_nadac(con, nadac_csv)
    finally:
        con.close()


def build(args: argparse.Namespace) -> None:
    env = {**os.environ, "WLS_DUCKDB_PATH": str(args.database.resolve())}
    cmd = [sys.executable, "-m", "dbt.cli.main", "build"]
    if args.select:
        cmd += ["--select", args.select]

    print(f"[dbt] {' '.join(cmd[2:])}", flush=True)
    result = subprocess.run(cmd, cwd=PROJECT_ROOT / "warehouse", env=env)
    if result.returncode != 0:
        raise SystemExit(f"dbt build failed (exit {result.returncode})")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    started = time.perf_counter()

    if not args.skip_land:
        landing(args)
    if not args.skip_dbt:
        build(args)

    elapsed = time.perf_counter() - started
    print("")
    print(f"[ok] warehouse ready at {args.database} ({elapsed:.1f}s)", flush=True)
    print(f"     query it with:  duckdb {args.database}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
