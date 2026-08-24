-- Reversals, typed. Same quarantine contract as stg_claims, and the same
-- source-local rule: no `ref()` to another model.
--
-- The reversal whose claim isn't in our universe (`orphan_claim_id`, 53 rows)
-- used to be classified here, which meant this model had to read `stg_claims`.
-- It's a relational question, so it moved to `int_reverts_scoped`.

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
    end as dq_reject_reason

from with_duplicates
