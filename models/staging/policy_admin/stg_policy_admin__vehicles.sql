-- One row per insured vehicle on an AUTO policy. A vehicle is the auto exposure unit: claim
-- frequency is measured per vehicle insured for a year (a "car-year").
with source as (
    select * from {{ source('policy_admin', 'vehicles') }}
),

final as (
    select
        vehicle_id,
        policy_id,
        model_year,
        make,
        body_type,
        {{ premium_is_test_policy('policy_id') }} as is_test_policy,
        created_at
    from source
    where not coalesce(_fivetran_deleted, false)
)

select * from final
