-- Loss development triangle: for each origin period (accident year, or accident quarter in the
-- quarterly variant) and line of business, cumulative paid loss, incurred loss and reported
-- claim count as they stood at successive evaluation dates.
--
-- How to read it: a row is one cell. origin_period says when the losses happened;
-- development_age_months says how long after the start of that period we look; the figures are
-- what was known at the evaluation date, the last day of that age. Accident year 2023 at age 12
-- is the 2023 losses as of 2023-12-31; at age 24, as of 2024-12-31. Along one origin period the
-- numbers grow ("develop") as late-reported claims arrive, open claims are paid and case
-- reserves are revised. The chain-ladder method (analyses/chain_ladder_development_factors.sql)
-- projects that growth to estimate ultimate losses, and with them IBNR.
--
-- Three grains (triangle_grain), which differ in their origin periods and evaluation dates:
--   ANNUAL               accident years at year ends: ages 12, 24, 36, ... The standard
--                        year-end triangle. Its latest diagonal is the last year end on or
--                        before the valuation date (2025-12-31 for a 2026-09-30 valuation), so
--                        it is up to 11 months old, and the current accident year has no cell.
--   QUARTERLY            accident quarters at quarter ends: ages 3, 6, 9, ... Shows the recent
--                        quarters the annual grain cannot show yet.
--   ANNUAL_AT_VALUATION  accident years at the valuation date and its anniversaries: ages 9,
--                        21, 33, ... for a September valuation (evaluation dates 09-30 of each
--                        year). Its latest diagonal is the valuation date itself, the same
--                        figures as dim_claims and rpt_loss_ratio_by_accident_year, which is
--                        what a reserve at the valuation date has to start from. The chain
--                        ladder uses this grain.
-- In a December valuation the two annual grains are the same cells.
--
-- Evaluated on booked periods: a cell counts events booked in its evaluation period or earlier,
-- so a cell never changes once its period is closed, the same figures the ledger showed then.
-- Only cells whose evaluation date is on or before the valuation date exist: the rest is the
-- unknown future, the empty lower-right half that gives the triangle its shape.
--
-- Loss only (cost_category = 'LOSS'): expenses develop differently and get their own analysis.
with financial_events as (
    select * from {{ ref('int_claims__financial_events') }}
),

claims as (
    select * from {{ ref('dim_claims') }}
),

accounting_periods as (
    select * from {{ ref('accounting_periods') }}
),

-- age_offset_months shifts the ages back from whole origin periods. For ANNUAL_AT_VALUATION it
-- is the number of months from the valuation date's month end to the year end (3 for
-- September), so the ages are 12 - 3 = 9, 24 - 3 = 21, ... and every evaluation date falls in
-- the valuation month. This assumes the valuation date is a month end, as the generator's is:
-- otherwise no evaluation date would equal it, and
-- tests/claims/assert_triangle_latest_diagonal_matches_control_totals.sql fails.
triangle_grains as (
    select
        'ANNUAL' as triangle_grain,
        'year' as origin_date_part,
        12 as months_per_origin_period,
        0 as age_offset_months
    union all
    select
        'QUARTERLY' as triangle_grain,
        'quarter' as origin_date_part,
        3 as months_per_origin_period,
        0 as age_offset_months
    union all
    select
        'ANNUAL_AT_VALUATION' as triangle_grain,
        'year' as origin_date_part,
        12 as months_per_origin_period,
        12 - month(cast('{{ var("valuation_date") }}' as date)) as age_offset_months
),

-- Loss events per origin period and booked period, for each grain.
loss_by_origin as (
    select
        triangle_grains.triangle_grain,
        financial_events.line_of_business,
        date_trunc(triangle_grains.origin_date_part, financial_events.loss_date)
            as origin_start_date,
        financial_events.accounting_period,
        sum(financial_events.paid_amount) as paid_loss_amount,
        sum(financial_events.reserve_change_amount) as reserve_change_loss_amount
    from financial_events
    cross join triangle_grains
    where financial_events.cost_category = 'LOSS'
    group by all
),

claims_by_origin as (
    select
        triangle_grains.triangle_grain,
        claims.line_of_business,
        date_trunc(triangle_grains.origin_date_part, claims.loss_date) as origin_start_date,
        claims.claim_id,
        claims.reported_at
    from claims
    cross join triangle_grains
),

origins as (
    select distinct
        claims_by_origin.triangle_grain,
        triangle_grains.origin_date_part,
        triangle_grains.months_per_origin_period,
        triangle_grains.age_offset_months,
        claims_by_origin.line_of_business,
        cast(claims_by_origin.origin_start_date as date) as origin_start_date
    from claims_by_origin
    inner join triangle_grains
        on claims_by_origin.triangle_grain = triangle_grains.triangle_grain
),

-- Ages are whole origin periods less the grain's offset: 12, 24, 36, ... (annual),
-- 3, 6, 9, ... (quarterly), 9, 21, 33, ... (annual at a September valuation). The offset is
-- below 12, so every age is at least one month. The evaluation date is the day before
-- origin start + age, always a month end, so it is the end date of an accounting period.
cells as (
    select
        origins.triangle_grain,
        origins.origin_date_part,
        origins.line_of_business,
        origins.origin_start_date,
        origin_multiples.multiple * origins.months_per_origin_period - origins.age_offset_months
            as development_age_months,
        cast(
            origins.origin_start_date
                + to_months(
                    origin_multiples.multiple * origins.months_per_origin_period
                        - origins.age_offset_months
                )
                - interval 1 day
            as date
        ) as evaluation_date
    from origins
    cross join (select range as multiple from range(1, 121)) as origin_multiples
),

evaluated_cells as (
    select
        cells.*,
        accounting_periods.accounting_period as evaluation_period
    from cells
    inner join accounting_periods
        on cells.evaluation_date = accounting_periods.period_end_date
    where cells.evaluation_date <= cast('{{ var("valuation_date") }}' as date)
),

cell_amounts as (
    select
        evaluated_cells.triangle_grain,
        evaluated_cells.line_of_business,
        evaluated_cells.origin_start_date,
        evaluated_cells.development_age_months,
        coalesce(sum(loss_by_origin.paid_loss_amount), 0) as cumulative_paid_loss_amount,
        coalesce(sum(loss_by_origin.reserve_change_loss_amount), 0) as case_reserve_loss_amount
    from evaluated_cells
    left join loss_by_origin
        on evaluated_cells.triangle_grain = loss_by_origin.triangle_grain
        and evaluated_cells.line_of_business = loss_by_origin.line_of_business
        and evaluated_cells.origin_start_date = loss_by_origin.origin_start_date
        and loss_by_origin.accounting_period <= evaluated_cells.evaluation_period
    group by all
),

-- A claim counts once it has been reported, whether or not anything was paid: claim counts
-- develop too, because of report lag.
cell_counts as (
    select
        evaluated_cells.triangle_grain,
        evaluated_cells.line_of_business,
        evaluated_cells.origin_start_date,
        evaluated_cells.development_age_months,
        count(claims_by_origin.claim_id) as reported_claim_count
    from evaluated_cells
    left join claims_by_origin
        on evaluated_cells.triangle_grain = claims_by_origin.triangle_grain
        and evaluated_cells.line_of_business = claims_by_origin.line_of_business
        and evaluated_cells.origin_start_date = claims_by_origin.origin_start_date
        and claims_by_origin.reported_at < evaluated_cells.evaluation_date + interval 1 day
    group by all
),

final as (
    select
        evaluated_cells.triangle_grain,
        evaluated_cells.line_of_business,
        case evaluated_cells.origin_date_part
            when 'year' then strftime(evaluated_cells.origin_start_date, '%Y')
            else strftime(evaluated_cells.origin_start_date, '%Y')
                || '-Q' || cast(quarter(evaluated_cells.origin_start_date) as varchar)
        end as origin_period,
        year(evaluated_cells.origin_start_date) as accident_year,
        evaluated_cells.origin_start_date,
        evaluated_cells.development_age_months,
        evaluated_cells.evaluation_date,
        evaluated_cells.evaluation_period,
        cell_amounts.cumulative_paid_loss_amount,
        cell_amounts.case_reserve_loss_amount,
        cell_amounts.cumulative_paid_loss_amount + cell_amounts.case_reserve_loss_amount
            as cumulative_incurred_loss_amount,
        cell_counts.reported_claim_count
    from evaluated_cells
    inner join cell_amounts
        on evaluated_cells.triangle_grain = cell_amounts.triangle_grain
        and evaluated_cells.line_of_business = cell_amounts.line_of_business
        and evaluated_cells.origin_start_date = cell_amounts.origin_start_date
        and evaluated_cells.development_age_months = cell_amounts.development_age_months
    inner join cell_counts
        on evaluated_cells.triangle_grain = cell_counts.triangle_grain
        and evaluated_cells.line_of_business = cell_counts.line_of_business
        and evaluated_cells.origin_start_date = cell_counts.origin_start_date
        and evaluated_cells.development_age_months = cell_counts.development_age_months
)

select * from final
