-- Policies in force at each period end, twice: as the books saw it at the period's close, and
-- as the policy system says today. One row per policy and accounting period where the policy
-- was in force on either basis, for the periods whose close the snapshot recorded.
--
-- As reported: the version of each term in snap_policy_terms that was current at the end of
-- the period's close date, with rule 3e (docs/source-systems.md) applied to that version. That
-- is the PIF the month-end report showed when the books closed.
-- Restated: fct_policy_month_end.is_in_force, the same rule on the current state of the terms.
--
-- They differ when something about the period end was entered after the close:
--   TERM_ENTERED_AFTER_CLOSE   the term in force today did not exist at the close: new business
--                              keyed in late, with an effective date in the period
--   REINSTATED_AFTER_CLOSE     at the close the term was cancelled effective on or before the
--                              period end; it was reinstated later, which erases the cancellation
--   CANCELLED_AFTER_CLOSE      at the close the term had no cancellation in effect; a
--                              cancellation entered later took effect on or before the period
--                              end (a backdated or late-entered cancellation)
--   TERM_REMOVED_AFTER_CLOSE   the term counted at the close is no longer in the policy system
--   OTHER                      any other change to the term's dates
--
-- Worked example: a monthly-pay policy misses its installment; the nonpayment cancellation
-- takes effect on 2025-05-25 and the term is reinstated on 2025-06-09, after May closed on
-- 2025-06-05. The May close counted the policy out of force; today's state has no
-- cancellation, so restated May PIF includes it. Restated May PIF is one higher, and the row
-- says REINSTATED_AFTER_CLOSE.
--
-- Which periods have an as-reported figure. First, only periods closed by the valuation date:
-- a period whose close date is later has not been reported yet. Second, a snapshot only knows
-- what it saw when it ran. For a close before the snapshot's first run, the versions it holds
-- are the states at that first run; a term that changed in between has no version at the
-- earlier close at all. So a period is covered only if every term entered by its close has a
-- version current at the close. Periods that fail either test have no rows here, and the
-- summary report shows them with a null as-reported count rather than a wrong one. The check
-- does not catch every close skipped in the middle of the history (a term that existed before
-- and changed twice keeps a stale version); docs/guide-snapshots-and-actuarial.md, section 3.
with snapshot_terms as (
    select * from {{ ref('snap_policy_terms') }}
),

-- Only periods whose books had closed by the valuation date can have an as-reported figure.
-- The valuation period itself closes after it (2026-09 closes on 2026-10-06): its month-end
-- report does not exist yet, so the snapshot's current state is not "as reported" for it, even
-- if a snapshot ran on or after its close date (the close simulation runs one with --end
-- 2026-09, on data that stops at the valuation date).
periods as (
    select * from {{ ref('dim_accounting_periods') }}
    where is_closed_at_valuation
),

policies as (
    select * from {{ ref('dim_policies') }}
),

current_terms as (
    select * from {{ ref('dim_policy_terms') }}
),

month_end as (
    select * from {{ ref('fct_policy_month_end') }}
),

-- The instant each period's books close: the end of its close date (docs/source-systems.md 1),
-- the same moment the month-end close simulation loads the sources as of.
-- A version is "current at the close" by its dbt_valid_from, which is the source updated_at.
-- Limitation: the report really saw the state at the moment it ran on the close date, and the
-- warehouse only sees a change at the next 6-hourly sync (2e), so a change made on the close
-- date after the report ran would count as known at the close here. This is right only because
-- the source changes nothing between the close-day export (17:30) and midnight: office hours
-- end at 17:00 and nightly batches run after 01:00 (on the close dates the latest change is at
-- 16:59:50). docs/guide-snapshots-and-actuarial.md, section 4, has the fix for a source where
-- that does not hold.
closes as (
    select
        accounting_period,
        period_end_date,
        close_date,
        cast(close_date as timestamp) + interval 1 day - interval 1 second as closed_at
    from periods
),

-- Real (non-test) terms in the snapshot, with the time each was first entered. Test policies
-- are dropped by the same macro staging uses; soft-deleted versions stay here so the coverage
-- check below sees every key, and are excluded from the in-force count.
snapshot_real_terms as (
    select *
    from snapshot_terms
    where not {{ premium_is_test_policy('snapshot_terms.policy_id') }}
),

-- The version of each term current at each close. With dbt_valid_to_current set to a far
-- future date, "current at t" is one range condition, no null handling.
terms_at_close as (
    select
        closes.accounting_period,
        closes.period_end_date,
        snapshot_real_terms.term_id,
        snapshot_real_terms.policy_id,
        snapshot_real_terms.term_effective_date,
        snapshot_real_terms.term_expiration_date,
        snapshot_real_terms.cancellation_effective_date,
        coalesce(snapshot_real_terms._fivetran_deleted, false) as is_deleted
    from closes
    inner join snapshot_real_terms
        on snapshot_real_terms.dbt_valid_from <= closes.closed_at
        and snapshot_real_terms.dbt_valid_to > closes.closed_at
),

-- Coverage check per close (see the header): terms entered by the close vs. terms with a
-- version current at the close. created_at never changes, so any version carries it.
term_entries as (
    select
        term_id,
        min(created_at) as created_at
    from snapshot_real_terms
    group by term_id
),

close_coverage as (
    select
        closes.accounting_period,
        count(*) as terms_entered_by_close,
        count(terms_at_close.term_id) as terms_with_version_at_close
    from closes
    inner join term_entries
        on term_entries.created_at <= closes.closed_at
    left join terms_at_close
        on closes.accounting_period = terms_at_close.accounting_period
        and term_entries.term_id = terms_at_close.term_id
    group by closes.accounting_period
),

covered_closes as (
    select closes.*
    from closes
    inner join close_coverage
        on closes.accounting_period = close_coverage.accounting_period
    where close_coverage.terms_with_version_at_close = close_coverage.terms_entered_by_close
),

-- Rule 3e at the period end, on the version current at the close.
as_reported_policies as (
    select
        terms_at_close.accounting_period,
        terms_at_close.policy_id,
        -- Terms of a policy do not overlap, so at most one is in force; max() picks it.
        max(terms_at_close.term_id) as as_reported_term_id
    from terms_at_close
    inner join covered_closes
        on terms_at_close.accounting_period = covered_closes.accounting_period
    where not terms_at_close.is_deleted
        and terms_at_close.term_effective_date <= terms_at_close.period_end_date
        and terms_at_close.period_end_date < terms_at_close.term_expiration_date
        and (
            terms_at_close.cancellation_effective_date is null
            or terms_at_close.cancellation_effective_date > terms_at_close.period_end_date
        )
    group by all
),

restated_policies as (
    select
        month_end.accounting_period,
        month_end.policy_id,
        month_end.in_force_term_id as restated_term_id
    from month_end
    inner join covered_closes
        on month_end.accounting_period = covered_closes.accounting_period
    where month_end.is_in_force
),

compared as (
    select
        coalesce(as_reported_policies.accounting_period, restated_policies.accounting_period)
            as accounting_period,
        coalesce(as_reported_policies.policy_id, restated_policies.policy_id) as policy_id,
        as_reported_policies.as_reported_term_id,
        restated_policies.restated_term_id,
        as_reported_policies.policy_id is not null as is_in_force_as_reported,
        restated_policies.policy_id is not null as is_in_force_restated
    from as_reported_policies
    full outer join restated_policies
        on as_reported_policies.accounting_period = restated_policies.accounting_period
        and as_reported_policies.policy_id = restated_policies.policy_id
),

-- Why a policy's status differs: look at the term that is in force on one side and not the
-- other, as it was at the close and as it is now.
classified as (
    select
        compared.*,
        case
            when compared.is_in_force_as_reported = compared.is_in_force_restated then null
            -- In force today, not at the close.
            when compared.is_in_force_restated and restated_at_close.term_id is null
                then 'TERM_ENTERED_AFTER_CLOSE'
            when compared.is_in_force_restated
                and restated_at_close.cancellation_effective_date <= covered_closes.period_end_date
                then 'REINSTATED_AFTER_CLOSE'
            -- In force at the close, not today.
            when compared.is_in_force_as_reported and reported_now.term_id is null
                then 'TERM_REMOVED_AFTER_CLOSE'
            when compared.is_in_force_as_reported
                and reported_now.cancellation_effective_date <= covered_closes.period_end_date
                then 'CANCELLED_AFTER_CLOSE'
            else 'OTHER'
        end as restatement_reason
    from compared
    inner join covered_closes
        on compared.accounting_period = covered_closes.accounting_period
    left join terms_at_close as restated_at_close
        on compared.accounting_period = restated_at_close.accounting_period
        and compared.restated_term_id = restated_at_close.term_id
    left join current_terms as reported_now
        on compared.as_reported_term_id = reported_now.term_id
),

final as (
    select
        {{ dbt_utils.generate_surrogate_key(['classified.policy_id', 'classified.accounting_period']) }}
            as policy_period_key,
        classified.policy_id,
        classified.accounting_period,
        policies.line_of_business,
        covered_closes.period_end_date,
        covered_closes.close_date,
        classified.is_in_force_as_reported,
        classified.is_in_force_restated,
        classified.as_reported_term_id,
        classified.restated_term_id,
        classified.restatement_reason
    from classified
    inner join covered_closes
        on classified.accounting_period = covered_closes.accounting_period
    -- dim_policies holds real policies only; the line of business never changes.
    inner join policies
        on classified.policy_id = policies.policy_id
)

select * from final
