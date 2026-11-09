-- One row per insured dwelling on a HOME policy; the home exposure unit (a "house-year").
with source as (
    select * from {{ source('policy_admin', 'dwellings') }}
),

final as (
    select
        dwelling_id,
        policy_id,
        year_built,
        construction_type,
        square_feet,
        -- Coverage A is the limit for the structure itself; contents and liability limits are
        -- set relative to it on a homeowners policy.
        coverage_a_limit,
        {{ premium_is_test_policy('policy_id') }} as is_test_policy,
        created_at
    from source
    where not coalesce(_fivetran_deleted, false)
)

select * from final
