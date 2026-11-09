-- A policy that has paid everything due shows nothing past due in the receivable aging.
--
-- "Paid everything due" is computed here from the billing and policy staging models, not from
-- int_accounting__installment_allocation, so the allocation does not grade itself. A policy is
-- paid up when:
--   1. no credit is left whose allocation would be a matter of convention: every credit
--      installment was either a cancellation that a reinstatement of the same term reversed,
--      or was refunded (the policy's refunds equal its remaining credits exactly); and
--   2. the cash it paid in (receipts, less bank returns) covers every installment due before
--      the valuation date. Reinstatement debits are left out: they reverse a credit and need
--      no cash (docs/source-systems.md 3b).
-- For such a policy, any allocation that settles due installments before later ones leaves
-- nothing past due, whatever the order within them.
--
-- Why it exists: the aging totals tie to the ledger and to the receivable however the
-- allocation spreads them, so those tests cannot see money aged into the wrong bucket. This
-- test can. An earlier allocation treated a reinstatement as a new charge and let the
-- cancellation credit settle the next renewal; on the default load it showed 75 of the 21,608
-- paid-up policies, all of them reinstated, with 45,212.43 past due.
--
-- Amounts are compared as decimals, never as DOUBLE: with floating-point sums, "cash covers
-- what is due" fails at random for a policy that paid exactly what was due.
--
-- A check that compares nothing must not pass silently, so a row is also returned when no
-- paid-up policy with a reinstatement was compared: those are the policies the test is for.
with installments as (
    select * from {{ ref('stg_billing__installments') }}
),

payments as (
    select * from {{ ref('stg_billing__payments') }}
),

transactions as (
    select * from {{ ref('stg_policy_admin__policy_transactions') }}
),

aging as (
    select * from {{ ref('rpt_premium_receivable_aging') }}
),

billed as (
    select
        installments.policy_id,
        installments.term_id,
        installments.due_date,
        installments.installment_amount,
        transactions.transaction_type
    from installments
    inner join transactions
        on installments.transaction_id = transactions.transaction_id
    where not installments.is_test_policy
),

-- The part of each term's cancellation credit that its reinstatement reverses.
reversals_by_term as (
    select
        policy_id,
        term_id,
        least(
            -sum(case when transaction_type = 'CANCELLATION' then installment_amount else 0 end),
            sum(case when transaction_type = 'REINSTATEMENT' then installment_amount else 0 end)
        ) as reversed_amount
    from billed
    group by all
),

billed_by_policy as (
    select
        policy_id,
        -sum(case when installment_amount < 0 then installment_amount else 0 end)
            as gross_credit_amount,
        sum(case
            when installment_amount > 0
                and transaction_type <> 'REINSTATEMENT'
                and due_date < cast('{{ var("valuation_date") }}' as date)
                then installment_amount
            else 0
        end) as due_before_valuation_amount,
        bool_or(transaction_type = 'REINSTATEMENT') as has_reinstatement
    from billed
    group by all
),

reversals_by_policy as (
    select
        policy_id,
        sum(reversed_amount) as reversed_amount
    from reversals_by_term
    group by all
),

cash_by_policy as (
    select
        policy_id,
        sum(case when not is_refund and not is_returned then payment_amount else 0 end)
            as paid_in_amount,
        -sum(case when is_refund then payment_amount else 0 end) as refunded_amount
    from payments
    where not is_test_policy
    group by all
),

paid_up_policies as (
    select
        billed_by_policy.policy_id,
        billed_by_policy.has_reinstatement
    from billed_by_policy
    inner join reversals_by_policy
        on billed_by_policy.policy_id = reversals_by_policy.policy_id
    left join cash_by_policy
        on billed_by_policy.policy_id = cash_by_policy.policy_id
    where billed_by_policy.gross_credit_amount - reversals_by_policy.reversed_amount
            = coalesce(cash_by_policy.refunded_amount, 0)
        and coalesce(cash_by_policy.paid_in_amount, 0)
            >= billed_by_policy.due_before_valuation_amount
),

compared as (
    select
        paid_up_policies.policy_id,
        paid_up_policies.has_reinstatement,
        aging.past_due_1_30_amount + aging.past_due_31_60_amount
            + aging.past_due_61_90_amount + aging.past_due_over_90_amount as past_due_amount
    from paid_up_policies
    inner join aging
        on paid_up_policies.policy_id = aging.policy_id
),

failures as (
    select
        policy_id,
        past_due_amount,
        'paid up, but the aging shows money past due' as problem
    from compared
    where past_due_amount <> 0
),

nothing_compared as (
    select
        null as policy_id,
        null as past_due_amount,
        'no paid-up policy with a reinstatement was compared' as problem
    where not exists (select 1 from compared where has_reinstatement)
)

select * from failures
union all
select * from nothing_compared
