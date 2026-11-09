-- The general ledger file dedupe removes exactly the rows the generator planted as
-- GL_FILE_REEXPORTED (raw.generator_audit.planted_issues): the lines of the superseded
-- 2025-03 export. Fewer means a superseded file survived and the period is counted twice;
-- more means lines of a valid file were dropped.
--
-- The planted count describes the default (valuation-date) load, so the comparison runs only on
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

raw_lines as (
    select * from {{ source('general_ledger', 'journal_lines') }}
),

staged_lines as (
    select * from {{ ref('stg_general_ledger__journal_lines') }}
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
    select sum(record_count) as record_count
    from planted_issues
    where issue_code = 'GL_FILE_REEXPORTED'
),

actual as (
    select (select count(*) from raw_lines) - (select count(*) from staged_lines) as record_count
)

select
    expected.record_count as planted_count,
    actual.record_count as removed_count
from expected
cross join actual
where expected.record_count is distinct from actual.record_count
    and (select is_default_load from is_default_load)
