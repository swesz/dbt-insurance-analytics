-- Month-end paid, case reserve and incurred per exposure, cost category and accounting period,
-- from the exposure's first booked period through the valuation period. Sum it over exposures
-- for any period to get the book's paid in the period, ITD paid, outstanding case reserves
-- and incurred at that period end; the loss reserve rollforward and the GL reconciliation are
-- built from it. The contract is enforced because those downstream models depend on its shape.
with exposure_balances as (
    select * from {{ ref('int_claims__exposure_balances_by_period') }}
),

final as (
    select
        exposure_id,
        cost_category,
        accounting_period,
        period_end_date,
        claim_id,
        coverage_code,
        line_of_business,
        loss_date,
        cast(accident_year as integer) as accident_year,
        -- Sums widen decimals to 38 digits; the contract fixes a stable money type instead.
        cast(period_paid_amount as decimal(18, 2)) as period_paid_amount,
        cast(period_reserve_change_amount as decimal(18, 2)) as period_reserve_change_amount,
        cast(itd_paid_amount as decimal(18, 2)) as itd_paid_amount,
        cast(case_reserve_amount as decimal(18, 2)) as case_reserve_amount,
        cast(incurred_amount as decimal(18, 2)) as incurred_amount
    from exposure_balances
)

select * from final
