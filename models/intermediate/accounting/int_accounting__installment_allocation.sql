-- Each positive installment at the valuation date, with how much of it is settled and how
-- much is still open: the basis of the receivable aging (rpt_premium_receivable_aging).
--
-- The billing system records what is billed (installments, per transaction) and what is paid
-- (payments, per policy), but never which payment settles which installment. Aging needs that
-- link, so it is constructed here, in four steps.
--
-- Step 1, reversals. A reinstatement reverses its term's cancellation exactly
-- (docs/source-systems.md 3b), and billing bills both: the cancellation's return premium as a
-- credit, the reinstatement as a debit of the same amount. The two offset each other without
-- cash; the customer only pays the installments they had missed. So a reinstatement debit is
-- settled by the cancellation credit of its own term, and that part of the credit is used up.
-- Treated as ordinary items instead, the debit would be a new charge that eats the policy's
-- cash, and the credit would settle some other installment, typically the next renewal's,
-- not yet due: a customer who paid everything on time would show the reinstatement amount as
-- past due.
--
-- Step 2, which credits are still available. A credit installment that was not reversed (a
-- cancellation's return premium, a credit endorsement) is not money: it lowers what the
-- customer owes. Billing often pays a credit out as a refund instead (a credit endorsement is
-- refunded, a cancellation refunds what was paid beyond the premium owed). A refunded credit
-- has been settled in cash and can no longer lower another installment, so refunds use up
-- credits first:
--     credits left = credits - refunds, if positive
--     cash pool    = receipts - bank returns - (refunds beyond the credits)
-- A refund carries only the policy, not the credit it pays out, so refunds use up the policy's
-- credits oldest first, term by term. Without that netting, a refunded credit would count
-- twice: once lowering the installments and once lowering the cash, and the aging would show
-- paid installments as past due.
--
-- Step 3, the credits left, latest due first, within their own term first. A cancellation
-- takes away the end of the coverage, so its credit takes away the end of the term's schedule.
-- Applied oldest-first instead, the credit would "pay" the very installment a nonpayment
-- cancellation was triggered by, and the aging would show the debt as younger than it is.
-- Within the term, because the credit is part of that term's premium: applied to the policy as
-- a whole, it would settle the next renewal's installments and leave the term's own unpaid
-- ones looking past due. Only a credit larger than everything its term billed goes on to the
-- rest of the policy (latest due first again); a term whose written premium is not negative
-- never has one, so this is a safety net, not a rule that shapes the result.
--
-- Step 4, the cash pool, oldest due first (first in, first out). A payment carries only the
-- policy, so the policy's cash settles what steps 1 and 3 left open, from the oldest due date
-- onward, ties broken by installment_id. That is the usual convention for open-item aging: a
-- customer who pays is assumed to pay their oldest debt, so nothing looks more overdue than it
-- is. Cash or credit beyond everything billed stays unapplied (a credit balance).
--
-- Every step is one window function: with the amounts in allocation order and a running
-- total, an installment receives what is left of the pool after the installments before it,
-- capped at its own amount:
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

load_info as (
    select * from {{ ref('stg_generator_audit__load_info') }}
),

valuation_period as (
    select accounting_period
    from accounting_periods
    where is_valuation_period
),

booked_transactions as (
    select distinct
        transaction_id,
        transaction_type,
        accounting_period as booked_period
    from transaction_lines
),

scheduled as (
    select
        installments.installment_id,
        installments.policy_id,
        installments.term_id,
        installments.transaction_id,
        booked_transactions.transaction_type,
        installments.installment_number,
        installments.due_date,
        installments.installment_amount
    from installments
    inner join booked_transactions
        on installments.transaction_id = booked_transactions.transaction_id
    where not installments.is_test_policy
        and booked_transactions.booked_period <= (select accounting_period from valuation_period)
),

-- Step 1: how much of each term's cancellation credit its reinstatement reverses. least()
-- makes it zero for a term that was cancelled and not reinstated.
term_reversals as (
    select
        term_id,
        least(
            -sum(case when transaction_type = 'CANCELLATION' then installment_amount else 0 end),
            sum(case when transaction_type = 'REINSTATEMENT' then installment_amount else 0 end)
        ) as reversed_amount
    from scheduled
    where transaction_type in ('CANCELLATION', 'REINSTATEMENT')
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

-- Step 2: each term's credits, net of what its reinstatement reversed...
term_credits as (
    select
        scheduled.policy_id,
        scheduled.term_id,
        min(scheduled.due_date) as first_credit_due_date,
        -sum(scheduled.installment_amount) as gross_credit_amount
    from scheduled
    where scheduled.installment_amount < 0
    group by 1, 2
),

term_credits_after_reversal as (
    select
        term_credits.policy_id,
        term_credits.term_id,
        term_credits.first_credit_due_date,
        term_credits.gross_credit_amount - coalesce(term_reversals.reversed_amount, 0)
            as credit_amount
    from term_credits
    left join term_reversals
        on term_credits.term_id = term_reversals.term_id
),

-- ...then used up by the policy's refunds, oldest credit first.
term_credits_available as (
    select
        term_credits_after_reversal.policy_id,
        term_credits_after_reversal.term_id,
        term_credits_after_reversal.credit_amount
            - greatest(0, least(
                term_credits_after_reversal.credit_amount,
                coalesce(cash_by_policy.refund_amount, 0) - (
                    sum(term_credits_after_reversal.credit_amount) over (
                        partition by term_credits_after_reversal.policy_id
                        order by
                            term_credits_after_reversal.first_credit_due_date,
                            term_credits_after_reversal.term_id
                        rows between unbounded preceding and current row
                    ) - term_credits_after_reversal.credit_amount
                )
            )) as available_credit_amount
    from term_credits_after_reversal
    left join cash_by_policy
        on term_credits_after_reversal.policy_id = cash_by_policy.policy_id
),

policy_credits as (
    select
        policy_id,
        sum(credit_amount) as credit_amount
    from term_credits_after_reversal
    group by 1
),

-- Refunds beyond the credits paid back cash, so they lower the cash pool instead.
cash_pools as (
    select
        cash_by_policy.policy_id,
        cash_by_policy.received_net_of_returns_amount
            - greatest(
                cash_by_policy.refund_amount - coalesce(policy_credits.credit_amount, 0),
                0
            ) as cash_pool_amount
    from cash_by_policy
    left join policy_credits
        on cash_by_policy.policy_id = policy_credits.policy_id
),

-- The charges, with step 1 applied: a reinstatement installment's share of its term's
-- reversal (a term normally has one; the running total handles more).
charges as (
    select
        scheduled.*,
        case
            when scheduled.transaction_type = 'REINSTATEMENT' then greatest(0, least(
                scheduled.installment_amount,
                coalesce(term_reversals.reversed_amount, 0) - (
                    sum(scheduled.installment_amount) over (
                        partition by scheduled.term_id, scheduled.transaction_type
                        order by scheduled.due_date, scheduled.installment_id
                        rows between unbounded preceding and current row
                    ) - scheduled.installment_amount
                )
            ))
            else 0
        end as reversed_amount
    from scheduled
    left join term_reversals
        on scheduled.term_id = term_reversals.term_id
    where scheduled.installment_amount > 0
),

-- Step 3a: each term's available credit against its own charges, latest due date first.
own_term_credit_applied as (
    select
        charges.*,
        charges.installment_amount - charges.reversed_amount as after_reversal_amount,
        greatest(0, least(
            charges.installment_amount - charges.reversed_amount,
            coalesce(term_credits_available.available_credit_amount, 0) - (
                sum(charges.installment_amount - charges.reversed_amount) over (
                    partition by charges.term_id
                    order by charges.due_date desc, charges.installment_id desc
                    rows between unbounded preceding and current row
                ) - (charges.installment_amount - charges.reversed_amount)
            )
        )) as own_term_credit_amount
    from charges
    left join term_credits_available
        on charges.term_id = term_credits_available.term_id
),

own_term_credit_by_term as (
    select
        term_id,
        sum(own_term_credit_amount) as own_term_credit_amount
    from own_term_credit_applied
    group by 1
),

-- What a term's credit could not use in its own term, pooled per policy for step 3b.
leftover_credits as (
    select
        term_credits_available.policy_id,
        sum(
            term_credits_available.available_credit_amount
            - coalesce(own_term_credit_by_term.own_term_credit_amount, 0)
        ) as leftover_credit_amount
    from term_credits_available
    left join own_term_credit_by_term
        on term_credits_available.term_id = own_term_credit_by_term.term_id
    group by 1
),

-- Step 3b: leftover credit against the rest of the policy, latest due date first.
other_term_credit_applied as (
    select
        own_term_credit_applied.*,
        greatest(0, least(
            own_term_credit_applied.after_reversal_amount
                - own_term_credit_applied.own_term_credit_amount,
            coalesce(leftover_credits.leftover_credit_amount, 0) - (
                sum(own_term_credit_applied.after_reversal_amount
                    - own_term_credit_applied.own_term_credit_amount) over (
                    partition by own_term_credit_applied.policy_id
                    order by own_term_credit_applied.due_date desc,
                        own_term_credit_applied.installment_id desc
                    rows between unbounded preceding and current row
                ) - (own_term_credit_applied.after_reversal_amount
                    - own_term_credit_applied.own_term_credit_amount)
            )
        )) as other_term_credit_amount
    from own_term_credit_applied
    left join leftover_credits
        on own_term_credit_applied.policy_id = leftover_credits.policy_id
),

credit_applied as (
    select
        other_term_credit_applied.*,
        reversed_amount + own_term_credit_amount + other_term_credit_amount
            as credit_applied_amount
    from other_term_credit_applied
),

-- Step 4: the cash pool against what steps 1 and 3 left open, oldest due date first.
cash_applied as (
    select
        credit_applied.*,
        credit_applied.installment_amount - credit_applied.credit_applied_amount
            as remaining_after_credit_amount,
        greatest(0, least(
            credit_applied.installment_amount - credit_applied.credit_applied_amount,
            coalesce(cash_pools.cash_pool_amount, 0) - (
                sum(credit_applied.installment_amount - credit_applied.credit_applied_amount) over (
                    partition by credit_applied.policy_id
                    order by credit_applied.due_date, credit_applied.installment_id
                    rows between unbounded preceding and current row
                ) - (credit_applied.installment_amount - credit_applied.credit_applied_amount)
            )
        )) as cash_applied_amount
    from credit_applied
    left join cash_pools
        on credit_applied.policy_id = cash_pools.policy_id
),

final as (
    select
        installment_id,
        policy_id,
        term_id,
        transaction_id,
        transaction_type,
        installment_number,
        due_date,
        cast(installment_amount as decimal(18, 2)) as installment_amount,
        cast(reversed_amount as decimal(18, 2)) as reversed_amount,
        cast(credit_applied_amount as decimal(18, 2)) as credit_applied_amount,
        cast(cash_applied_amount as decimal(18, 2)) as cash_applied_amount,
        cast(remaining_after_credit_amount - cash_applied_amount as decimal(18, 2))
            as open_amount,
        -- Positive once the due date has passed; 0 or less while not yet past due.
        {{ dbt.datediff('due_date', 'load_info.valuation_date', 'day') }} as days_past_due
    from cash_applied
    cross join load_info
)

select * from final
