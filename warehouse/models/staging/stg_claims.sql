-- One claim event per row, typed, with its rejection reason attached.
--
-- **Source-local only.** This model reads `raw.claims` and nothing else — no
-- `ref()` to another staging model. Every rule below is decidable by looking at
-- the row itself, or at the batch it arrived in. The rule that needs the
-- pharmacy reference data ("is this NPI one of ours?") is a *relational*
-- question, and it lives one layer up in `int_claims_scoped`.
--
-- That split is not bookkeeping. A row rejected here is **malformed** — the data
-- producer has to fix it, and it never comes back on its own. A row excluded up
-- there is **out of scope** — it is a perfectly good claim whose pharmacy we
-- don't have on file, and it returns by itself the day that pharmacy is
-- onboarded. Same 460 rows, completely different follow-up.
--
-- Malformed-record policy: **quarantine, don't drop**. No row disappears here.
-- Every one comes out with a `dq_reject_reason` — NULL when it's clean.
-- Downstream models filter on NULL; `dq_rejects` collects the rest with the
-- reason and the original text that arrived.
--
-- The CASE ordering *is* the policy, and it is deliberate: most structural
-- defect first, most semantic last. A row with a missing field *and* an
-- unreadable number is reported as `missing_required_field`, because that's the
-- problem the data producer has to fix first. Precedence survives the layer
-- split for free: `int_claims_scoped` only ever sees rows that passed here, so a
-- row that is both malformed and out of scope is still reported as malformed.

with source as (

    select * from {{ source('raw', 'claims') }}

),

parsed as (

    select
        nullif(trim(id), '')    as claim_id,
        nullif(trim(npi), '')   as npi,
        nullif(trim(ndc), '')   as ndc,

        try_cast(price as double)          as price,
        try_cast(quantity as double)       as quantity,
        try_cast(pbm_fee as double)        as pbm_fee,
        try_cast("timestamp" as timestamp) as filled_at,

        -- The raw text rides along: without it, `dq_rejects` would say
        -- "unreadable number" without being able to show that the number was
        -- the word "one hundred".
        price       as price_raw,
        quantity    as quantity_raw,
        pbm_fee     as pbm_fee_raw,
        "timestamp" as timestamp_raw,

        _source_file
    from source

),

with_duplicates as (

    select
        *,
        count(*) over (partition by claim_id) as id_occurrences
    from parsed

)

select
    claim_id,
    npi,
    ndc,
    filled_at,
    cast(filled_at as date) as filled_date,

    {{ to_cents('price') }}   as price_cents,
    {{ to_cents('pbm_fee') }} as pbm_fee_cents,
    quantity,

    price_raw,
    quantity_raw,
    pbm_fee_raw,
    timestamp_raw,
    id_occurrences,
    _source_file,

    case
        -- 1. Required field absent from the file (148 rows in the sample).
        when claim_id is null
             or npi is null
             or ndc is null
             or price_raw is null
             or quantity_raw is null
             or pbm_fee_raw is null
             or timestamp_raw is null
            then 'missing_required_field'

        -- 2. Unreadable number: `"one hundred"`, `"thirty"` (126 rows). We do
        --    not translate spelled-out numbers — that would be an endless rule
        --    set reconstructing a value we'd be guessing at.
        when price is null or quantity is null or pbm_fee is null
            then 'unparseable_number'

        -- 3. Impossible timestamp: `2026-13-45T99:99:99`, `not-a-date` (146).
        when filled_at is null
            then 'unparseable_timestamp'

        -- 4. Economically meaningless value: negative quantity (117) or
        --    zero/negative price (162). A zero price with a positive pbm_fee
        --    doesn't add up: nobody charges a fee on a sale that didn't happen.
        when price <= 0 or quantity <= 0
            then 'non_positive_amount'

        -- 5. Same UUID, different content (140 ids, 281 rows). Verified: *none*
        --    of these duplicates is an identical copy — they are entirely
        --    different claims competing for one id. There is no way to pick a
        --    winner without inventing a criterion, and picking wrong corrupts
        --    revenue silently. Quarantine both sides.
        --
        --    This one needs the whole batch rather than the single row, but it
        --    still needs no other model, so it belongs here.
        when id_occurrences > 1
            then 'duplicate_claim_id'
    end as dq_reject_reason

from with_duplicates
