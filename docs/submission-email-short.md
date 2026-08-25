Subject: White Lodge Savings take-home — [YOUR NAME]

---

Hi Dale, Gordon, [recruiter],

Submission: [GITHUB URL]

A DuckDB + dbt mini-warehouse. Two targets build it end to end:

    make setup
    make pipeline

(`make query` opens a DuckDB shell on the result.)

The README covers how to run it, how to query it, the modelling decisions, and what
I'd do with more time. Every number below comes out of the model; the queries and
charts are in analysis/analysis.ipynb, which ships with outputs already executed.


────────────────────────────────────────────────────────────
DALE — partner mix before renegotiations
────────────────────────────────────────────────────────────

Chain: meridian — largest by volume (10,271 net claims, $51.4M net GMV). All figures
are net of reversals.

  Most valuable   Kafka Rx    $19,490 retained   3,052 claims   86.5% retention
  Second          Hudi Rx     $10,113 retained   2,759 claims   50.0% retention

Kafka is worth 1.9x Hudi, and it isn't volume. The two drive comparable business —
3,052 claims vs 2,759, and Hudi actually originates almost as much fee ($20,240 vs
$22,542). The gap is entirely commercial terms: Kafka takes a $1.00 flat cut (we keep
86.5%), Hudi takes 50%.

Your leverage is Flink Rx. Third by claims in meridian and second-best of six partners
by conversion (48.4%, behind only Kafka at 53.5%) — but dead last by value: an 80%
payout turns $12,335 of fee into $2,467 retained. Moving Flink to Hudi's 50% terms is
worth +$16,563 across all chains, +9% of everything White Lodge retains today, from
one contract.

Protect Kafka's terms; take Flink into the room first.

Note the ranking is by what we keep after payout and after reversals. Ranked by volume
or by funnel performance, Flink reads as a top-two relationship — which is how this
gets missed.


────────────────────────────────────────────────────────────
GORDON — margin
────────────────────────────────────────────────────────────

Our fee has no relationship to the value we intermediate. pbm_fee sits at roughly $7-9
whether the claim is worth $20 or $200,000 — correlation between price and fee is 0.07.

  up to $100     24,143 claims    $0.6M GMV    $180,535 fee    take rate 32.15%
  $100 - $10k    12,757 claims   $14.5M GMV     $86,914 fee    take rate 0.598%
  above $10k      1,761 claims  $185.6M GMV     $16,465 fee    take rate 0.0089%

1,761 claims — 4% of the book — carry 92% of GMV and generate 6% of the fee. These are
real fills, not errors (largest group: Tremfya, ~$7,700/unit across 794 fills).

Four levers, sized against the $183,645 we retain today:

  1. PRICE THE FEE TO THE VALUE. Take the above-$10k band from 0.0089% to 0.05% —
     still 12x below what we charge the middle band. +$52,541 (+29%). Slow: pricing.
  2. RENEGOTIATE FLINK RX from 80% to 50%. +$16,563 (+9%). Fast: one contract.
  3. LIFT WEBSITE CONVERSION. Integration converts at 44.8%, website at 14.7% on 2.6x
     the volume. +$5,458 per point. Medium: product work.
  4. ATTACK REVERSALS. $13,127 handed back, 7.1% of retained revenue, median 9.5 days.
     +$6,564 if half is recovered.

Lever 1 answers your question as asked. I sized it by repricing each claim in the band
and running it back through the actual fee split, rather than applying our blended
64.7% retention — a portfolio average that doesn't describe the partners originating
high-value fills. Not knowing your contractual constraints, read it as what even a
timid move is worth. Lever 2 is the one I'd do this quarter regardless.

One number I'd deliberately not lead with: NADAC shows $29.6M of acquisition cost
inside brand fills that have a published generic (Epclusa alone is $24.3M across 602
fills). It's the largest figure in the analysis by two orders of magnitude — but it's
*pharmacy* acquisition cost, not our revenue. A negotiating asset with plan sponsors,
not a margin lever. Easiest mistake to make with this dataset, so I'm flagging it
rather than tabling it.

────────────────────────────────────────────────────────────

Happy to walk through any of it, and looking forward to the sessions.

[YOUR NAME]
