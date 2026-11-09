-- One row per coverage, from seeds/coverages.csv. A policy's premium is split by coverage
-- because coverages differ in what they pay for (liability to others vs. damage to the
-- insured's own property) and in which annual statement line they are reported on.

with coverages as (
    select * from {{ ref('coverages') }}
),

final as (
    select
        coverage_code,
        coverage_name,
        line_of_business,
        coverage_group,
        annual_statement_line,
        annual_statement_line_name,
        is_liability,
        -- What one unit of exposure is for the coverage (docs/source-systems.md 3a).
        case line_of_business
            when 'AUTO' then 'VEHICLE'
            when 'HOME' then 'DWELLING'
        end as exposure_unit
    from coverages
)

select * from final
