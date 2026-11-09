-- Claim financial transactions in their current state: the latest version per
-- claim_transaction_id, without keys whose latest version is a delete (see stg_claims__claims
-- for why the delete filter comes after picking the latest version).
with claim_transaction_versions as (
    select * from {{ ref('stg_claims__claim_transaction_versions') }}
),

final as (
    select
        claim_transaction_id,
        claim_id,
        exposure_id,
        transaction_type,
        cost_category,
        expense_type,
        reserve_reason,
        amount,
        transaction_date,
        transaction_status,
        transaction_status = 'VOIDED' as is_voided,
        voided_at,
        created_at,
        updated_at,
        loaded_at
    from claim_transaction_versions
    where is_latest_version
        and not is_deleted
)

select * from final
