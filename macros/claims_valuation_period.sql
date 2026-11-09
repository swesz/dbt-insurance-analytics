{#
    The accounting period that contains the valuation date (var valuation_date), as 'YYYY-MM'.

    Claims balances "at valuation" are sums over events booked in this period or earlier. Looked
    up in the calendar seed rather than computed from the date, so the claims models follow the
    calendar if periods ever stop being calendar months.

    Usage, anywhere an expression is allowed:
        where accounting_period <= {{ claims_valuation_period() }}
#}
{% macro claims_valuation_period() -%}
    (
        select _periods.accounting_period
        from {{ ref('accounting_periods') }} as _periods
        where cast('{{ var("valuation_date") }}' as date)
            between _periods.period_start_date and _periods.period_end_date
    )
{%- endmacro %}
