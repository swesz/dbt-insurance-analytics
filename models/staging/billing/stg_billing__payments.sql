-- One row per payment: money received from a customer, or a refund paid out to one.
-- Payments are made per policy, not per installment: the billing system does not say which
-- installment a payment settles. rpt_premium_receivable_aging allocates them.
with source as (
    select * from {{ source('billing', 'payments') }}
),

final as (
    select
        payment_id,
        policy_id,
        received_at,
        cast(received_at as date) as received_date,
        -- Signed, in dollars: positive is money in, negative a refund paid out.
        {{ cents_to_dollars('amount_cents') }} as payment_amount,
        amount_cents < 0 as is_refund,
        payment_method,
        payment_status,
        -- RETURNED_PAYMENTS: the bank sent the money back (insufficient funds) days later, and
        -- the source overwrote the row. The money did come in and was in the books when the
        -- month closed, so accounting keeps the receipt in its month and books the return as a
        -- separate event in the month of returned_at (int_accounting__billing_cash_events).
        payment_status = 'RETURNED' as is_returned,
        returned_at,
        {{ premium_is_test_policy('policy_id') }} as is_test_policy,
        created_at,
        updated_at
    from source
    where not coalesce(_fivetran_deleted, false)
)

select * from final
