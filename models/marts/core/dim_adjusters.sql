-- One row per adjuster in their current state, with their current caseload. Adjusters without
-- claims stay in the dimension: a dimension lists every member, used or not.
with adjusters as (
    select * from {{ ref('stg_claims__adjusters') }}
),

claims as (
    select * from {{ ref('stg_claims__claims') }}
),

caseloads as (
    select
        adjuster_id,
        count(*) as assigned_claim_count,
        count(*) filter (where is_open) as open_claim_count
    from claims
    where not is_test_policy_claim
    group by adjuster_id
),

final as (
    select
        adjusters.adjuster_id,
        adjusters.adjuster_name,
        adjusters.team,
        adjusters.is_active,
        adjusters.hired_date,
        coalesce(caseloads.assigned_claim_count, 0) as assigned_claim_count,
        coalesce(caseloads.open_claim_count, 0) as open_claim_count,
        adjusters.updated_at
    from adjusters
    left join caseloads
        on adjusters.adjuster_id = caseloads.adjuster_id
)

select * from final
