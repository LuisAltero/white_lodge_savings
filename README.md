# White Lodge Savings — mini-warehouse

A local, queryable warehouse over the pharmacy event streams: claims, reversals
and price lookups, enriched with CMS NADAC acquisition costs.

**DuckDB + dbt + a Python ingestion layer.** One command builds it end to end in
about 12 seconds, running 75 tests alongside the 20 models it builds.

```bash
python -m venv .venv && .venv/Scripts/python -m pip install -r requirements.txt
python -m pipeline.run
```

Then query it:

```bash
duckdb data/duckdb/warehouse.duckdb
```

```sql
select partner, sum(net_wls_revenue_cents) / 100.0 as revenue_usd
from marts.fct_claim
group by 1 order by 2 desc;
```

The original brief is preserved at [`docs/ASSIGNMENT.md`](docs/ASSIGNMENT.md).

---

## Contents

- [Running it](#running-it)
- [How to query it](#how-to-query-it)
- [The data model](#the-data-model)
- [The five decisions that shaped it](#the-five-decisions-that-shaped-it)
- [Data quality: quarantine, not drop](#data-quality-quarantine-not-drop)
- [Why this stack — and why not the others](#why-this-stack--and-why-not-the-others)
- [Tests](#tests)
- [What the data says](#what-the-data-says)
- [What breaks at 100×](#what-breaks-at-100)
- [What I'd do with more time](#what-id-do-with-more-time)

---

## Running it

| command | what it does |
|---|---|
| `make setup` | creates `.venv`, installs pinned dependencies |
| `make pipeline` | ingestion + `dbt build` (models **and** tests) |
| `make notebook` | rebuilds and executes `analysis/analysis.ipynb` |
| `make test` | pytest + dbt unit tests |
| `make query` | opens the DuckDB shell on the warehouse |
| `make rebuild` | drops the database and rebuilds from scratch |

Without `make` (Windows), every target is one line — `python -m pipeline.run`
does the whole build.

**Source directories are flags**, as the brief asks. They default to
`sample-data/`:

```bash
python -m pipeline.run \
  --claims path/to/claims --reverts path/to/reverts --lookups path/to/lookups \
  --pharmacies path/to/pharmacies --partners path/to/partners \
  --database out/warehouse.duckdb
```

Useful extras: `--skip-land` (iterate on SQL without re-ingesting),
`--select marts+` (rebuild a subtree), `--refresh-nadac` (force a fresh
download).

### NADAC

`pipeline/nadac.py` resolves the current CSV distribution from the CMS catalog
API (the filename carries a date and changes weekly, so a hardcoded link would
rot), downloads ~83 MB once, and caches it in `data/raw/nadac/`. **Every run
after the first is fully offline** — which matters because the live sessions
start with the machine already loaded.

The download writes to a `.part` file and renames on completion, so an
interrupted download can't leave a truncated CSV that the next run treats as
valid.

---

## How to query it

Four schemas, in dependency order:

| schema | materialisation | what's in it |
|---|---|---|
| `raw` | tables | exactly what landed, every column VARCHAR |
| `staging` | views | typed, cleaned, each row tagged with its rejection reason |
| `intermediate` | views | the three business decisions (cost, attribution, fee split) |
| `marts` | tables | what you query |

Schemas are named plainly — `marts.fct_claim`, not dbt's default
`main_marts.fct_claim`. That's a deliberate override
(`macros/generate_schema_name.sql`): the default exists to stop developers
overwriting each other in a shared warehouse, and here everyone has their own
local file.

### Opening a session

```bash
make query                      # or: python analysis/shell.py
```

A SQL prompt on the warehouse. `.tables` lists everything, `.schema <table>`
gives columns and types, statements end at `;`.

Or from Python, which is what the notebook does:

```python
from analysis.wls import q
q("select partner, net_wls_revenue_cents from marts.mart_partner_performance")
```

Both open the database **read-only**, and that is not a detail. DuckDB allows one
writer per file: a shell left open on a read-write connection blocks
`python -m pipeline.run` with a lock error. Read-only means you can query while
the pipeline rebuilds underneath you.

Any DuckDB 1.5 client works too — DBeaver, the `duckdb` CLI binary, a
`duckdb.connect(..., read_only=True)` of your own. There is nothing proprietary
in the file, it's just `data/duckdb/warehouse.duckdb`.

### The marts

| table | grain | use it for |
|---|---|---|
| **`fct_claim`** | one valid claim | almost everything |
| `fct_lookup` | one price lookup | the funnel, conversion |
| `dim_pharmacy` | one pharmacy | NPI → chain |
| `dim_partner` | one partner | commercial terms |
| `dim_drug` | one NDC | drug attributes, brand/generic |
| `dim_date` | one day | time series with no invisible gaps |
| `dq_rejects` | one rejected record | what we lost and why |
| `mart_partner_performance` | one partner | the commercial summary |
| `mart_drug_economics` | one NDC | margin levers per drug |
| `mart_funnel_daily` | day × partner × channel | the funnel over time |

### Two conventions worth knowing before you write a query

**1. Money is integer cents.** `price_cents`, `pbm_fee_cents`,
`net_wls_revenue_cents`. Summing 41k floating-point claims puts the rounding
error in the third decimal, and two people with different `GROUP BY`s get
different totals. Integers make the sum exact. Divide by 100 only to display.

The one exception is `unit_cost_usd`, which stays DOUBLE — NADAC publishes rates
to five decimals, and rounding to the cent *before* multiplying by quantity
loses ~1% per claim.

**2. `net_*` columns already net out reversals.** A reversed claim is treated as
if the fill never happened, so `net_price_cents`, `net_wls_revenue_cents` and
`net_claim_count` are zero on reversed rows.

```sql
-- Right, with no filter to remember:
select sum(net_wls_revenue_cents) from marts.fct_claim;

-- Gross, for measuring what was reversed:
select sum(wls_net_fee_cents) filter (where is_reverted) from marts.fct_claim;
```

The design intent is that the *easy* query is the *correct* one. Forgetting a
`where` clause should not silently inflate revenue.

### The analysis notebook

[`analysis/analysis.ipynb`](analysis/analysis.ipynb) ships **with its outputs
executed** — it reads in the browser without installing anything. It answers both
email questions and doubles as a live-session scratchpad.

`analysis/wls.py` is the toolkit behind it: `q()` for SQL → DataFrame,
`tables()` / `columns()` for orientation, and pre-styled `bar` / `stacked_bar` /
`line` / `scatter` / `heatmap` / `kpi`. Everything that is a styling decision is
already settled there, so a live question only costs the SQL.

Cell sources live in `analysis/build_notebook.py`, not in the `.ipynb` — a
notebook with outputs is unreadable in a diff. Edit the `.py` and run
`make notebook`.

---

## The data model

```
                    ┌──────────────┐
                    │  dim_date    │
                    └──────┬───────┘
┌─────────────┐            │            ┌──────────────┐
│ dim_partner ├────────────┼────────────┤  dim_drug    │
└──────┬──────┘            │            └──────┬───────┘
       │            ┌──────▼───────┐           │
       ├────────────►  fct_claim   ◄───────────┤
       │            │ (41,400 rows)│           │
       │            └──────▲───────┘           │
       │                   │ claim_id          │
       │            ┌──────┴───────┐           │
       └────────────►  fct_lookup  ◄───────────┘
                    │(176,721 rows)│
                    └──────┬───────┘
                    ┌──────▼───────┐
                    │dim_pharmacy  │
                    └──────────────┘
```

Two facts at two grains, four conformed dimensions, joined on natural keys
(`ndc`, `npi`, `partner`) rather than generated surrogates — natural keys are
what people type in a live session, and there is no key-collision risk at this
scale.

**`fct_claim` is a wide fact, not a thin one.** `chain`, `partner`, `channel` and
`drug_class` are denormalised onto it alongside the foreign keys. The dimensions
still exist and hold the long-tail attributes.

That's a deliberate trade against textbook star schema, and the reason is the
usage context. Questions arrive spoken, on a shared screen. "Revenue by chain
last month" has to be one `select … group by` against one table. In a strict
star it's three joins written under time pressure — and the expensive failure
mode isn't typing slowly, it's getting a join wrong and presenting a plausible,
false number.

The cost is that `chain` lives in two places and could drift. With a full reload
every run, both sides are rebuilt from the same source in the same run, so they
don't.

---

## The five decisions that shaped it

### 1. The claim event has no partner — attribution runs through the lookup

The claim schema is `id, npi, ndc, price, quantity, pbm_fee, timestamp`. There is
no partner on it. **Commercial attribution exists only through the lookup that
converted**, which means the funnel isn't a side report — it's the critical path
of revenue, and every fee split depends on it.

Verified on the sample: no claim has two lookups pointing at it, so the
relationship is 1:1 and `partner` can be denormalised onto the fact safely. There
is a `qualify` guard anyway, with `attributing_lookup_count` exposing any future
violation.

823 analysable claims have no lookup at all (1,539 before quarantine). They
become **`direct`** — a named member of `dim_partner`, not a NULL. In a `left
join` against NULL, every direct claim silently disappears from `group by
partner` and the fact total stops matching the sum of its parts, with no warning.

### 2. NADAC cost is as-of the fill date

NADAC is a rolling series of weekly snapshots — the same NDC appears 33 times in
2026 alone. "The cost of this drug" is not a number, so a choice had to be made.

**Chosen: the last price in force on the date the claim was filled**, resolved
with DuckDB's `ASOF JOIN`.

- **Why:** it's the cost the market was charging on the day of the transaction,
  so March margin uses March cost. And it's *stable* — reprocessing in six months
  returns the same numbers, which is not true of "latest snapshot".
- **What it costs:** a more expensive join than a single-value lookup, and claims
  predating an NDC's first snapshot don't match. There's a documented fallback to
  the earliest available snapshot, labelled in `cost_basis`. On this data it
  fires **zero** times — NADAC effective dates reach back to 2025-01-01 and our
  claims start 2026-03-01 — but the label means a future run that needs it says
  so rather than hiding it.
- **Why `ASOF JOIN` and not a window function:** the alternative (cross every
  claim against all snapshots for its NDC, rank, keep the first) materialises the
  intermediate product before filtering. ASOF resolves it as an ordered search,
  and it says what it's doing in its own name.

**I measured what the choice is worth.** Against "use the latest snapshot for
everything", total acquisition cost differs by only **−0.31%** in aggregate. At
the individual drug level it matters much more: NDC `45802013430` ranges from
$0.86 to $1.72 per unit within 2026 — using one number for the year halves or
doubles that drug's margin depending on which end you land on. So the honest
summary is: the choice barely moves the portfolio total, and it materially moves
per-drug analysis, which is where the margin questions actually get asked.

**Coverage:** 46 of 49 NDCs match. The three that never match (`77777000303`,
`88888000202`, `99999000101`) are deliberate in the sample data; they cover 571
claims which stay in the fact with `has_cost_match = false` and
`pharmacy_margin_cents = NULL`. NULL rather than zero, so `avg()` and `sum()`
skip them instead of treating unknown margin as zero margin.

**What I took from NADAC:** 9 of 12 columns. Cost and dates for the join;
`classification_for_rate_setting` and `corresponding_generic_drug_nadac_per_unit`
because they carry the margin question; description/unit/OTC as labels. Dropped
`explanation_code`, `pharmacy_type_indicator` and the generic effective date —
nothing in scope uses them.

### 3. A reversal is a column on the claim, not its own fact

The brief says a reversed claim is treated as if the fill never happened. So
`is_reverted`, `reverted_at` and `hours_to_revert` live on `fct_claim`.

The Kimball name for this shape is an **accumulating snapshot fact**: one row per
claim, tracking a lifecycle with more than one milestone — the fill, and if it
comes, the reversal. The row is rewritten when the later milestone lands.

If reverts were a separate fact, every money question would be an anti-join
("claims not appearing in `fct_revert`") — precisely the join people forget under
time pressure, producing inflated revenue that looks right. As a column, the same
question is a `where`, and the `net_*` columns make the safe default automatic.

Reversal *timing* isn't lost — "how long do reversals take" is still a
single-table query. If a claim were ever reverted twice the earliest reversal
wins and `revert_event_count` records that there were two; no claim in this
sample reaches that model with two reverts, since the 26 duplicate revert ids are
quarantined in staging.

**What it costs: history restates.** `net_*` is measured at `filled_date`, and
712 of the 2,739 reversals (26%) land in a different month than the fill they
cancel. A claim filled in March and reverted in July removes revenue *from
March*, on the next run. March is therefore "March as we understand it today",
not "March as we reported it in April" — the right default for the economics of a
cohort of fills, but it means the warehouse has no "revenue as reported at month
close". That would be a snapshot of `fct_claim` taken at a date, and it doesn't
exist here.

Because of that, `mart_funnel_daily` never says `reverted_claims`. It carries
**two** measures on two different dates, and they only agree over the full period:

| column | keyed on | answers |
|---|---|---|
| `claims_filled_then_reverted` | `filled_date` | of the fills we drove that day, how many stuck — the cohort measure, and what `cohort_reversal_rate` divides |
| `reverts_on_day` (+ `revenue_reversed_cents`) | `reverted_at` | what we actually handed back that day — the activity measure |

March: 524 by cohort, 358 by activity. July: 595 vs 800.

### 4. Money is integer cents, resolved at the last possible moment

Covered under [conventions](#two-conventions-worth-knowing-before-you-write-a-query).
The subtle part is *where* the conversion happens: NADAC's per-unit rate stays
DOUBLE through staging and only becomes cents after being multiplied by quantity,
because $0.26341 × 30 = $7.90 but $0.26 × 30 = $7.80.

### 5. The fee split, and a cap that turned out never to fire

`fee_cents` is a flat cut; `fee_percentage` is a proportional share, normalised
from the 0–100 scale it arrives on to a 0–1 rate once, in staging. `direct`
claims have no one to pay, so White Lodge keeps the whole fee.

`fee_cents = 0` (Airflow Rx) is a *zero-commission partner*, not missing data.
The code tests `is not null` rather than truthiness — a naive `coalesce` would
route that partner into the percentage branch.

Then the interesting part. 471 raw claims have a `pbm_fee` below $1.00, and Kafka
Rx charges a flat $1.00. That reads as a landmine: payout exceeding the fee
collected, negative revenue. So I wrote the cap — `least(fee, pbm_fee)` — and
instrumented it with `partner_fee_was_capped` to size the damage.

**It fires zero times.** Of those 471, 460 are from pharmacies outside the
reference data and land in quarantine before reaching the calculation; the other
11 are duplicates, non-positive amounts and one unreadable timestamp. The lowest
`pbm_fee` in the analysable population is $1.08. The conflict was an artefact of
dirty data, not a commercial rule.

The cap stays: it's a cheap invariant against a future batch, and the flag column
is what turned "I don't think this happens" into "I measured it, it's zero rows."
It is also a *modelling* decision, not a known fact — the real contract may have
White Lodge eat the difference. Swapping `least(...)` for the raw value is one
line, and `sum(capped_shortfall_cents)` already answers "how much would that
change".

---

## Data quality: quarantine, not drop

**No row disappears.** Every staging model tags each row with `dq_reject_reason`
— NULL when clean. Downstream models filter on NULL; `marts.dq_rejects` collects
the rest with the reason, the source file, and the original payload.

```sql
select source_table, reject_reason, count(*)
from marts.dq_rejects group by 1, 2 order by 3 desc;
```

| source | reason | rows |
|---|---|---:|
| claims | `unknown_npi` | 460 |
| claims | `duplicate_claim_id` | 281 |
| claims | `non_positive_amount` | 279 |
| claims | `missing_required_field` | 148 |
| claims | `unparseable_timestamp` | 146 |
| claims | `unparseable_number` | 126 |
| lookups | `unparseable_timestamp` | 844 |
| reverts | `orphan_claim_id` | 53 |
| reverts | `duplicate_revert_id` | 26 |
| reverts | `missing_required_field` | 13 |
| reverts | `unparseable_timestamp` | 11 |

**41,400 of 42,840 claims are analysable — 96.6% coverage.** A dbt test asserts
`landed = kept + rejected`, so if someone adds a filter to an intermediate model
and forgets to record a reason, the arithmetic stops balancing in CI rather than
in a meeting three weeks later.

`raw_payload` keeps what arrived, so "unreadable number" is auditable down to the
literal `"one hundred"` without going back to the JSON.

### The policy, and the judgement calls in it

The `CASE` ordering *is* the policy: most structural defect first. A row with a
missing field *and* an unknown NPI reports as `missing_required_field`, because
that's what the data producer has to fix first. Unit tests pin the ordering, so
reordering breaks a named test instead of silently reclassifying thousands of
rows.

Four calls worth defending:

- **Spelled-out numbers (`"one hundred"`, `"thirty"`) are rejected, not
  translated.** Translating would be an endless rule set reconstructing a value I
  would be guessing at. 126 rows, 0.3%.
- **Duplicate claim ids quarantine *both* sides.** I checked: none of the 140
  duplicated UUIDs is an identical copy — they are entirely different claims
  competing for one id. There is no way to pick a winner without inventing a
  criterion, and picking wrong corrupts revenue silently.
- **Missing partner on a lookup becomes `unknown`, not a rejection.** All 886 of
  them failed to convert, so they're real lookup events that merely lost
  attribution. Dropping them would shrink the funnel denominator and inflate
  everyone else's conversion rate — trading incomplete data for a wrong number.
- **Channel is normalised, not validated.** The brief calls the list open
  ("e.g. integration, website"), so `fax`, `phone` and `APP` are legitimate
  low-volume channels; `APP` is just uppercase. Rejecting on unknown channel
  would be staging deciding which lines of business exist.

Reversals pointing at claims we don't have (53) are logged rather than applied —
applying them would be a no-op, ignoring them silently would hide an ingestion
gap.

---

## Why this stack — and why not the others

**DuckDB.** The whole dataset is 220k events and a 1M-row reference table. That's
a laptop-scale problem, and DuckDB is an embedded engine with real analytical SQL
— window functions, `ASOF JOIN`, `QUALIFY`, native JSON and CSV readers. The
warehouse is a single 41 MB file: clone, run, query.

- *Not Postgres in Docker* — a container to start, a port to manage, a server to
  keep alive, for a single-user analytical workload. And Postgres has no
  `ASOF JOIN`.
- *Not SQLite* — no window functions worth the name, no columnar execution, no
  direct file readers. I'd be writing Python to do what SQL should do.
- *Not Spark, BigQuery, Snowflake* — out of scope per the brief, and genuinely
  wrong here: cluster overhead for data that fits in memory, or a cloud
  dependency for something that must run cold on a laptop.

**dbt.** The value isn't templating, it's that the DAG, the tests and the
documentation are the same artifact as the transformation. `dbt build` interleaves
models and tests, so a model whose test fails doesn't propagate bad data
downstream. And in Part 3 I'll be editing a model live: `ref()` means I change one
file and the DAG re-resolves rather than me hunting for the next script that
reads the table I just changed.

- *Not plain SQL scripts* — I'd hand-maintain execution order, and every test
  would be a script somebody remembers to run.
- *Not pandas/Polars transformations* — the logic here is joins, windows and
  aggregations. That's SQL's job, and it keeps the transformation legible to
  anyone who reads SQL rather than to whoever knows the DataFrame API.
- *Not SQLMesh* — genuinely appealing (real column-level lineage, virtual data
  environments), but dbt is what a data team is most likely to already read
  fluently, and this repo gets read by other people.

**Python only for landing.** Fetch NADAC, drop raw files into `raw.*` tables. No
transformation logic lives in Python, so there's exactly one place to look when a
number is wrong.

- *Not Airflow / Dagster / Prefect* — four steps, one process, no schedule, no
  partial retry, no SLA. An orchestrator adds a service to keep alive without
  making anything easier to run or change. `dbt build` already resolves the DAG.

**requirements.txt, not Poetry/uv.** Seven direct dependencies. Pinned versions,
and no package manager to install before you can install the packages.

**No dbt packages.** `dbt_utils` would be used for exactly one test, so that test
is six lines of local macro instead. Adding it would turn `git clone && run` into
`git clone && dbt deps && run`, with a network call that can fail on the morning
of a live session.

---

## Tests

`make pipeline` builds 20 models and runs **75 dbt tests** alongside them (a
95-node build); `make test` adds 9 pytest tests. They are concentrated where the
brief says it matters — the fee split, reversal handling, malformed records — not
spread for coverage.

**dbt unit tests (13)** run the *real* model SQL against fabricated inputs, so
editing a model is seen by its tests. They cover every branch of the fee split
(flat, percentage, rounding, the cap, `direct`, the zero-fee partner, quarantined
input), reversal deduplication, and every data-quality classification including
precedence.

**Singular tests (4)** assert invariants:

- the split reconciles: `partner_fee + wls_net = pbm_fee`, exactly, every row
- the partner never takes more than we collected, and net revenue is never
  negative
- reversed claims carry zero in every `net_*` column
- **no claim is lost silently**: `raw = fct_claim + dq_rejects`

**Schema tests (58)** cover uniqueness and not-null on every key, referential
integrity from both facts into all four dimensions, and accepted values on every
enumerated column — including the rejection reasons, so adding a new one without
documenting it fails the build.

**pytest (9)** covers the ingestion layer, and specifically the landing decision:
NDC keeps its leading zeros, `"one hundred"` survives as text, a batch missing a
field still produces the column, `fee_cents = 0` stays distinct from empty. Plus
NADAC URL resolution and the offline-cache guarantee — none of them touch the
network.

---

## What the data says

Numbers from the current build, for orientation. The reasoning behind them is in
[`analysis/analysis.ipynb`](analysis/analysis.ipynb) and in the submission email.

**Scale.** 41,400 analysable claims, Mar–Jul 2026, $200.7M in net GMV across 37
pharmacies in 7 chains. White Lodge collected $283,914 in pbm_fee, paid out
$100,269 to partners, and retained **$183,645**.

**The funnel.** 176,721 lookups → 23.0% conversion → 6.6% reversal rate.
Reversals cost $13,127, 6.7% of potential revenue, at a median of 9.5 days to
reverse.

**Channel matters more than it looks.** `integration` converts at **44.8%**
versus **14.7%** for `website` — a 3× gap on the largest single volume driver.

**Partner value depends entirely on which measure you use:**

| partner | terms | claims | payout | White Lodge keeps | retention |
|---|---|---:|---:|---:|---:|
| Kafka Rx | $1.00 flat | 10,534 | $9,971 | **$63,051** | 86% |
| Hudi Rx | 50% | 11,104 | $37,657 | $37,606 | 50% |
| Druid Rx | 20% | 5,789 | $7,806 | $31,226 | 80% |
| Iceberg Rx | $0.20 flat | 3,536 | $665 | $23,779 | 97% |
| Airflow Rx | $0.00 flat | 1,715 | $0 | $11,242 | 100% |
| Flink Rx | 80% | 7,899 | $44,169 | $11,042 | 20% |

Hudi Rx drives the most claims. Kafka Rx produces the most revenue *and* the best
conversion rate (53.5%). Flink Rx converts nearly as well (48.4%) with the worst
economics of the six — it takes $44k to leave $11k, so its second-highest
lookup-to-claim rate buys White Lodge almost nothing. Which is exactly why
`mart_partner_performance` pins "value" to
`net_wls_revenue_cents`: without that definition written down, two people answer
"who is our best partner" and name different partners.

**The margin finding.** The pbm_fee is effectively flat — around $7–9 — no matter
what the claim is worth:

| claim value | claims | net GMV | fee collected | take rate |
|---|---:|---:|---:|---:|
| up to $100 | 24,143 | $0.6M | $180,535 | 32.15% |
| $100 – $10k | 12,757 | $14.5M | $86,914 | 0.598% |
| above $10k | 1,761 | $185.6M | $16,465 | **0.0089%** |

1,761 claims carry 92% of the GMV and generate 6% of the fee. Revenue is
decoupled from the value being intermediated. The top 1% of claims alone are 58%
of GMV — specialty biologics like Tremfya at ~$7,350 per unit, which are real,
not data errors.

Secondary lever: NADAC's generic-equivalent pricing puts **$29.6M** of
acquisition cost inside brand fills that have a published generic — Epclusa alone
is $24.3M.

---

## What breaks at 100×

At 100× (4.2M claims, 17.7M lookups, ~30 GB of NADAC history) most of this holds
and three things don't.

**What holds.** DuckDB handles tens of millions of rows on a 10-core box
comfortably; it's columnar, it spills to disk, and it parallelises scans across
cores. The star schema, the grain choices and the cents convention are all
scale-independent. `dbt build` currently takes ~4 seconds of the 12.

**1. Full reload stops being free.** Right now every run rebuilds everything, and
that's the right call at 12 seconds. At 100× the claim staging and `fct_claim`
become incremental models partitioned on `filled_date`, with a lookback window
for late-arriving reverts (reversals lag the fill by a median of 9.5 days, so a
30-day window covers it). `dq_rejects` stays a full rebuild — it's small and you
want its history.

**2. Landing 17M lookups through a single Python process is the wrong shape.**
The JSON reads would move to Parquet conversion on the way in — partitioned by
event date, written once, read many times. DuckDB reads a partitioned Parquet
directory with predicate pushdown, so most queries stop touching most of the
data. Landing stays Python; the storage format changes.

**3. The NADAC as-of join is the part I'd watch.** `ASOF JOIN` against 30 GB of
snapshot history is the one operation whose cost grows super-linearly with both
sides. Two mitigations, in order: restrict the NADAC staging model to the NDCs we
actually dispense (49 out of 26,000 today — a 500× reduction that costs nothing
analytically), and collapse the weekly snapshots into effective-dated ranges
(`valid_from` / `valid_to`) so the join hits a much smaller interval table.

**What I'd stop doing in the notebook.** The price-vs-fee scatter pulls every
non-reverted claim into the browser — 41k points is fine, 4M is not, and it would
need `using sample` or 2D binning. And `select *` in the scratch cells: a
columnar engine only pays for the columns you name, so at 100× explicit
projection stops being a style preference.

**What wouldn't change.** I would not reach for Spark. 4M claims is still a
single-node problem, and the moment there's a cluster there's a cluster to
operate. The move after DuckDB-on-one-box is DuckDB on a bigger box, then a
managed warehouse — not a distributed engine.

---

## What I'd do with more time

Deliberately left out, in rough priority order:

**Reference-data history (SCD-2).** `dim_pharmacy` and `dim_partner` are full
reloads showing current state. If a pharmacy changes chain, its entire history is
reattributed to the new one; if a partner renegotiates terms, historical fee
splits get recalculated at the new rate. That second one is the real problem —
it silently rewrites reported revenue. The fix is effective-dated dimensions
(`valid_from` / `valid_to`) with the fact carrying the terms in force at fill
time. I'd implement it as a dbt snapshot on `stg_partners` first, because
commercial terms are where the damage is.

**Freshness and volume monitoring.** Right now a batch that silently arrives with
half the usual claims passes every test. `dbt source freshness` plus a row-count
anomaly test on the daily fact would catch it.

**Pin the NADAC file.** The cache stores whatever was current when it was
downloaded. For truly reproducible numbers across machines, the run should record
the NADAC `as_of_date` it used, and ideally pin it. Right now two people who
downloaded in different weeks get slightly different costs — a real reproducibility
gap, and the honest reason it isn't fixed is that it doesn't bite at this scale.

**Partner economics as a scenario model.** Everything here is descriptive. The
question Dale actually wants answered is "what happens if I move Flink Rx from
80% to 50%", which means a small parameterised model over the existing fact.
That's maybe 30 lines of SQL and would make the renegotiation conversation
concrete.

**Unit price consistency checks.** The schema says `price = unit_price ×
quantity` but we never see `unit_price`, so it can't be validated. Comparing
implied unit price against NADAC would surface pricing anomalies — I built the
join that would let you do it (`unit_cost_usd` is on the fact) but didn't build
the check.

**Lookup deduplication semantics.** Every lookup is currently a distinct funnel
event. If a patient checks the same drug three times in an hour, that's arguably
one intent, and the conversion rate is understated. I'd want to know the product
definition before modelling it, so I left it alone rather than inventing a
session window.
