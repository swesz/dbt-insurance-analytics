{#
    A ratio for the actuarial reports: numerator / denominator, rounded to `scale` decimals and
    returned as a decimal, or null when the denominator is zero or null.

    Null rather than zero, because a ratio without a base is unknown, not 0%: a month with no
    earned premium has no loss ratio, and reporting 0% would look like a perfect result. DuckDB
    divides DECIMALs in DOUBLE, so the result is rounded and cast back to a fixed scale; the
    rounding error is far below anything a ratio is read at.

    Usage, in a select list:
        {{ actuarial_ratio('incurred_loss_amount', 'earned_premium') }} as loss_ratio
        {{ actuarial_ratio('claim_count', 'earned_exposure_years', 8) }} as claim_frequency
#}
{% macro actuarial_ratio(numerator, denominator, scale=4) -%}
    cast(
        round(({{ numerator }}) / nullif({{ denominator }}, 0), {{ scale }})
        as decimal(18, {{ scale }})
    )
{%- endmacro %}
