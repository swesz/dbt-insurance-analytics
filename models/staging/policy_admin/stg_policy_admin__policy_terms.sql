-- One row per policy term: a 6-month (auto) or 12-month (home) period of coverage.
-- The row holds the term's current state: a cancellation or reinstatement overwrites it, so
-- the status history is only in snapshots.
with source as (
    select * from {{ source('policy_admin', 'policy_terms') }}
),

final as (
    select
        term_id,
        policy_id,
        term_number,
        term_effective_date,
        -- Exclusive: the term covers [term_effective_date, term_expiration_date).
        term_expiration_date,
        -- With an exclusive end date, the difference is the number of covered days. Earning
        -- spreads premium over days, so this is the denominator of the earning formula.
        {{ dbt.datediff('term_effective_date', 'term_expiration_date', 'day') }} as term_days,
        billing_plan,
        term_status,
        cancellation_effective_date,
        cancellation_reason,
        -- Running total of the term's transactions; the transactions are the source of truth.
        term_written_premium,
        {{ premium_is_test_policy('policy_id') }} as is_test_policy,
        created_at,
        updated_at
    from source
    where not coalesce(_fivetran_deleted, false)
)

select * from final
