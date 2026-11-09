-- The unearned premium rollforward agrees with independent records of the same figures:
--   1. the ledger: for every closed period, the closing UPR equals the ledger's 2100 balance,
--      apart from documented reconciling items. The ledger only ever received the monthly
--      "increase in UPR" postings, so a match proves every month's posting up to then;
--   2. the generator: on the default load, written premium, earned premium and closing UPR
--      equal the generator's control totals (written_premium, earned_premium,
--      unearned_premium_end) per period and line of business, which it computes in Python
--      from its own records;
--   3. the premium subledger's own consistency: opening + written - earned = closing. Written,
--      earned and the closing UPR are three separate columns of fct_premium_by_policy_period,
--      so this can fail. tests/premium checks the same identity per policy and coverage; here
--      it also catches a gap in the report's period spine, which would carry the wrong opening.
--
-- Not tested: opening = the prior period's closing. The report computes the opening with
-- lag(), so recomputing that lag here could never disagree.
--
-- Exact to the cent: the tolerance (macro accounting_reconciliation_tolerance) is zero. The
-- control-total check runs only on the load the control totals describe (load_info.as_of);
-- on any other load it returns nothing and the other two checks still apply.
with rollforward as (
    select * from {{ ref('rpt_unearned_premium_rollforward') }}
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
        'closing_unearned_premium' as measure,
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
        and control_totals.metric in ('written_premium', 'earned_premium', 'unearned_premium_end')
),

actual as (
    select 'written_premium' as metric, accounting_period, line_of_business, written_premium as value
    from rollforward
    union all
    select 'earned_premium', accounting_period, line_of_business, earned_premium
    from rollforward
    union all
    select 'unearned_premium_end', accounting_period, line_of_business, closing_unearned_premium
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

subledger_breaks as (
    select
        accounting_period,
        line_of_business,
        'opening + written - earned - closing' as measure,
        'subledger' as check_name,
        opening_unearned_premium + written_premium - earned_premium - closing_unearned_premium
            as break_amount
    from rollforward
    where abs(opening_unearned_premium + written_premium - earned_premium - closing_unearned_premium)
        > {{ accounting_reconciliation_tolerance() }}
)

select * from ledger_breaks
union all
select * from control_total_breaks
union all
select * from subledger_breaks
