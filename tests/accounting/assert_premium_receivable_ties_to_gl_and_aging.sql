-- The premium receivable agrees with the ledger and with its own aging:
--   1. for every closed period, written - collected equals the ledger's 1200 balance, apart
--      from documented reconciling items;
--   2. at the valuation period, the per-policy aging (built installment by installment from
--      billing) adds up to the same receivable per line of business (built from written
--      premium and cash). The two start from different tables, so this also checks that
--      billing billed what was written.
-- Within a cent (macro accounting_reconciliation_tolerance).

with receivable as (
    select * from {{ ref('rpt_premium_receivable') }}
),

aging as (
    select * from {{ ref('rpt_premium_receivable_aging') }}
),

accounting_periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

aging_by_line as (
    select
        line_of_business,
        sum(receivable_amount) as aging_receivable_amount
    from aging
    group by 1
),

ledger_breaks as (
    select
        accounting_period,
        line_of_business,
        'ledger' as check_name,
        unexplained_difference as break_amount
    from receivable
    where is_period_closed
        and abs(coalesce(unexplained_difference, 0)) > {{ accounting_reconciliation_tolerance() }}
),

aging_breaks as (
    select
        receivable.accounting_period,
        receivable.line_of_business,
        'aging' as check_name,
        receivable.receivable_amount - coalesce(aging_by_line.aging_receivable_amount, 0)
            as break_amount
    from receivable
    inner join accounting_periods
        on receivable.accounting_period = accounting_periods.accounting_period
    left join aging_by_line
        on receivable.line_of_business = aging_by_line.line_of_business
    where accounting_periods.is_valuation_period
        and abs(receivable.receivable_amount - coalesce(aging_by_line.aging_receivable_amount, 0))
            > {{ accounting_reconciliation_tolerance() }}
)

select * from ledger_breaks
union all
select * from aging_breaks
