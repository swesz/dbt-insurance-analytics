-- Claim exposures in their current state. An exposure is one coverage and one claimant on a
-- claim (a collision claim can have a COLL exposure for our insured's car and a PD exposure for
-- the other driver's). Reserves and payments are held per exposure.
-- Latest version per exposure_id; keys whose latest version is a delete are dropped
-- (DELETED_CLAIMS deletes the exposures of a deleted claim too).
with claim_exposures_source as (
    select * from {{ source('claims', 'claim_exposures') }}
),

distinct_versions as (
    {{ claims_cdc_versions('claim_exposures_source', 'exposure_id') }}
),

final as (
    select
        exposure_id,
        claim_id,
        coverage_code,
        claimant_type,
        exposure_status,
        exposure_status = 'OPEN' as is_open,
        opened_at,
        closed_at,
        version_number as version_count,
        updated_at,
        _rivery_last_update as loaded_at
    from distinct_versions
    where is_latest_version
        and not coalesce(__deleted, false)
)

select * from final
