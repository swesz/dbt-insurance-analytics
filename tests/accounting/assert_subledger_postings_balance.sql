-- The postings built from the subledgers are balanced entries: per period and line of
-- business their signed amounts sum to zero. Every entry in int_accounting__subledger_postings
-- is two legs of opposite sign, so a non-zero sum means a leg was dropped or a sign flipped.
-- Unlike the ledger, nothing here moves amounts between lines of business, so the check can be
-- per line.

with postings as (
    select * from {{ ref('int_accounting__subledger_postings') }}
)

select
    accounting_period,
    line_of_business,
    sum(subledger_amount) as out_of_balance
from postings
group by 1, 2
having sum(subledger_amount) <> 0
