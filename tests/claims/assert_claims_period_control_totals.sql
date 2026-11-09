-- Claims figures per accounting period and line of business match the generator's control
-- totals (docs/source-systems.md, section 5). The generator computes them in Python from its own
-- records; dbt computes them in SQL from the raw tables. Neither uses the other's code, so
-- agreement is evidence that both implement the rules in section 3 the same way.
--
--   paid_loss_net             loss payments - loss recoveries, voids reversed at the void
--   paid_expense              expense payments, same booking
--   case_reserve_loss_end     LOSS reserve changes booked in the period or earlier
--   case_reserve_expense_end  same for EXPENSE
--   claims_reported           claims by month of reported_at
--
-- Tolerance: none. Every figure is a sum of two-decimal amounts or a count, with no rounding on
-- either side, so they must agree to the cent.
--
-- The control totals are valid only for a load at their as_of (the default, valuation-date
-- load). On any other load the comparison is skipped and the test passes with no rows.
-- Paid comes from fct_claim_transactions and reserves from fct_claim_exposure_period_balances,
-- so the test covers both facts.
with load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

control_totals as (
    select * from {{ source('generator_audit', 'control_totals') }}
),

claim_transactions as (
    select * from {{ ref('fct_claim_transactions') }}
),

balances as (
    select * from {{ ref('fct_claim_exposure_period_balances') }}
),

claims as (
    select * from {{ ref('dim_claims') }}
),

expected as (
    select
        control_totals.metric,
        control_totals.period,
        control_totals.line_of_business,
        control_totals.value
    from control_totals
    inner join load_info
        on control_totals.as_of = load_info.as_of
    where control_totals.grain = 'accounting_period'
        and control_totals.metric in (
            'paid_loss_net', 'paid_expense', 'case_reserve_loss_end',
            'case_reserve_expense_end', 'claims_reported'
        )
),

actual_paid as (
    select
        'paid_loss_net' as metric,
        accounting_period as period,
        line_of_business,
        cast(sum(paid_amount) as decimal(18, 2)) as value
    from claim_transactions
    where cost_category = 'LOSS'
    group by all

    union all

    select
        'paid_expense' as metric,
        accounting_period as period,
        line_of_business,
        cast(sum(paid_amount) as decimal(18, 2)) as value
    from claim_transactions
    where cost_category = 'EXPENSE'
    group by all
),

actual_reserves as (
    select
        case cost_category
            when 'LOSS' then 'case_reserve_loss_end'
            else 'case_reserve_expense_end'
        end as metric,
        accounting_period as period,
        line_of_business,
        cast(sum(case_reserve_amount) as decimal(18, 2)) as value
    from balances
    group by all
),

actual_reported as (
    select
        'claims_reported' as metric,
        strftime(reported_at, '%Y-%m') as period,
        line_of_business,
        cast(count(*) as decimal(18, 2)) as value
    from claims
    group by all
),

actual as (
    select * from actual_paid
    union all
    select * from actual_reserves
    union all
    select * from actual_reported
),

compared as (
    select
        coalesce(expected.metric, actual.metric) as metric,
        coalesce(expected.period, actual.period) as period,
        coalesce(expected.line_of_business, actual.line_of_business) as line_of_business,
        expected.value as expected_value,
        actual.value as actual_value,
        coalesce(actual.value, 0) - coalesce(expected.value, 0) as difference
    from expected
    full outer join actual
        on expected.metric = actual.metric
        and expected.period = actual.period
        and expected.line_of_business = actual.line_of_business
)

select *
from compared
-- A missing row on one side counts as zero, so a period with no activity on either side is no
-- difference. Compare only when the load matches the control totals' as_of.
where difference <> 0
    and exists (select 1 from expected)
order by metric, period, line_of_business
