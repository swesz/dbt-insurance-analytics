-- Every subledger-to-GL difference is explained: per closed period, line of business and
-- account, the difference between the ledger and the subledgers equals the documented
-- reconciling items within a cent (docs/source-systems.md 3h, seeds/gl_reconciling_items.csv).
--
-- A failing row is either a bug (in these models, an upstream model or the generator) or a
-- real reconciling item nobody has documented yet. The fix is never to widen the tolerance: find
-- the cause, and document it only if the ledger is right to differ.

with reconciliation as (
    select * from {{ ref('rpt_subledger_gl_reconciliation') }}
)

select *
from reconciliation
where abs(unexplained_difference) > {{ accounting_reconciliation_tolerance() }}
    or status = 'UNEXPLAINED'
