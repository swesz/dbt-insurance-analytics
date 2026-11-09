{#
    The largest difference, in dollars, that the accounting reports and tests treat as zero:
    none (D-015).

    Every amount on both sides of every reconciliation is a sum of two-decimal values, kept as
    DECIMAL throughout, so a correct reconciliation is exact to the cent, and on this data every
    reconciliation, rollforward and receivable difference is exactly 0.00. An allowance of a
    cent, the conventional "within a penny", would buy nothing and would hide the one class of
    bug that produces differences that small: a unit or type conversion (dividing cents by 100
    in floating point, rounding each line instead of the total) that is off by a cent here and
    there. With zero tolerance, that fails the build.

    Kept as a macro, although it is zero, so the policy is stated once and the reconciliation's
    status column and the tests that check it cannot disagree.

    Usage: abs(unexplained_difference) <= {{ accounting_reconciliation_tolerance() }}
#}
{% macro accounting_reconciliation_tolerance() -%}
    0
{%- endmacro %}
