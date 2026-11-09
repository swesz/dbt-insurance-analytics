-- One row per real policyholder (QA test customers excluded), with a summary of their
-- policies.

with policyholders as (
    select * from {{ ref('stg_policy_admin__policyholders') }}
),

policies as (
    select * from {{ ref('stg_policy_admin__policies') }}
),

policy_summary as (
    select
        policyholder_id,
        count(*) as policy_count,
        count(case when line_of_business = 'AUTO' then 1 end) as auto_policy_count,
        count(case when line_of_business = 'HOME' then 1 end) as home_policy_count,
        min(original_effective_date) as first_policy_effective_date
    from policies
    where not is_test_policy
    group by 1
),

final as (
    select
        policyholders.policyholder_id,
        policyholders.first_name,
        policyholders.last_name,
        policyholders.date_of_birth,
        policyholders.email,
        policyholders.address_state,
        policyholders.address_zip,
        coalesce(policy_summary.policy_count, 0) as policy_count,
        coalesce(policy_summary.auto_policy_count, 0) as auto_policy_count,
        coalesce(policy_summary.home_policy_count, 0) as home_policy_count,
        -- A customer with both lines is the classic cross-sell ("multi-line") segment.
        coalesce(policy_summary.auto_policy_count > 0 and policy_summary.home_policy_count > 0, false)
            as has_auto_and_home,
        policy_summary.first_policy_effective_date,
        policyholders.created_at,
        policyholders.updated_at
    from policyholders
    left join policy_summary
        on policyholders.policyholder_id = policy_summary.policyholder_id
    where not policyholders.is_test_record
)

select * from final
