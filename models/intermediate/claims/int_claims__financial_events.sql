-- One row per claim financial event, booked in its accounting period
-- (docs/source-systems.md 3c and 3f). Every claims figure downstream (paid, case reserve,
-- incurred, the triangle, the GL postings) is a sum over these rows.
--
-- Events come from the current state of the transactions:
--   PAYMENT          money paid out: +amount to paid
--   RECOVERY         salvage or subrogation money received back: -amount to paid, because
--                    net paid = payments - recoveries
--   RESERVE_CHANGE   a signed change to the case reserve (initial, revision, erosion, close,
--                    reopen, void restore)
--   PAYMENT_VOID     the reversal of a voided payment: -amount to paid
--
-- Why a void is two events and not a deleted payment: the source overwrites a voided payment in
-- place, so its current state alone would make the payment vanish from the month it was paid in.
-- That month may already be closed and reported to the general ledger, and closed periods never
-- change. So the payment stays where it was booked, and the reversal is a new event booked when
-- the void happened (by the same booking rule, with the void timestamp as both the transaction
-- date and the entry time). Within the period of the void the two net to zero; across periods,
-- each closed period keeps the figure that was reported at its close.
--
-- Claims on QA test policies are excluded here, and therefore from every claims mart.
with claim_transactions as (
    select * from {{ ref('stg_claims__claim_transactions') }}
),

claim_exposures as (
    select * from {{ ref('stg_claims__claim_exposures') }}
),

claims as (
    select * from {{ ref('stg_claims__claims') }}
),

coverages as (
    select * from {{ ref('coverages') }}
),

original_events as (
    select
        claim_transaction_id,
        case transaction_type
            when 'RESERVE' then 'RESERVE_CHANGE'
            else transaction_type
        end as event_type,
        false as is_void_reversal,
        transaction_type,
        transaction_date as event_date,
        created_at as entered_at,
        case transaction_type
            when 'PAYMENT' then amount
            when 'RECOVERY' then -amount
            else 0
        end as paid_amount,
        case transaction_type
            when 'RESERVE' then amount
            else 0
        end as reserve_change_amount
    from claim_transactions
),

void_reversals as (
    select
        claim_transaction_id,
        transaction_type || '_VOID' as event_type,
        true as is_void_reversal,
        transaction_type,
        cast(voided_at as date) as event_date,
        voided_at as entered_at,
        -- The exact negative of the original event's paid amount.
        case transaction_type
            when 'PAYMENT' then -amount
            when 'RECOVERY' then amount
            else 0
        end as paid_amount,
        -- The reserve side of a void is its own VOID_RESTORE reserve row in the source, so the
        -- reversal itself changes only paid.
        0 as reserve_change_amount
    from claim_transactions
    where is_voided
),

events as (
    select * from original_events
    union all
    select * from void_reversals
),

final as (
    select
        -- One original event per transaction, plus at most one reversal, so the transaction id
        -- and the event type identify an event.
        cast(events.claim_transaction_id as varchar) || '-' || events.event_type
            as financial_event_id,
        events.claim_transaction_id,
        events.event_type,
        events.is_void_reversal,
        events.transaction_type,
        claim_transactions.claim_id,
        claim_transactions.exposure_id,
        claim_exposures.coverage_code,
        coverages.line_of_business,
        claim_transactions.cost_category,
        claim_transactions.expense_type,
        claim_transactions.reserve_reason,
        claim_transactions.transaction_date,
        events.event_date,
        events.entered_at,
        {{ booked_accounting_period('events.event_date', 'events.entered_at') }}
            as accounting_period,
        cast(events.paid_amount as decimal(18, 2)) as paid_amount,
        cast(events.reserve_change_amount as decimal(18, 2)) as reserve_change_amount,
        claims.loss_date,
        -- Accident year groups losses by when they happened, not when they were paid: the
        -- basis of loss development triangles.
        year(claims.loss_date) as accident_year,
        -- The latest loader write among the rows this event is built from. A change to any of
        -- them (a void, a claim correction) moves this forward, which is what the incremental
        -- fct_claim_transactions uses to find the events to rebuild.
        greatest(claim_transactions.loaded_at, claim_exposures.loaded_at, claims.loaded_at)
            as source_loaded_at
    from events
    inner join claim_transactions
        on events.claim_transaction_id = claim_transactions.claim_transaction_id
    -- Inner joins: staging relationships tests guarantee every transaction has its exposure and
    -- claim, so these joins only remove the test-policy claims filtered below.
    inner join claim_exposures
        on claim_transactions.exposure_id = claim_exposures.exposure_id
    inner join claims
        on claim_transactions.claim_id = claims.claim_id
    left join coverages
        on claim_exposures.coverage_code = coverages.coverage_code
    where not claims.is_test_policy_claim
)

select * from final
