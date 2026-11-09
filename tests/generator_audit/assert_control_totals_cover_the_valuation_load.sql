-- Guard for the control-total tests (tests/premium, tests/claims). Those tests compare only
-- when the raw load's as_of equals the as_of the generator computed its totals for, and pass
-- without comparing on any other load. That is right for a month-by-month replay: the totals
-- describe the valuation date, not an earlier close.
--
-- The catch: if the default load's as_of ever drifted from the totals' as_of (a changed
-- timestamp precision, a new default in the loader or the generator), every control-total test
-- would pass without checking anything, and CI would stay green. A test that cannot fail is
-- worse than no test, because it reads as evidence.
--
-- So a load that sees the whole simulated history (as_of on or after the valuation date) must
-- have control totals for exactly its as_of. Earlier loads are replays and are exempt.
with load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

control_totals as (
    select * from {{ source('generator_audit', 'control_totals') }}
),

final as (
    select
        load_info.as_of as load_as_of,
        load_info.valuation_date
    from load_info
    where cast(load_info.as_of as date) >= load_info.valuation_date
        -- not exists, not "not in": a null as_of in the totals must not hide a missing match
        and not exists (
            select 1
            from control_totals
            where control_totals.as_of = load_info.as_of
        )
)

select * from final
