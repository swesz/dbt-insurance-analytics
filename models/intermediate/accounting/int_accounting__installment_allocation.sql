-- Each positive installment at the valuation date, with how much of it is settled and how
-- much is still open: the basis of the receivable aging (rpt_premium_receivable_aging).
--
-- The billing system records what is billed (installments, per transaction) and what is paid
-- (payments, per policy), but never which payment settles which installment. Aging needs that
-- link, so it is constructed here, in two passes over the policy's positive installments.
--
-- First, which credits are still available. A credit installment (a cancellation's return
-- premium, a credit endorsement) is not money: it lowers what the customer owes. Billing often
-- pays a credit out as a refund instead (a credit endorsement is refunded, a cancellation
-- refunds what was paid beyond the premium owed). A credit that was refunded has been settled
-- in cash and can no longer lower another installment, so refunds use up credits first:
--     credit pool  = credits - refunds, if positive
--     cash pool    = receipts - bank returns - (refunds beyond the credits)
-- Without that netting, a refunded credit would count twice: once lowering the installments
-- and once lowering the cash, and the aging would show paid installments as past due.
--
-- Pass 1, the credit pool, latest due first. A cancellation takes away the end of the
-- coverage, so its credit takes away the end of the schedule. Applied oldest-first instead, the
-- credit would "pay" the very installment a nonpayment cancellation was triggered by, and the
-- aging would show the debt as younger than it is.
--
-- Pass 2, the cash pool, oldest due first (first in, first out). A payment carries only the
-- policy, so the policy's cash settles what credits left open, from the oldest due date
-- onward, ties broken by installment_id. That is the usual convention for open-item aging: a
-- customer who pays is assumed to pay their oldest debt, so nothing looks more overdue than it
-- is. Cash or credit beyond everything billed stays unapplied (a credit balance).
--
-- Both passes are one window function each: with the amounts in allocation order and a
-- running total, an installment receives what is left of the pool after the installments
-- before it, capped at its own amount:
--     applied = greatest(0, least(amount, pool - (running_total - amount)))
--
-- Scope: installments of real policies' transactions booked in or before the valuation period
-- (a transaction dated after it is not written premium yet), and cash to the valuation date.
with installments as (
    select * from {{ ref('stg_billing__installments') }}
),

transaction_lines as (
    select * from {{ ref('fct_policy_transaction_lines') }}
),

cash_events as (
    select * from {{ ref('int_accounting__billing_cash_events') }}
),

accounting_periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

valuation_period as (
    select accounting_period
    from accounting_periods
    where is_valuation_period
),

booked_transactions as (
    select distinct
        transaction_id,
        accounting_period as booked_period
    from transaction_lines
),

scheduled as (
    select
        installments.installment_id,
        installments.policy_id,
        installments.term_id,
        installments.transaction_id,
        installments.installment_number,
        installments.due_date,
        installments.installment_amount
    from installments
    inner join booked_transactions
        on installments.transaction_id = booked_transactions.transaction_id
    where not installments.is_test_policy
        and booked_transactions.booked_period <= (select accounting_period from valuation_period)
),

credits_by_policy as (
    select
        policy_id,
        -sum(installment_amount) as credit_amount
    from scheduled
    where installment_amount < 0
    group by 1
),

cash_by_policy as (
    select
        policy_id,
        sum(case when cash_event_type = 'REFUND' then -cash_amount else 0 end) as refund_amount,
        sum(case when cash_event_type <> 'REFUND' then cash_amount else 0 end)
            as received_net_of_returns_amount
    from cash_events
    group by 1
),

pools as (
    select
        coalesce(credits_by_policy.policy_id, cash_by_policy.policy_id) as policy_id,
        greatest(
            coalesce(credits_by_policy.credit_amount, 0) - coalesce(cash_by_policy.refund_amount, 0),
            0
        ) as credit_pool_amount,
        coalesce(cash_by_policy.received_net_of_returns_amount, 0)
            - greatest(
                coalesce(cash_by_policy.refund_amount, 0) - coalesce(credits_by_policy.credit_amount, 0),
                0
            ) as cash_pool_amount
    from credits_by_policy
    full outer join cash_by_policy
        on credits_by_policy.policy_id = cash_by_policy.policy_id
),

charges as (
    select
        scheduled.*,
        coalesce(pools.credit_pool_amount, 0) as credit_pool_amount,
        coalesce(pools.cash_pool_amount, 0) as cash_pool_amount
    from scheduled
    left join pools
        on scheduled.policy_id = pools.policy_id
    where scheduled.installment_amount > 0
),

-- Pass 1: the credit pool against the policy's charges, latest due date first.
credit_applied as (
    select
        charges.*,
        greatest(0, least(
            installment_amount,
            credit_pool_amount - (
                sum(installment_amount) over (
                    partition by policy_id
                    order by due_date desc, installment_id desc
                    rows between unbounded preceding and current row
                ) - installment_amount
            )
        )) as credit_applied_amount
    from charges
),

-- Pass 2: the cash pool against what credits left open, oldest due date first.
cash_applied as (
    select
        credit_applied.*,
        installment_amount - credit_applied_amount as remaining_after_credit_amount,
        greatest(0, least(
            installment_amount - credit_applied_amount,
            cash_pool_amount - (
                sum(installment_amount - credit_applied_amount) over (
                    partition by policy_id
                    order by due_date, installment_id
                    rows between unbounded preceding and current row
                ) - (installment_amount - credit_applied_amount)
            )
        )) as cash_applied_amount
    from credit_applied
),

final as (
    select
        installment_id,
        policy_id,
        term_id,
        transaction_id,
        installment_number,
        due_date,
        cast(installment_amount as decimal(18, 2)) as installment_amount,
        cast(credit_applied_amount as decimal(18, 2)) as credit_applied_amount,
        cast(cash_applied_amount as decimal(18, 2)) as cash_applied_amount,
        cast(remaining_after_credit_amount - cash_applied_amount as decimal(18, 2))
            as open_amount,
        -- Positive once the due date has passed; 0 or less while not yet past due.
        {{ dbt.datediff('due_date', "cast('" ~ var('valuation_date') ~ "' as date)", 'day') }}
            as days_past_due
    from cash_applied
)

select * from final
