{#
    The accounting period a transaction is booked in (docs/source-systems.md, 3c).

    A transaction belongs to the first period, on or after the period of its transaction_date,
    that was still open when the transaction was entered. Closed periods never change, so a
    transaction keyed in after its month closed lands in the next open period instead.

    Returns a 'YYYY-MM' string. Usage, in a select list:
        {{ booked_accounting_period('transaction_date', 'created_at') }} as accounting_period

    Written as a scalar subquery so it can be used in any model without an extra join. DuckDB
    decorrelates it into a join, so it stays fast on millions of rows. 'YYYY-MM' strings sort
    in date order, which makes min() the earliest period.
#}
{% macro booked_accounting_period(transaction_date, entered_at) -%}
    (
        select min(_periods.accounting_period)
        from {{ ref('accounting_periods') }} as _periods
        where _periods.period_end_date >= cast({{ transaction_date }} as date)
          and {{ entered_at }} < _periods.close_date + interval 1 day
    )
{%- endmacro %}
