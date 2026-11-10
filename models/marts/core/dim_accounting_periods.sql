-- One row per accounting period (calendar month), from seeds/accounting_periods.csv, with
-- the attributes reports filter and join on: a sequence number for "the prior period"
-- arithmetic, and where each period stands at the valuation date.

with accounting_periods as (
    select * from {{ ref('accounting_periods') }}
),

load_info as (
    select * from {{ ref('stg_generator_audit__load_info') }}
),

final as (
    select
        accounting_period,
        -- 1 for the first period. Period P-1 is period_sequence - 1, which is easier to join
        -- on than date arithmetic on 'YYYY-MM' strings.
        row_number() over (order by accounting_period) as period_sequence,
        lag(accounting_period) over (order by accounting_period) as prior_accounting_period,
        period_start_date,
        period_end_date,
        {{ dbt.datediff('period_start_date', 'period_end_date', 'day') }} + 1 as days_in_period,
        -- The books close at the end of the 4th business day of the following month. After
        -- that nothing new is booked into the period: late entries land in the next open one.
        close_date,
        fiscal_year,
        fiscal_quarter,
        -- The valuation date is the last simulated day, observed at its end; a period whose
        -- close date is on or before it was closed by then.
        close_date <= load_info.valuation_date as is_closed_at_valuation,
        load_info.valuation_date between period_start_date and period_end_date
            as is_valuation_period,
        period_start_date > load_info.valuation_date as is_after_valuation
    from accounting_periods
    cross join load_info
)

select * from final
