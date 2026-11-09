-- One row per coverage line of a premium transaction. The line is the grain premium is
-- earned at: each coverage earns over its own window.
--
-- No is_test_policy flag here: lines carry no policy_id, and staging does not join. The
-- intermediate model takes the flag from the transaction header.
with source as (
    select * from {{ source('policy_admin', 'policy_transaction_lines') }}
),

final as (
    select
        transaction_line_id,
        transaction_id,
        coverage_code,
        written_premium
    from source
    where not coalesce(_fivetran_deleted, false)
)

select * from final
