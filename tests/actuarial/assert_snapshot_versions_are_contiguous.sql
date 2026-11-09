-- The versions of each snapshot key form an unbroken, non-overlapping timeline: every version
-- has dbt_valid_from < dbt_valid_to, and each version ends exactly where the next begins.
--
-- Point-in-time queries ("the version current at the end of the close date") rely on this:
-- with a gap, a key would have no version at some moment; with an overlap, two. It also guards
-- the choice of updated_at in snap_policyholders: had it used the source updated_at, which a
-- soft delete leaves unchanged, the delete version would start at the same moment as the
-- version before it, and that version would have zero length.
{% set snapshots = [
    ('snap_policy_terms', 'term_id'),
    ('snap_policyholders', 'policyholder_id'),
    ('snap_billing_payments', 'payment_id'),
] %}

with
{% for snapshot_name, key in snapshots %}
{{ snapshot_name }} as (
    select
        '{{ snapshot_name }}' as snapshot_name,
        cast({{ key }} as varchar) as snapshot_key,
        dbt_valid_from,
        dbt_valid_to,
        lead(dbt_valid_from) over (partition by {{ key }} order by dbt_valid_from) as next_valid_from
    from {{ ref(snapshot_name) }}
){{ "," if not loop.last }}
{% endfor %}

select *
from (
{% for snapshot_name, key in snapshots %}
    select * from {{ snapshot_name }}
    {{ "union all" if not loop.last }}
{% endfor %}
) as versions
where dbt_valid_from >= dbt_valid_to
    or (next_valid_from is not null and next_valid_from <> dbt_valid_to)
