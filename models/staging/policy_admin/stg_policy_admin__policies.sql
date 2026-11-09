-- One row per policy: the contract with a policyholder, renewed term after term.
-- policy_status is the current state only; Fivetran overwrites it in place.
with source as (
    select * from {{ source('policy_admin', 'policies') }}
),

final as (
    select
        policy_id,
        policy_number,
        policyholder_id,
        line_of_business,
        risk_state,
        sales_channel,
        original_effective_date,
        policy_status,
        {{ premium_is_test_policy('policy_id') }} as is_test_policy,
        created_at,
        updated_at
    from source
    -- Policies created in error and deleted in the source (SOFT_DELETED_POLICIES).
    where not coalesce(_fivetran_deleted, false)
)

select * from final
