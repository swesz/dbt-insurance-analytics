-- One row per real policy (QA test policies excluded): the policy, its policyholder, what it
-- insures (vehicles or a dwelling) and where it stands now. Contract enforced, because the
-- accounting and actuarial marts join to it.

with policies as (
    select * from {{ ref('stg_policy_admin__policies') }}
),

policyholders as (
    select * from {{ ref('stg_policy_admin__policyholders') }}
),

terms as (
    select * from {{ ref('stg_policy_admin__policy_terms') }}
),

vehicles as (
    select * from {{ ref('stg_policy_admin__vehicles') }}
),

dwellings as (
    select * from {{ ref('stg_policy_admin__dwellings') }}
),

vehicle_summary as (
    select
        policy_id,
        count(*) as vehicle_count
    from vehicles
    group by 1
),

-- A homeowners policy insures one dwelling. If the source ever had two, the lowest
-- dwelling_id is shown and dwelling_count makes the duplicate visible (it is tested).
dwelling_ranked as (
    select
        dwellings.*,
        count(*) over (partition by policy_id) as dwelling_count,
        row_number() over (partition by policy_id order by dwelling_id) as dwelling_rank
    from dwellings
),

term_summary as (
    select
        policy_id,
        count(*) as term_count,
        max(term_number) as latest_term_number,
        -- In force at the valuation date, by the rule in docs/source-systems.md 3e, applied to
        -- the current state of the terms.
        bool_or(
            term_effective_date <= cast('{{ var("valuation_date") }}' as date)
            and cast('{{ var("valuation_date") }}' as date) < term_expiration_date
            and (
                cancellation_effective_date is null
                or cancellation_effective_date > cast('{{ var("valuation_date") }}' as date)
            )
        ) as is_in_force_at_valuation
    from terms
    group by 1
),

latest_terms as (
    select
        terms.policy_id,
        terms.term_id,
        terms.term_effective_date,
        terms.term_expiration_date,
        terms.term_status,
        terms.cancellation_effective_date,
        terms.cancellation_reason
    from terms
    inner join term_summary
        on terms.policy_id = term_summary.policy_id
        and terms.term_number = term_summary.latest_term_number
),

final as (
    select
        cast(policies.policy_id as bigint) as policy_id,
        cast(policies.policy_number as varchar) as policy_number,
        cast(policies.line_of_business as varchar) as line_of_business,
        cast(policies.risk_state as varchar) as risk_state,
        cast(policies.sales_channel as varchar) as sales_channel,
        cast(policies.original_effective_date as date) as original_effective_date,
        cast(policies.policy_status as varchar) as policy_status,
        cast(coalesce(term_summary.is_in_force_at_valuation, false) as boolean)
            as is_in_force_at_valuation,
        cast(coalesce(term_summary.term_count, 0) as bigint) as term_count,
        cast(latest_terms.term_id as bigint) as latest_term_id,
        cast(latest_terms.term_effective_date as date) as latest_term_effective_date,
        cast(latest_terms.term_expiration_date as date) as latest_term_expiration_date,
        cast(latest_terms.term_status as varchar) as latest_term_status,
        cast(latest_terms.cancellation_effective_date as date) as latest_cancellation_effective_date,
        cast(latest_terms.cancellation_reason as varchar) as latest_cancellation_reason,
        cast(policies.policyholder_id as bigint) as policyholder_id,
        cast(policyholders.first_name as varchar) as policyholder_first_name,
        cast(policyholders.last_name as varchar) as policyholder_last_name,
        cast(policyholders.date_of_birth as date) as policyholder_date_of_birth,
        cast(policyholders.address_state as varchar) as policyholder_address_state,
        cast(policyholders.address_zip as varchar) as policyholder_address_zip,
        -- Exposure units on the policy now: vehicles for AUTO, the dwelling for HOME.
        cast(coalesce(vehicle_summary.vehicle_count, 0) as bigint) as vehicle_count,
        cast(coalesce(dwelling_ranked.dwelling_count, 0) as bigint) as dwelling_count,
        cast(dwelling_ranked.dwelling_id as bigint) as dwelling_id,
        cast(dwelling_ranked.year_built as integer) as dwelling_year_built,
        cast(dwelling_ranked.construction_type as varchar) as dwelling_construction_type,
        cast(dwelling_ranked.square_feet as integer) as dwelling_square_feet,
        cast(dwelling_ranked.coverage_a_limit as decimal(12, 2)) as dwelling_coverage_a_limit,
        cast(policies.created_at as timestamp) as created_at,
        cast(policies.updated_at as timestamp) as updated_at
    from policies
    left join policyholders
        on policies.policyholder_id = policyholders.policyholder_id
    left join term_summary
        on policies.policy_id = term_summary.policy_id
    left join latest_terms
        on policies.policy_id = latest_terms.policy_id
    left join vehicle_summary
        on policies.policy_id = vehicle_summary.policy_id
    left join dwelling_ranked
        on policies.policy_id = dwelling_ranked.policy_id
        and dwelling_ranked.dwelling_rank = 1
    where not policies.is_test_policy
)

select * from final
