"""Interactive SQL shell on the warehouse.

    python analysis/shell.py

The DuckDB Python package ships no `__main__`, so `python -m duckdb` is not a
shell. This is: a read-only connection plus a read-eval-print loop that prints
the result of whatever SQL you type.

Read-only *and* short-lived. DuckDB allows one writer per file and its read lock
excludes that writer too, so a shell holding any open connection blocks
`python -m pipeline.run` — exactly the failure you don't want mid-session. This
shell opens a connection per statement and closes it, so you can rebuild the
warehouse in another terminal without quitting here.

    .tables            list every table, by schema
    .schema <table>    column names and types
    .quit              exit (Ctrl-D also works)

Statements end at a blank line, so multi-line SQL can be pasted whole.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import duckdb

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATABASE = PROJECT_ROOT / "data" / "duckdb" / "warehouse.duckdb"

# DuckDB draws its result tables with box-drawing characters. The Windows
# console defaults to cp1252, which cannot encode them, and the traceback that
# follows looks like a database error when it's really a terminal error.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

TABLES = """
select table_schema, table_name
from information_schema.tables
where table_schema not in ('information_schema', 'pg_catalog')
order by
    case table_schema
        when 'marts' then 1 when 'intermediate' then 2
        when 'staging' then 3 else 4
    end,
    table_name
"""


def run(sql: str) -> None:
    """Open a connection, run one statement, close it.

    Per statement, not per session, for the same reason as `analysis/wls.py`:
    DuckDB's read lock excludes a writer, so a shell left open on a persistent
    connection blocks `python -m pipeline.run` — the rebuild you want to do
    *while* this shell is open. Holding the lock only for the duration of a
    statement costs ~13 ms and removes the conflict.
    """
    deadline = time.monotonic() + 60
    try:
        while True:
            try:
                with duckdb.connect(str(DATABASE), read_only=True) as con:
                    con.sql(sql).show(max_rows=40)
                return
            except duckdb.IOException:
                # The pipeline is probably rebuilding: the lock is exclusive in
                # both directions, so wait it out instead of erroring at you.
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.25)
    except duckdb.Error as error:
        # An unreadable query is the normal case in an exploratory shell, not a
        # crash: print the message and keep the session alive.
        print(f"error: {error}")


def main() -> int:
    if not DATABASE.exists():
        print(f"{DATABASE} does not exist. Run `python -m pipeline.run` first.")
        return 1

    print(f"warehouse: {DATABASE}  (read-only, one connection per statement)")
    print("`.tables` to list, `.schema <table>` for columns, `.quit` to exit.\n")

    buffer: list[str] = []
    while True:
        try:
            line = input("... " if buffer else "wls> ")
        except (EOFError, KeyboardInterrupt):
            print()
            break

        stripped = line.strip()

        if not buffer and stripped in (".quit", ".exit", "exit", "quit"):
            break
        if not buffer and stripped == ".tables":
            run(TABLES)
            continue
        if not buffer and stripped.startswith(".schema "):
            run(f"describe {stripped.split(maxsplit=1)[1]}")
            continue

        # A blank line, or a trailing semicolon, ends the statement. Anything
        # else is a continuation, so pasted multi-line SQL survives intact.
        if stripped:
            buffer.append(line)
            if not stripped.endswith(";"):
                continue
        if not buffer:
            continue

        run("\n".join(buffer).rstrip().rstrip(";"))
        buffer = []

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
