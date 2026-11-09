-- Incurred loss in the loss ratio reports equals the claims marts, each checked against a
-- different mart than the one the report is built from, so a join that loses or doubles
-- claims shows up:
--
--   rpt_loss_ratio_by_period (built on fct_claim_exposure_period_balances) vs.
--   fct_claim_transactions: per booked period and line, net paid loss, calendar-period
--   incurred loss (paid + reserve change) and incurred LAE, for periods up to the valuation
--   period.
--
--   rpt_loss_ratio_by_accident_year (built on dim_claims) vs. fct_claim_exposure_period_balances
--   at the valuation period: per accident year and line, net paid and incurred loss.
--
-- Exact: sums of the same two-decimal amounts on both sides.
with claim_transactions as (
    select * from {{ ref('fct_claim_transactions') }}
),

balances as (
    select * from {{ ref('fct_claim_exposure_period_balances') }}
),

by_period as (
    select * from {{ ref('rpt_loss_ratio_by_period') }}
),

by_accident_year as (
    select * from {{ ref('rpt_loss_ratio_by_accident_year') }}
),

expected_by_period as (
    select
        accounting_period as period,
        line_of_business,
        sum(case when cost_category = 'LOSS' then paid_amount else 0 end) as net_paid_loss_amount,
        sum(case when cost_category = 'LOSS' then paid_amount + reserve_change_amount else 0 end)
            as incurred_loss_amount,
        sum(case when cost_category = 'EXPENSE' then paid_amount + reserve_change_amount else 0 end)
            as incurred_lae_amount
    from claim_transactions
    where accounting_period <= {{ claims_valuation_period() }}
    group by all
),

expected_by_year as (
    select
        cast(accident_year as varchar) as period,
        line_of_business,
        sum(itd_paid_amount) as net_paid_loss_amount,
        sum(incurred_amount) as incurred_loss_amount
    from balances
    where cost_category = 'LOSS'
        and accounting_period = {{ claims_valuation_period() }}
    group by all
),

actual_by_period as (
    select
        accounting_period as period,
        line_of_business,
        net_paid_loss_amount,
        incurred_loss_amount,
        incurred_lae_amount
    from by_period
),

actual_by_year as (
    select
        cast(accident_year as varchar) as period,
        line_of_business,
        net_paid_loss_amount,
        incurred_loss_amount
    from by_accident_year
),

compared as (
    select
        'rpt_loss_ratio_by_period' as report,
        coalesce(expected.period, actual.period) as period,
        coalesce(expected.line_of_business, actual.line_of_business) as line_of_business,
        coalesce(actual.net_paid_loss_amount, 0) - coalesce(expected.net_paid_loss_amount, 0)
            as net_paid_difference,
        coalesce(actual.incurred_loss_amount, 0) - coalesce(expected.incurred_loss_amount, 0)
            as incurred_difference,
        coalesce(actual.incurred_lae_amount, 0) - coalesce(expected.incurred_lae_amount, 0)
            as lae_difference
    from expected_by_period as expected
    full outer join actual_by_period as actual
        on expected.period = actual.period
        and expected.line_of_business = actual.line_of_business

    union all

    select
        'rpt_loss_ratio_by_accident_year' as report,
        coalesce(expected.period, actual.period) as period,
        coalesce(expected.line_of_business, actual.line_of_business) as line_of_business,
        coalesce(actual.net_paid_loss_amount, 0) - coalesce(expected.net_paid_loss_amount, 0)
            as net_paid_difference,
        coalesce(actual.incurred_loss_amount, 0) - coalesce(expected.incurred_loss_amount, 0)
            as incurred_difference,
        0 as lae_difference
    from expected_by_year as expected
    full outer join actual_by_year as actual
        on expected.period = actual.period
        and expected.line_of_business = actual.line_of_business
)

select *
from compared
where net_paid_difference <> 0
    or incurred_difference <> 0
    or lae_difference <> 0
order by report, period, line_of_business
