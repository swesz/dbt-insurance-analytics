-- Unearned premium at each period end, per line of business, equals the generator's control
-- total (docs/source-systems.md 5) to the cent, for the same reason as earned premium: both
-- sides round per line in integer cents the same way (D-008). Compares only on the load the
-- totals belong to.

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
    where control_totals.metric = 'unearned_premium_end'
        and control_totals.grain = 'accounting_period'
),

actual as (
    select
        accounting_period,
        line_of_business,
        sum(unearned_premium_end) as value
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
