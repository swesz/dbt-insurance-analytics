-- As-reported in-force status equals the restated one for every policy whose terms did not
-- change, after the close, in any way that matters for the period end.
--
-- The formulation. Rule 3e at a date d reads only a term's effective date, expiration date and
-- cancellation date. So for a period P and a policy, if every term that could be in force at
-- P's end (effective <= period end < expiration, on either side) looks the same at P's close
-- (snap_policy_terms) and today (dim_policy_terms) in those three columns, exists on both sides
-- and is not deleted, then both views apply the same rule to the same data and must agree:
-- fct_policy_in_force_at_close.is_in_force_as_reported = fct_policy_month_end.is_in_force.
-- Any difference is a bug in one of the two implementations or in the snapshot, never a real
-- restatement. Policies with a relevant change are left out: for them a difference is expected.
--
-- Why not a period-level test ("periods where nothing changed after the close"): terms change
-- every day (expirations, endorsements), so no period would qualify and the test would check
-- nothing. Per policy, almost every policy qualifies.
--
-- "Unchanged" is computed here from the snapshot and the current terms directly, not from the
-- model's own restatement_reason, so a bug in that column cannot hide a mismatch. And a period
-- the summary covers but where no policy could be compared returns a row too: a check that
-- compares nothing must not pass silently.
with snapshot_terms as (
    select * from {{ ref('snap_policy_terms') }}
    where not {{ premium_is_test_policy('policy_id') }}
),

current_terms as (
    select * from {{ ref('dim_policy_terms') }}
),

in_force_at_close as (
    select * from {{ ref('fct_policy_in_force_at_close') }}
),

month_end as (
    select * from {{ ref('fct_policy_month_end') }}
),

summary as (
    select * from {{ ref('rpt_policies_in_force_as_reported_vs_restated') }}
),

closes as (
    select distinct
        accounting_period,
        period_end_date,
        cast(close_date as timestamp) + interval 1 day - interval 1 second as closed_at
    from summary
    where has_as_reported
),

-- Terms that could be in force at the period end, as they were at the close...
relevant_at_close as (
    select
        closes.accounting_period,
        snapshot_terms.policy_id,
        snapshot_terms.term_id,
        snapshot_terms.term_effective_date,
        snapshot_terms.term_expiration_date,
        snapshot_terms.cancellation_effective_date,
        coalesce(snapshot_terms._fivetran_deleted, false) as is_deleted
    from closes
    inner join snapshot_terms
        on snapshot_terms.dbt_valid_from <= closes.closed_at
        and snapshot_terms.dbt_valid_to > closes.closed_at
    where snapshot_terms.term_effective_date <= closes.period_end_date
        and snapshot_terms.term_expiration_date > closes.period_end_date
),

-- ...and as they are today.
relevant_now as (
    select
        closes.accounting_period,
        current_terms.policy_id,
        current_terms.term_id,
        current_terms.term_effective_date,
        current_terms.term_expiration_date,
        current_terms.cancellation_effective_date
    from closes
    inner join current_terms
        on current_terms.term_effective_date <= closes.period_end_date
        and current_terms.term_expiration_date > closes.period_end_date
),

term_comparison as (
    select
        coalesce(at_close.accounting_period, now.accounting_period) as accounting_period,
        coalesce(at_close.policy_id, now.policy_id) as policy_id,
        -- Unchanged only if present on both sides, not deleted, with the same three dates.
        not (
            at_close.term_id is not null
            and now.term_id is not null
            and not at_close.is_deleted
            and at_close.term_effective_date = now.term_effective_date
            and at_close.term_expiration_date = now.term_expiration_date
            and at_close.cancellation_effective_date is not distinct from now.cancellation_effective_date
        ) as has_relevant_change
    from relevant_at_close as at_close
    full outer join relevant_now as now
        on at_close.accounting_period = now.accounting_period
        and at_close.term_id = now.term_id
),

unchanged_policies as (
    select
        accounting_period,
        policy_id
    from term_comparison
    group by all
    having not bool_or(has_relevant_change)
),

compared as (
    select
        unchanged_policies.accounting_period,
        unchanged_policies.policy_id,
        coalesce(in_force_at_close.is_in_force_as_reported, false) as is_in_force_as_reported,
        coalesce(month_end.is_in_force, false) as is_in_force_restated
    from unchanged_policies
    left join in_force_at_close
        on unchanged_policies.accounting_period = in_force_at_close.accounting_period
        and unchanged_policies.policy_id = in_force_at_close.policy_id
    left join month_end
        on unchanged_policies.accounting_period = month_end.accounting_period
        and unchanged_policies.policy_id = month_end.policy_id
),

mismatches as (
    select
        accounting_period,
        policy_id,
        is_in_force_as_reported,
        is_in_force_restated,
        'status differs although nothing relevant changed after the close' as problem
    from compared
    where is_in_force_as_reported <> is_in_force_restated
),

empty_periods as (
    select
        closes.accounting_period,
        null as policy_id,
        null as is_in_force_as_reported,
        null as is_in_force_restated,
        'no policy could be compared for a covered period' as problem
    from closes
    where not exists (
        select 1
        from compared
        where compared.accounting_period = closes.accounting_period
    )
)

select * from mismatches
union all
select * from empty_periods
