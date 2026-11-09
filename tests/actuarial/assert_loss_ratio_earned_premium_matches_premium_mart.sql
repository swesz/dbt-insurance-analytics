-- Earned premium in both loss ratio reports equals the premium subledger
-- (fct_premium_by_policy_period): per accounting period and line in rpt_loss_ratio_by_period,
-- per calendar year and line in rpt_loss_ratio_by_accident_year. The reports build spines and
-- join premium onto them, so a missing period, a duplicated join row or a wrong year would show
-- here. The expected side groups by the period string, independent of the reports' joins.
-- Exact: both sides are sums of the same two-decimal amounts.
with premium as (
    select * from {{ ref('fct_premium_by_policy_period') }}
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
        sum(earned_premium) as earned_premium
    from premium
    group by all
),

expected_by_year as (
    select
        left(accounting_period, 4) as period,
        line_of_business,
        sum(earned_premium) as earned_premium
    from premium
    group by all
),

compared as (
    select
        'rpt_loss_ratio_by_period' as report,
        coalesce(expected.period, actual.accounting_period) as period,
        coalesce(expected.line_of_business, actual.line_of_business) as line_of_business,
        expected.earned_premium as expected_earned_premium,
        actual.earned_premium as actual_earned_premium
    from expected_by_period as expected
    full outer join by_period as actual
        on expected.period = actual.accounting_period
        and expected.line_of_business = actual.line_of_business

    union all

    select
        'rpt_loss_ratio_by_accident_year' as report,
        coalesce(expected.period, cast(actual.accident_year as varchar)) as period,
        coalesce(expected.line_of_business, actual.line_of_business) as line_of_business,
        expected.earned_premium as expected_earned_premium,
        actual.earned_premium as actual_earned_premium
    from expected_by_year as expected
    full outer join by_accident_year as actual
        on expected.period = cast(actual.accident_year as varchar)
        and expected.line_of_business = actual.line_of_business
)

select *
from compared
-- A row missing on one side counts as zero: a report row without premium is fine, premium
-- without a report row is not (it would be nonzero on one side only).
where coalesce(expected_earned_premium, 0) <> coalesce(actual_earned_premium, 0)
order by report, period, line_of_business
