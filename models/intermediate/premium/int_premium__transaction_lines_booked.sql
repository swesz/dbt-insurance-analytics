{{ config(materialized='table') }}

-- One row per premium transaction line of a real (non-test) policy, with everything the
-- premium calculations need on the row: the transaction header, the term and the policy, the
-- accounting period the line is booked in, and the window it earns over.
--
-- A table, not a view: the booking lookup runs once here instead of in every model that
-- reads it (the earning model, the line fact, the dims).

with lines as (
    select * from {{ ref('stg_policy_admin__policy_transaction_lines') }}
),

transactions as (
    select * from {{ ref('stg_policy_admin__policy_transactions') }}
),

terms as (
    select * from {{ ref('stg_policy_admin__policy_terms') }}
),

policies as (
    select * from {{ ref('stg_policy_admin__policies') }}
),

accounting_periods as (
    select * from {{ ref('accounting_periods') }}
),

joined as (
    select
        lines.transaction_line_id,
        lines.transaction_id,
        transactions.policy_id,
        transactions.term_id,
        policies.policy_number,
        policies.policyholder_id,
        policies.line_of_business,
        policies.risk_state,
        lines.coverage_code,
        transactions.transaction_type,
        transactions.transaction_date,
        transactions.effective_date,
        transactions.is_backdated,
        transactions.created_at as transaction_created_at,
        terms.term_number,
        terms.term_effective_date,
        terms.term_expiration_date,
        terms.term_days,
        lines.written_premium,
        -- Booking rule, docs/source-systems.md 3c: the first period on or after the
        -- transaction's month that was still open when it was entered. Implemented once, in
        -- the shared macro, so premium and claims book identically.
        {{ booked_accounting_period('transactions.transaction_date', 'transactions.created_at') }}
            as accounting_period
    from lines
    inner join transactions
        on lines.transaction_id = transactions.transaction_id
    inner join terms
        on transactions.term_id = terms.term_id
    inner join policies
        on transactions.policy_id = policies.policy_id
    -- QA test policies never reach the books (docs/data-issues.md TEST_POLICIES).
    where not transactions.is_test_policy
),

final as (
    select
        joined.transaction_line_id,
        joined.transaction_id,
        joined.policy_id,
        joined.term_id,
        joined.policy_number,
        joined.policyholder_id,
        joined.line_of_business,
        joined.risk_state,
        joined.coverage_code,
        joined.transaction_type,
        joined.transaction_date,
        joined.effective_date,
        joined.is_backdated,
        joined.transaction_created_at,
        joined.term_number,
        joined.term_effective_date,
        joined.term_expiration_date,
        joined.term_days,
        joined.written_premium,
        joined.accounting_period,
        -- The calendar period of transaction_date. When the booked period is later, the
        -- transaction was keyed in after its own month had closed.
        transaction_periods.accounting_period as transaction_date_period,
        joined.accounting_period <> transaction_periods.accounting_period as is_booked_after_close,
        -- Earning window, docs/source-systems.md 3d: each line earns evenly from its own
        -- effective date to the end of the term, [coverage_start_date, coverage_end_date).
        -- For a new-business or renewal line that is the whole term; for an endorsement the
        -- rest of the term; for a cancellation line [cancellation date, expiration), where its
        -- negative earning cancels the original lines' earning after the cancellation.
        joined.effective_date as coverage_start_date,
        joined.term_expiration_date as coverage_end_date,
        {{ dbt.datediff('joined.effective_date', 'joined.term_expiration_date', 'day') }}
            as window_days
    from joined
    left join accounting_periods as transaction_periods
        on joined.transaction_date between transaction_periods.period_start_date
            and transaction_periods.period_end_date
)

select * from final
