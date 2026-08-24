"""Generates `analysis/analysis.ipynb` from this file.

The delivered notebook ships **with its outputs executed**, on purpose: anyone
opening the repo in a browser reads the whole analysis, charts included, without
installing anything.

The price is that the .ipynb is unreadable in a diff — base64 images and
execution metadata drown the actual change. Hence this file: the cell sources
live here, in Python, where `git diff` shows the question that changed.

    python analysis/build_notebook.py                    # rebuild (no outputs)
    jupyter nbconvert --execute --inplace --to notebook \
        analysis/analysis.ipynb                          # execute and save outputs

Or `make notebook`, which does both. Re-running is safe: it overwrites
everything. Edit the cells **here**, never in the .ipynb — the next build throws
that edit away.
"""

from __future__ import annotations

import json
from pathlib import Path

NOTEBOOK = Path(__file__).resolve().parent / "analysis.ipynb"


def _source(text: str) -> list[str]:
    r"""nbformat stores cell source as a list of lines *with* the trailing \n.

    Without the newlines Jupyter concatenates everything onto one line and the
    cell becomes a syntax error — the kind of bug that only shows up when
    somebody opens the notebook.
    """
    lines = text.strip().split("\n")
    return [line + "\n" for line in lines[:-1]] + lines[-1:]


def _cell_id(index: int) -> str:
    """Stable ids derived from position.

    nbformat requires an id per cell. Generating a fresh UUID on every build
    would make each rebuild show up as a 27-cell diff — exactly what this file
    exists to avoid.
    """
    return f"wls-{index:02d}"


def md(text: str) -> dict:
    return {"cell_type": "markdown", "metadata": {}, "source": _source(text)}


def code(text: str) -> dict:
    return {
        "cell_type": "code",
        "execution_count": None,
        "metadata": {},
        "outputs": [],
        "source": _source(text),
    }


CELLS = [
    md("""
# White Lodge Savings — mini-warehouse analysis

This notebook answers the two questions that arrived by email, and doubles as
the starting point for ad-hoc questions.

**Before running:** `python -m pipeline.run` (builds the warehouse).

Shortcuts worth memorising before a live session:

| call | what it does |
|---|---|
| `tables()` | everything in the warehouse |
| `columns("marts.fct_claim")` | columns and types of one table |
| `q("select ...")` | SQL → DataFrame |
| `bar` `stacked_bar` `line` `scatter` `heatmap` `kpi` | pre-styled charts |
| `usd(cents)` `pct(fraction)` | formatting |

Money is always **integer cents** in the warehouse. Divide by 100 only when
displaying — `usd()` does that for you.
"""),
    code("""
# Edits to analysis/wls.py take effect on the next cell run, with no kernel
# restart. Without this, `from ... import kpi` binds the function object into
# this namespace and a later edit to the file is invisible — you fix a chart,
# re-run, and see the old one. That costs minutes you don't have in a live
# session.
%load_ext autoreload
%autoreload 2

import sys
sys.path.insert(0, "..")

from analysis.wls import (
    q, tables, columns, usd, pct, set_mode,
    bar, stacked_bar, line, scatter, heatmap, kpi,
)

# set_mode("dark")   # the dark palette is selected, not an inversion of light
tables()
"""),
    md("""
---
## 0. What survived ingestion

Before any business number: how much of the raw data is usable, and what was
blocked. Without that figure in mind, every total below is a guess.
"""),
    code("""
coverage = q(\"\"\"
    select
        (select count(*) from raw.claims)                                   as raw_rows,
        (select count(*) from marts.fct_claim)                              as analysable,
        (select count(*) from marts.dq_rejects where source_table='claims')  as quarantined
\"\"\").iloc[0]

totals = q(\"\"\"
    select
        count(*)                                    as claims,
        count(*) filter (where is_reverted)          as reverted,
        sum(net_price_cents)                        as gmv,
        sum(net_wls_revenue_cents)                  as wls_revenue,
        count(*) filter (where not has_cost_match)   as no_cost
    from marts.fct_claim
\"\"\").iloc[0]

kpi([
    ("analysable claims", f"{coverage.analysable:,}"),
    ("coverage", pct(coverage.analysable / coverage.raw_rows)),
    ("net GMV", usd(totals.gmv)),
    ("White Lodge revenue", usd(totals.wls_revenue)),
    ("reversal rate", pct(totals.reverted / totals.claims)),
], title="The analysable base")
"""),
    code("""
# Why each row was dropped. Every rejection has a named reason and a source file.
q(\"\"\"
    select source_table, reject_reason, count(*) as rows
    from marts.dq_rejects
    group by 1, 2
    order by 1, 3 desc
\"\"\")
"""),
    code("""
# Auditable down to the original text: what exactly was "unreadable"?
q(\"\"\"
    select record_id, raw_payload
    from marts.dq_rejects
    where reject_reason = 'unparseable_number'
    limit 3
\"\"\")
"""),
    md("""
---
## 1. Dale Cooper — partner mix before renegotiations

> *"For a chain of your choice: who's our most valuable partner, and how do they
> compare to the second-best?"*

The question hides a trap: **"most valuable" by which measure?** By claim volume
and by retained revenue the answer is different, because the commercial terms
range from a flat $1.00 cut to 80% of the fee.

Start with the overall picture, then drop into the chain.
"""),
    code("""
partners = q(\"\"\"
    select
        partner,
        fee_model,
        lookups, claims,
        net_wls_revenue_cents      as wls_revenue,
        net_partner_payout_cents   as payout,
        conversion_rate,
        reversal_rate,
        wls_fee_retention          as retention,
        revenue_cents_per_lookup   as revenue_per_lookup
    from marts.mart_partner_performance
    where claims > 0
    order by wls_revenue desc
\"\"\")
partners.assign(
    wls_revenue=lambda d: d.wls_revenue.map(usd),
    payout=lambda d: d.payout.map(usd),
    conversion_rate=lambda d: d.conversion_rate.map(pct),
    reversal_rate=lambda d: d.reversal_rate.map(pct),
    retention=lambda d: d.retention.map(pct),
    revenue_per_lookup=lambda d: d.revenue_per_lookup.map(usd),
)
"""),
    code("""
# Part-to-whole: of every dollar of pbm_fee a partner originates, how much stays
# with us and how much walks out. This is the comparison the terms obscure.
stacked_bar(
    partners,
    y="partner",
    series={"wls_revenue": "White Lodge keeps", "payout": "Partner payout"},
    title="Where the pbm_fee goes, by partner",
    note="Net of reversals · full period (Mar–Jul 2026)",
    sort_by="wls_revenue",
)
"""),
    md("""
### Dropping into one chain

The email asks for a specific chain. I pick **`meridian`**, the largest by claim
volume — it's where a renegotiation moves the most money.
"""),
    code("""
chain = "meridian"

by_chain = q(f\"\"\"
    select
        partner,
        count(*)                                              as claims,
        sum(net_claim_count)                                  as net_claims,
        sum(net_price_cents)                                  as gmv,
        sum(net_pbm_fee_cents)                                as fee_collected,
        sum(net_partner_fee_cents)                            as payout,
        sum(net_wls_revenue_cents)                            as wls_revenue,
        count(*) filter (where is_reverted) * 1.0 / count(*)   as reversal_rate
    from marts.fct_claim
    where chain = '{chain}'
    group by 1
    order by wls_revenue desc
\"\"\")
by_chain.assign(
    gmv=lambda d: d.gmv.map(usd),
    fee_collected=lambda d: d.fee_collected.map(usd),
    payout=lambda d: d.payout.map(usd),
    wls_revenue=lambda d: d.wls_revenue.map(usd),
    reversal_rate=lambda d: d.reversal_rate.map(pct),
)
"""),
    code("""
bar(
    by_chain,
    x="wls_revenue", y="partner",
    title=f"White Lodge net revenue in the {chain} chain, by partner",
    note="After the partner payout and net of reversals",
    xtitle="retained revenue",
)
"""),
    code("""
# The full chain × partner picture, so the chain isn't chosen blind.
grid = q(\"\"\"
    select chain, partner, sum(net_wls_revenue_cents) as revenue
    from marts.fct_claim
    group by 1, 2
\"\"\")
heatmap(grid, x="partner", y="chain", z="revenue",
        title="Revenue retained by White Lodge — chain × partner",
        note="Darker is more revenue · blank cells had no claims")
"""),
    md("""
---
## 2. Gordon Cole — where the margin would come from

> *"If we wanted to increase White Lodge's margin, what would you suggest —
> based on what you're seeing in the data?"*

The answer is in one thing that shows up the moment you put price and fee on the
same chart.
"""),
    code("""
sample = q(\"\"\"
    select price_cents / 100.0 as price, pbm_fee_cents / 100.0 as fee
    from marts.fct_claim
    where not is_reverted
\"\"\")

scatter(
    sample, x="price", y="fee",
    title="What we charge has no relationship to the value we intermediate",
    note="One point per claim · price axis on a log scale",
    xtitle="claim price (log)", ytitle="pbm_fee charged",
    log_x=True, money_x=True, money_y=True,
)
"""),
    code("""
# The same fact, quantified: take rate collapses as the claim grows.
bands = q(\"\"\"
    select
        case
            when price_cents < 10000    then '1 · up to $100'
            when price_cents < 1000000  then '2 · $100 to $10k'
            else                             '3 · above $10k'
        end                                         as band,
        count(*)                                    as claims,
        sum(price_cents)                            as gmv,
        sum(pbm_fee_cents)                          as fee,
        sum(pbm_fee_cents) * 1.0 / sum(price_cents)  as take_rate
    from marts.fct_claim
    where not is_reverted
    group by 1
    order by 1
\"\"\")
bands.assign(gmv=lambda d: d.gmv.map(usd), fee=lambda d: d.fee.map(usd),
             take_rate=lambda d: d.take_rate.map(lambda v: f"{v*100:.4f}%"))
"""),
    code("""
# Two measures on incomparable scales (GMV in millions, take rate in thousandths
# of a percent) => two charts. Never a secondary axis.
bar(bands, x="gmv", y="band",
    title="Where the financial volume is",
    note="Net GMV by claim value band", xtitle="GMV")
"""),
    code("""
bar(bands.assign(take_bp=lambda d: d.take_rate * 10000), x="take_bp", y="band",
    money=False,
    title="Where our compensation is",
    note="Take rate in basis points (1 bp = 0.01%) — same ordering as the chart above",
    xtitle="take rate (basis points)")
"""),
    md("""
### The second lever: generic substitution

For every brand drug, NADAC publishes the cost of the equivalent generic. That
lets us estimate how much acquisition cost would leave the chain if the same
fill were dispensed as the generic.
"""),
    code("""
generics = q(\"\"\"
    select
        ndc, ndc_description, drug_class,
        net_claims                          as claims,
        net_gmv_cents                       as gmv,
        net_wls_revenue_cents               as wls_revenue,
        generic_substitution_savings_cents  as potential_saving,
        reversal_rate
    from marts.mart_drug_economics
    where generic_substitution_savings_cents > 0
    order by potential_saving desc
    limit 10
\"\"\")
generics.assign(gmv=lambda d: d.gmv.map(usd), wls_revenue=lambda d: d.wls_revenue.map(usd),
                potential_saving=lambda d: d.potential_saving.map(usd),
                reversal_rate=lambda d: d.reversal_rate.map(pct))
"""),
    code("""
bar(generics.head(6), x="potential_saving", y="ndc_description",
    title="Acquisition cost that generic substitution would remove",
    note="Gap between brand NADAC and the equivalent generic, at dispensed volume",
    xtitle="estimated saving")
"""),
    md("""
### The third: reversals

A reversal is revenue that was earned and handed back. Unlike margin that never
existed, this one is recoverable.
"""),
    code("""
reversals = q(\"\"\"
    select
        sum(wls_net_fee_cents) filter (where is_reverted) as revenue_lost,
        sum(wls_net_fee_cents)                            as revenue_potential,
        median(hours_to_revert)                           as hours_to_revert
    from marts.fct_claim
\"\"\").iloc[0]

kpi([
    ("revenue lost to reversals", usd(reversals.revenue_lost)),
    ("% of potential revenue", pct(reversals.revenue_lost / reversals.revenue_potential)),
    ("median time to reversal", f"{reversals.hours_to_revert / 24:.1f} days"),
], title="What reversals cost")
"""),
    code("""
weekly = q(\"\"\"
    select week_start, partner,
           sum(claims) as claims, sum(reverted_claims) as reverted
    from marts.mart_funnel_daily
    where partner <> 'unknown'
    group by 1, 2
\"\"\")
weekly["rate"] = weekly.reverted / weekly.claims

line(weekly, x="week_start", y="rate", color="partner",
     title="Reversal rate by partner, by week",
     note="Flat across all of them — a structural cost, not a one-off incident",
     ytitle="reversal rate")
"""),
    md("""
---
## Scratch area

Room for whatever arrives live. The shortest path is almost always
`marts.fct_claim` on its own — it already carries `chain`, `partner`, `channel`
and `drug_class` denormalised for exactly this.
"""),
    code("""
columns("marts.fct_claim")
"""),
    code("""
q(\"\"\"
    select *
    from marts.fct_claim
    limit 5
\"\"\")
"""),
]


def main() -> None:
    cells = [{**cell, "id": _cell_id(index)} for index, cell in enumerate(CELLS)]
    notebook = {
        "cells": cells,
        "metadata": {
            "kernelspec": {
                "display_name": "Python 3",
                "language": "python",
                "name": "python3",
            },
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }
    NOTEBOOK.write_text(json.dumps(notebook, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"[ok] {NOTEBOOK} ({len(CELLS)} cells)")


if __name__ == "__main__":
    main()
