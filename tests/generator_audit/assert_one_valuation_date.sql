-- The valuation date has exactly one row (stg_generator_audit__load_info, D-024).
--
-- Every model that uses the date cross joins that one-row model. With no row, each of them
-- would come out empty without an error; with two, each would double its rows. unique and
-- not_null on the column cannot see either case. The loader writes one row per load, and
-- dbt build runs this test before any model that reads the date, so a broken load stops the
-- build there.
with load_info as (
    select * from {{ ref('stg_generator_audit__load_info') }}
),

final as (
    select count(*) as row_count
    from load_info
    having count(*) <> 1
)

select * from final
