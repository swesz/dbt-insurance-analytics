-- Re-loaded CDC versions (same key and updated_at) are exact copies of each other in every
-- business column, so collapsing them in staging loses nothing (macros/claims_cdc_versions.sql).
-- If two rows share a key and updated_at but differ in content, they are not a re-load but two
-- different changes stamped with the same time, and keeping only one would lose a change.
-- Returns the (table, key, updated_at) groups whose copies differ.
{% set tables = [
    ('claims', 'claim_id'),
    ('claim_exposures', 'exposure_id'),
    ('claim_transactions', 'claim_transaction_id'),
    ('adjusters', 'adjuster_id'),
] %}
{% set loader_columns = ['_rivery_last_update', '_rivery_run_id', '_rivery_river_id'] %}

{% for table_name, key in tables %}
{#- Columns are read from the database, which dbt can do only at execution, not at parse. -#}
{%- set business_columns = [key, 'updated_at'] -%}
{%- for column in (adapter.get_columns_in_relation(source('claims', table_name)) if execute else []) -%}
    {%- if column.name not in loader_columns + [key, 'updated_at'] -%}
        {%- do business_columns.append(column.name) -%}
    {%- endif -%}
{%- endfor %}
select
    '{{ table_name }}' as source_table,
    {{ key }} as source_key,
    updated_at,
    count(*) as copies,
    count(distinct ({{ business_columns | join(', ') }})) as distinct_contents
from {{ source('claims', table_name) }}
group by {{ key }}, updated_at
having count(*) > 1
    and count(distinct ({{ business_columns | join(', ') }})) > 1
{% if not loop.last %}union all{% endif %}
{% endfor %}
