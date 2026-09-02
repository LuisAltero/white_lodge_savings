-- The split has to balance: what White Lodge keeps plus what goes to the partner
-- is exactly the pbm_fee collected. Not a cent more, not a cent less.
--
-- This is the invariant that guards against the most expensive possible bug in
-- this project — money created or destroyed by rounding in the percentage split.

select
    claim_id,
    pbm_fee_cents,
    partner_fee_cents,
    wls_fee_cents,
    partner_fee_cents + wls_fee_cents as reconstructed
from {{ ref('int_claim_economics') }}
where partner_fee_cents + wls_fee_cents <> pbm_fee_cents
