-- Month-end paid, case reserve and incurred per exposure, cost category and accounting period,
-- from the exposure's first booked period through the valuation period. Sum it over exposures
-- for any period to get the book's paid in the period, ITD paid, outstanding case reserves
-- and incurred at that period end; the loss reserve rollforward and the GL reconciliation are
-- built from it.
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
        accident_year,
        period_paid_amount,
        period_reserve_change_amount,
        itd_paid_amount,
        case_reserve_amount,
        incurred_amount
    from exposure_balances
)

select * from final
