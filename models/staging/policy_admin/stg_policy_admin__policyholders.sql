-- One row per policyholder (the customer) in the policy administration system.
with source as (
    select * from {{ source('policy_admin', 'policyholders') }}
),

final as (
    select
        policyholder_id,
        first_name,
        last_name,
        date_of_birth,
        email,
        address_state,
        address_zip,
        -- QA convention (docs/source-systems.md 3h): test customers use a reserved mail domain.
        -- Flagged here, filtered downstream, so staging stays 1:1 with its source table.
        coalesce(lower(email) like '%@test.example.com', false) as is_test_record,
        created_at,
        updated_at
    from source
    -- Fivetran keeps rows deleted in the source, flagged. These are duplicate customer records
    -- that were merged away (SOFT_DELETED_POLICYHOLDERS in docs/data-issues.md).
    where not coalesce(_fivetran_deleted, false)
)

select * from final
