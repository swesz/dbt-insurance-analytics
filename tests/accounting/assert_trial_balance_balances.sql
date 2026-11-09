-- Double entry: in every period of the ledger, total debits equal total credits, over all
-- accounts and lines of business. A difference means the export lost or duplicated lines, or
-- an amount was parsed wrongly (say, a thousands separator read as a decimal point).
--
-- Checked per period, not per line of business: a manual journal may move an amount from one
-- line to the other (the 2024-06 reclass), which balances only across both.

with trial_balance as (
    select * from {{ ref('rpt_trial_balance') }}
)

select
    accounting_period,
    sum(debit_amount) as total_debits,
    sum(credit_amount) as total_credits,
    sum(debit_amount) - sum(credit_amount) as out_of_balance
from trial_balance
group by 1
having sum(debit_amount) <> sum(credit_amount)
