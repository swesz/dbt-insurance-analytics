-- Policies in force at each period end, per line of business, equal the generator's control
-- total exactly (docs/source-systems.md 3e and 5). Compares only on the load the totals
-- belong to.

with load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

control_totals as (
    select * from {{ source('generator_audit', 'control_totals') }}
),

month_end as (
    select * from {{ ref('fct_policy_month_end') }}
),

expected as (
    select
        control_totals.period as accounting_period,
        control_totals.line_of_business,
        control_totals.value
    from control_totals
    inner join load_info
        on control_totals.as_of = load_info.as_of
    where control_totals.metric = 'policies_in_force_end'
        and control_totals.grain = 'accounting_period'
),

actual as (
    select
        accounting_period,
        line_of_business,
        count(case when is_in_force then 1 end) as value
    from month_end
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
