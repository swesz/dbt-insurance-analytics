-- Each positive installment at the valuation date, with how much of it is settled and how
-- much is still open: the basis of the receivable aging (rpt_premium_receivable_aging).
--
-- The billing system records what is billed (installments, per transaction) and what is paid
-- (payments, per policy), but never which payment settles which installment. Aging needs that
-- link, so it is constructed here, in two passes.
--
-- Pass 1, credits, within the term, latest due first. A credit installment (a cancellation's
-- return premium, a credit endorsement) is not money: it reduces the premium the customer owes
-- for the term. A cancellation takes away the end of the coverage, so its credit takes away the
-- end of the schedule: it is applied to the term's latest-due installments first. Applied
-- oldest-first instead, the credit would "pay" the very installment a nonpayment cancellation
-- was triggered by, and the aging would show the debt as younger than it is.
--
-- Pass 2, cash, across the policy, oldest due first (first in, first out). A payment carries
-- only the policy, so the policy's net cash to date (receipts - refunds - bank returns), plus
-- any credit the term could not use, settles the remaining amounts from the oldest due date
-- onward, ties broken by installment_id. That is the usual convention for open-item aging:
-- a customer who pays is assumed to pay their oldest debt, so whatever is left open is the
-- youngest debt, and nothing looks more overdue than it is.
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

term_totals as (
    select
        term_id,
        policy_id,
        sum(case when installment_amount < 0 then -installment_amount else 0 end)
            as credit_pool_amount,
        sum(case when installment_amount > 0 then installment_amount else 0 end)
            as charge_total_amount
    from scheduled
    group by 1, 2
),

charges as (
    select
        scheduled.*,
        term_totals.credit_pool_amount
    from scheduled
    inner join term_totals
        on scheduled.term_id = term_totals.term_id
    where scheduled.installment_amount > 0
),

-- Pass 1: credits against the term's charges, latest due date first.
credit_applied as (
    select
        charges.*,
        greatest(0, least(
            installment_amount,
            credit_pool_amount - (
                sum(installment_amount) over (
                    partition by term_id
                    order by due_date desc, installment_id desc
                    rows between unbounded preceding and current row
                ) - installment_amount
            )
        )) as credit_applied_amount
    from charges
),

-- What pass 2 has to settle with cash: the policy's net cash to date, plus credits larger than
-- their term's charges (a refund owed to the customer that billing has not paid out yet).
cash_by_policy as (
    select
        policy_id,
        sum(cash_amount) as collected_amount
    from cash_events
    group by 1
),

excess_credit_by_policy as (
    select
        policy_id,
        sum(greatest(credit_pool_amount - charge_total_amount, 0)) as excess_credit_amount
    from term_totals
    group by 1
),

cash_pool as (
    select
        coalesce(cash_by_policy.policy_id, excess_credit_by_policy.policy_id) as policy_id,
        coalesce(cash_by_policy.collected_amount, 0)
            + coalesce(excess_credit_by_policy.excess_credit_amount, 0) as cash_pool_amount
    from cash_by_policy
    full outer join excess_credit_by_policy
        on cash_by_policy.policy_id = excess_credit_by_policy.policy_id
),

-- Pass 2: cash against what credits left open, oldest due date first.
cash_applied as (
    select
        credit_applied.*,
        installment_amount - credit_applied_amount as remaining_after_credit_amount,
        coalesce(cash_pool.cash_pool_amount, 0) as cash_pool_amount,
        greatest(0, least(
            installment_amount - credit_applied_amount,
            coalesce(cash_pool.cash_pool_amount, 0) - (
                sum(installment_amount - credit_applied_amount) over (
                    partition by credit_applied.policy_id
                    order by due_date, installment_id
                    rows between unbounded preceding and current row
                ) - (installment_amount - credit_applied_amount)
            )
        )) as cash_applied_amount
    from credit_applied
    left join cash_pool
        on credit_applied.policy_id = cash_pool.policy_id
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
