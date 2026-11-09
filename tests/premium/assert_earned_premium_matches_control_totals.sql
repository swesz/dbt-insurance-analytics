-- Earned premium per accounting period and line of business equals the generator's control
-- total (docs/source-systems.md 5) to the cent. Both sides round each line's inception-to-date
-- earned amount half away from zero in integer cents and then sum (D-008), so any difference,
-- even a cent, means the two implementations disagree on a window or a booking. A tolerance
-- would hide exactly the small errors: a one-day slip on a $60 coverage is 33 cents.
-- Compares only on the load the totals belong to.

with load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

control_totals as (
    select * from {{ source('generator_audit', 'control_totals') }}
),

premium as (
    select * from {{ ref('fct_premium_by_policy_period') }}
),

expected as (
    select
        control_totals.period as accounting_period,
        control_totals.line_of_business,
        control_totals.value
    from control_totals
    inner join load_info
        on control_totals.as_of = load_info.as_of
    where control_totals.metric = 'earned_premium'
        and control_totals.grain = 'accounting_period'
),

actual as (
    select
        accounting_period,
        line_of_business,
        sum(earned_premium) as value
    from premium
    group by 1, 2
),

compared as (
    select
        coalesce(expected.accounting_period, actual.accounting_period) as accounting_period,
        coalesce(expected.line_of_business, actual.line_of_business) as line_of_business,
        expected.value as expected_value,
        actual.value as actual_value,
        coalesce(actual.value, 0) - coalesce(expected.value, 0) as difference
    from expected
    full outer join actual
        on expected.accounting_period = actual.accounting_period
        and expected.line_of_business = actual.line_of_business
)

select *
from compared
where exists (select 1 from expected)
    and abs(difference) > 0
