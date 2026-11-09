-- One row per movement of billing cash, in the accounting period the ledger books it in:
--   RECEIPT   money received from a customer, in the month of received_at
--   REFUND    money paid back to a customer (a negative payment), in the month of received_at
--   RETURN    a receipt the bank sent back later (insufficient funds), in the month of
--             returned_at, as the exact negative of the receipt
--
-- Why a returned payment is two events and not a deleted payment: the source overwrites the row
-- with RETURNED, so its current state alone would make the receipt vanish from the month the
-- money came in. That month may be closed already, and closed periods never change. So the
-- receipt stays where it was, and the return reverses it in the month it happened
-- (docs/source-systems.md 3h). It is the billing twin of a voided claim payment.
--
-- The month is the calendar month of the event (3h says "by month of received_at"), not the
-- booking rule of 3c: a bank receipt is dated by the bank, and billing records it the same day.
--
-- QA test policies are excluded here: they never reach the ledger.
with payments as (
    select * from {{ ref('stg_billing__payments') }}
),

policies as (
    select * from {{ ref('stg_policy_admin__policies') }}
),

accounting_periods as (
    select * from {{ ref('accounting_periods') }}
),

receipts as (
    select
        payment_id,
        case when is_refund then 'REFUND' else 'RECEIPT' end as cash_event_type,
        received_at as event_at,
        payment_amount as cash_amount
    from payments
    where not is_test_policy
),

returns as (
    select
        payment_id,
        'RETURN' as cash_event_type,
        returned_at as event_at,
        -payment_amount as cash_amount
    from payments
    where not is_test_policy
        and is_returned
),

events as (
    select * from receipts
    union all
    select * from returns
),

final as (
    select
        -- One receipt or refund per payment plus at most one return, so the payment id and the
        -- event type identify an event.
        cast(events.payment_id as varchar) || '-' || events.cash_event_type as cash_event_id,
        events.payment_id,
        events.cash_event_type,
        payments.policy_id,
        policies.policy_number,
        policies.line_of_business,
        payments.payment_method,
        events.event_at,
        cast(events.event_at as date) as event_date,
        accounting_periods.accounting_period,
        cast(events.cash_amount as decimal(18, 2)) as cash_amount
    from events
    inner join payments
        on events.payment_id = payments.payment_id
    inner join policies
        on payments.policy_id = policies.policy_id
    left join accounting_periods
        on cast(events.event_at as date) between accounting_periods.period_start_date
            and accounting_periods.period_end_date
)

select * from final
