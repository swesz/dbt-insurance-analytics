-- Premium receivable at each period end, per line of business: what policyholders owe, split
-- into what is already due and what is billed for later, and tied to the ledger's 1200.
--
-- How to read a row (all inception-to-date at the period end):
--   itd_written_premium         premium booked so far (booking rule, docs/source-systems.md 3c)
--   itd_billed_due_amount       installments of those transactions that have fallen due
--   itd_collected_amount        cash received, net of refunds and bank returns (by month of
--                               receipt, returns by month of return, as the ledger books it)
--   receivable_amount           written - collected: the ledger's view. Written premium is
--                               debited to 1200 when booked, cash is credited to it when it
--                               arrives, so 1200 holds exactly this
--   billed_due_receivable_amount  billed and due - collected: what is owed now. Negative when
--                               customers paid ahead of their due dates
--   not_yet_due_amount          written - billed and due: installments scheduled after the
--                               period end, a receivable that is not yet collectible. Gross:
--                               cash paid ahead lowers billed_due_receivable_amount, not this
--                               (the aging's open_not_yet_due_amount is the net figure)
-- so receivable_amount = billed_due_receivable_amount + not_yet_due_amount.
--
-- An insurer books the whole term's premium as written on day one, even on a monthly plan, so
-- most of the receivable of a monthly-plan book is not yet due; aging only makes sense for the
-- due part (rpt_premium_receivable_aging).
--
-- Due dates are the installments' current state: a due date the customer moved is seen at the
-- new date in every period (the source overwrites it; the history would need a snapshot).
with premium as (
    select * from {{ ref('fct_premium_by_policy_period') }}
),

transaction_lines as (
    select * from {{ ref('fct_policy_transaction_lines') }}
),

installments as (
    select * from {{ ref('stg_billing__installments') }}
),

cash_events as (
    select * from {{ ref('int_accounting__billing_cash_events') }}
),

gl_balances as (
    select * from {{ ref('int_accounting__gl_balances_by_period') }}
),

accounting_periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

written_by_period as (
    select
        accounting_period,
        line_of_business,
        sum(written_premium) as written_premium
    from premium
    group by 1, 2
),

booked_transactions as (
    select distinct
        transaction_id,
        line_of_business,
        accounting_period as booked_period
    from transaction_lines
),

-- An installment counts as billed and due from the later of two periods: the one its
-- transaction is booked in (before that, the premium is not written yet, so it cannot be owed)
-- and the one containing its due date. Assigning each installment to that single period and
-- summing to date avoids a periods x installments cross join.
billed_due_by_period as (
    select
        greatest(booked_transactions.booked_period, due_periods.accounting_period)
            as accounting_period,
        booked_transactions.line_of_business,
        sum(installments.installment_amount) as billed_due_amount
    from installments
    -- Inner join: drops test policies' installments (their transactions are not in the fact).
    inner join booked_transactions
        on installments.transaction_id = booked_transactions.transaction_id
    inner join accounting_periods as due_periods
        on installments.due_date between due_periods.period_start_date
            and due_periods.period_end_date
    where not installments.is_test_policy
    group by 1, 2
),

collected_by_period as (
    select
        accounting_period,
        line_of_business,
        sum(cash_amount) as collected_amount
    from cash_events
    group by 1, 2
),

spine as (
    select
        accounting_periods.accounting_period,
        accounting_periods.period_sequence,
        accounting_periods.period_end_date,
        accounting_periods.is_closed_at_valuation,
        lines_of_business.line_of_business
    from accounting_periods
    cross join (select distinct line_of_business from written_by_period) as lines_of_business
    where accounting_periods.accounting_period >= (select min(accounting_period) from written_by_period)
        and not accounting_periods.is_after_valuation
),

to_date as (
    select
        spine.accounting_period,
        spine.period_end_date,
        spine.is_closed_at_valuation,
        spine.line_of_business,
        sum(coalesce(written_by_period.written_premium, 0)) over itd as itd_written_premium,
        sum(coalesce(billed_due_by_period.billed_due_amount, 0)) over itd as itd_billed_due_amount,
        sum(coalesce(collected_by_period.collected_amount, 0)) over itd as itd_collected_amount
    from spine
    left join written_by_period
        on spine.accounting_period = written_by_period.accounting_period
        and spine.line_of_business = written_by_period.line_of_business
    left join billed_due_by_period
        on spine.accounting_period = billed_due_by_period.accounting_period
        and spine.line_of_business = billed_due_by_period.line_of_business
    left join collected_by_period
        on spine.accounting_period = collected_by_period.accounting_period
        and spine.line_of_business = collected_by_period.line_of_business
    window itd as (
        partition by spine.line_of_business
        order by spine.period_sequence
        rows between unbounded preceding and current row
    )
),

final as (
    select
        cast(to_date.accounting_period || '|' || to_date.line_of_business as varchar)
            as receivable_key,
        cast(to_date.accounting_period as varchar) as accounting_period,
        cast(to_date.period_end_date as date) as period_end_date,
        cast(to_date.line_of_business as varchar) as line_of_business,
        cast(to_date.itd_written_premium as decimal(18, 2)) as itd_written_premium,
        cast(to_date.itd_billed_due_amount as decimal(18, 2)) as itd_billed_due_amount,
        cast(to_date.itd_collected_amount as decimal(18, 2)) as itd_collected_amount,
        cast(to_date.itd_written_premium - to_date.itd_collected_amount as decimal(18, 2))
            as receivable_amount,
        cast(to_date.itd_billed_due_amount - to_date.itd_collected_amount as decimal(18, 2))
            as billed_due_receivable_amount,
        cast(to_date.itd_written_premium - to_date.itd_billed_due_amount as decimal(18, 2))
            as not_yet_due_amount,
        cast(to_date.is_closed_at_valuation as boolean) as is_period_closed,
        -- 1200 is debit-normal, so its signed balance is already in the natural sign.
        cast(gl_balances.gl_itd_balance_amount as decimal(18, 2)) as gl_receivable_amount,
        cast(gl_balances.gl_itd_balance_amount
            - (to_date.itd_written_premium - to_date.itd_collected_amount) as decimal(18, 2))
            as gl_difference,
        cast(gl_balances.documented_items_itd_amount as decimal(18, 2)) as documented_items_amount,
        cast(
            gl_balances.gl_itd_balance_amount
            - (to_date.itd_written_premium - to_date.itd_collected_amount)
            - gl_balances.documented_items_itd_amount
        as decimal(18, 2)) as unexplained_difference
    from to_date
    left join gl_balances
        on to_date.accounting_period = gl_balances.accounting_period
        and to_date.line_of_business = gl_balances.line_of_business
        and gl_balances.account_number = '1200'
)

select * from final
