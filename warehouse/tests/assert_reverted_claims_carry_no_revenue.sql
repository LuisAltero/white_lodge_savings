-- A reversed claim is as if it never happened. Every net_* column on it is zero
-- — that is what makes it safe to sum revenue without writing the filter.

select claim_id
from {{ ref('fct_claim') }}
where is_reverted
  and (net_price_cents <> 0
       or net_pbm_fee_cents <> 0
       or net_partner_fee_cents <> 0
       or net_wls_revenue_cents <> 0
       or net_claim_count <> 0)
