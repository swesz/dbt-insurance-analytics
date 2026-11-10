-- Accident-year loss ratio per accident year and line of business, at the valuation date.
--
--   accident-year incurred loss = net paid + outstanding case reserve, at the valuation date,
--                                 of the claims whose loss_date falls in the year
--   accident-year loss ratio    = accident-year incurred loss / calendar-year earned premium
--
-- The two halves of the ratio are matched in time: the losses of accidents that happened in
-- 2024 against the premium earned for the coverage provided in 2024 (earned premium of the
-- accounting periods 2024-01 to 2024-12). This is the ratio pricing and reserving look at,
-- because a year's figure only moves when that year's own claims develop. The calendar-period
-- ratio (rpt_loss_ratio_by_period) mixes in reserve changes on older years instead.
--
-- The catch: the incurred loss of a recent accident year is not final. Claims are still being
-- reported (IBNR, especially bodily injury and liability) and case reserves revised, so the
-- latest years' ratios are expected to rise as they mature. development_age_months says how
-- mature each row is. These incurred figures are the latest diagonal of the
-- ANNUAL_AT_VALUATION grain of rpt_loss_development_triangle, which also shows each accident
-- year at every earlier anniversary of the valuation date; its year-end ANNUAL grain stops at
-- the last year end, so its figures are older than these.
-- analyses/chain_ladder_development_factors.sql projects them to ultimate. Compare accident
-- years at equal ages, not at the valuation date.
--
-- Worked example (round numbers, not this data): AY 2024 AUTO earned $9.0M in calendar 2024,
-- and its accidents show $5.8M incurred at 2026-09-30 (age 33 months): 64.4%. AY 2026 is only
-- 9 months old: its 2026-01 to 2026-09 premium against losses that have had at most nine
-- months to be reported.
--
-- Claims: every claim in dim_claims (deleted and test-policy claims excluded, orphan claims and
-- claims outside a term kept), the same population as the generator's accident-year control
-- totals, so the incurred, paid and claim count columns can be checked against them.
with periods as (
    select * from {{ ref('dim_accounting_periods') }}
    where not is_after_valuation
),

premium as (
    select * from {{ ref('fct_premium_by_policy_period') }}
),

claims as (
    select * from {{ ref('dim_claims') }}
),

load_info as (
    select * from {{ ref('stg_generator_audit__load_info') }}
),

earned_by_year as (
    select
        year(periods.period_end_date) as calendar_year,
        premium.line_of_business,
        sum(premium.earned_premium) as earned_premium,
        -- 12 for a full year; fewer for the valuation year, whose later months are not over yet.
        count(distinct premium.accounting_period) as earned_months
    from premium
    inner join periods
        on premium.accounting_period = periods.accounting_period
    group by all
),

claims_by_year as (
    select
        accident_year,
        line_of_business,
        count(*) as claim_count,
        count(case when not is_catastrophe then 1 end) as non_catastrophe_claim_count,
        sum(net_paid_loss_amount) as net_paid_loss_amount,
        sum(case_reserve_loss_amount) as case_reserve_loss_amount,
        sum(incurred_loss_amount) as incurred_loss_amount,
        sum(case when is_catastrophe then incurred_loss_amount else 0 end)
            as catastrophe_incurred_loss_amount,
        sum(case when not is_catastrophe then incurred_loss_amount else 0 end)
            as non_catastrophe_incurred_loss_amount
    from claims
    group by all
),

-- Full outer join: a year can have claims and no premium (a loss dated before the first term,
-- LOSS_OUTSIDE_TERM) or premium and no claims. Neither side may drop the other's rows.
combined as (
    select
        coalesce(earned_by_year.calendar_year, claims_by_year.accident_year) as accident_year,
        coalesce(earned_by_year.line_of_business, claims_by_year.line_of_business)
            as line_of_business,
        coalesce(earned_by_year.earned_premium, 0) as earned_premium,
        coalesce(earned_by_year.earned_months, 0) as earned_months,
        coalesce(claims_by_year.claim_count, 0) as claim_count,
        coalesce(claims_by_year.non_catastrophe_claim_count, 0) as non_catastrophe_claim_count,
        coalesce(claims_by_year.net_paid_loss_amount, 0) as net_paid_loss_amount,
        coalesce(claims_by_year.case_reserve_loss_amount, 0) as case_reserve_loss_amount,
        coalesce(claims_by_year.incurred_loss_amount, 0) as incurred_loss_amount,
        coalesce(claims_by_year.catastrophe_incurred_loss_amount, 0)
            as catastrophe_incurred_loss_amount,
        coalesce(claims_by_year.non_catastrophe_incurred_loss_amount, 0)
            as non_catastrophe_incurred_loss_amount
    from earned_by_year
    full outer join claims_by_year
        on earned_by_year.calendar_year = claims_by_year.accident_year
        and earned_by_year.line_of_business = claims_by_year.line_of_business
),

final as (
    select
        cast(accident_year as integer) as accident_year,
        line_of_business,
        load_info.valuation_date,
        -- Months from the start of the accident year to the valuation date: 9 for accident
        -- year 2026 at a 2026-09-30 valuation, 21 for 2025, and so on. The same ages as the
        -- triangle's ANNUAL_AT_VALUATION cells (not its year-end ANNUAL ones).
        cast(
            (year(load_info.valuation_date) - accident_year) * 12
                + month(load_info.valuation_date)
        as integer) as development_age_months,
        cast(earned_months as integer) as earned_months,
        cast(earned_premium as decimal(18, 2)) as earned_premium,
        cast(claim_count as integer) as claim_count,
        cast(non_catastrophe_claim_count as integer) as non_catastrophe_claim_count,
        cast(net_paid_loss_amount as decimal(18, 2)) as net_paid_loss_amount,
        cast(case_reserve_loss_amount as decimal(18, 2)) as case_reserve_loss_amount,
        cast(incurred_loss_amount as decimal(18, 2)) as incurred_loss_amount,
        cast(catastrophe_incurred_loss_amount as decimal(18, 2)) as catastrophe_incurred_loss_amount,
        cast(non_catastrophe_incurred_loss_amount as decimal(18, 2))
            as non_catastrophe_incurred_loss_amount,
        {{ actuarial_ratio('incurred_loss_amount', 'earned_premium') }} as incurred_loss_ratio,
        {{ actuarial_ratio('net_paid_loss_amount', 'earned_premium') }} as paid_loss_ratio,
        {{ actuarial_ratio('non_catastrophe_incurred_loss_amount', 'earned_premium') }}
            as non_catastrophe_incurred_loss_ratio
    from combined
    cross join load_info
)

select * from final
