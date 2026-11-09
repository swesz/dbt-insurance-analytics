{#
    Convert an integer amount in cents (the billing system's unit) to dollars with two decimals.
    Dividing by 100 as a DECIMAL keeps the result exact; integer / 100 would give a DOUBLE.
#}
{% macro cents_to_dollars(column_name) -%}
    cast({{ column_name }} as decimal(18, 2)) / 100
{%- endmacro %}
