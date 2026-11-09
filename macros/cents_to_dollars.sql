{#
    Convert an integer amount in cents (the billing system's unit) to dollars with two decimals.

    Multiply by 0.01 instead of dividing by 100: DuckDB computes DECIMAL / INTEGER as a DOUBLE
    (binary floating point), so sums of the result pick up float noise (1034.7500000000002).
    DECIMAL * DECIMAL stays DECIMAL, and the outer cast fixes the scale at two places.
#}
{% macro cents_to_dollars(column_name) -%}
    cast(cast({{ column_name }} as decimal(18, 0)) * 0.01 as decimal(18, 2))
{%- endmacro %}
