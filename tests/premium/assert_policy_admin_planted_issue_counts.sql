-- The number of rows the policy_admin staging models remove or flag for each planted defect
-- equals the number the generator planted (raw.generator_audit.planted_issues,
-- docs/data-issues.md). Too low means a defect slips through; too high means clean rows are
-- being caught.
--
--   SOFT_DELETED_POLICYHOLDERS  raw rows staging drops as _fivetran_deleted
--   SOFT_DELETED_POLICIES       same, for policies
--   TEST_POLICIES               policies and policyholders staging flags as QA test records
--   BACKDATED_ENDORSEMENTS      endorsements effective before their transaction_date
--   LATE_ENTERED_TRANSACTIONS   transactions entered 1-20 days after their transaction_date
--
-- The planted counts describe the default (valuation-date) load, so the comparison runs only on
-- that load (load_info.as_of equals the control totals' as_of) and passes with no rows otherwise.

with load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

control_totals as (
    select * from {{ source('generator_audit', 'control_totals') }}
),

planted_issues as (
    select * from {{ source('generator_audit', 'planted_issues') }}
),

policyholders as (
    select * from {{ ref('stg_policy_admin__policyholders') }}
),

policies as (
    select * from {{ ref('stg_policy_admin__policies') }}
),

transactions as (
    select * from {{ ref('stg_policy_admin__policy_transactions') }}
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
    where source_table like 'policy_admin.%'
),

actual as (
    select
        'SOFT_DELETED_POLICYHOLDERS' as issue_code,
        'policy_admin.policyholders' as source_table,
        (select count(*) from {{ source('policy_admin', 'policyholders') }})
        - (select count(*) from policyholders) as record_count

    union all

    select
        'SOFT_DELETED_POLICIES',
        'policy_admin.policies',
        (select count(*) from {{ source('policy_admin', 'policies') }})
        - (select count(*) from policies)

    union all

    select 'TEST_POLICIES', 'policy_admin.policies', count(*)
    from policies
    where is_test_policy

    union all

    select 'TEST_POLICIES', 'policy_admin.policyholders', count(*)
    from policyholders
    where is_test_record

    union all

    select 'BACKDATED_ENDORSEMENTS', 'policy_admin.policy_transactions', count(*)
    from transactions
    where transaction_type = 'ENDORSEMENT'
        and is_backdated

    union all

    select 'LATE_ENTERED_TRANSACTIONS', 'policy_admin.policy_transactions', count(*)
    from transactions
    where {{ dbt.datediff('transaction_date', 'cast(created_at as date)', 'day') }} between 1 and 20
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
