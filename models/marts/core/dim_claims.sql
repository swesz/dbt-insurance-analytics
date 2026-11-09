-- One row per claim in its current state, with the matched policy, data-quality flags and the
-- claim's financial position at the valuation date. Test-policy claims and deleted claims are
-- not here.
with claims as (
    select * from {{ ref('stg_claims__claims') }}
),

claim_versions as (
    select * from {{ ref('stg_claims__claim_versions') }}
),

claim_exposures as (
    select * from {{ ref('stg_claims__claim_exposures') }}
),

adjusters as (
    select * from {{ ref('stg_claims__adjusters') }}
),

policies as (
    select * from {{ ref('stg_policy_admin__policies') }}
),

policy_terms as (
    select * from {{ ref('stg_policy_admin__policy_terms') }}
),

catastrophe_events as (
    select * from {{ ref('catastrophe_events') }}
),

financial_events as (
    select * from {{ ref('int_claims__financial_events') }}
),

real_claims as (
    select *
    from claims
    where not is_test_policy_claim
),

-- The claims system stores the policy number as typed, not a policy_id. After normalization in
-- staging it matches the policy system's number, except for ORPHAN_CLAIMS: claims on a legacy
-- book that was never migrated, whose policies do not exist here. They stay, flagged, because
-- the losses are real and belong in the financials.
matched_policies as (
    select
        real_claims.claim_id,
        policies.policy_id,
        policies.line_of_business as policy_line_of_business
    from real_claims
    left join policies
        on real_claims.policy_number = policies.policy_number
),

-- A loss is covered only if it happened while a term was in force: on or after the term's
-- effective date, before its (exclusive) expiration date, and before any cancellation took
-- effect (the in-force test of 3e, applied at the loss date). LOSS_OUTSIDE_TERM claims fail
-- this; in the source they were all closed without payment, which is what a claims department
-- does with a loss the policy did not cover.
covering_terms as (
    select distinct
        real_claims.claim_id
    from real_claims
    inner join matched_policies
        on real_claims.claim_id = matched_policies.claim_id
    inner join policy_terms
        on matched_policies.policy_id = policy_terms.policy_id
    where policy_terms.term_effective_date <= real_claims.loss_date
        and policy_terms.term_expiration_date > real_claims.loss_date
        and (
            policy_terms.cancellation_effective_date is null
            or policy_terms.cancellation_effective_date > real_claims.loss_date
        )
),

-- The current state only says what the status is now. Whether a claim was ever reopened is in
-- the version history: a closed claim that reopened and closed again looks like any other
-- closed claim in its latest version.
status_history as (
    select
        claim_id,
        bool_or(claim_status = 'REOPENED') as was_reopened
    from claim_versions
    where not is_deleted
    group by claim_id
),

exposure_counts as (
    select
        claim_id,
        count(*) as exposure_count
    from claim_exposures
    group by claim_id
),

-- Financial position at the valuation date: everything booked in the valuation period or before.
claim_financials as (
    select
        claim_id,
        sum(case when cost_category = 'LOSS' then paid_amount else 0 end) as net_paid_loss_amount,
        sum(case when cost_category = 'EXPENSE' then paid_amount else 0 end) as paid_expense_amount,
        sum(case when cost_category = 'LOSS' then reserve_change_amount else 0 end)
            as case_reserve_loss_amount,
        sum(case when cost_category = 'EXPENSE' then reserve_change_amount else 0 end)
            as case_reserve_expense_amount
    from financial_events
    where accounting_period <= {{ claims_valuation_period() }}
    group by claim_id
),

final as (
    select
        real_claims.claim_id,
        real_claims.claim_number,
        real_claims.policy_number,
        real_claims.source_policy_number,
        real_claims.is_policy_number_malformed,
        matched_policies.policy_id,
        matched_policies.policy_id is not null as has_matching_policy,
        -- The matched policy decides the line; an orphan claim falls back to the prefix of its
        -- policy number, which encodes the product ('PA' auto, 'HO' home).
        coalesce(
            matched_policies.policy_line_of_business,
            case left(real_claims.policy_number, 2)
                when 'PA' then 'AUTO'
                when 'HO' then 'HOME'
            end
        ) as line_of_business,
        real_claims.loss_date,
        year(real_claims.loss_date) as accident_year,
        real_claims.reported_at,
        -- Days from the loss to its first report. Long lags (bodily injury, liability) are why
        -- losses keep being reported years after the accident year ends: the "IBNR" in incurred
        -- but not reported.
        {{ dbt.datediff('real_claims.loss_date', 'cast(real_claims.reported_at as date)', 'day') }}
            as report_lag_days,
        real_claims.loss_cause,
        real_claims.loss_state,
        real_claims.catastrophe_code,
        catastrophe_events.event_name as catastrophe_event_name,
        real_claims.catastrophe_code is not null as is_catastrophe,
        real_claims.claim_status,
        real_claims.is_open,
        real_claims.closed_at,
        coalesce(status_history.was_reopened, false) as was_reopened,
        real_claims.adjuster_id,
        adjusters.adjuster_name,
        -- Unknown (null) for orphan claims: without the policy there are no terms to check.
        case
            when matched_policies.policy_id is null then null
            else covering_terms.claim_id is null
        end as is_loss_outside_term,
        coalesce(exposure_counts.exposure_count, 0) as exposure_count,
        coalesce(claim_financials.net_paid_loss_amount, 0) as net_paid_loss_amount,
        coalesce(claim_financials.paid_expense_amount, 0) as paid_expense_amount,
        coalesce(claim_financials.case_reserve_loss_amount, 0) as case_reserve_loss_amount,
        coalesce(claim_financials.case_reserve_expense_amount, 0) as case_reserve_expense_amount,
        coalesce(claim_financials.net_paid_loss_amount, 0)
            + coalesce(claim_financials.case_reserve_loss_amount, 0) as incurred_loss_amount,
        coalesce(claim_financials.paid_expense_amount, 0)
            + coalesce(claim_financials.case_reserve_expense_amount, 0) as incurred_expense_amount,
        real_claims.updated_at
    from real_claims
    left join matched_policies
        on real_claims.claim_id = matched_policies.claim_id
    left join covering_terms
        on real_claims.claim_id = covering_terms.claim_id
    left join status_history
        on real_claims.claim_id = status_history.claim_id
    left join exposure_counts
        on real_claims.claim_id = exposure_counts.claim_id
    left join claim_financials
        on real_claims.claim_id = claim_financials.claim_id
    left join adjusters
        on real_claims.adjuster_id = adjusters.adjuster_id
    left join catastrophe_events
        on real_claims.catastrophe_code = catastrophe_events.catastrophe_code
)

select * from final
