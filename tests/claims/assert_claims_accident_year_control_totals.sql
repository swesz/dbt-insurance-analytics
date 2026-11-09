-- Claims figures per accident year and line of business match the generator's control totals
-- (docs/source-systems.md, section 5):
--   incurred_loss   net paid loss + outstanding loss reserve at the valuation date
--   paid_loss_net   net paid loss at the valuation date
--   claim_count     claims by year of loss_date (deleted and test-policy claims excluded)
-- Accident year groups by when the loss happened, so this checks the loss_date join as well as
-- the money. Exact match (sums of two-decimal amounts and counts, no rounding).
-- Compared only on a load at the control totals' as_of; passes with no rows otherwise.
with load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

control_totals as (
    select * from {{ source('generator_audit', 'control_totals') }}
),

claims as (
    select * from {{ ref('dim_claims') }}
),

expected as (
    select
        control_totals.metric,
        control_totals.period,
        control_totals.line_of_business,
        control_totals.value
    from control_totals
    inner join load_info
        on control_totals.as_of = load_info.as_of
    where control_totals.grain = 'accident_year'
        and control_totals.metric in ('incurred_loss', 'paid_loss_net', 'claim_count')
),

actual as (
    select
        metric,
        cast(accident_year as varchar) as period,
        line_of_business,
        value
    from (
        select
            accident_year,
            line_of_business,
            -- One type for all three, so unpivot does not fall back to a floating-point type.
            cast(sum(incurred_loss_amount) as decimal(18, 2)) as incurred_loss,
            cast(sum(net_paid_loss_amount) as decimal(18, 2)) as paid_loss_net,
            cast(count(*) as decimal(18, 2)) as claim_count
        from claims
        group by all
    ) unpivot (value for metric in (incurred_loss, paid_loss_net, claim_count))
),

compared as (
    select
        coalesce(expected.metric, actual.metric) as metric,
        coalesce(expected.period, actual.period) as period,
        coalesce(expected.line_of_business, actual.line_of_business) as line_of_business,
        expected.value as expected_value,
        actual.value as actual_value,
        coalesce(actual.value, 0) - coalesce(expected.value, 0) as difference
    from expected
    full outer join actual
        on expected.metric = actual.metric
        and expected.period = actual.period
        and expected.line_of_business = actual.line_of_business
)

select *
from compared
where difference <> 0
    and exists (select 1 from expected)
order by metric, period, line_of_business
