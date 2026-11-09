-- No exposure's outstanding case reserve is negative at any month end.
-- A case reserve is the adjuster's estimate of what is still to be paid, so it cannot be below
-- zero. The source keeps it there: payment erosion lowers the reserve by the payment but never
-- below zero, and closing an exposure sets it to exactly zero (3f). A negative balance here
-- would mean an event is missing, counted twice, or booked in the wrong period.
-- Returns the offending balance rows.
select
    exposure_id,
    cost_category,
    accounting_period,
    case_reserve_amount
from {{ ref('fct_claim_exposure_period_balances') }}
where case_reserve_amount < 0
