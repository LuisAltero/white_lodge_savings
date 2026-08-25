"""Tests for the ingestion layer.

What's under test here is *a decision*, not a function: land everything as
VARCHAR. These tests exist because dbt cannot see this layer at all — its world
starts at `raw.*`, after landing already happened — so a landing bug produces a
raw table that is internally consistent and simply wrong.

The decision is about **determinism**. DuckDB's type inference samples the first
~20k rows, so what a file lands as depends on what else arrived in the batch: the
same dirty value is harmless in one run and fatal in the next. Declaring the
schema makes ingestion behave the same way every time.

Not about leading zeros, despite the obvious guess — current DuckDB preserves
them on its own in both JSON and CSV. Verified. The zero survives; the
determinism doesn't.
"""

from __future__ import annotations

import json

import duckdb
import pytest

from pipeline import land


@pytest.fixture
def con():
    connection = duckdb.connect(":memory:")
    connection.execute("create schema if not exists raw")
    yield connection
    connection.close()


def write_events(directory, rows):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "output-batch.json").write_text(json.dumps(rows), encoding="utf-8")
    return directory


def test_landing_preserves_leading_zeros_in_ndc(con, tmp_path):
    """NDC is an 11-digit code, not a number.

    Current DuckDB happens to preserve the leading zero on its own, so this is a
    regression guard rather than a bug we hit: if a future version, a different
    reader, or a `cast` added upstream ever turns "00078050161" into 78050161,
    every join to NADAC fails silently — not with an error, with zero matches.
    """
    directory = write_events(
        tmp_path / "claims",
        [{"id": "a", "npi": "1", "ndc": "00078050161", "price": "1.0",
          "quantity": "1", "pbm_fee": "1.0", "timestamp": "2026-05-01T00:00:00"}],
    )

    land.land_events(con, "claims", directory)

    (ndc,) = con.execute("select ndc from raw.claims").fetchone()
    assert ndc == "00078050161"


def test_landing_preserves_text_that_cannot_be_a_number(con, tmp_path):
    """`price: "one hundred"` reaches staging intact, *and the batch survives it*.

    The dirty row sits past DuckDB's inference sampling window (~20k rows) on
    purpose, because that is the case that actually bites. Under type inference
    the sample is all-numeric, DuckDB commits to DOUBLE, and then hits the text:
    the whole ingest dies with `JSON transform error`. One bad row out of 25,001
    takes the run down, and which row does it depends on where it landed in the
    batch.

    With the schema declared, it lands as text and becomes exactly one row of
    `unparseable_number` in dq_rejects, with the original literal preserved.
    """
    # price/quantity are JSON *numbers* here, exactly as the real files carry
    # them (`"price": 9.57`). That is what makes the sampler commit to DOUBLE —
    # write them as quoted strings and there is no type conflict to detect, and
    # this test would pass whether or not the schema is declared.
    clean = [{"id": f"c{index}", "npi": "1", "ndc": "1", "price": 1.0,
              "quantity": 1.0, "pbm_fee": 1.0, "timestamp": "2026-05-01T00:00:00"}
             for index in range(25_000)]
    dirty = {"id": "dirty", "npi": "1", "ndc": "1", "price": "one hundred",
             "quantity": "thirty", "pbm_fee": 1.0, "timestamp": "2026-05-01T00:00:00"}
    directory = write_events(tmp_path / "claims", clean + [dirty])

    assert land.land_events(con, "claims", directory) == 25_001

    price, quantity = con.execute(
        "select price, quantity from raw.claims where id = 'dirty'"
    ).fetchone()
    assert price == "one hundred"
    assert quantity == "thirty"


def test_landing_fills_missing_fields_with_null_instead_of_failing(con, tmp_path):
    """A whole batch with no `ndc` still produces an `ndc` column.

    The schema is declared, not inferred, so the raw table always has the same
    shape — downstream models don't break because of batch composition.
    """
    directory = write_events(
        tmp_path / "claims",
        [{"id": "a", "npi": "1", "price": "1.0", "quantity": "1",
          "pbm_fee": "1.0", "timestamp": "2026-05-01T00:00:00"}],
    )

    land.land_events(con, "claims", directory)

    columns = [c[0] for c in con.execute("describe raw.claims").fetchall()]
    assert "ndc" in columns
    assert con.execute("select ndc from raw.claims").fetchone()[0] is None




def test_landing_keeps_zero_fee_partner_distinct_from_missing(con, tmp_path):
    """`fee_cents = 0` (Airflow Rx) and an empty `fee_cents` are different things.

    Collapsing both to NULL at landing would make stg_partners pick the wrong fee
    rule for a real partner.
    """
    directory = tmp_path / "partners"
    directory.mkdir(parents=True)
    (directory / "output-partners.csv").write_text(
        "partner,fee_cents,fee_percentage\nAirflow Rx,0,\nHudi Rx,,50.0\n",
        encoding="utf-8",
    )

    land.land_partners(con, directory)

    rows = dict(con.execute("select partner, fee_cents from raw.partners").fetchall())
    assert rows["Airflow Rx"] == "0"
    assert rows["Hudi Rx"] is None
