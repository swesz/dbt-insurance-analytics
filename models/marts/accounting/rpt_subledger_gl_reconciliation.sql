-- The subledger-to-general-ledger reconciliation: for every closed accounting period, line of
-- business and GL account, what the subledgers say the ledger should hold, what it does hold,
-- and whether every difference is explained.
--
-- What a reconciliation proves: that each figure in the ledger, which is what the financial
-- statements are built from, is supported by the detailed records (policies, payments, claims),
-- and that nothing was posted twice, posted to the wrong line or account, or left out. It does
-- not prove the subledgers themselves are right; the control-total tests in tests/premium and
-- tests/claims do that.
--
-- Columns, all signed debit positive and credit negative:
--   difference                = gl_amount - subledger_amount
--   documented_items_amount   = the reconciling items an accountant has documented for the row
--                               in seeds/gl_reconciling_items.csv, signed the same way: the
--                               amount by which the ledger is expected to differ
--   unexplained_difference    = difference - documented_items_amount
-- and status:
--   MATCHED      no difference and nothing documented
--   EXPLAINED    a difference, fully accounted for by documented items
--   UNEXPLAINED  anything else, including a documented item that no longer matches a
--                difference (a stale or wrong item is a finding too)
--
-- Scope: periods that are closed at the valuation date (only closed periods have a ledger
-- export) plus any period the ledger has, so a file for a period that should not exist yet
-- would show up instead of being ignored.
with postings as (
    select * from {{ ref('int_accounting__subledger_postings') }}
),

journal_lines as (
    select * from {{ ref('stg_general_ledger__journal_lines') }}
),

reconciling_items as (
    select * from {{ ref('gl_reconciling_items') }}
),

accounting_periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

gl_accounts as (
    select * from {{ ref('gl_accounts') }}
),

periods_in_scope as (
    select accounting_period
    from accounting_periods
    where is_closed_at_valuation
    union
    select distinct accounting_period
    from journal_lines
),

subledger as (
    select
        accounting_period,
        line_of_business,
        account_number,
        subledger_amount
    from postings
    where accounting_period in (select accounting_period from periods_in_scope)
),

ledger as (
    select
        accounting_period,
        line_of_business,
        account_number,
        sum(net_amount) as gl_amount
    from journal_lines
    group by 1, 2, 3
),

documented as (
    select
        accounting_period,
        line_of_business,
        account_number,
        sum(amount) as documented_items_amount,
        count(*) as documented_item_count
    from reconciling_items
    group by 1, 2, 3
),

-- Every key that appears on any of the three sides: a posting the ledger lacks, a ledger line
-- with no subledger behind it (a manual journal), and a documented item with neither.
keys as (
    select accounting_period, line_of_business, account_number from subledger
    union
    select accounting_period, line_of_business, account_number from ledger
    union
    select accounting_period, line_of_business, account_number from documented
),

compared as (
    select
        keys.accounting_period,
        keys.line_of_business,
        keys.account_number,
        coalesce(subledger.subledger_amount, 0) as subledger_amount,
        coalesce(ledger.gl_amount, 0) as gl_amount,
        coalesce(ledger.gl_amount, 0) - coalesce(subledger.subledger_amount, 0) as difference,
        coalesce(documented.documented_items_amount, 0) as documented_items_amount,
        coalesce(documented.documented_item_count, 0) as documented_item_count
    from keys
    left join subledger
        on keys.accounting_period = subledger.accounting_period
        and keys.line_of_business = subledger.line_of_business
        and keys.account_number = subledger.account_number
    left join ledger
        on keys.accounting_period = ledger.accounting_period
        and keys.line_of_business = ledger.line_of_business
        and keys.account_number = ledger.account_number
    left join documented
        on keys.accounting_period = documented.accounting_period
        and keys.line_of_business = documented.line_of_business
        and keys.account_number = documented.account_number
),

final as (
    select
        cast(compared.accounting_period || '|' || compared.line_of_business || '|'
            || compared.account_number as varchar) as reconciliation_key,
        cast(compared.accounting_period as varchar) as accounting_period,
        cast(compared.line_of_business as varchar) as line_of_business,
        cast(compared.account_number as varchar) as account_number,
        cast(gl_accounts.account_name as varchar) as account_name,
        cast(gl_accounts.account_type as varchar) as account_type,
        cast(compared.subledger_amount as decimal(18, 2)) as subledger_amount,
        cast(compared.gl_amount as decimal(18, 2)) as gl_amount,
        cast(compared.difference as decimal(18, 2)) as difference,
        cast(compared.documented_items_amount as decimal(18, 2)) as documented_items_amount,
        cast(compared.documented_item_count as integer) as documented_item_count,
        cast(compared.difference - compared.documented_items_amount as decimal(18, 2))
            as unexplained_difference,
        cast(case
            when abs(compared.difference) <= {{ accounting_reconciliation_tolerance() }}
                and compared.documented_item_count = 0
                then 'MATCHED'
            when abs(compared.difference - compared.documented_items_amount)
                <= {{ accounting_reconciliation_tolerance() }}
                then 'EXPLAINED'
            else 'UNEXPLAINED'
        end as varchar) as status
    from compared
    left join gl_accounts
        on compared.account_number = gl_accounts.account_number
)

select * from final
