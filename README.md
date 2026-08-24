# White Lodge Savings — mini-warehouse

A local, queryable warehouse over the pharmacy event streams — claims, reversals
and price lookups — enriched with CMS NADAC acquisition costs.

**DuckDB + dbt + a Python ingestion layer.** One command builds it end to end in
about 11 seconds, running 99 tests alongside the 23 models it builds.

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

> Each model file carries its own reasoning in a header comment. This README is
> the map; the model is the argument. Where they'd repeat each other, this file
> points instead of restating.

---

## Running it

| command | what it does |
|---|---|
| `make setup` | creates `.venv`, installs pinned dependencies |
| `make pipeline` | ingestion + `dbt build` (models **and** tests) |
| `make test` | pytest + dbt unit tests |
| `make notebook` | re-executes `analysis/analysis.ipynb` in place |
| `make query` | opens a read-only SQL shell on the warehouse |
| `make rebuild` | drops the database and rebuilds from scratch |

Without `make` (Windows), every target is one line — `python -m pipeline.run`
does the whole build.

**Source directories are flags**, as the brief asks, defaulting to `sample-data/`:

```bash
python -m pipeline.run \
  --claims path/to/claims --reverts path/to/reverts --lookups path/to/lookups \
  --pharmacies path/to/pharmacies --partners path/to/partners \
  --database out/warehouse.duckdb
```

Useful extras: `--skip-land` (iterate on SQL without re-ingesting),
`--select marts+` (rebuild a subtree), `--refresh-nadac` (force a fresh download).

**NADAC** is resolved from the CMS catalog API rather than a hardcoded link (the
filename carries a date and changes weekly), downloaded once (~83 MB) and cached
in `data/raw/nadac/`. Every run after the first is fully offline. The download
writes to a `.part` file and renames on completion, so an interrupted download
can't leave a truncated CSV that the next run treats as valid.

---

## How to query it

Four schemas, in dependency order:

| schema | materialisation | what's in it |
|---|---|---|
| `raw` | tables | exactly what landed, every column VARCHAR |
| `staging` | views | typed, cleaned, each row tagged with its rejection reason |
| `intermediate` | views | the rules that need a second table: scope, then cost, attribution, fee split, reversal |
| `marts` | tables | what you query |

Schemas are named plainly — `marts.fct_claim`, not dbt's default
`main_marts.fct_claim`. That override (`macros/generate_schema_name.sql`) exists
because the default is there to stop developers overwriting each other in a
shared warehouse, and here everyone has their own local file.

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

**1. Money is integer cents.** Summing 41k floating-point claims puts the
rounding error in the third decimal, and two people with different `GROUP BY`s
get different totals. Integers make the sum exact. Divide by 100 only to display.

The one exception is `unit_cost_usd`, which stays DOUBLE — NADAC publishes rates
to five decimals, and rounding to the cent *before* multiplying by quantity loses
~1% per claim ($0.26341 × 30 = $7.90; $0.26 × 30 = $7.80).

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
`where` should not silently inflate revenue.

### Opening a session

`make query` (or `python analysis/shell.py`) gives a SQL prompt: `.tables`,
`.schema <table>`, statements end at `;`. Any DuckDB 1.5 client works too — the
file is just `data/duckdb/warehouse.duckdb`.

**You can rebuild the warehouse without closing anything**, and that took a
deliberate fix. DuckDB allows one writer per file, and its *read* lock excludes
that writer too — so a notebook or shell holding an open read-only connection
makes `python -m pipeline.run` die with `IO Error: file is already in use`. Not
theoretical: it's the first thing that bites, and it bites exactly during the
edit-a-model → rebuild → re-query loop.

So neither client holds a connection. `wls.q()` and the shell open a read-only
connection per statement and close it, holding the lock for the duration of a
query instead of the duration of a kernel. Measured cost: ~13 ms of setup against
~250 ms for a real group-by on `fct_claim`. A kernel you forgot about in another
window costs you nothing.

The lock is exclusive in both directions, so the mirror case still exists: while
the pipeline is writing, a reader can't open the file either. That window is the
~10 s of a build, so a query issued inside it **waits and then runs** rather than
raising — a cell that takes a moment longer beats a traceback with an audience.
Verified end to end: querying in a loop across a full `pipeline.run`, 60 queries,
0 failures, 2 of them waiting 1.5 s and 5.3 s.

[`analysis/analysis.ipynb`](analysis/analysis.ipynb) ships with its outputs
executed — it reads in a browser without installing anything — and doubles as the
live-session scratchpad. `analysis/wls.py` behind it is deliberately four query
helpers and two formatters; **charts are plain `plotly.express`**, because the
fastest chart to change live is the one whose API the room already knows. The
`.ipynb` is the source: edit it in Jupyter, and `make notebook` re-executes it.

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
what people type in a live session, and there's no collision risk at this scale.

**`fct_claim` is a wide fact, not a thin one.** `chain`, `partner`, `channel` and
`drug_class` are denormalised onto it alongside the foreign keys; the dimensions
still exist and hold the long-tail attributes.

That's a deliberate trade against textbook star schema, and the reason is the
usage context. Questions arrive spoken, on a shared screen. "Revenue by chain
last month" has to be one `select … group by` against one table. In a strict star
it's three joins written under time pressure — and the expensive failure mode
isn't typing slowly, it's getting a join wrong and presenting a plausible, false
number.

The cost is that `chain` lives in two places and could drift. With a full reload
every run, both sides are rebuilt from the same source in the same run, so they
don't.

---

## The five decisions that shaped it

Each one is argued in full in the header of the model named beside it.

### 1. The claim event has no partner — attribution runs through the lookup
*→ `models/intermediate/int_claim_attribution.sql`*

The claim schema is `id, npi, ndc, price, quantity, pbm_fee, timestamp`. No
partner. **Commercial attribution exists only through the lookup that
converted**, which makes the funnel the critical path of revenue rather than a
side report.

Verified: no claim has two lookups pointing at it, so `partner` denormalises onto
the fact safely (there's a `qualify` guard anyway, with
`attributing_lookup_count` exposing any future violation). 823 analysable claims
have no lookup at all — they become **`direct`**, a named member of
`dim_partner`, not a NULL. Against NULL, every direct claim silently vanishes
from `group by partner` and the fact total stops matching the sum of its parts.

### 2. NADAC cost is as-of the fill date
*→ `models/intermediate/int_claim_cost.sql`*

The same NDC appears 33 times in 2026 alone, so "the cost of this drug" is not a
number. **Chosen: the last price in force on the fill date**, resolved with
DuckDB's `ASOF JOIN` — it's the cost the market was charging that day, and it's
stable, which "latest snapshot" is not.

**I measured what the choice is worth.** Against "latest snapshot for
everything", total acquisition cost differs by **−0.31%** in aggregate — but NDC
`45802013430` ranges from $0.86 to $1.72 per unit within 2026, so one number for
the year halves or doubles that drug's margin. The choice barely moves the
portfolio and materially moves per-drug analysis, which is where margin questions
get asked.

A claim with no snapshot on or before the fill date gets **no cost at all**:
`cost_basis = 'no_match'`, every cost column NULL. 46 of 49 NDCs match; the three
that don't are deliberate in the sample and cover 571 claims, which stay in the
fact with `pharmacy_margin_cents = NULL`. NULL and not zero, so `avg()` and
`sum()` skip them rather than treating unknown margin as zero margin.

**What I took from NADAC:** 9 of 12 columns — cost and dates for the join;
`classification_for_rate_setting` and the generic-equivalent price because they
carry the margin question; description/unit/OTC as labels. Nothing in scope uses
the other three.

### 3. A reversal is a column on the claim, not its own fact
*→ `models/intermediate/int_claim_revert.sql`, `models/marts/fct_claim.sql`*

`is_reverted`, `reverted_at` and `hours_to_revert` live on `fct_claim`. The
Kimball name for the shape is an **accumulating snapshot fact**: one row per
claim, tracking a lifecycle with more than one milestone, rewritten when the
later one lands.

If reverts were a separate fact, every money question would be an anti-join
("claims not appearing in `fct_revert`") — precisely the join people forget under
time pressure, producing inflated revenue that looks right.

**What it costs: history restates.** `net_*` is measured at `filled_date`, and
712 of the 2,739 reversals (26%) land in a different month than the fill they
cancel. A claim filled in March and reverted in July removes revenue *from
March*, on the next run. That's the right default for the economics of a cohort
of fills, but it means there is no "revenue as reported at month close" here —
that would be a snapshot of `fct_claim` taken at a date.

So `mart_funnel_daily` never says `reverted_claims`. It carries two measures on
two dates, and they only agree over the full period:

| column | keyed on | answers |
|---|---|---|
| `claims_filled_then_reverted` | `filled_date` | of the fills we drove that day, how many stuck — the cohort measure |
| `reverts_on_day` (+ `revenue_reversed_cents`) | `reverted_at` | what we actually handed back that day |

March: 524 by cohort, 358 by activity. July: 595 vs 800.

### 4. Money is integer cents, resolved at the last possible moment
*→ `macros/to_cents.sql`*

Covered under [conventions](#two-conventions-worth-knowing-before-you-write-a-query).
The subtle part is *where* the conversion happens — after multiplying by
quantity, never before.

### 5. The fee split, and a cap that turned out never to fire
*→ `models/intermediate/int_claim_economics.sql`*

`fee_cents` is a flat cut; `fee_percentage` is a proportional share, normalised
from 0–100 to a 0–1 rate once, in staging. `direct` claims have no one to pay, so
White Lodge keeps the whole fee. `fee_cents = 0` (Airflow Rx) is a
*zero-commission partner*, not missing data — the code tests `is not null` rather
than truthiness, because a naive `coalesce` would route it into the percentage
branch.

Then the interesting part. 471 raw claims have a `pbm_fee` below $1.00 and Kafka
Rx charges a flat $1.00 — which reads as payout exceeding fee, negative revenue.
So I wrote the cap (`least(fee, pbm_fee)`) and instrumented it with
`partner_fee_was_capped` to size the damage.

**It fires zero times.** 460 of those 471 are pharmacies outside the reference
data and land in quarantine first; the other 11 are duplicates, non-positive
amounts and one unreadable timestamp. The lowest `pbm_fee` in the analysable
population is $1.08. The conflict was an artefact of dirty data, not a commercial
rule. The cap stays as a cheap invariant, and the flag is what turned "I don't
think this happens" into "I measured it, it's zero rows". It's also a *modelling*
decision, not a known fact — swapping `least(...)` for the raw value is one line,
and `sum(capped_shortfall_cents)` already answers "how much would that change".

---

## Data quality: quarantine, not drop

**No row disappears** — and rows leave the pipeline at two different points, for
two kinds of reason that need different follow-up:

| | where | column | what it means |
|---|---|---|---|
| **defect** | `staging` | `dq_reject_reason` | judged from the row itself (or its batch): unreadable number, impossible timestamp, one UUID on two claims |
| **exclusion** | `intermediate` | `scope_exclusion_reason` | needs a second table: a claim whose NPI isn't in the pharmacy reference, a revert whose claim we don't have |

**Staging reads its source and nothing else.** No `ref()` between staging models,
which keeps the layer a flat fan-out you can rebuild in any order, and keeps its
unit tests fabricating rows for one source instead of three. The relational rules
live in `int_claims_scoped`, `int_reverts_scoped` and `int_lookups_resolved`.

The semantic reason matters more than the layering one. `"one hundred"` in a
price field is **malformed** — somebody upstream has to fix it and the row never
returns. A claim from an unlisted pharmacy is **out of scope** — a perfectly good
claim carrying real revenue, and all 460 come back by themselves the day that NPI
is onboarded. Sharing one column made "how much of what I rejected is
recoverable?" unanswerable. `marts.dq_rejects` unions both layers and answers it:

```sql
select defect_class, reject_reason, count(*)
from marts.dq_rejects group by 1, 2 order by 3 desc;
```

| class | rows | reasons | who fixes it |
|---|---:|---|---|
| `malformed` | 1,567 | `unparseable_timestamp` (1,001), `missing_required_field` (161), `unparseable_number` (126), `non_positive_amount` (279) | the data producer |
| `out_of_scope` | 513 | `unknown_npi` (460), `orphan_claim_id` (53) | nobody — it returns on its own |
| `ambiguous` | 307 | `duplicate_claim_id` (281), `duplicate_revert_id` (26) | a human, once |

`detected_in` names the layer that stopped the row, so changing a rule starts
with knowing which file to open. `raw_payload` keeps what arrived, so "unreadable
number" is auditable down to the literal `"one hundred"`.

**41,400 of 42,840 claims are analysable — 96.6% coverage.** A dbt test asserts
`landed = kept + rejected`, so a filter added anywhere without recording a reason
breaks the arithmetic in the build rather than in a meeting three weeks later.
That test is also what makes the reason column single-valued worth keeping: one
row, one reason, so the counts add up.

The `CASE` ordering in `stg_claims` *is* the policy: most structural defect
first, so a row with an unreadable price *and* a negative quantity reports as
`unparseable_number` — you can't judge an amount you couldn't read. Precedence
survives the layer split for free: only rows that passed staging reach the scope
models, so a claim that is both malformed and out of scope is still reported as
malformed. Unit tests pin both halves.

Four judgement calls worth defending:

- **Spelled-out numbers are rejected, not translated.** Reconstructing `"one
  hundred"` is an endless rule set around a value I'd be guessing at. 126 rows, 0.3%.
- **Duplicate claim ids quarantine *both* sides.** None of the 140 duplicated
  UUIDs is an identical copy — they're different claims competing for one id.
  Picking a winner needs an invented criterion, and picking wrong corrupts
  revenue silently.
- **Missing partner on a lookup becomes `unknown`, not a rejection.** All 886
  failed to convert, so they're real events that merely lost attribution.
  Dropping them shrinks the funnel denominator and inflates everyone else's
  conversion rate.
- **Channel is normalised, not validated.** The brief calls the list open, so
  `fax`, `phone` and `APP` are legitimate low-volume channels. Rejecting unknown
  channels would be staging deciding which lines of business exist.

---

## Why this stack

**DuckDB** — 220k events and a 1M-row reference table is a laptop-scale problem,
and DuckDB is an embedded engine with real analytical SQL (`ASOF JOIN`,
`QUALIFY`, window functions, native JSON/CSV readers). The warehouse is a single
41 MB file: clone, run, query. Postgres would mean a container and a server for a
single-user workload, and has no `ASOF JOIN`; SQLite has no columnar execution.

**dbt** — the value isn't templating, it's that the DAG, the tests and the docs
are the same artifact as the transformation. `dbt build` interleaves models and
tests, so a model whose test fails doesn't propagate bad data downstream. And in
Part 3 I'll be editing a model live: `ref()` means I change one file and the DAG
re-resolves. No dbt packages — `dbt_utils` would be used for exactly one test, so
that test is six lines of local macro instead of turning `git clone && run` into
`git clone && dbt deps && run`.

**Python only for landing** — fetch NADAC, drop raw files into `raw.*`. No
transformation logic in Python, so there's exactly one place to look when a
number is wrong. No orchestrator: four steps, one process, no schedule, no
partial retry, no SLA. `dbt build` already resolves the DAG.

---

## Tests

`make pipeline` builds 23 models and runs **99 dbt tests** alongside them;
`make test` adds 7 pytest tests. They're concentrated where the brief says it
matters — the fee split, reversal handling, malformed records, and the NADAC
snapshot choice — not spread for coverage.

- **19 unit tests** run the *real* model SQL against fabricated inputs, so
  editing a model is seen by its tests. Every branch of the fee split, reversal
  deduplication, every data-quality classification including precedence, and the
  as-of cost resolution (which snapshot wins, what happens when none does, and
  that the unit rate is multiplied before it's rounded).
- **4 singular tests** assert invariants: the split reconciles to the cent, the
  partner never takes more than we collected, reversed claims carry zero in every
  `net_*` column, and **no claim is lost silently** (`raw = fct_claim + dq_rejects`).
- **76 schema tests** cover uniqueness and not-null on every key, referential
  integrity from both facts into all four dimensions, and accepted values on
  every enumerated column — including rejection reasons, so adding one without
  documenting it fails the build.
- **7 pytest** cover the one layer dbt structurally cannot see. dbt's world
  starts at `raw.*`, *after* landing happened, so a landing bug produces a raw
  table that is internally consistent and simply wrong. They pin the decision to
  declare every column VARCHAR — a dirty value past DuckDB's ~20k-row inference
  window kills the whole ingest under type inference, and lands as one documented
  `unparseable_number` with the schema declared — plus a batch missing a field
  still producing the column, `fee_cents = 0` staying distinct from empty, NADAC
  URL resolution, and the offline-cache guarantee. None of them touch the network.

---

## The two questions from the email

Both are answered in full in [`analysis/analysis.ipynb`](analysis/analysis.ipynb),
with the queries and the charts. The short version, and the numbers behind it:

**Scale.** 41,400 analysable claims, Mar–Jul 2026, **$200.7M net GMV** across 37
pharmacies in 7 chains. White Lodge collected $283,914 in `pbm_fee`, paid $100,269
to partners and retained **$183,645** — a blended retention of 64.7%. The funnel:
176,721 lookups → 23.0% conversion → 6.6% reversal rate.

### Dale — "who's our most valuable partner, and how do they compare to the second-best?"

Chain: **`meridian`**, the largest by volume (11,139 claims, $51.4M GMV) and so
where a renegotiation moves the most money.

| partner | terms | claims | fee collected | payout | **White Lodge keeps** | retention |
|---|---|---:|---:|---:|---:|---:|
| **Kafka Rx** | $1.00 flat | 3,253 | $22,542 | $3,052 | **$19,490** | 86.5% |
| Hudi Rx | 50% | 3,046 | $20,240 | $10,127 | $10,113 | 50.0% |
| Druid Rx | 20% | 1,524 | $10,011 | $2,002 | $8,009 | 80.0% |
| Iceberg Rx | $0.20 flat | 904 | $6,184 | $170 | $6,014 | 97.3% |
| Airflow Rx | $0.00 flat | 412 | $2,640 | $0 | $2,640 | 100% |
| Flink Rx | 80% | 1,764 | $12,335 | $9,868 | $2,467 | 20.0% |
| *direct* | — | 236 | $1,525 | $0 | $1,525 | 100% |

**Kafka Rx, and it isn't close — but not for the reason the volume suggests.**
Kafka and Hudi drive effectively the same business in meridian: 3,253 claims
against 3,046, seven percent apart, and Hudi actually originates more fee
overall. Kafka returns **1.9× the revenue** anyway, because Kafka is a $1.00 flat
cut and Hudi takes half. On this chain the volume is a tie and the terms decide
the whole thing.

**The number worth walking into the renegotiation with is Flink Rx.** It is third
by claims and second-best by conversion of the six (48.4%), and it is *last* by
value: 20% retention turns $12,335 of fee into $2,467. Rank partners by volume or
by funnel performance and Flink looks like a top-two relationship; rank them by
what White Lodge keeps and it is the weakest one we have. That's the gap the
`net_wls_revenue_cents` definition exists to close — see
`mart_partner_performance`.

So: protect Kafka, and take Flink into the room. Moving Flink from 80% to 50%
(Hudi's terms) is worth **+$16,563 across all chains — +9% of total retained
revenue**, from one contract.

### Gordon — "where would you increase margin?"

**The finding: the `pbm_fee` is effectively flat (~$7–9) no matter what the claim
is worth.** Our compensation is decoupled from the value we intermediate.

| claim value | claims | net GMV | fee collected | take rate |
|---|---:|---:|---:|---:|
| up to $100 | 24,143 | $0.6M | $180,535 | 32.15% |
| $100 – $10k | 12,757 | $14.5M | $86,914 | 0.598% |
| **above $10k** | **1,761** | **$185.6M** | **$16,465** | **0.0089%** |

1,761 claims — 4% of the book — carry **92% of the GMV and generate 6% of the
fee**. These are real fills, not data errors: the largest group is Tremfya at
~$7,700 per unit across 794 fills. We are doing the most valuable work we do
essentially for free.

Four levers, sized against the $183,645 retained today:

| # | lever | worth | how fast |
|---|---|---:|---|
| 1 | **Price the fee to the value.** Take the >$10k band from 0.0089% to 0.05% — still **12× below** what we already charge the middle band | **+$49,366 (+27%)** | slow: it's a pricing change |
| 2 | **Renegotiate Flink Rx** from 80% to 50% | **+$16,563 (+9%)** | fast: one contract |
| 3 | **Lift website conversion.** `integration` converts at 44.8%, `website` at 14.7% on 2.6× the volume | **+$5,458 per point** | medium: product work |
| 4 | **Attack reversals.** $13,127 handed back, 7.1% of retained revenue, median 9.5 days to reverse | **+$6,564 if half is recovered** | medium: it's revenue already earned |

Lever 1 is the answer to the question as asked, and I'd say plainly that I don't
know the contractual or competitive constraints on it — the sizing shows what
even a timid move is worth, not what the market will bear. Lever 2 is the one to
do this quarter regardless.

**One number I would deliberately not lead with.** NADAC's generic-equivalent
pricing shows **$29.6M** of acquisition cost sitting inside brand fills that have
a published generic — Epclusa alone is $24.3M across 602 fills. It is the largest
figure in this analysis by two orders of magnitude, and it is *pharmacy*
acquisition cost, not White Lodge revenue. It's a negotiating asset — value
demonstrably delivered to plan sponsors — rather than a margin lever, and
confusing the two is the easiest mistake to make with this dataset.

## What breaks at 100×

At 100× (4.2M claims, 17.7M lookups, ~30 GB of NADAC history) most of this holds.
DuckDB handles tens of millions of rows on a 10-core box; the grain choices, the
star schema and the cents convention are scale-independent. Three things don't:

**1. Full reload stops being free.** Claim staging and `fct_claim` become
incremental models partitioned on `filled_date`, with a lookback window for
late-arriving reverts (median 9.5 days to reverse, so 30 days covers it).
`dq_rejects` stays a full rebuild — small, and you want its history.

**2. Landing 17M lookups through one Python process is the wrong shape.** The
JSON reads become Parquet conversion on the way in, partitioned by event date.
DuckDB reads a partitioned Parquet directory with predicate pushdown, so most
queries stop touching most of the data. Landing stays Python; the format changes.

**3. The NADAC as-of join is what I'd watch** — the one operation whose cost
grows super-linearly with both sides. Two mitigations in order: restrict
`stg_nadac` to the NDCs we actually dispense (49 of 26,000 today, a 500×
reduction that costs nothing analytically), then collapse the weekly snapshots
into effective-dated ranges so the join hits a much smaller interval table.

**In the notebook**, the price-vs-fee scatter pulls every non-reverted claim into
the browser — fine at 39k points, not at 4M, and it would need `using sample` or
2D binning. And `select *` in scratch cells: a columnar engine only pays for the
columns you name.

**What wouldn't change:** no Spark. 4M claims is still a single-node problem, and
the moment there's a cluster there's a cluster to operate. The move after
DuckDB-on-one-box is DuckDB on a bigger box, then a managed warehouse.

---

## What I'd do with more time

Deliberately left out, in rough priority order.

**Reference-data history (SCD-2).** `dim_pharmacy` and `dim_partner` are full
reloads showing current state, so if a partner renegotiates terms, historical fee
splits get recalculated at the new rate — it silently rewrites reported revenue.
The fix is effective-dated dimensions with the fact carrying the terms in force
at fill time. I'd do it as a dbt snapshot on `stg_partners` first, because
commercial terms are where the damage is.

**Freshness and volume monitoring.** A batch that silently arrives with half the
usual claims passes every test today. `dbt source freshness` plus a row-count
anomaly test on the daily fact would catch it.

**Pin the NADAC file.** The cache stores whatever was current when downloaded, so
two people who downloaded in different weeks get slightly different costs. The run
should record the `as_of_date` it used, and ideally pin it. A real reproducibility
gap; the honest reason it isn't fixed is that it doesn't bite at this scale.

**Partner economics as a scenario model.** Everything here is descriptive. What
Dale actually wants is "what happens if I move Flink Rx from 80% to 50%" — a small
parameterised model over the existing fact, maybe 30 lines of SQL.

**Unit price consistency checks.** The schema says `price = unit_price × quantity`
but we never see `unit_price`, so it can't be validated. Comparing implied unit
price against NADAC would surface pricing anomalies — the join exists
(`unit_cost_usd` is on the fact), the check doesn't.

**Lookup deduplication semantics.** Every lookup is a distinct funnel event today.
If a patient checks the same drug three times in an hour that's arguably one
intent, and conversion is understated. I'd want the product definition before
modelling it rather than inventing a session window.
