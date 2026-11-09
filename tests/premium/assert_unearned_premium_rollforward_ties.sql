-- The unearned premium rollforward ties for every policy and coverage, to the cent:
--
--     UPR(P) = UPR(P-1) + written(P) - earned(P)
--
-- This is the identity accountants check at every close: the reserve can only move by premium
-- written into it and premium earned out of it. It holds by construction if earned is the
-- difference of ITD earned (docs/source-systems.md 3d), so a failure means a bug in the
-- earning model, such as a missing period row or an ITD computed on the wrong date.
--
-- A full outer join of each row with the policy-coverage's previous period also catches a
-- series that stops while unearned premium is still open (opening UPR with no closing row).

with premium as (
    select * from {{ ref('fct_premium_by_policy_period') }}
),

periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

balances as (
    select
        premium.policy_id,
        premium.coverage_code,
        periods.period_sequence,
        premium.written_premium,
        premium.earned_premium,
        premium.unearned_premium_end
    from premium
    inner join periods
        on premium.accounting_period = periods.accounting_period
),

valuation_period as (
    select period_sequence from periods where is_valuation_period
),

rollforward as (
    select
        coalesce(current_period.policy_id, prior_period.policy_id) as policy_id,
        coalesce(current_period.coverage_code, prior_period.coverage_code) as coverage_code,
        coalesce(current_period.period_sequence, prior_period.period_sequence + 1) as period_sequence,
        coalesce(prior_period.unearned_premium_end, 0) as unearned_premium_opening,
        coalesce(current_period.written_premium, 0) as written_premium,
        coalesce(current_period.earned_premium, 0) as earned_premium,
        coalesce(current_period.unearned_premium_end, 0) as unearned_premium_closing
    from balances as current_period
    full outer join balances as prior_period
        on current_period.policy_id = prior_period.policy_id
        and current_period.coverage_code = prior_period.coverage_code
        and current_period.period_sequence = prior_period.period_sequence + 1
)

select *
from rollforward
-- The series is capped at the valuation period, so there is no row after it to roll into.
where period_sequence <= (select period_sequence from valuation_period)
    and unearned_premium_opening + written_premium - earned_premium <> unearned_premium_closing
