-- One row per general ledger journal line, typed, from the latest export file of each
-- accounting period. This is the ledger as the ERP holds it, which the subledgers are
-- reconciled to (rpt_subledger_gl_reconciliation).
with source as (
    select * from {{ source('general_ledger', 'journal_lines') }}
),

-- GL_FILE_REEXPORTED: when a period's export is corrected, the ERP writes the whole period
-- again as a new file (gl_export_2025_03_v2.csv), and the file connector loads it next to the
-- first one. The new file replaces the old one as a whole, so the choice is made per file, not
-- per line: deduplicating lines on (journal_id, line_number) would keep lines that the
-- correction removed, and pick between changed lines arbitrarily.
--
-- Tiebreak, which file is "latest": the newest file modification time (_modified), because a
-- re-export is by definition written after the export it corrects. If two files ever had the
-- same _modified, the later load (_fivetran_synced), then the file name in reverse order, decide,
-- so the result never depends on the order DuckDB happens to read rows in. The file name alone
-- would be a weak rule: it sorts '_v2' after '.csv' by luck of ASCII ('_' > '.'), and '_v10'
-- before '_v2'.
files as (
    select
        trim(accounting_period) as accounting_period,
        _file as source_file_name,
        max(_modified) as file_modified_at,
        max(_fivetran_synced) as file_synced_at
    from source
    group by 1, 2
),

latest_files as (
    select
        accounting_period,
        source_file_name
    from files
    qualify row_number() over (
        partition by accounting_period
        order by file_modified_at desc, file_synced_at desc, source_file_name desc
    ) = 1
),

parsed as (
    select
        trim(source.journal_id) as journal_id,
        cast(trim(source.line_number) as integer) as line_number,
        trim(source.accounting_period) as accounting_period,
        -- US-format text, 'MM/DD/YYYY'. strptime is DuckDB's parser (another warehouse would
        -- use parse_date or to_date); it fails on text that does not match, which is what we
        -- want for a date the ledger depends on.
        cast(strptime(trim(source.posting_date), '%m/%d/%Y') as date) as posting_date,
        trim(source.account_number) as account_number,
        upper(trim(source.line_of_business)) as line_of_business,
        {{ accounting_parse_gl_amount('source.debit') }} as debit_amount,
        {{ accounting_parse_gl_amount('source.credit') }} as credit_amount,
        upper(trim(source.source_system)) as source_system,
        source.description,
        source._file as source_file_name,
        source._line as source_file_line,
        source._modified as file_modified_at,
        source._fivetran_synced as synced_at
    from source
    inner join latest_files
        on trim(source.accounting_period) = latest_files.accounting_period
        and source._file = latest_files.source_file_name
),

final as (
    select
        journal_id,
        line_number,
        accounting_period,
        posting_date,
        account_number,
        line_of_business,
        debit_amount,
        credit_amount,
        -- Signed, debit positive and credit negative: the convention every accounting model
        -- here uses, so that a balanced entry sums to zero and the subledger postings compare
        -- with a plain subtraction.
        debit_amount - credit_amount as net_amount,
        source_system,
        description,
        source_file_name,
        source_file_line,
        file_modified_at,
        synced_at
    from parsed
)

select * from final
