"""Tests for the ingestion layer.

What's under test here is *a decision*, not a function: land everything as
VARCHAR. If someone "improves" `land.py` by letting DuckDB infer types, these
tests fail with a name that explains the damage — NDC loses its leading zero,
unreadable text becomes NULL with no trace.
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

    If type inference turns "00078050161" into BIGINT it becomes 78050161, and
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
    """`price: "one hundred"` reaches staging intact.

    Under type inference that row would become NULL, and `dq_rejects` would say
    "unreadable number" without being able to show *which* text was unreadable.
    """
    directory = write_events(
        tmp_path / "claims",
        [{"id": "a", "npi": "1", "ndc": "1", "price": "one hundred",
          "quantity": "thirty", "pbm_fee": "1.0", "timestamp": "2026-05-01T00:00:00"}],
    )

    land.land_events(con, "claims", directory)

    price, quantity = con.execute("select price, quantity from raw.claims").fetchone()
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


def test_landing_reads_every_file_in_the_directory(con, tmp_path):
    """Events arrive split across many files — 119 for lookups alone."""
    directory = tmp_path / "claims"
    directory.mkdir(parents=True)
    for index in range(3):
        (directory / f"output-{index}.json").write_text(
            json.dumps([{"id": str(index), "npi": "1", "ndc": "1", "price": "1.0",
                         "quantity": "1", "pbm_fee": "1.0",
                         "timestamp": "2026-05-01T00:00:00"}]),
            encoding="utf-8",
        )

    assert land.land_events(con, "claims", directory) == 3


def test_landing_records_the_file_each_row_came_from(con, tmp_path):
    """When a number looks wrong, step one is finding the file."""
    directory = write_events(
        tmp_path / "claims",
        [{"id": "a", "npi": "1", "ndc": "1", "price": "1.0", "quantity": "1",
          "pbm_fee": "1.0", "timestamp": "2026-05-01T00:00:00"}],
    )

    land.land_events(con, "claims", directory)

    (source_file,) = con.execute("select _source_file from raw.claims").fetchone()
    assert source_file.endswith("output-batch.json")


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
