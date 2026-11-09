-- No two terms of a policy cover the same day. fct_policy_month_end relies on it: it adds a
-- policy's covered days across its terms, and takes "the" in-force term with max(), which is
-- right only if at most one term can be in force (a renewal starts on the prior term's
-- expiration date, docs/source-systems.md 3a). Overlapping terms would double a policy's
-- exposure and make its in-force premium depend on which term max() happened to pick.
--
-- Coverage windows, not scheduled terms: a cancelled term ends at its cancellation date, and a
-- flat-cancelled term covers no day at all.
with terms as (
    select * from {{ ref('dim_policy_terms') }}
),

overlapping_terms as (
    select
        earlier.policy_id,
        earlier.term_id as earlier_term_id,
        later.term_id as later_term_id,
        earlier.coverage_end_date as earlier_coverage_end_date,
        later.term_effective_date as later_term_effective_date
    from terms as earlier
    inner join terms as later
        on earlier.policy_id = later.policy_id
        and earlier.term_id < later.term_id
        -- Half-open windows [start, end) overlap when each starts before the other ends.
        and earlier.term_effective_date < later.coverage_end_date
        and later.term_effective_date < earlier.coverage_end_date
    where earlier.covered_days > 0
        and later.covered_days > 0
),

final as (
    select * from overlapping_terms
)

select * from final
