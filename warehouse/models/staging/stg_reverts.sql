-- Reversals. Same quarantine contract as stg_claims.
--
-- `orphan_claim_id` (53 rows) is the interesting rejection: the reversal arrived
-- but the claim it invalidates isn't in our universe — either it never landed,
-- or it was itself rejected (unknown NPI, duplicate id). Applying that reversal
-- would be a no-op; ignoring it silently would hide an ingestion gap.

with source as (

    select * from {{ source('raw', 'reverts') }}

),

parsed as (

    select
        nullif(trim(id), '')               as revert_id,
        nullif(trim(claim_id), '')         as claim_id,
        try_cast("timestamp" as timestamp) as reverted_at,
        "timestamp" as timestamp_raw,
        _source_file
    from source

),

with_duplicates as (

    select *, count(*) over (partition by revert_id) as id_occurrences
    from parsed

),

with_claim as (

    select
        r.*,
        c.claim_id is not null as claim_is_known
    from with_duplicates as r
    left join (
        select claim_id from {{ ref('stg_claims') }} where dq_reject_reason is null
    ) as c using (claim_id)

)

select
    revert_id,
    claim_id,
    reverted_at,
    timestamp_raw,
    id_occurrences,
    _source_file,

    case
        when revert_id is null or claim_id is null or timestamp_raw is null
            then 'missing_required_field'
        when reverted_at is null
            then 'unparseable_timestamp'
        when id_occurrences > 1
            then 'duplicate_revert_id'
        when not claim_is_known
            then 'orphan_claim_id'
    end as dq_reject_reason

from with_claim
