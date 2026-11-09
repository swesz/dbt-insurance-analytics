-- Warn when a snapshot's current version belongs to a key the source no longer has.
--
-- The snapshots use hard_deletes = 'ignore' (snapshots/snap_policy_terms.yml explains why):
-- Fivetran-style tables keep deleted rows flagged, so a vanished key is a loading accident, not
-- a deletion, and the snapshot does not write it into history. This test keeps the accident
-- visible instead. Typical causes: the raw database was loaded at an earlier as-of than the
-- snapshot has seen (run scripts/simulate_month_end_closes.py with --fresh), or a connector
-- re-sync dropped rows.
{{ config(severity='warn') }}

{% set snapshots = [
    ('snap_policy_terms', 'term_id', source('policy_admin', 'policy_terms')),
    ('snap_policyholders', 'policyholder_id', source('policy_admin', 'policyholders')),
    ('snap_billing_payments', 'payment_id', source('billing', 'payments')),
] %}

{% for snapshot_name, key, source_relation in snapshots %}
select
    '{{ snapshot_name }}' as snapshot_name,
    cast(snapshot_rows.{{ key }} as varchar) as snapshot_key
from {{ ref(snapshot_name) }} as snapshot_rows
left join {{ source_relation }} as source_rows
    on snapshot_rows.{{ key }} = source_rows.{{ key }}
where snapshot_rows.dbt_valid_to = cast('9999-12-31 00:00:00' as timestamp)
    and source_rows.{{ key }} is null
{{ "union all" if not loop.last }}
{% endfor %}
