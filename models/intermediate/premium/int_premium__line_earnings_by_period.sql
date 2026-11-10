{{ config(materialized='table') }}

-- One row per transaction line and accounting period, from the period the line is booked in
-- through the period of its last earning day (capped at the valuation period): written
-- premium booked, inception-to-date (ITD) earned at the period end, earned in the period and
-- unearned at the period end. docs/source-systems.md 3d is the specification.
--
-- Why earned(P) = ITD(P) - ITD(P-1) instead of "days of the window inside P":
--   1. Rounding. Each ITD value is rounded to the cent, and differences of rounded running
--      totals add up to the rounded total exactly. Summing separately rounded monthly pieces
--      would not, and a fully earned line could end a cent away from its written premium.
--   2. Closed periods never change. A backdated endorsement booked in March but effective in
--      February has no row in February (February's books were closed without it). Its ITD
--      at the end of March includes the February days, and since its ITD before March is 0,
--      March's earned picks up the elapsed days at once: the "catch-up".
--   3. The unearned premium rollforward ties by construction:
--      UPR(P) = written ITD(P) - earned ITD(P), so UPR(P) - UPR(P-1) = written(P) - earned(P).
--
-- The heaviest model of the project (lines x months), so it is a table with only the keys
-- and the four amounts; join int_premium__transaction_lines_booked for attributes.

with lines as (
    select
        transaction_line_id,
        accounting_period as booked_accounting_period,
        written_premium,
        coverage_start_date,
        coverage_end_date,
        window_days
    from {{ ref('int_premium__transaction_lines_booked') }}
),

accounting_periods as (
    select * from {{ ref('accounting_periods') }}
),

load_info as (
    select * from {{ ref('stg_generator_audit__load_info') }}
),

periods as (
    select
        accounting_period,
        period_start_date,
        period_end_date,
        cast({{ dbt.dateadd('day', -1, 'period_start_date') }} as date) as prior_period_end_date
    from accounting_periods
    cross join load_info
    -- The data stops at the valuation date, so the month-end series stops at its period.
    where period_start_date <= load_info.valuation_date
),

line_periods as (
    select
        lines.transaction_line_id,
        lines.booked_accounting_period,
        lines.written_premium,
        lines.coverage_start_date,
        lines.window_days,
        periods.accounting_period,
        periods.period_end_date,
        periods.prior_period_end_date
    from lines
    inner join periods
        on periods.accounting_period >= lines.booked_accounting_period
        and (
            -- Always the booked period, even when the window has already ended by then
            -- (a late cancellation): that is where the whole effect lands.
            periods.accounting_period = lines.booked_accounting_period
            -- Then every period that still holds a day of the window. The window ends at
            -- coverage_end_date exclusive, so a period starting on or after it adds nothing.
            or (lines.window_days > 0 and periods.period_start_date < lines.coverage_end_date)
        )
),

earned as (
    select
        transaction_line_id,
        accounting_period,
        booked_accounting_period,
        written_premium as line_written_premium,
        {{ premium_earned_to_date(
            'written_premium', 'coverage_start_date', 'window_days', 'period_end_date'
        ) }} as itd_earned_premium,
        -- ITD at the prior period end counts only lines booked by then. In the booked period
        -- the line was not on the books yet, so its prior ITD is 0 and any elapsed days are
        -- earned now.
        case
            when accounting_period = booked_accounting_period then cast(0 as decimal(18, 2))
            else {{ premium_earned_to_date(
                'written_premium', 'coverage_start_date', 'window_days', 'prior_period_end_date'
            ) }}
        end as itd_earned_premium_prior
    from line_periods
),

final as (
    select
        transaction_line_id,
        accounting_period,
        cast(
            case when accounting_period = booked_accounting_period then line_written_premium else 0 end
        as decimal(18, 2)) as written_premium,
        itd_earned_premium,
        cast(itd_earned_premium - itd_earned_premium_prior as decimal(18, 2)) as earned_premium,
        -- The line is on the books from its booked period on, so all of its written premium
        -- counts toward ITD written here.
        cast(line_written_premium - itd_earned_premium as decimal(18, 2)) as unearned_premium_end
    from earned
)

select * from final
