"""NADAC ingestion (National Average Drug Acquisition Cost, CMS).

Two decisions worth explaining:

1. **We resolve the URL from the catalog, not a hardcoded link.** CMS republishes
   the file weekly with the date baked into the filename
   (`nadac-...-08-19-2026.csv`). A hardcoded link breaks by itself on the next
   release, so we ask the metastore which CSV distribution is current.

2. **The download is cached on disk, and the pipeline runs offline afterwards.**
   It's ~83 MB. The live sessions start with the machine already loaded; a
   pipeline that needs the network to run is a pipeline that fails at the worst
   possible moment. `--refresh-nadac` forces a fresh download.
"""

from __future__ import annotations

import json
import shutil
import urllib.request
from pathlib import Path

# The "NADAC (National Average Drug Acquisition Cost) 2026" dataset on
# data.medicaid.gov. One dataset per calendar year; this one covers the 2026
# weekly snapshots, which is where our claims live (2026-03-01 to 2026-07-31).
NADAC_DATASET_ID = "fbb83258-11c7-47f5-8b18-5f8e79f7e704"
METASTORE_URL = "https://data.medicaid.gov/api/1/metastore/schemas/dataset/items/{}"

USER_AGENT = "white-lodge-savings-warehouse/1.0 (take-home exercise)"


def resolve_download_url(dataset_id: str = NADAC_DATASET_ID, timeout: int = 60) -> str:
    """Ask the CMS catalog which CSV distribution is current for this dataset."""
    req = urllib.request.Request(
        METASTORE_URL.format(dataset_id), headers={"User-Agent": USER_AGENT}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        meta = json.load(resp)

    for dist in meta.get("distribution", []):
        data = dist.get("data", {})
        if data.get("format", "").lower() == "csv" and data.get("downloadURL"):
            return data["downloadURL"]

    raise RuntimeError(
        f"No CSV distribution found for NADAC dataset {dataset_id}. "
        "Download it manually and point --nadac at the directory."
    )


def ensure_nadac(dest_dir: Path, refresh: bool = False, timeout: int = 600) -> Path:
    """Guarantee a NADAC CSV in `dest_dir`; return its path.

    If a cached CSV is already there and `refresh` is False, this never touches
    the network.
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    cached = sorted(dest_dir.glob("*.csv"))

    if cached and not refresh:
        print(f"[nadac] using cache: {cached[-1].name}", flush=True)
        return cached[-1]

    url = resolve_download_url(timeout=min(timeout, 60))
    target = dest_dir / url.rsplit("/", 1)[-1]

    print(f"[nadac] downloading {url}", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    # Write to .part and only then rename: a Ctrl+C mid-download must not leave a
    # truncated CSV in the cache that the next run happily treats as valid.
    partial = target.with_suffix(target.suffix + ".part")
    with urllib.request.urlopen(req, timeout=timeout) as resp, partial.open("wb") as fh:
        shutil.copyfileobj(resp, fh)
    partial.replace(target)

    print(f"[nadac] saved to {target} ({target.stat().st_size / 1e6:.0f} MB)", flush=True)
    return target
