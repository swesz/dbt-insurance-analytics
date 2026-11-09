-- Along one origin period, the number of reported claims never goes down as the triangle ages:
-- a claim, once reported, stays reported (deleted claims are excluded from every evaluation,
-- not removed from later ones only). Paid and incurred are not tested this way: a recovery or a
-- void can lower paid, and a reserve release can lower incurred.
-- Returns cells whose count is below the previous age's.
with triangle as (
    select
        *,
        lag(reported_claim_count) over (
            partition by triangle_grain, line_of_business, origin_period
            order by development_age_months
        ) as previous_reported_claim_count
    from {{ ref('rpt_loss_development_triangle') }}
)

select *
from triangle
where reported_claim_count < previous_reported_claim_count
