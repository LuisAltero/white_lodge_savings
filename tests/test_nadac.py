"""Tests for NADAC ingestion. None of them touch the network."""

from __future__ import annotations

import io
import json

import pytest

from pipeline import nadac


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def test_resolve_download_url_picks_the_csv_distribution(monkeypatch):
    """The catalog may list several distributions; we want the CSV."""
    payload = {
        "distribution": [
            {"data": {"format": "json", "downloadURL": "https://example.test/x.json"}},
            {"data": {"format": "csv", "downloadURL": "https://example.test/nadac.csv"}},
        ]
    }
    monkeypatch.setattr(
        nadac.urllib.request, "urlopen",
        lambda *a, **k: FakeResponse(json.dumps(payload).encode()),
    )

    assert nadac.resolve_download_url("id") == "https://example.test/nadac.csv"


def test_resolve_download_url_fails_loudly_when_there_is_no_csv(monkeypatch):
    """Better an error with an instruction than a pipeline that runs with no cost."""
    monkeypatch.setattr(
        nadac.urllib.request, "urlopen",
        lambda *a, **k: FakeResponse(json.dumps({"distribution": []}).encode()),
    )

    with pytest.raises(RuntimeError, match="Download it manually"):
        nadac.resolve_download_url("id")


def test_ensure_nadac_uses_the_cache_without_touching_the_network(monkeypatch, tmp_path):
    """The pipeline has to run offline after the first download.

    The live sessions start with the machine already loaded; a pipeline that
    needs the network is a pipeline that fails at the wrong moment.
    """
    cached = tmp_path / "nadac-2026.csv"
    cached.write_text("NDC,NADAC Per Unit\n", encoding="utf-8")

    def explode(*args, **kwargs):
        raise AssertionError("a present cache must not hit the network")

    monkeypatch.setattr(nadac.urllib.request, "urlopen", explode)

    assert nadac.ensure_nadac(tmp_path) == cached
