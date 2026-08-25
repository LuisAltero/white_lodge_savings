-- Everything blocked before the marts, with a reason, a class, and the text that
-- arrived.
--
-- ## Two layers, one table
--
-- * **staging** rejects what it can see in the row itself — `stg_claims`,
--   `stg_reverts`, `stg_lookups` and their `dq_reject_reason`.
-- * **intermediate** excludes what needs a second table — `int_claims_scoped`,
--   `int_reverts_scoped` and their `scope_exclusion_reason`.
--
-- `detected_in` names which layer stopped the row, so changing a rule starts with
-- knowing which file to open.
--
-- ## Why `defect_class` is the column that matters
--
-- Counting rejects tells you how much you lost. It doesn't tell you what to do,
-- and the three answers are completely different:
--
-- | class | what it means | who fixes it |
-- |---|---|---|
-- | `malformed` | the file carried garbage — `"one hundred"` in a price, `2026-13-45` in a timestamp | the data producer; the row never returns on its own |
-- | `ambiguous` | well formed but self-contradictory — one UUID on two different claims | a human, once, with a rule we don't have yet |
-- | `out_of_scope` | a valid record about something we don't have on file — a pharmacy missing from the reference data | nobody; it returns by itself when reference data catches up |
--
-- That last row is 460 claims of real revenue. Sharing one bucket with unreadable
-- numbers made "how much of what I rejected is recoverable?" unanswerable.
--
--     select defect_class, reject_reason, count(*)
--     from marts.dq_rejects group by 1, 2 order by 3 desc;
--
-- `raw_payload` keeps what arrived, so "unreadable number" is auditable down to
-- the literal `"one hundred"` without going back to the JSON.

with staging_defects as (

    select
        'claims'         as source_table,
        'staging'        as detected_in,
        claim_id         as record_id,
        dq_reject_reason as reject_reason,
        _source_file,
        to_json({
            'id': claim_id, 'npi': npi, 'ndc': ndc,
            'price': price_raw, 'quantity': quantity_raw,
            'pbm_fee': pbm_fee_raw, 'timestamp': timestamp_raw
        }) as raw_payload
    from {{ ref('stg_claims') }}
    where dq_reject_reason is not null

    union all

    select
        'reverts',
        'staging',
        revert_id,
        dq_reject_reason,
        _source_file,
        to_json({
            'id': revert_id, 'claim_id': claim_id, 'timestamp': timestamp_raw
        })
    from {{ ref('stg_reverts') }}
    where dq_reject_reason is not null

    union all

    select
        'lookups',
        'staging',
        lookup_id,
        dq_reject_reason,
        _source_file,
        to_json({
            'id': lookup_id, 'claim_id': claim_id, 'ndc': ndc,
            'partner': partner, 'channel': channel, 'timestamp': timestamp_raw
        })
    from {{ ref('stg_lookups') }}
    where dq_reject_reason is not null

),

scope_exclusions as (

    select
        'claims'                as source_table,
        'intermediate'          as detected_in,
        claim_id                as record_id,
        scope_exclusion_reason  as reject_reason,
        _source_file,
        to_json({
            'id': claim_id, 'npi': npi, 'ndc': ndc,
            'price': price_raw, 'quantity': quantity_raw,
            'pbm_fee': pbm_fee_raw, 'timestamp': timestamp_raw
        }) as raw_payload
    from {{ ref('int_claims_scoped') }}
    where scope_exclusion_reason is not null

    union all

    select
        'reverts',
        'intermediate',
        revert_id,
        scope_exclusion_reason,
        _source_file,
        to_json({
            'id': revert_id, 'claim_id': claim_id, 'timestamp': timestamp_raw
        })
    from {{ ref('int_reverts_scoped') }}
    where scope_exclusion_reason is not null

),

everything as (

    select * from staging_defects
    union all
    select * from scope_exclusions

)

select
    source_table,
    detected_in,
    record_id,
    reject_reason,

    -- The class is a property of the reason, not of the layer: a duplicate id is
    -- caught in staging but isn't malformed, it's undecidable. Listing every
    -- reason explicitly (rather than an `else`) means a new rule has to state
    -- its class here, and the accepted_values test fails until it does.
    case reject_reason
        when 'missing_required_field' then 'malformed'
        when 'unparseable_number'     then 'malformed'
        when 'unparseable_timestamp'  then 'malformed'
        when 'non_positive_amount'    then 'malformed'
        when 'duplicate_claim_id'     then 'ambiguous'
        when 'duplicate_revert_id'    then 'ambiguous'
        when 'unknown_npi'            then 'out_of_scope'
        when 'orphan_claim_id'        then 'out_of_scope'
    end as defect_class,

    _source_file,
    raw_payload
from everything
