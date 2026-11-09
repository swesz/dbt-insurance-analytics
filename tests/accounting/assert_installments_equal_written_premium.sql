-- Billing bills exactly what policy administration writes: per term, the installments (cents
-- converted to dollars) add up to the written premium of the term's transactions, to the cent
-- (BILLING_AMOUNTS_IN_CENTS in docs/data-issues.md).
--
-- A wrong unit conversion (forgetting / 100, or dividing an integer and getting a rounded
-- DOUBLE) fails this at once. Compared over all transactions, whatever period they are booked
-- in, because billing does not know about periods. Test policies are excluded on both sides.

with installments as (
    select * from {{ ref('stg_billing__installments') }}
),

transactions as (
    select * from {{ ref('stg_policy_admin__policy_transactions') }}
),

billed as (
    select
        term_id,
        sum(installment_amount) as billed_amount
    from installments
    where not is_test_policy
    group by 1
),

written as (
    select
        term_id,
        sum(written_premium) as written_premium
    from transactions
    where not is_test_policy
    group by 1
)

select
    coalesce(written.term_id, billed.term_id) as term_id,
    written.written_premium,
    billed.billed_amount,
    coalesce(billed.billed_amount, 0) - coalesce(written.written_premium, 0) as difference
from written
full outer join billed
    on written.term_id = billed.term_id
where coalesce(billed.billed_amount, 0) <> coalesce(written.written_premium, 0)
