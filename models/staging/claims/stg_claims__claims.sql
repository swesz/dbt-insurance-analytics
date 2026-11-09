-- Claims in their current state: the latest version of each claim_id.
-- A claim deleted in the source (DELETED_CLAIMS: duplicate first notices of loss) has a delete
-- as its latest version and is dropped. The order matters: pick the latest version first and
-- then drop deletes. Dropping deletes first would bring back the version before the delete.
-- Test-policy claims are kept and flagged (is_test_policy_claim); intermediate models and marts
-- exclude them.
with claim_versions as (
    select * from {{ ref('stg_claims__claim_versions') }}
),

final as (
    select
        claim_id,
        claim_number,
        policy_number,
        source_policy_number,
        is_policy_number_malformed,
        is_test_policy_claim,
        loss_date,
        reported_at,
        loss_cause,
        loss_state,
        catastrophe_code,
        claim_status,
        is_open,
        source_claim_status,
        closed_at,
        adjuster_id,
        version_number as version_count,
        updated_at,
        loaded_at
    from claim_versions
    where is_latest_version
        and not is_deleted
)

select * from final
