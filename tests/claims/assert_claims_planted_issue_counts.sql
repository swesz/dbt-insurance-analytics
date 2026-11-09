-- The number of rows the claims models remove or flag for each planted defect equals the number
-- the generator planted (raw.generator_audit.planted_issues, docs/data-issues.md). A count that
-- is too low means a defect slips through; too high means clean rows are being caught.
--
--   DELETED_CLAIMS            claim and exposure keys whose latest version is a delete (dropped)
--   CDC_DUPLICATE_VERSIONS    raw rows collapsed as re-loaded copies of a version, per table
--   ORPHAN_CLAIMS             claims with no matching policy (kept, flagged)
--   MALFORMED_POLICY_NUMBERS  claims whose typed policy number needed normalizing
--   LOSS_OUTSIDE_TERM         claims whose loss date no covering term includes (kept, flagged)
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

claim_versions as (
    select * from {{ ref('stg_claims__claim_versions') }}
),

staged_claims as (
    select * from {{ ref('stg_claims__claims') }}
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
        'MALFORMED_POLICY_NUMBERS', 'LOSS_OUTSIDE_TERM'
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

    select 'MALFORMED_POLICY_NUMBERS', 'claims.claims', count(*)
    from staged_claims
    where is_policy_number_malformed

    union all

    select 'LOSS_OUTSIDE_TERM', 'claims.claims', count(*)
    from claims
    where is_loss_outside_term
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
