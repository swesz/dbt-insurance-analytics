{#
    True for the QA test policies that live in production data (docs/source-systems.md 3h,
    docs/data-issues.md TEST_POLICIES).

    QA reserves policy_id 9000000 and up for test policies. Because the id is on every
    policy_admin table that belongs to a policy (policies, terms, transactions), each staging
    model can flag test rows from its own columns, without a join. Staging only flags them;
    intermediate models and marts filter them out.

    Usage, in a select list:
        {{ premium_is_test_policy('policy_id') }} as is_test_policy
#}
{% macro premium_is_test_policy(policy_id) -%}
    coalesce({{ policy_id }} >= 9000000, false)
{%- endmacro %}
