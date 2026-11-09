-- The case reserve rollforward agrees with independent records of the same figures:
--   1. the ledger: for every closed period, the closing reserve equals the ledger's 2200 (LOSS)
--      or 2300 (EXPENSE) balance, apart from documented reconciling items. The ledger only
--      ever received the monthly reserve-change postings, so a match proves every month's
--      posting up to then;
--   2. the generator: on the default load, the closing reserve and the period's net paid equal
--      the generator's control totals (case_reserve_loss_end, case_reserve_expense_end,
--      paid_loss_net, paid_expense) per period and line of business, which it computes in
--      Python from its own records;
--   3. the claims mart: the closing reserve equals fct_claim_exposure_period_balances summed.
--      Both models are built from int_claims__financial_events, so this does not check how
--      claim transactions are booked (1 and 2 do). It checks aggregation: that the
--      rollforward, built on the incremental fct_claim_transactions, agrees with the balances,
--      rebuilt in full every run, so an event an incremental run lost or doubled would show.
--
-- Not tested: opening + incurred - paid = closing, and opening = the prior closing. The report
-- defines incurred as paid + the change in reserve, and the opening as closing - change, so
-- both hold by algebra and a test of them could never fail.
--
-- Exact to the cent: the tolerance (macro accounting_reconciliation_tolerance) is zero. The
-- control-total check runs only on the load the control totals describe (load_info.as_of);
-- on any other load it returns nothing and the other two checks still apply.
with rollforward as (
    select * from {{ ref('rpt_loss_reserve_rollforward') }}
),

exposure_balances as (
    select * from {{ ref('fct_claim_exposure_period_balances') }}
),

load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

control_totals as (
    select * from {{ source('generator_audit', 'control_totals') }}
),

ledger_breaks as (
    select
        accounting_period,
        line_of_business,
        cost_category as measure,
        'ledger' as check_name,
        unexplained_difference as break_amount
    from rollforward
    where is_period_closed
        and abs(coalesce(unexplained_difference, 0)) > {{ accounting_reconciliation_tolerance() }}
),

expected as (
    select
        control_totals.metric,
        control_totals.period as accounting_period,
        control_totals.line_of_business,
        control_totals.value
    from control_totals
    inner join load_info
        on control_totals.as_of = load_info.as_of
    where control_totals.grain = 'accounting_period'
        and control_totals.metric in (
            'case_reserve_loss_end', 'case_reserve_expense_end', 'paid_loss_net', 'paid_expense'
        )
),

actual as (
    select
        case cost_category
            when 'LOSS' then 'case_reserve_loss_end'
            else 'case_reserve_expense_end'
        end as metric,
        accounting_period,
        line_of_business,
        closing_case_reserve as value
    from rollforward

    union all

    select
        case cost_category when 'LOSS' then 'paid_loss_net' else 'paid_expense' end as metric,
        accounting_period,
        line_of_business,
        paid_amount as value
    from rollforward
),

-- A row missing on one side counts as zero (a period without activity), so the full outer
-- join also catches a period the report lacks or one the generator does not know.
control_total_breaks as (
    select
        coalesce(expected.accounting_period, actual.accounting_period) as accounting_period,
        coalesce(expected.line_of_business, actual.line_of_business) as line_of_business,
        coalesce(expected.metric, actual.metric) as measure,
        'control_totals' as check_name,
        coalesce(actual.value, 0) - coalesce(expected.value, 0) as break_amount
    from expected
    full outer join actual
        on expected.metric = actual.metric
        and expected.accounting_period = actual.accounting_period
        and expected.line_of_business = actual.line_of_business
    where abs(coalesce(actual.value, 0) - coalesce(expected.value, 0))
            > {{ accounting_reconciliation_tolerance() }}
        and exists (select 1 from expected)
),

claims_mart as (
    select
        accounting_period,
        line_of_business,
        cost_category,
        sum(case_reserve_amount) as case_reserve_amount
    from exposure_balances
    group by 1, 2, 3
),

claims_mart_breaks as (
    select
        rollforward.accounting_period,
        rollforward.line_of_business,
        rollforward.cost_category as measure,
        'claims_mart' as check_name,
        rollforward.closing_case_reserve - coalesce(claims_mart.case_reserve_amount, 0)
            as break_amount
    from rollforward
    left join claims_mart
        on rollforward.accounting_period = claims_mart.accounting_period
        and rollforward.line_of_business = claims_mart.line_of_business
        and rollforward.cost_category = claims_mart.cost_category
    where abs(rollforward.closing_case_reserve - coalesce(claims_mart.case_reserve_amount, 0))
        > {{ accounting_reconciliation_tolerance() }}
)

select * from ledger_breaks
union all
select * from control_total_breaks
union all
select * from claims_mart_breaks
