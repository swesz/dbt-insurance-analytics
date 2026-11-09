-- Each snapshot key has at most one current version (dbt_valid_to = the dbt_valid_to_current
-- value, 9999-12-31, configured in snapshots/*.yml).
--
-- Two current versions of one term would make every "as of now" query count it twice, and a
-- point-in-time join return two rows. dbt guarantees this only while unique_key really is
-- unique in the source and the snapshot is never run concurrently with itself, so it is worth
-- checking. (Zero current versions is allowed: that is what hard_deletes = 'invalidate' would
-- produce for a deleted key; with 'ignore', as configured, every key keeps one.)
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
        count(*) as current_versions
    from {{ ref(snapshot_name) }}
    where dbt_valid_to = cast('9999-12-31 00:00:00' as timestamp)
    group by all
    having count(*) > 1
){{ "," if not loop.last }}
{% endfor %}

{% for snapshot_name, key in snapshots %}
select * from {{ snapshot_name }}
{{ "union all" if not loop.last }}
{% endfor %}
