-- Policies in force (PIF) per accounting period and line of business: as reported at the
-- period's close, as restated today, the difference, and what caused it.
--
-- How to read a row: policies_in_force_as_reported is the PIF the month-end report showed
-- when the books closed; policies_in_force_restated is the PIF the same rule (3e) gives today
-- for the same date, on the current state of the terms. A positive difference means the
-- period end looks bigger in hindsight (late-entered new business, reinstatements after the
-- close); a negative one, smaller (cancellations entered after the close but effective before
-- the period end). Closed periods keep their reported figures in the ledger and in board packs,
-- so this is the reconciliation between "what we said" and "what we now know".
--
-- Worked example (round numbers, not this data): May AUTO was reported at the close with
-- 10,000 PIF. Since then, 12 policies whose new business was keyed in after the close turned
-- out to have started in May, 3 policies cancelled for nonpayment in late May were reinstated
-- after the close, and 9 cancellations effective in May were entered after the close.
-- Restated PIF is 10,000 + 12 + 3 - 9 = 10,006, a difference of +6, and the main driver is
-- TERM_ENTERED_AFTER_CLOSE.
--
-- Periods before the snapshot history starts have no as-reported figure (null), and neither
-- has the valuation period, whose books close after the valuation date; see
-- fct_policy_in_force_at_close.
with periods as (
    select * from {{ ref('dim_accounting_periods') }}
    where not is_after_valuation
),

coverages as (
    select * from {{ ref('dim_coverages') }}
),

month_end as (
    select * from {{ ref('fct_policy_month_end') }}
),

in_force_at_close as (
    select * from {{ ref('fct_policy_in_force_at_close') }}
),

lines_of_business as (
    select distinct line_of_business
    from coverages
),

period_spine as (
    select
        periods.accounting_period,
        periods.period_end_date,
        periods.close_date,
        lines_of_business.line_of_business
    from periods
    cross join lines_of_business
),

restated as (
    select
        accounting_period,
        line_of_business,
        count(case when is_in_force then 1 end) as policies_in_force_restated
    from month_end
    group by all
),

-- Periods with an as-reported figure are exactly those fct_policy_in_force_at_close covers.
covered_periods as (
    select distinct accounting_period
    from in_force_at_close
),

as_reported as (
    select
        accounting_period,
        line_of_business,
        count(case when is_in_force_as_reported then 1 end) as policies_in_force_as_reported,
        count(case when is_in_force_restated and not is_in_force_as_reported then 1 end)
            as policies_added_after_close,
        count(case when is_in_force_as_reported and not is_in_force_restated then 1 end)
            as policies_dropped_after_close,
        count(case when restatement_reason = 'TERM_ENTERED_AFTER_CLOSE' then 1 end)
            as term_entered_after_close_count,
        count(case when restatement_reason = 'REINSTATED_AFTER_CLOSE' then 1 end)
            as reinstated_after_close_count,
        count(case when restatement_reason = 'CANCELLED_AFTER_CLOSE' then 1 end)
            as cancelled_after_close_count,
        count(case when restatement_reason = 'TERM_REMOVED_AFTER_CLOSE' then 1 end)
            as term_removed_after_close_count,
        count(case when restatement_reason = 'OTHER' then 1 end) as other_restatement_count
    from in_force_at_close
    group by all
),

combined as (
    select
        period_spine.accounting_period,
        period_spine.line_of_business,
        period_spine.period_end_date,
        period_spine.close_date,
        covered_periods.accounting_period is not null as has_as_reported,
        coalesce(restated.policies_in_force_restated, 0) as policies_in_force_restated,
        -- Null, not 0, when the snapshot did not record the close: unknown is not zero.
        case
            when covered_periods.accounting_period is not null
                then coalesce(as_reported.policies_in_force_as_reported, 0)
        end as policies_in_force_as_reported,
        as_reported.policies_added_after_close,
        as_reported.policies_dropped_after_close,
        as_reported.term_entered_after_close_count,
        as_reported.reinstated_after_close_count,
        as_reported.cancelled_after_close_count,
        as_reported.term_removed_after_close_count,
        as_reported.other_restatement_count
    from period_spine
    left join restated
        on period_spine.accounting_period = restated.accounting_period
        and period_spine.line_of_business = restated.line_of_business
    left join covered_periods
        on period_spine.accounting_period = covered_periods.accounting_period
    left join as_reported
        on period_spine.accounting_period = as_reported.accounting_period
        and period_spine.line_of_business = as_reported.line_of_business
),

final as (
    select
        accounting_period,
        line_of_business,
        period_end_date,
        close_date,
        has_as_reported,
        cast(policies_in_force_as_reported as integer) as policies_in_force_as_reported,
        cast(policies_in_force_restated as integer) as policies_in_force_restated,
        cast(policies_in_force_restated - policies_in_force_as_reported as integer)
            as policies_in_force_difference,
        cast(coalesce(policies_added_after_close, 0) as integer) as policies_added_after_close,
        cast(coalesce(policies_dropped_after_close, 0) as integer) as policies_dropped_after_close,
        cast(coalesce(term_entered_after_close_count, 0) as integer) as term_entered_after_close_count,
        cast(coalesce(reinstated_after_close_count, 0) as integer) as reinstated_after_close_count,
        cast(coalesce(cancelled_after_close_count, 0) as integer) as cancelled_after_close_count,
        cast(coalesce(term_removed_after_close_count, 0) as integer) as term_removed_after_close_count,
        cast(coalesce(other_restatement_count, 0) as integer) as other_restatement_count,
        -- The reason behind the most restated policies; ties go to the first in this list.
        -- Null when nothing was restated (or the close was not recorded).
        case
            when coalesce(policies_added_after_close, 0) + coalesce(policies_dropped_after_close, 0) = 0
                then null
            when term_entered_after_close_count = greatest(
                term_entered_after_close_count, reinstated_after_close_count,
                cancelled_after_close_count, term_removed_after_close_count, other_restatement_count
            ) then 'TERM_ENTERED_AFTER_CLOSE'
            when reinstated_after_close_count = greatest(
                reinstated_after_close_count, cancelled_after_close_count,
                term_removed_after_close_count, other_restatement_count
            ) then 'REINSTATED_AFTER_CLOSE'
            when cancelled_after_close_count = greatest(
                cancelled_after_close_count, term_removed_after_close_count, other_restatement_count
            ) then 'CANCELLED_AFTER_CLOSE'
            when term_removed_after_close_count >= other_restatement_count
                then 'TERM_REMOVED_AFTER_CLOSE'
            else 'OTHER'
        end as main_restatement_driver
    from combined
)

select * from final
