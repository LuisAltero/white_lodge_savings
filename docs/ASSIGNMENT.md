# Analytics / Data Engineer — Take-Home Assignment

> **Read this first — it's the whole point of the exercise.** What you build here doesn't
> stop at submission: it's the material for **two separate live sessions** later in the
> loop. In the **Live Analytics Session** you'll answer new, ad-hoc business questions *by
> querying — and visualizing — this data model, live*. In the **Data System Design & Live
> Debug** session we open the repo with you, walk your decisions, and then **change
> something in it together, live**. So build a clean, queryable **mini-warehouse** you can
> run, query, *and modify* on your own laptop — **not** a one-off script that prints fixed
> outputs, and **not** a productionized platform. If it can't be queried live, you can't
> complete the next round. See
> [Where this goes next](#where-this-goes-next--two-live-sessions-on-this-code) and
> [What you do *not* need to build](#what-you-do-not-need-to-build).

## The scenario

You've just joined **White Lodge Savings** — a brand-new pharmacy benefit manager
(PBM) — as its **first data engineer**. Raw pharmacy events (claims, reverts, and price
lookups) are already streaming in as files, the reference data lives in spreadsheets, and
the business team keeps asking questions nobody can answer quickly yet. The data
foundation doesn't exist — that's what you're here to build.

No prior healthcare experience required; the primer below covers the PBM world. White
Lodge Savings is a fictional company invented for this exercise — no need to look it up.

## What we're asking you to do

Architect and build a data pipeline that turns our raw pharmacy events into a clean,
**queryable** foundation others can build on — business teams, and the AI agents working
on their behalf — to answer questions and track metrics. Along the way you'll decide how
to **model** the data, **enrich** it with an external cost/reference source, and propose
useful metrics.

We care about both the working code *and* the thinking behind it: how you structured and
modeled the data, the tradeoffs you weighed, and where you'd take it next.

You don't need prior healthcare experience — the primer below covers it. Ask us anything.

**Don't gold-plate.** We've drawn that line explicitly in
[What you do *not* need to build](#what-you-do-not-need-to-build), so read it before you
start, and tell us in the README what you'd do with more time.

---

## Where this goes next — two live sessions on this code

Your submission is used twice more in the loop, in **two separate sessions**:

|  | Session | What happens |
|---|---|---|
| **Part 2** | **Live Analytics Session** (~75 min, screen-shared) | We give you new ad-hoc business questions and you answer them **by querying the model you built here** — and for at least one, you **turn the answer into a visualization, live**. |
| **Part 3** | **Data System Design & Live Debug** (~60 min) | We open your repo with you and walk your decisions — why this model, why this grain, why this tech, how you wired in NADAC, what breaks at 100×. Then we **change the ask on the spot** and you work it in your own code with us: a question the model doesn't answer yet, a requirement that moves, something that needs fixing. |

Two practical consequences for how you build:

- **It has to run and be queryable on your machine, cold.** Both sessions start with you
  running your own project. Come with the environment working and the data loaded — not
  set up from scratch on the call.
- **It has to be changeable by you.** Part 3 isn't a memory test; it's you editing your own
  code while we watch. A repo you can navigate and modify quickly matters more than a repo
  that looks impressive.

Neither session has a trick in it, and getting through everything isn't the bar — we're
watching how you think.

---

## ⚠️ Two things that shape how we'll evaluate this

**1. Build a queryable data model — a mini-warehouse — because you'll query it live.**
Both live sessions above run against this model. Treat the deliverable as a small
warehouse others can query and extend — **not** a one-off script that prints a fixed set
of outputs. **If your model can't be queried live, you won't be able to complete the next
round**, so make querying it easy.

**Plan your query + visualization tooling in advance.** Decide *now* how you'll query and
chart on the spot — whatever you're fastest in: an AI-generated HTML chart, a local viz
tool (e.g. Apache Superset), a Jupyter notebook, or even sketching the chart on a
whiteboard. We care about your thinking and the answer, not the tool — but come ready;
figuring it out live will cost you.

**2. Two of our leaders emailed you. Reply to both — in the body of your submission email**
(not a PDF, not the README):

> **From:** Dale Cooper (Head of Business)
> **Subject:** partner mix before renegotiations
>
> Hey — heading into some partner renegotiations and I want to focus where it matters. For
> a chain of your choice: who's our most valuable partner, and how do they compare to the
> second-best? Just trying to see where our leverage is. Thanks!

> **From:** Gordon Cole (CEO)
> **Subject:** margin
>
> Big-picture question for you: if we wanted to increase White Lodge's margin, what would
> you suggest — based on what you're seeing in the data? You won't know our pricing
> playbook, and that's fine; I want your read on where the opportunity is.

---

## How we'll evaluate

We look at three things together:

1. **Your data model** — how you structure everything into a clean, queryable base, and
   the tradeoffs behind it. **This is the heart of the exercise.** White Lodge's Head of
   Engineering, **Harry Truman**, will read your repo and dig into these choices with you
   in **Part 3**.
2. **Your answers to the email questions** — the analysis *and* how clearly you
   communicate it.
3. **The project itself** — correct, reproducible, and easy to run and build on.

**We expect you to use AI tools on this, and we evaluate how well you own what they
produce** — see [Using AI tools](#using-ai-tools) below. **Part 3** walks your repo, asks
why you made each decision, and has you change it live.

---

## A short primer on the PBM world

### What is a PBM?

A **Pharmacy Benefit Manager (PBM)** sits in the middle of the prescription-drug supply
chain, connecting patients, pharmacies, drug manufacturers, and payers, and negotiating
drug prices. We work to offer the lowest possible price on generic and branded
medications, insured or not.

The core flow:

1. A patient gets a **prescription** for a drug, identified by an **NDC** (National Drug
   Code) and a **quantity**.
2. They take it to a **pharmacy**, identified by its **NPI** (National Provider
   Identifier).
3. The pharmacist tells them the **price** and submits a **claim** — a record that this
   drug was filled at this pharmacy for this price.

### What is a claim? A reversal?

A **claim** is the event generated when a pharmacy fills a prescription: *which* drug
(`ndc`), *at which* pharmacy (`npi`), at *what* total `price`, in *what* `quantity`, and
*when* (`timestamp`).

Sometimes a fill doesn't complete (often the patient never picks it up). The pharmacist
then submits a **reversal** (`revert`) that **invalidates** the original claim — pointing
back at it by `claim_id`. A reversed claim is treated as if the fill never happened for
revenue, volume, fees, and payouts — but a high reversal rate is itself a signal worth
measuring.

### How the money works (simplified)

For each fill, the patient pays a **price**. The pharmacy acquired the drug at some
**cost**. On top of that we (the PBM) collect a **`pbm_fee`** on the claim, which we
**share with the partner** that drove the business. Each partner's commercial terms live
in the `partners` table — either a flat cut (`fee_cents`) or a proportional cut of the
`pbm_fee` (`fee_percentage`).

Roughly:
- **Pharmacy keeps:** `price − cost − pbm_fee`
- **Partner earns:** their share of the `pbm_fee` (`fee_cents` *or* `fee_percentage`)
- **We keep:** the rest of the `pbm_fee`

Reverse a claim and all of it reverses with it. *(This is a simplified model — the real
world has more nuance — but it's enough here.)*

### What is a lookup? (conversion)

Before a claim, a patient — usually via a **partner**, through either an **integration**
or the partner's **website** (the `channel`) — looks up a price for a drug. Each **lookup**
records that partner and channel and the drug (`ndc`) being priced. A lookup that
**converts** produces a claim (linked by `claim_id`); many lookups never convert. This
**lookup → claim → (maybe) reversal** path is our **conversion** funnel.

### Where cost comes from

We benchmark drug cost with **NADAC** (National Average Drug Acquisition Cost), a public
CMS dataset of per-unit costs — and drug details — by NDC:

https://data.medicaid.gov/dataset/fbb83258-11c7-47f5-8b18-5f8e79f7e704

It's raw and lightly documented on purpose — figuring out what's useful and wiring it in
is part of the task.

**One thing worth knowing before you join to it:** NADAC is published as a rolling series
of **weekly snapshots** — the same NDC appears many times, with an `effective_date` and an
`as_of_date`. So "the cost of this drug" isn't a single number, and the file you download
won't line up perfectly with our event dates. **Picking which NADAC row represents a
claim's cost is a modeling decision we want you to make and state** — as-of the fill date,
latest available, an average, one snapshot for everything. Any of those can be defended;
what we're looking for is that you noticed the choice existed, made one, and wrote down
why (and what it costs you). Some claims won't match NADAC at all — that's deliberate.

---

## Inputs

Your application should accept directory paths for each event / reference source.

- Pharmacies and partners are **slowly-changing reference data**.
- Claims, reverts, and lookups arrive as **streams of events** split across many files.
- Some events **don't** comply with the schemas below. Handle malformed/invalid records
  sensibly — how is your call.
- We only care about events for pharmacies that exist in the pharmacy dataset.
- **How you model all of this is up to you** — one big table, a star schema, something
  else. We're interested in the choice *and why*.

Sample data is provided alongside this brief as `sample-data.tar.gz`; pull NADAC from the
link above.

### Data schemas

**Claim event** (JSON)

| field | type | notes |
|-------|------|-------|
| `id` | string | UUID identifying the claim |
| `npi` | string | pharmacy that filled the claim |
| `ndc` | string | drug identifier |
| `price` | float | total price charged (`unit_price` × `quantity`) |
| `quantity` | integer/float | amount dispensed |
| `pbm_fee` | float | fee we collect on this claim (shared with the partner) |
| `timestamp` | datetime | when the claim was filled |

**Revert event** (JSON)

| field | type | notes |
|-------|------|-------|
| `id` | string | UUID identifying the revert |
| `claim_id` | string | the claim being invalidated |
| `timestamp` | datetime | when the revert happened |

**Lookup event** (JSON)

| field | type | notes |
|-------|------|-------|
| `id` | string | UUID identifying the lookup |
| `claim_id` | string | the claim it produced if it converted, else null |
| `ndc` | string | the drug whose price was looked up |
| `partner` | string | partner that drove the lookup |
| `channel` | string | e.g. `integration`, `website` |
| `timestamp` | datetime | when the lookup happened |

**Pharmacy** (CSV)

| field | type | notes |
|-------|------|-------|
| `npi` | string | identifier of the pharmacy |
| `chain` | string | the chain the pharmacy belongs to |

**Partner** (CSV)

| field | type | notes |
|-------|------|-------|
| `partner` | string | partner name |
| `fee_cents` | int | flat cut of the `pbm_fee` (nullable) |
| `fee_percentage` | float | proportional cut of the `pbm_fee` (nullable) |

*(A partner has one of `fee_cents` / `fee_percentage`, not both.)*

**NADAC** (external) — per-unit acquisition cost and drug details by NDC. Schema per the
CMS dataset.

---

## Technical requirements

- Write the application in **Python**. Any build tool is fine.
- Assume the app runs on a **single instance with 10 cores**.
- **How you hand it over is up to you** — send it back to the email addresses on this
  thread however you think works best. What we need either way is a **README** covering how
  to run it against the sample files, how to query the result, and the decisions you made.
  Bear in mind you'll be running and changing this code with us in the later sessions.
- The resulting system must be **queryable** (see above).

---

## What you do *not* need to build

The bar is **"a teammate clones this, runs it on a laptop, and queries it"** — not a
production platform. Everything below is explicitly **out of scope**. Leaving it out costs
you nothing; building it spends your week on things we aren't scoring.

- **No cloud, no infrastructure-as-code, no deployment.** No AWS/GCP, no Terraform, no
  Kubernetes, no hosted warehouse. Local files plus a local engine — DuckDB, SQLite,
  Postgres in Docker, Parquet + dataframes, your call — is exactly right.
- **No orchestrator.** No Airflow / Dagster / Prefect. One command (or a `make` target)
  that runs the pipeline end to end is the right amount of orchestration.
- **No streaming stack.** The event files *are* the stream. No Kafka, no Spark, no Flink —
  batch over directories is fine.
- **No CI/CD, and containers only if they help.** Docker is welcome if it makes *running*
  this easier for us; it's never a requirement.
- **No exhaustive test suite.** A handful of tests on the logic that's actually tricky
  (the fee split, reversal handling, malformed records) tells us more than a coverage
  number.
- **No BI server, no web app, no API, no UI.** You bring your own way to chart an answer
  in the live session; you don't build a reporting layer here.
- **No incremental loads, CDC, or real SCD-2 history machinery.** A full reload each run
  is fine. If you'd track reference-data history differently at scale, **say so in the
  README** — a paragraph of reasoning scores the same as an implementation here.
- **No performance engineering.** Assume the single 10-core box and this volume of data.
  Tell us in the README what you'd change at 100× instead of building for it.
- **No exhaustive NADAC ingestion.** Take the fields you need and say why — you don't need
  every column, or every historical file.
- **No attempt to handle every malformed record.** One documented, defensible policy beats
  a long tail of special cases.
- **No polish for its own sake.** No logging framework, config system, plugin
  architecture, or docs site. A README that covers how to run it, how to query it, and
  what you decided is the documentation we want.

**Rule of thumb:** if a piece of work makes the project harder to *read* or *change*
rather than easier to *query*, it's out of scope — and Part 3 is where "easy to change"
pays off. If you're genuinely unsure whether something is in or out, **ask us**. Anything
you deliberately left out is worth a line in the README's "what I'd do with more time."

---

## Using AI tools

**We expect you to use AI tools (Claude, ChatGPT, Copilot, Cursor, etc.) on this.** They're
part of how we work every day, and part of what we're assessing is how well you work *with*
them. Not using them won't earn you points — this isn't a test of writing code unassisted.

**What we evaluate is ownership, and we evaluate it explicitly.** In **Part 3** we open
your repo with you, walk your decisions, and then change something in it together: why this model and grain, why this tech,
how you wired in NADAC, what breaks at 100× volume. We're listening for *your* reasoning —
what you tried, what you rejected, where you overrode the tool and why. Code you can't
account for reads as the tool owning the work, and it's the single most common reason a
strong-looking submission doesn't advance.

So: use AI freely, then make sure you understand and can defend every line you submit. Come
back to your own repo cold before that conversation.

---

## Stuck on question 2? A nudge

**There's no right answer here.** We're evaluating how you reason through an open,
underspecified problem with no clean solution — which is a big part of the work here.

If the margin question leaves you staring at a blank page: think about the patterns you
can actually *see* in the data — by **drug, pharmacy, partner, and channel** — and the
funnel of **lookups → claims → reversals**. A useful framing is *which one or two
north-star metrics would move margin the most, and where?*
