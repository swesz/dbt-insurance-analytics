{#
    The accounting period that contains the valuation date (stg_generator_audit__load_info,
    D-024), as 'YYYY-MM'.

    Claims balances "at valuation" are sums over events booked in this period or earlier. Looked
    up in the calendar seed rather than computed from the date, so the claims models follow the
    calendar if periods ever stop being calendar months. Both refs register as dependencies of
    the calling model when dbt parses it, so the lineage shows them.

    Usage, anywhere an expression is allowed:
        where accounting_period <= {{ claims_valuation_period() }}
#}
{% macro claims_valuation_period() -%}
    (
        select _periods.accounting_period
        from {{ ref('accounting_periods') }} as _periods
        inner join {{ ref('stg_generator_audit__load_info') }} as _load_info
            on _load_info.valuation_date
                between _periods.period_start_date and _periods.period_end_date
    )
{%- endmacro %}
