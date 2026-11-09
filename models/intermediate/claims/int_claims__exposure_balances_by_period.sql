-- Month-end balances per exposure, cost category and accounting period, from the exposure's
-- first booked period through the valuation period.
--
-- The financial events are flows (what happened in a month); balances are stocks (where things
-- stand at month end). The outstanding case reserve is a stock: the running sum of all reserve
-- changes booked so far. So is inception-to-date (ITD) paid. A period with no activity still
-- has a balance (the reserve carried over from the month before), which is why this model
-- builds a row for every month between the first event and the valuation period, not only for
-- months with events. Incurred = ITD net paid + outstanding case reserve (3f).
--
-- Grain: exposure_id x cost_category x accounting_period. Only the cost categories an exposure
-- has events in get rows.
with financial_events as (
    select * from {{ ref('int_claims__financial_events') }}
),

accounting_periods as (
    select * from {{ ref('accounting_periods') }}
),

-- Nothing in the source is entered after the valuation date, but a transaction dated in
-- advance would be booked in a later period. Balances stop at the valuation period.
booked_events as (
    select financial_events.*
    from financial_events
    where financial_events.accounting_period <= {{ claims_valuation_period() }}
),

exposure_first_periods as (
    select
        exposure_id,
        min(accounting_period) as first_accounting_period
    from booked_events
    group by exposure_id
),

-- Attributes of the exposure and its claim; they are the same on every event of an exposure.
exposure_cost_categories as (
    select distinct
        exposure_id,
        cost_category,
        claim_id,
        coverage_code,
        line_of_business,
        loss_date,
        accident_year
    from booked_events
),

period_spine as (
    select
        exposure_cost_categories.*,
        accounting_periods.accounting_period,
        accounting_periods.period_end_date
    from exposure_cost_categories
    inner join exposure_first_periods
        on exposure_cost_categories.exposure_id = exposure_first_periods.exposure_id
    inner join accounting_periods
        on accounting_periods.accounting_period >= exposure_first_periods.first_accounting_period
        and accounting_periods.accounting_period <= {{ claims_valuation_period() }}
),

period_activity as (
    select
        exposure_id,
        cost_category,
        accounting_period,
        sum(paid_amount) as period_paid_amount,
        sum(reserve_change_amount) as period_reserve_change_amount
    from booked_events
    group by exposure_id, cost_category, accounting_period
),

running_balances as (
    select
        period_spine.exposure_id,
        period_spine.cost_category,
        period_spine.accounting_period,
        period_spine.period_end_date,
        period_spine.claim_id,
        period_spine.coverage_code,
        period_spine.line_of_business,
        period_spine.loss_date,
        period_spine.accident_year,
        coalesce(period_activity.period_paid_amount, 0) as period_paid_amount,
        coalesce(period_activity.period_reserve_change_amount, 0) as period_reserve_change_amount,
        sum(coalesce(period_activity.period_paid_amount, 0)) over exposure_to_date
            as itd_paid_amount,
        sum(coalesce(period_activity.period_reserve_change_amount, 0)) over exposure_to_date
            as case_reserve_amount
    from period_spine
    left join period_activity
        on period_spine.exposure_id = period_activity.exposure_id
        and period_spine.cost_category = period_activity.cost_category
        and period_spine.accounting_period = period_activity.accounting_period
    window exposure_to_date as (
        partition by period_spine.exposure_id, period_spine.cost_category
        order by period_spine.accounting_period
        rows between unbounded preceding and current row
    )
),

final as (
    select
        *,
        itd_paid_amount + case_reserve_amount as incurred_amount
    from running_balances
)

select * from final
