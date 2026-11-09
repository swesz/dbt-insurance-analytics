-- Frequency and severity per accident year, line of business and coverage, with catastrophe
-- claims excluded (is_catastrophe_included = false) and included (true) as two rows.
--
--   claim frequency = claim count / earned exposure years      (how often)
--   severity        = incurred loss / claim count               (how much, per claim)
--   pure premium    = incurred loss / earned exposure years     (loss cost per exposure year)
--                   = frequency x severity
--
-- Pricing works with the two parts separately because they move for different reasons:
-- frequency with driving, weather and the mix of risks; severity with repair costs, medical
-- inflation and court awards (the ~6% a year trend in docs/source-systems.md 4). A flat pure
-- premium can hide fewer but larger claims.
--
-- Worked example (round numbers, not this data): 10,000 earned car-years with collision and
-- 500 collision claims incurring $2.5M give frequency 0.05 (one claim per 20 car-years),
-- severity $5,000 and pure premium $250 per car-year. If the collision premium is $400 per
-- car-year, the coverage's loss ratio is 250 / 400 = 62.5%.
--
-- Claim count means distinct claims, as in the glossary ("claims per earned exposure unit")
-- and the frequency targets of docs/source-systems.md 4. A claim counts once on every coverage
-- it has an exposure on: a collision that also damages a third party's car is one COLL claim
-- and one PD claim, because each coverage is priced separately.
--
-- Claimants are shown too, under their own name. An exposure is one coverage and one claimant
-- (3f), so on a coverage the exposure count is the claimant count. It differs from the claim
-- count only where one claim has several claimants on the same coverage, which is common for
-- bodily injury (one accident, several injured people) and rare elsewhere. claimant_frequency
-- is worth keeping for BI: limits apply per person (100,000 per claimant here), so pricing and
-- reserving look at injured people per car-year as well as at accidents per car-year.
--
-- Severity is per claim, including claims closed without payment, and incurred is at the
-- valuation date: recent accident years are immature (reserves still developing, late claims
-- still to come), so their severity, and for liability their frequency, will still move.
-- Catastrophes are shown apart because one event adds thousands of claims to a single year:
-- the non-catastrophe frequency is the one with a trend.
--
-- Which claims count: only those that can be matched to the exposure base. Orphan claims
-- (has_matching_policy = false, a legacy book not in the policy system) have no exposure here,
-- and claims whose loss is outside any term (is_loss_outside_term, closed without payment)
-- were not covered, so neither belongs in a ratio of claims to covered exposure. The
-- accident-year loss ratio report keeps them, because there every dollar has to be in.
with month_end as (
    select * from {{ ref('fct_policy_month_end') }}
),

premium as (
    select * from {{ ref('fct_premium_by_policy_period') }}
),

coverages as (
    select * from {{ ref('dim_coverages') }}
),

claim_exposures as (
    select * from {{ ref('dim_claim_exposures') }}
),

claims as (
    select * from {{ ref('dim_claims') }}
),

-- Earned exposure per coverage.
--
-- fct_policy_month_end has earned exposure per policy and month (covered days x vehicles or
-- dwellings / 365), not per coverage. Attributing it to coverages needs a rule, because not
-- every policy carries every coverage: auto BI and PD are mandatory, but COLL and COMP
-- (physical damage) are optional, and some auto policies go without. Giving COLL the exposure
-- of all auto policies would put cars that cannot have a collision claim in the denominator
-- and understate collision frequency by the share of policies without it.
--
-- The rule: a policy's exposure in a month counts for a coverage when the policy earned
-- premium on that coverage in that month (fct_premium_by_policy_period.earned_premium > 0).
-- Earning premium is the definition of being covered, it is per coverage, and it comes from the
-- premium subledger, so exposure and premium use the same notion of "covered".
-- Edge cases, and why they do not distort the result:
--   - A cancellation booked after its month closed earns negatively in the booking month; the
--     policy has no covered days then, so fct_policy_month_end has no row and nothing is
--     attributed.
--   - A month's earned premium is on booked periods while covered days use the current state
--     of the terms; the two can disagree on the days of a late-entered change, which moves
--     exposure by days, not policies.
-- A coverage every policy of a line carries (BI, PD, the three home coverages) therefore gets
-- the line's full exposure, which the build output can be checked against.
coverage_exposure as (
    select
        year(month_end.period_end_date) as accident_year,
        month_end.line_of_business,
        premium.coverage_code,
        sum(month_end.earned_exposure_years) as earned_exposure_years
    from month_end
    inner join premium
        on month_end.policy_id = premium.policy_id
        and month_end.accounting_period = premium.accounting_period
    where premium.earned_premium > 0
    group by all
),

-- Earned premium of the coverage in the calendar year, for the premium side of the coverage's
-- loss ratio (pure premium / earned premium per exposure year).
coverage_premium as (
    select
        cast(left(accounting_period, 4) as integer) as accident_year,
        line_of_business,
        coverage_code,
        sum(earned_premium) as earned_premium
    from premium
    group by all
),

catastrophe_treatments as (
    select false as is_catastrophe_included
    union all
    select true as is_catastrophe_included
),

covered_claim_exposures as (
    select
        claim_exposures.exposure_id,
        claim_exposures.claim_id,
        claim_exposures.accident_year,
        claim_exposures.line_of_business,
        claim_exposures.coverage_code,
        claim_exposures.incurred_loss_amount,
        claims.is_catastrophe
    from claim_exposures
    inner join claims
        on claim_exposures.claim_id = claims.claim_id
    where claims.has_matching_policy
        and not claims.is_loss_outside_term
),

-- Each exposure appears in the "included" row; non-catastrophe exposures in both rows.
claims_by_treatment as (
    select
        catastrophe_treatments.is_catastrophe_included,
        covered_claim_exposures.accident_year,
        covered_claim_exposures.line_of_business,
        covered_claim_exposures.coverage_code,
        count(*) as claim_exposure_count,
        count(distinct covered_claim_exposures.claim_id) as claim_count,
        sum(covered_claim_exposures.incurred_loss_amount) as incurred_loss_amount
    from covered_claim_exposures
    inner join catastrophe_treatments
        on catastrophe_treatments.is_catastrophe_included
        or not covered_claim_exposures.is_catastrophe
    group by all
),

exposure_by_treatment as (
    select
        catastrophe_treatments.is_catastrophe_included,
        coverage_exposure.*
    from coverage_exposure
    cross join catastrophe_treatments
),

-- Full outer join, so a claim on a coverage-year without attributed exposure would still show
-- (with a null frequency) instead of disappearing.
combined as (
    select
        coalesce(exposure_by_treatment.is_catastrophe_included, claims_by_treatment.is_catastrophe_included)
            as is_catastrophe_included,
        coalesce(exposure_by_treatment.accident_year, claims_by_treatment.accident_year) as accident_year,
        coalesce(exposure_by_treatment.line_of_business, claims_by_treatment.line_of_business)
            as line_of_business,
        coalesce(exposure_by_treatment.coverage_code, claims_by_treatment.coverage_code) as coverage_code,
        coalesce(exposure_by_treatment.earned_exposure_years, 0) as earned_exposure_years,
        coalesce(claims_by_treatment.claim_exposure_count, 0) as claim_exposure_count,
        coalesce(claims_by_treatment.claim_count, 0) as claim_count,
        coalesce(claims_by_treatment.incurred_loss_amount, 0) as incurred_loss_amount
    from exposure_by_treatment
    full outer join claims_by_treatment
        on exposure_by_treatment.is_catastrophe_included = claims_by_treatment.is_catastrophe_included
        and exposure_by_treatment.accident_year = claims_by_treatment.accident_year
        and exposure_by_treatment.line_of_business = claims_by_treatment.line_of_business
        and exposure_by_treatment.coverage_code = claims_by_treatment.coverage_code
),

final as (
    select
        cast(combined.accident_year as integer) as accident_year,
        combined.line_of_business,
        combined.coverage_code,
        coverages.coverage_group,
        combined.is_catastrophe_included,
        cast(combined.earned_exposure_years as decimal(18, 6)) as earned_exposure_years,
        cast(combined.claim_exposure_count as integer) as claim_exposure_count,
        cast(combined.claim_count as integer) as claim_count,
        cast(combined.incurred_loss_amount as decimal(18, 2)) as incurred_loss_amount,
        -- Eight decimals: frequencies are small (0.012 for BI), and the product with severity
        -- should reproduce pure premium to the cent when a reader multiplies them.
        {{ actuarial_ratio('combined.claim_count', 'combined.earned_exposure_years', 8) }}
            as claim_frequency,
        {{ actuarial_ratio('combined.claim_exposure_count', 'combined.earned_exposure_years', 8) }}
            as claimant_frequency,
        {{ actuarial_ratio('combined.incurred_loss_amount', 'combined.claim_count', 2) }}
            as average_incurred_severity,
        {{ actuarial_ratio('combined.incurred_loss_amount', 'combined.earned_exposure_years', 2) }}
            as pure_premium,
        cast(coalesce(coverage_premium.earned_premium, 0) as decimal(18, 2)) as earned_premium,
        {{ actuarial_ratio('coverage_premium.earned_premium', 'combined.earned_exposure_years', 2) }}
            as earned_premium_per_exposure_year
    from combined
    left join coverages
        on combined.coverage_code = coverages.coverage_code
    left join coverage_premium
        on combined.accident_year = coverage_premium.accident_year
        and combined.line_of_business = coverage_premium.line_of_business
        and combined.coverage_code = coverage_premium.coverage_code
)

select * from final
