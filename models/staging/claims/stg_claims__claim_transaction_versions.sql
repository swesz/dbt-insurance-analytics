-- Every distinct version of every claim financial transaction.
-- A transaction row is written once and normally never changes. The exception is a voided
-- payment: the source overwrites the payment with transaction_status = 'VOIDED' and voided_at
-- (VOIDED_PAYMENTS), so a voided payment has two versions here, POSTED and then VOIDED. The
-- current state (stg_claims__claim_transactions) keeps only the VOIDED one, which still carries
-- the original amount and dates, and int_claims__financial_events builds the reversal from it.
with claim_transactions_source as (
    select * from {{ source('claims', 'claim_transactions') }}
),

distinct_versions as (
    {{ claims_cdc_versions('claim_transactions_source', 'claim_transaction_id') }}
),

final as (
    select
        claim_transaction_id,
        version_number,
        claim_id,
        exposure_id,
        transaction_type,
        cost_category,
        expense_type,
        reserve_reason,
        amount,
        transaction_date,
        transaction_status,
        voided_at,
        created_at,
        updated_at,
        valid_to,
        is_latest_version,
        coalesce(__deleted, false) as is_deleted,
        _rivery_last_update as loaded_at,
        _rivery_run_id as load_run_id
    from distinct_versions
)

select * from final
