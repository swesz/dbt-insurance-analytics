-- Adjusters in their current state: the latest version per adjuster_id, without deleted keys.
with adjusters_source as (
    select * from {{ source('claims', 'adjusters') }}
),

distinct_versions as (
    {{ claims_cdc_versions('adjusters_source', 'adjuster_id') }}
),

final as (
    select
        adjuster_id,
        adjuster_name,
        team,
        is_active,
        hired_date,
        updated_at,
        _rivery_last_update as loaded_at
    from distinct_versions
    where is_latest_version
        and not coalesce(__deleted, false)
)

select * from final
