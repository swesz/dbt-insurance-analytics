-- The case reserve rollforward ties, and agrees with the ledger:
--   1. opening + incurred - paid = closing, per period, line of business and cost category,
--      and the opening balance is the prior period's closing balance;
--   2. the closing reserve equals the claims subledger's own month-end balances
--      (fct_claim_exposure_period_balances summed), an independent computation of the same
--      figure from the claims team's model;
--   3. for every closed period, the closing reserve equals the ledger's 2200 (LOSS) or 2300
--      (EXPENSE) balance, apart from documented reconciling items.
-- Within a cent (macro accounting_reconciliation_tolerance).

with rollforward as (
    select * from {{ ref('rpt_loss_reserve_rollforward') }}
),

exposure_balances as (
    select * from {{ ref('fct_claim_exposure_period_balances') }}
),

claims_view as (
    select
        accounting_period,
        line_of_business,
        cost_category,
        sum(case_reserve_amount) as case_reserve_amount
    from exposure_balances
    group by 1, 2, 3
),

checked as (
    select
        rollforward.*,
        rollforward.opening_case_reserve + rollforward.incurred_amount
            - rollforward.paid_amount - rollforward.closing_case_reserve as rollforward_break,
        rollforward.opening_case_reserve - coalesce(lag(rollforward.closing_case_reserve) over (
            partition by rollforward.line_of_business, rollforward.cost_category
            order by rollforward.accounting_period
        ), 0) as opening_break,
        rollforward.closing_case_reserve - coalesce(claims_view.case_reserve_amount, 0)
            as claims_subledger_break
    from rollforward
    left join claims_view
        on rollforward.accounting_period = claims_view.accounting_period
        and rollforward.line_of_business = claims_view.line_of_business
        and rollforward.cost_category = claims_view.cost_category
)

select *
from checked
where abs(rollforward_break) > {{ accounting_reconciliation_tolerance() }}
    or abs(opening_break) > {{ accounting_reconciliation_tolerance() }}
    or abs(claims_subledger_break) > {{ accounting_reconciliation_tolerance() }}
    or (
        is_period_closed
        and abs(coalesce(unexplained_difference, 0)) > {{ accounting_reconciliation_tolerance() }}
    )
