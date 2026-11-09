{#
    The largest difference, in dollars, that the accounting reports and tests treat as zero.

    Every amount on both sides is a sum of two-decimal values, so a correct reconciliation is
    exact to the cent. One cent of tolerance is the conventional "within a penny" allowance, and
    it is far below any real error (a missed payment, a misposted journal). Defined once so the
    reconciliation's status column and the tests that check it can never disagree.

    Usage: abs(unexplained_difference) <= {{ accounting_reconciliation_tolerance() }}
#}
{% macro accounting_reconciliation_tolerance() -%}
    0.01
{%- endmacro %}
