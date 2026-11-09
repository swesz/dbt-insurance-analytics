{#
    Parse a debit or credit amount from the general ledger export (text) into decimal(18, 2).

    The export writes each journal line's amount on one side; the other side is empty. Until
    2024-12 amounts look like '1234.56'; from 2025-01 the ERP adds thousands separators,
    '1,234.56' (GL_AMOUNT_FORMAT_CHANGE in docs/data-issues.md). So:
        - remove ',' (a thousands separator; the export never uses ',' as a decimal mark),
        - an empty or blank field is 0 on that side, not null: a line with only a credit has a
          debit of zero, and summing debits must not skip it,
        - cast with cast(), not try_cast(): text that is still not a number after this cleanup
          is a new format nobody has seen yet, and the build should fail loudly instead of
          turning it into a silent null or zero.

    Usage, in a select list:
        {{ accounting_parse_gl_amount('debit') }} as debit_amount
#}
{% macro accounting_parse_gl_amount(column_name) -%}
    coalesce(
        cast(nullif(replace(trim({{ column_name }}), ',', ''), '') as decimal(18, 2)),
        cast(0 as decimal(18, 2))
    )
{%- endmacro %}
