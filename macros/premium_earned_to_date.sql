{#
    Inception-to-date earned premium of one transaction line at the end of as_of_date
    (docs/source-systems.md 3d):

        round(written_premium * elapsed / window_days, 2), rounding half away from zero,
        elapsed = clamp((as_of_date + 1) - effective_date, 0, window_days),
        and a zero-day window is fully earned at once.

    Premium earns evenly per day, so after `elapsed` of `window_days` days that fraction of the
    line's premium is earned. "+ 1" because as_of_date is inclusive: at the end of the first
    covered day one day has elapsed.

    Why integer cents instead of the formula as written: DuckDB divides DECIMALs in DOUBLE
    (binary floating point), and a double cannot hold most decimal fractions exactly, so
    round(..., 2) can round the wrong way at an exact half cent (round(1.005::double, 2) is 1.0).
    Here every step is exact integer arithmetic:

        n = written_cents * elapsed, w = window_days, both integers,
        round_half_away_from_zero(n / w) = sign(n) * floor((2 * |n| + w) / (2 * w))

    Adding half the divisor before dividing rounds a half up, and doing it on |n| with the sign
    put back afterwards makes negative lines (cancellations) round away from zero too. `//` is
    DuckDB's integer division (it truncates, which equals floor for the non-negative operands
    used here); another warehouse needs its own operator, for example div() on BigQuery. The
    cents go back to dollars by multiplying with 0.01, which stays DECIMAL, unlike / 100.

    Arguments are SQL expressions. Returns decimal(18, 2).
#}
{% macro premium_earned_to_date(written_premium, effective_date, window_days, as_of_date) -%}
    case
        when {{ window_days }} = 0 then cast({{ written_premium }} as decimal(18, 2))
        else cast(
            cast(
                sign(cast({{ written_premium }} * 100 as bigint))
                * (
                    (
                        2 * abs(cast({{ written_premium }} * 100 as bigint))
                        * least(
                            greatest(
                                {{ dbt.datediff(effective_date, as_of_date, 'day') }} + 1,
                                0
                            ),
                            {{ window_days }}
                        )
                        + {{ window_days }}
                    ) // (2 * {{ window_days }})
                )
            as decimal(18, 0)) * 0.01
        as decimal(18, 2))
    end
{%- endmacro %}
