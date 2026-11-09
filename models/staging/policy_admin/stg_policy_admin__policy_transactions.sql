-- One row per premium transaction (the header). Rows never change once written: a correction
-- is a new transaction, which is what makes written premium auditable.
with source as (
    select * from {{ source('policy_admin', 'policy_transactions') }}
),

final as (
    select
        transaction_id,
        policy_id,
        term_id,
        transaction_type,
        -- transaction_date decides the accounting period (with created_at, see the booking
        -- rule); effective_date decides when the coverage change starts to earn.
        transaction_date,
        effective_date,
        written_premium,
        -- A backdated change takes effect before the date it is dated. Its already-elapsed
        -- earning is caught up in the period it is booked in (docs/source-systems.md 3d).
        coalesce(effective_date < transaction_date, false) as is_backdated,
        {{ premium_is_test_policy('policy_id') }} as is_test_policy,
        -- When the transaction was keyed in. Together with the period close dates this decides
        -- whether it still made its own month's books.
        created_at
    from source
    where not coalesce(_fivetran_deleted, false)
)

select * from final
