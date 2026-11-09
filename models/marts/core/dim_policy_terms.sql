-- One row per term of a real policy, with its policy attributes, its outcome (renewed into,
-- cancelled, expired) and its written premium recomputed from the transactions.

with terms as (
    select * from {{ ref('stg_policy_admin__policy_terms') }}
),

policies as (
    select * from {{ ref('stg_policy_admin__policies') }}
),

lines as (
    select * from {{ ref('int_premium__transaction_lines_booked') }}
),

term_premium as (
    select
        term_id,
        sum(written_premium) as transaction_written_premium,
        count(distinct transaction_id) as transaction_count
    from lines
    group by 1
),

final as (
    select
        terms.term_id,
        terms.policy_id,
        policies.policy_number,
        policies.policyholder_id,
        policies.line_of_business,
        policies.risk_state,
        terms.term_number,
        terms.term_number > 1 as is_renewal,
        terms.term_effective_date,
        terms.term_expiration_date,
        terms.term_days,
        terms.billing_plan,
        terms.term_status,
        terms.cancellation_effective_date,
        terms.cancellation_reason,
        terms.cancellation_effective_date is not null as is_cancelled,
        -- A flat cancellation is effective on the first day: the term never provided coverage
        -- and all its premium is returned.
        coalesce(terms.cancellation_effective_date = terms.term_effective_date, false)
            as is_flat_cancellation,
        -- Coverage ends at the cancellation if there is one, else at expiration (exclusive).
        coalesce(terms.cancellation_effective_date, terms.term_expiration_date) as coverage_end_date,
        {{ dbt.datediff(
            'terms.term_effective_date',
            'coalesce(terms.cancellation_effective_date, terms.term_expiration_date)',
            'day'
        ) }} as covered_days,
        -- True when the term's last covered day is on or before the valuation date, so every
        -- line of the term is fully earned by then (the expiration date itself is not covered).
        terms.term_expiration_date <= cast({{ dbt.dateadd('day', 1, "cast('" ~ var('valuation_date') ~ "' as date)") }} as date)
            as is_expired_at_valuation,
        -- The source's running total, and the same figure rebuilt from the transactions.
        terms.term_written_premium,
        coalesce(term_premium.transaction_written_premium, 0) as transaction_written_premium,
        coalesce(term_premium.transaction_count, 0) as transaction_count,
        terms.created_at,
        terms.updated_at
    from terms
    inner join policies
        on terms.policy_id = policies.policy_id
    left join term_premium
        on terms.term_id = term_premium.term_id
    where not terms.is_test_policy
)

select * from final
