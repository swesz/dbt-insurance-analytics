-- The triangle's cells at the valuation date equal the generator's accident-year control totals
-- (docs/source-systems.md, section 5): incurred loss, net paid loss and claim count per accident
-- year and line of business. The generator computes them in Python from its own records, so this
-- checks the triangle's cell logic (origin grouping, evaluation dates, the booked-period cutoff)
-- against figures it did not produce.
--
-- Two grains have cells at the valuation date: ANNUAL_AT_VALUATION, whose latest diagonal is the
-- valuation date for every accident year, the current one included; and QUARTERLY, whose
-- accident quarters are summed to the year here. (The ANNUAL grain is evaluated at year ends and
-- has no such cells.) The chain-ladder analysis projects from the ANNUAL_AT_VALUATION diagonal,
-- so this test is what guarantees it starts from today's figures: if that grain had no cell at
-- the valuation date (say, a valuation date that is not a month end), every expected row would
-- be missing on the triangle side and show up here.
--
-- Exact match: sums of two-decimal amounts and counts on both sides, no rounding.
-- Compared only on a load at the control totals' as_of; passes with no rows otherwise
-- (tests/generator_audit/assert_control_totals_cover_the_valuation_load.sql fails if the
-- default load is not such a load).
with load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

control_totals as (
    select * from {{ source('generator_audit', 'control_totals') }}
),

triangle as (
    select * from {{ ref('rpt_loss_development_triangle') }}
),

grains_at_valuation as (
    select 'ANNUAL_AT_VALUATION' as triangle_grain
    union all
    select 'QUARTERLY' as triangle_grain
),

expected as (
    select
        grains_at_valuation.triangle_grain,
        control_totals.metric,
        control_totals.period,
        control_totals.line_of_business,
        control_totals.value
    from control_totals
    inner join load_info
        on control_totals.as_of = load_info.as_of
    -- Each grain is compared with the same totals.
    cross join grains_at_valuation
    where control_totals.grain = 'accident_year'
        and control_totals.metric in ('incurred_loss', 'paid_loss_net', 'claim_count')
),

actual as (
    select
        triangle_grain,
        metric,
        period,
        line_of_business,
        value
    from (
        select
            triangle.triangle_grain,
            cast(triangle.accident_year as varchar) as period,
            triangle.line_of_business,
            -- One type for all three, so unpivot does not fall back to a floating-point type.
            cast(sum(triangle.cumulative_incurred_loss_amount) as decimal(18, 2)) as incurred_loss,
            cast(sum(triangle.cumulative_paid_loss_amount) as decimal(18, 2)) as paid_loss_net,
            -- Every claim is reported by the valuation date, so the reported count at the
            -- valuation date is the accident year's claim count.
            cast(sum(triangle.reported_claim_count) as decimal(18, 2)) as claim_count
        from triangle
        inner join grains_at_valuation
            on triangle.triangle_grain = grains_at_valuation.triangle_grain
        -- The load's own row: the same valuation date the models read through
        -- stg_generator_audit__load_info.
        cross join load_info
        where triangle.evaluation_date = load_info.valuation_date
        group by all
    ) unpivot (value for metric in (incurred_loss, paid_loss_net, claim_count))
),

compared as (
    select
        coalesce(expected.triangle_grain, actual.triangle_grain) as triangle_grain,
        coalesce(expected.metric, actual.metric) as metric,
        coalesce(expected.period, actual.period) as period,
        coalesce(expected.line_of_business, actual.line_of_business) as line_of_business,
        expected.value as expected_value,
        actual.value as actual_value
    from expected
    full outer join actual
        on expected.triangle_grain = actual.triangle_grain
        and expected.metric = actual.metric
        and expected.period = actual.period
        and expected.line_of_business = actual.line_of_business
)

-- A row missing on either side is a failure here, not a zero: every accident year and line in
-- the control totals has claims, so each must have a cell at the valuation date.
select *
from compared
where expected_value is distinct from actual_value
    and exists (select 1 from expected)
order by triangle_grain, metric, period, line_of_business
