-- Chain-ladder development factors from the loss development triangle.
--
-- `dbt compile --select chain_ladder_development_factors` writes the SQL to target/; run it
-- against the dev database. An analysis is not built or tested by dbt: it is a worked example.
--
-- Which triangle: the ANNUAL_AT_VALUATION grain, accident years evaluated at the valuation date
-- and at its anniversaries (ages 9, 21, 33, 45 and 57 months for a 2026-09-30 valuation, all
-- evaluated on 30 September). A reserve is stated at the valuation date, so the projection has
-- to start from what is known on that date: the latest diagonal must be the valuation date.
-- The year-end ANNUAL grain would not do. Its latest diagonal is 2025-12-31, so its ultimate is
-- projected from incurred that is nine months old, and "ultimate minus today's incurred" would
-- count the development since 2025-12-31 twice: once in today's incurred and once in the
-- projection.
--
-- The chain-ladder method in four steps
--
-- 1. Age-to-age factors. For each pair of neighboring ages (21 -> 33, 33 -> 45, ...) take the
--    accident years that have both cells and divide the sum of their losses at the later age by
--    the sum at the earlier age. Summing before dividing makes it *volume-weighted*: a large
--    accident year counts more than a small one, instead of averaging each year's own ratio.
--    A factor of 1.25 from 21 to 33 means losses known at 21 months have grown by a quarter a
--    year later: late-reported claims, payments on open claims, reserve strengthening.
-- 2. Cumulative development factors (CDF). Multiply the age-to-age factors from an age to the
--    last one: the CDF at 21 is f(21->33) x f(33->45) x ... It says how much the losses known at
--    that age grow until development ends. This project's history is under five years, so the
--    product stops at the oldest age observed. Real reserving adds a *tail factor* for the
--    development after it, which matters for slow lines like bodily injury and liability.
-- 3. Ultimate loss. For each accident year, the latest diagonal cell (incurred at the valuation
--    date) times the CDF at its age.
-- 4. IBNR = ultimate - reported incurred at the valuation date. This is IBNR in the broad sense:
--    "incurred but not reported" claims that happened but have not reached us yet (pure IBNR),
--    plus the future development of claims already reported, whose case reserves will turn out
--    too low or too high (IBNER, "incurred but not enough reported").
--    It can be negative: home property reserves here tend to be set high and released as claims
--    settle, so an incurred factor below 1 projects an accident year *down*. A negative estimate
--    says the case reserves are expected to be redundant, not that claims are negative.
--
-- The current accident year is not projected. At a 2026-09-30 valuation, accident year 2026 is
-- 9 months old and only its January-September accidents have happened. Its factor would be
-- f(9->21), learned from earlier years' age-9 cells, which also held only January-September
-- accidents, against their age-21 cells, which hold the whole year. That factor mixes two
-- things: the development of the accidents already in the cell, and the October-December
-- accidents that had not happened yet. Applied to 2026 it would project accidents that have not
-- happened. Those are covered by the unearned premium of policies still running, not by a loss
-- reserve, which is for accidents that already happened. So the current year shows its
-- reported incurred, and its factor, ultimate and IBNR are null. (Reserving estimates the
-- current year's IBNR another way, for example from an expected loss ratio on the premium
-- earned so far.) The f(9->21) row is still listed: it shows how much of a young year's growth
-- is exposure that had not been earned yet.
--
-- IBNR is an estimate, not source data. No system records it; it is the actuary's projection
-- from patterns like these, and it changes with the method, the averaging, the tail factor and
-- judgment about unusual years (a catastrophe year develops differently and is often excluded
-- from the factor selection). The claims source holds paid and case reserves only, and every
-- model in this project reports those. This analysis shows where IBNR would come from.
--
-- Incurred is used below; switch measure to 'paid' for the paid triangle. Paid factors are larger
-- and develop longer, because payments trail the reserves set for them.
{% set measure = 'incurred' %}

with triangle as (
    select
        line_of_business,
        accident_year,
        development_age_months,
        evaluation_date,
        {% if measure == 'paid' -%}
        cumulative_paid_loss_amount
        {%- else -%}
        cumulative_incurred_loss_amount
        {%- endif %} as cumulative_loss_amount
    from {{ ref('rpt_loss_development_triangle') }}
    where triangle_grain = 'ANNUAL_AT_VALUATION'
),

load_info as (
    select * from {{ ref('stg_generator_audit__load_info') }}
),

-- Pair each cell with the same accident year's cell one age (12 months) later.
cell_pairs as (
    select
        earlier.line_of_business,
        earlier.accident_year,
        earlier.development_age_months as from_age_months,
        later.development_age_months as to_age_months,
        earlier.cumulative_loss_amount as from_amount,
        later.cumulative_loss_amount as to_amount
    from triangle as earlier
    inner join triangle as later
        on earlier.line_of_business = later.line_of_business
        and earlier.accident_year = later.accident_year
        and later.development_age_months = earlier.development_age_months + 12
),

age_to_age_factors as (
    select
        line_of_business,
        from_age_months,
        to_age_months,
        count(*) as accident_years_used,
        sum(to_amount) / nullif(sum(from_amount), 0) as age_to_age_factor
    from cell_pairs
    group by all
),

-- The product of the factors from an age onward, by exp(sum(ln(x))) because SQL has no product
-- aggregate. The factors are positive, so the logarithm is defined.
cumulative_factors as (
    select
        later_factors.line_of_business,
        ages.from_age_months as development_age_months,
        exp(sum(ln(later_factors.age_to_age_factor))) as cumulative_development_factor
    from age_to_age_factors as ages
    inner join age_to_age_factors as later_factors
        on ages.line_of_business = later_factors.line_of_business
        and later_factors.from_age_months >= ages.from_age_months
    group by all
),

-- The cells evaluated at the valuation date. Selected by date, not as each year's oldest age,
-- so that a valuation date with no cell (one that is not a month end) gives no projection
-- instead of a stale one.
latest_diagonal as (
    select triangle.*
    from triangle
    cross join load_info
    where triangle.evaluation_date = load_info.valuation_date
),

projections as (
    select
        latest_diagonal.line_of_business,
        latest_diagonal.accident_year,
        latest_diagonal.development_age_months as latest_age_months,
        latest_diagonal.cumulative_loss_amount as reported_amount,
        -- Younger than 12 months: the accident year is not over, so it is not projected (see
        -- the header). Otherwise the oldest age has no later factor and is taken as developed
        -- (no tail factor).
        case
            when latest_diagonal.development_age_months >= 12
                then coalesce(cumulative_factors.cumulative_development_factor, 1)
        end as cumulative_development_factor
    from latest_diagonal
    left join cumulative_factors
        on latest_diagonal.line_of_business = cumulative_factors.line_of_business
        and latest_diagonal.development_age_months = cumulative_factors.development_age_months
),

-- The factors are floating point, so the ultimate is rounded back to cents. A null factor
-- (the current accident year) gives a null ultimate, and with it a null IBNR.
estimates as (
    select
        *,
        round(reported_amount * cumulative_development_factor, 2) as estimated_ultimate_amount
    from projections
),

final as (
    select
        'age_to_age' as row_type,
        line_of_business,
        null as accident_year,
        from_age_months,
        to_age_months,
        accident_years_used,
        round(age_to_age_factor, 4) as factor,
        null as reported_amount,
        null as estimated_ultimate_amount,
        null as estimated_ibnr_amount
    from age_to_age_factors

    union all

    select
        'projection' as row_type,
        line_of_business,
        accident_year,
        latest_age_months as from_age_months,
        null as to_age_months,
        null as accident_years_used,
        round(cumulative_development_factor, 4) as factor,
        reported_amount,
        estimated_ultimate_amount,
        -- Rounded again because the subtraction mixes a double with a decimal.
        round(estimated_ultimate_amount - reported_amount, 2) as estimated_ibnr_amount
    from estimates
)

select * from final
order by line_of_business, row_type, coalesce(accident_year, 0), from_age_months
