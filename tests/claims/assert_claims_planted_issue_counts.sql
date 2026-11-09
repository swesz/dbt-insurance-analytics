-- The number of rows the claims models remove or flag for each planted defect equals the number
-- the generator planted (raw.generator_audit.planted_issues, docs/data-issues.md). A count that
-- is too low means a defect slips through; too high means clean rows are being caught.
--
--   DELETED_CLAIMS            claim and exposure keys whose latest version is a delete (dropped)
--   CDC_DUPLICATE_VERSIONS    raw rows collapsed as re-loaded copies of a version, per table
--   ORPHAN_CLAIMS             claims with no matching policy (kept, flagged)
--   MALFORMED_POLICY_NUMBERS  raw claim rows whose typed policy number staging had to normalize,
--                             rerun copies included: the generator counts every loaded row
--   LOSS_OUTSIDE_TERM         claims whose loss date no covering term includes (kept, flagged)
--   REOPENED_CLAIMS           claims with a REOPENED version: dim_claims.was_reopened, plus the
--                             test-policy and deleted claims dim_claims leaves out
--
-- The planted counts describe the default (valuation-date) load, so the comparison runs only on
-- that load (load_info.as_of equals the control totals' as_of) and passes with no rows otherwise.
{% set cdc_tables = [
    ('claims', 'claim_id'),
    ('claim_exposures', 'exposure_id'),
    ('claim_transactions', 'claim_transaction_id'),
    ('adjusters', 'adjuster_id'),
] %}

with load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

control_totals as (
    select * from {{ source('generator_audit', 'control_totals') }}
),

planted_issues as (
    select * from {{ source('generator_audit', 'planted_issues') }}
),

claims_source as (
    select * from {{ source('claims', 'claims') }}
),

claim_versions as (
    select * from {{ ref('stg_claims__claim_versions') }}
),

claims as (
    select * from {{ ref('dim_claims') }}
),

is_default_load as (
    select exists (
        select 1
        from load_info
        inner join control_totals
            on load_info.as_of = control_totals.as_of
    ) as is_default_load
),

expected as (
    select
        issue_code,
        source_table,
        record_count
    from planted_issues
    where issue_code in (
        'DELETED_CLAIMS', 'CDC_DUPLICATE_VERSIONS', 'ORPHAN_CLAIMS',
        'MALFORMED_POLICY_NUMBERS', 'LOSS_OUTSIDE_TERM', 'REOPENED_CLAIMS'
    )
),

exposure_versions as (
    {{ claims_cdc_versions(source('claims', 'claim_exposures'), 'exposure_id') }}
),

actual as (
    select 'DELETED_CLAIMS' as issue_code, 'claims.claims' as source_table, count(*) as record_count
    from claim_versions
    where is_latest_version and is_deleted

    union all

    select 'DELETED_CLAIMS', 'claims.claim_exposures', count(*)
    from exposure_versions
    where is_latest_version and coalesce(__deleted, false)

    {% for table_name, key in cdc_tables %}
    union all

    -- Raw rows minus the distinct versions staging keeps.
    select
        'CDC_DUPLICATE_VERSIONS',
        'claims.{{ table_name }}',
        (select count(*) from {{ source('claims', table_name) }})
        - (select count(*) from ({{ claims_cdc_versions(source('claims', table_name), key) }}))
    {% endfor %}

    union all

    select 'ORPHAN_CLAIMS', 'claims.claims', count(*)
    from claims
    where not has_matching_policy

    union all

    -- A claim typed with a bad number keeps it in later versions; staging normalizes each one.
    -- The generator counts raw rows, so a version a rerun loaded twice (CDC_DUPLICATE_VERSIONS)
    -- counts twice. Counting staging's deduplicated versions instead agrees only while no rerun
    -- copy happens to fall on a malformed version (true at seed 42, not at seed 1). So each raw
    -- row is counted, with the flag of the version it collapses into: the copies of a version
    -- are identical (assert_cdc_duplicate_versions_are_exact), so they share its flag.
    select 'MALFORMED_POLICY_NUMBERS', 'claims.claims', count(*)
    from claims_source
    inner join claim_versions
        on claims_source.claim_id = claim_versions.claim_id
        and claims_source.updated_at = claim_versions.updated_at
    where claim_versions.is_policy_number_malformed

    union all

    select 'LOSS_OUTSIDE_TERM', 'claims.claims', count(*)
    from claims
    where is_loss_outside_term

    union all

    -- The generator counts every claim that ever had a REOPENED version, test-policy claims
    -- included (one at seed 42). The real claims are counted through dim_claims.was_reopened,
    -- the flag under test; it must come from the version history, because a claim that
    -- reopened and closed again is CLOSED in its current state. The reopened claims dim_claims
    -- leaves out (test-policy or deleted) are added from the history directly.
    select
        'REOPENED_CLAIMS',
        'claims.claims',
        (select count(*) from claims where was_reopened)
        + (
            select count(distinct claim_versions.claim_id)
            from claim_versions
            where claim_versions.claim_status = 'REOPENED'
                and not exists (
                    select 1
                    from claims
                    where claims.claim_id = claim_versions.claim_id
                )
        )
),

compared as (
    select
        expected.issue_code,
        expected.source_table,
        expected.record_count as planted_count,
        actual.record_count as model_count
    from expected
    left join actual
        on expected.issue_code = actual.issue_code
        and expected.source_table = actual.source_table
)

select *
from compared
where planted_count is distinct from model_count
    and (select is_default_load from is_default_load)
