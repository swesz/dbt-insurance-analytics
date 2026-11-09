-- Each premium transaction's written premium equals the sum of its coverage lines, and every
-- transaction has lines (raw contract, loader/raw_schema.sql). The premium models earn and
-- book at the line level, so a header whose lines do not add up would make the subledger
-- disagree with the transaction totals the billing system invoices from.

with transactions as (
    select * from {{ ref('stg_policy_admin__policy_transactions') }}
),

lines as (
    select * from {{ ref('stg_policy_admin__policy_transaction_lines') }}
),

line_totals as (
    select
        transaction_id,
        count(*) as line_count,
        sum(written_premium) as line_written_premium
    from lines
    group by 1
)

select
    coalesce(transactions.transaction_id, line_totals.transaction_id) as transaction_id,
    transactions.written_premium as header_written_premium,
    line_totals.line_written_premium,
    coalesce(line_totals.line_count, 0) as line_count
from transactions
full outer join line_totals
    on transactions.transaction_id = line_totals.transaction_id
where transactions.transaction_id is null
    or line_totals.transaction_id is null
    or transactions.written_premium <> line_totals.line_written_premium
