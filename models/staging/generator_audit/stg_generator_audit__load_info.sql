-- The valuation date of the load, one row: the last day the generator simulated, which on the
-- default load is the last day the source data covers.
--
-- Every model that states something "at the valuation date" (in force, earned, aged, the
-- triangle's latest diagonal) cross joins this model, so the date always comes from the data it
-- is applied to. It used to be a var in dbt_project.yml: data generated with another
-- --valuation-date then built on the var's date instead, past the end of the data (D-024).
--
-- generator_audit is otherwise the answer key, and models must not read it. load_info is load
-- metadata rather than an answer, and only its valuation_date is passed on: a real warehouse
-- would take the same fact from its pipeline's load metadata or a reporting calendar.

with load_info as (
    select * from {{ source('generator_audit', 'load_info') }}
),

final as (
    select
        valuation_date
    from load_info
)

select * from final
