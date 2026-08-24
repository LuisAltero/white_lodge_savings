-- Everything blocked before the marts, with a reason and the original text.
--
-- This table is half of the quality policy — the other half is
-- `dq_reject_reason` in staging. Together they answer the question that always
-- comes up when a number looks low: *how much* did we lose, *why*, and *from
-- which file*.
--
--     select source_table, reject_reason, count(*)
--     from marts.dq_rejects group by 1, 2 order by 3 desc;
--
-- `raw_payload` keeps what arrived, so "unreadable number" is auditable down to
-- the literal `"one hundred"` without going back to the JSON.

with claims as (

    select
        'claims'         as source_table,
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

),

reverts as (

    select
        'reverts',
        revert_id,
        dq_reject_reason,
        _source_file,
        to_json({
            'id': revert_id, 'claim_id': claim_id, 'timestamp': timestamp_raw
        })
    from {{ ref('stg_reverts') }}
    where dq_reject_reason is not null

),

lookups as (

    select
        'lookups',
        lookup_id,
        dq_reject_reason,
        _source_file,
        to_json({
            'id': lookup_id, 'claim_id': claim_id, 'ndc': ndc,
            'partner': partner, 'channel': channel, 'timestamp': timestamp_raw
        })
    from {{ ref('stg_lookups') }}
    where dq_reject_reason is not null

)

select * from claims
union all select * from reverts
union all select * from lookups
