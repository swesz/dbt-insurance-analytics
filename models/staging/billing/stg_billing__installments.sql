-- One row per billing installment: an amount the customer is asked to pay on a due date.
-- Every policy transaction is billed, so the installments of a transaction add up to its
-- written premium (tests/accounting/assert_installments_equal_written_premium.sql). Billing is
-- the only system that stores cents; this is the one place they become dollars.
with source as (
    select * from {{ source('billing', 'installments') }}
),

final as (
    select
        installment_id,
        policy_id,
        term_id,
        transaction_id,
        installment_number,
        -- Current state only: when a customer moves a due date, the source overwrites it.
        due_date,
        -- BILLING_AMOUNTS_IN_CENTS: the shared macro divides as a DECIMAL, so the dollars are
        -- exact (an integer / 100 would become a floating-point DOUBLE).
        {{ cents_to_dollars('amount_cents') }} as installment_amount,
        -- A credit (a cancellation's return premium, a credit endorsement) is a negative
        -- installment: it reduces what the customer owes instead of asking for money.
        amount_cents < 0 as is_credit,
        {{ premium_is_test_policy('policy_id') }} as is_test_policy,
        created_at,
        updated_at
    from source
    where not coalesce(_fivetran_deleted, false)
)

select * from final
