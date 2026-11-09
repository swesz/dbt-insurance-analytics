-- One row per calendar day over the whole accounting calendar in seeds/accounting_periods.csv,
-- with calendar attributes and the accounting period the day belongs to.

{%- set periods_relation = ref('accounting_periods') %}
{%- set spine_start = "(select min(period_start_date) from " ~ periods_relation ~ ")" %}
{#- date_spine's end date is exclusive, so end one day after the last period. #}
{%- set spine_end = dbt.dateadd('day', 1, "(select max(period_end_date) from " ~ periods_relation ~ ")") %}

with accounting_periods as (
    select * from {{ periods_relation }}
),

date_spine as (
    {{ dbt_utils.date_spine(datepart='day', start_date=spine_start, end_date=spine_end) }}
),

days as (
    select cast(date_day as date) as date_day
    from date_spine
),

final as (
    select
        days.date_day,
        extract(year from days.date_day) as calendar_year,
        extract(quarter from days.date_day) as calendar_quarter,
        extract(month from days.date_day) as calendar_month,
        -- monthname/dayname are DuckDB functions; other warehouses have their own.
        monthname(days.date_day) as month_name,
        extract(day from days.date_day) as day_of_month,
        -- ISO numbering: 1 = Monday ... 7 = Sunday.
        extract(isodow from days.date_day) as day_of_week,
        dayname(days.date_day) as day_name,
        -- Business days are Monday to Friday, with no holidays: that is the rule the close
        -- calendar uses (close = 4th business day of the next month).
        extract(isodow from days.date_day) <= 5 as is_weekday,
        cast({{ dbt.date_trunc('month', 'days.date_day') }} as date) as month_start_date,
        accounting_periods.accounting_period,
        accounting_periods.fiscal_year,
        accounting_periods.fiscal_quarter,
        accounting_periods.period_end_date,
        days.date_day = accounting_periods.period_end_date as is_period_end,
        days.date_day <= cast('{{ var("valuation_date") }}' as date) as is_on_or_before_valuation
    from days
    inner join accounting_periods
        on days.date_day between accounting_periods.period_start_date
            and accounting_periods.period_end_date
)

select * from final
