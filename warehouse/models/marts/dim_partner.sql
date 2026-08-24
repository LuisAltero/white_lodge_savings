-- One row per partner, plus two synthetic members.
--
-- `direct` (a claim that arrived with no lookup) and `unknown` (a lookup that
-- arrived with no partner) exist as real rows, not NULLs. The reason is
-- practical: in a `left join` against NULL, every direct claim disappears from
-- any `group by partner` and the fact total stops matching the sum of its parts
-- — with no warning at all. As a named member, it shows up in the table and
-- somebody asks what it is.

with partners as (

    select
        partner        as partner_name,
        fee_model,
        flat_fee_cents,
        fee_rate,
        false          as is_synthetic
    from {{ ref('stg_partners') }}

),

synthetic as (

    select * from (values
        ('direct',  'none', cast(null as bigint), cast(null as double), true),
        ('unknown', 'none', cast(null as bigint), cast(null as double), true)
    ) as t(partner_name, fee_model, flat_fee_cents, fee_rate, is_synthetic)

)

select * from partners
union all
select * from synthetic
