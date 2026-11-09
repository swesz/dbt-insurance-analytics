-- Every distinct version of every claim, with codes normalized: the claim's full history.
-- The CDC log already holds the history, so this plays the role a dbt snapshot plays for the
-- Fivetran tables: [updated_at, valid_to) is the time each version was the current state.
-- stg_claims__claims is the latest version per claim; dim_claims uses this history for
-- was_reopened.
with claims_source as (
    select * from {{ source('claims', 'claims') }}
),

claim_status_map as (
    select * from {{ ref('claim_status_map') }}
),

distinct_versions as (
    {{ claims_cdc_versions('claims_source', 'claim_id') }}
),

normalized as (
    select
        *,
        -- Policy numbers are typed by hand (MALFORMED_POLICY_NUMBERS): 'pa-0001234',
        -- 'PA0001234', ' PA-0001234 '. Keeping only letters and digits and upper-casing gives
        -- 'PA0001234' for all of them, which is then rebuilt as 'PA-0001234' below.
        upper(regexp_replace(policy_number, '[^A-Za-z0-9]', '', 'g')) as policy_number_compact
    from distinct_versions
),

final as (
    select
        normalized.claim_id,
        normalized.version_number,
        normalized.claim_number,
        -- A value that does not reduce to two letters and seven digits stays null instead of
        -- being guessed at; the not_null test on policy_number then fails loudly.
        case
            when regexp_matches(normalized.policy_number_compact, '^[A-Z]{2}[0-9]{7}$')
                then left(normalized.policy_number_compact, 2)
                    || '-' || right(normalized.policy_number_compact, 7)
        end as policy_number,
        normalized.policy_number as source_policy_number,
        normalized.loss_date,
        normalized.reported_at,
        -- INCONSISTENT_CODE_CASING: ' Hail', 'collision', 'tx'.
        upper(trim(normalized.loss_cause)) as loss_cause,
        upper(trim(normalized.loss_state)) as loss_state,
        nullif(upper(trim(normalized.catastrophe_code)), '') as catastrophe_code,
        -- LEGACY_STATUS_CODES: versions written before the 2023-07-01 system upgrade say
        -- 'O', 'C', 'R'. The seed maps both generations onto one set of statuses.
        claim_status_map.claim_status,
        claim_status_map.is_open,
        normalized.claim_status as source_claim_status,
        normalized.closed_at,
        normalized.adjuster_id,
        normalized.updated_at,
        normalized.valid_to,
        normalized.is_latest_version,
        coalesce(normalized.__deleted, false) as is_deleted,
        normalized._rivery_last_update as loaded_at,
        normalized._rivery_run_id as load_run_id
    from normalized
    left join claim_status_map
        on upper(trim(normalized.claim_status)) = claim_status_map.source_status
),

flagged as (
    select
        *,
        -- The raw value differs from the clean one (whitespace, case or a missing dash).
        source_policy_number is distinct from policy_number as is_policy_number_malformed,
        -- QA reserves policy_id 9000000 and up for test policies, and the policy number's
        -- digits are the policy_id (docs/source-systems.md 3h). That lets staging flag test
        -- claims from the claim row alone, without joining to policies.
        coalesce(cast(right(policy_number, 7) as integer) >= 9000000, false) as is_test_policy_claim
    from final
)

select * from flagged
