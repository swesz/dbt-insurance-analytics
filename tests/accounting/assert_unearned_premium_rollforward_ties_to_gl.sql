-- The unearned premium rollforward ties, and agrees with the ledger:
--   1. opening + written - earned = closing, per period and line of business, and the opening
--      balance is the prior period's closing balance (lag-based, so a gap in the spine would
--      break it);
--   2. for every closed period, the closing UPR equals the ledger's 2100 balance, apart from
--      documented reconciling items.
-- Exact to the cent: the tolerance (macro accounting_reconciliation_tolerance) is zero.

with rollforward as (
    select * from {{ ref('rpt_unearned_premium_rollforward') }}
),

checked as (
    select
        *,
        opening_unearned_premium + written_premium - earned_premium - closing_unearned_premium
            as rollforward_break,
        opening_unearned_premium - coalesce(lag(closing_unearned_premium) over (
            partition by line_of_business
            order by accounting_period
        ), 0) as opening_break
    from rollforward
)

select *
from checked
where abs(rollforward_break) > {{ accounting_reconciliation_tolerance() }}
    or abs(opening_break) > {{ accounting_reconciliation_tolerance() }}
    or (
        is_period_closed
        and abs(coalesce(unexplained_difference, 0)) > {{ accounting_reconciliation_tolerance() }}
    )
