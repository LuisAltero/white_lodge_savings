-- The cap must always hold: the partner never takes more than we collected, and
-- White Lodge's net revenue is never negative.
--
-- Without it, the 471 raw claims with a pbm_fee below $1.00 combined with Kafka
-- Rx's flat $1.00 fee would produce negative revenue silently.

select claim_id, partner, pbm_fee_cents, partner_fee_cents, wls_net_fee_cents
from {{ ref('int_claim_economics') }}
where partner_fee_cents > pbm_fee_cents
   or wls_net_fee_cents < 0
