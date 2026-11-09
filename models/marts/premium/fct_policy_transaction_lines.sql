-- Every premium transaction line of a real policy, with the period it is booked in: the
-- detail behind written premium. Summed by accounting_period it gives written premium per
-- period; the earning view of the same lines is fct_premium_by_policy_period.

with lines as (
    select * from {{ ref('int_premium__transaction_lines_booked') }}
),

final as (
    select
        transaction_line_id,
        transaction_id,
        policy_id,
        term_id,
        policyholder_id,
        policy_number,
        line_of_business,
        risk_state,
        coverage_code,
        transaction_type,
        transaction_date,
        effective_date,
        transaction_created_at,
        accounting_period,
        transaction_date_period,
        is_booked_after_close,
        is_backdated,
        term_number,
        term_effective_date,
        term_expiration_date,
        term_days,
        coverage_start_date,
        coverage_end_date,
        window_days,
        written_premium
    from lines
)

select * from final
